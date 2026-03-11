#!/usr/bin/env bash
# ===========================================================================
# Pre-flight checks for Katonic Platform installation
#
# Validates:
#   - Required CLI tools are installed
#   - Cloud provider CLI is authenticated
#   - DNS resolution for target domain
#   - Sufficient disk space
#   - License file validity
#   - Network/registry connectivity (or air-gap bundle)
#   - Kubernetes cluster access (if bare_metal)
#
# Usage:
#   ./pre-flight.sh /path/to/katonic.yml
# ===========================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

CONFIG="${1:-/katonic/katonic.yml}"

log_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
log_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
log_warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; WARN=$((WARN + 1)); }

# ---------------------------------------------------------------------------
# Parse config
# ---------------------------------------------------------------------------
parse_config() {
  if [ ! -f "$CONFIG" ]; then
    log_fail "Config file not found: $CONFIG"
    exit 1
  fi

  CLOUD=$(python3 -c "
import yaml
with open('$CONFIG') as f:
    c = yaml.safe_load(f)
print(c.get('cloud_provider', 'bare_metal'))
")
  DOMAIN=$(python3 -c "
import yaml
with open('$CONFIG') as f:
    c = yaml.safe_load(f)
print(c.get('domain', ''))
")
  AIRGAP=$(python3 -c "
import yaml
with open('$CONFIG') as f:
    c = yaml.safe_load(f)
print(str(c.get('airgap_enabled', False)).lower())
")
  LICENSE_FILE=$(python3 -c "
import yaml
with open('$CONFIG') as f:
    c = yaml.safe_load(f)
print(c.get('license_file', '/katonic/license.json'))
")
}

# ---------------------------------------------------------------------------
# Check: Required tools
# ---------------------------------------------------------------------------
check_tools() {
  echo ""
  echo "=== Required Tools ==="

  for tool in kubectl helm jq python3; do
    if command -v "$tool" &>/dev/null; then
      log_pass "$tool installed ($(command -v "$tool"))"
    else
      log_fail "$tool not found"
    fi
  done

  # Terraform only needed for cloud-provisioned clusters
  if [ "$CLOUD" != "bare_metal" ] && [ "$CLOUD" != "azure" ]; then
    if command -v terraform &>/dev/null; then
      log_pass "terraform installed"
    else
      log_fail "terraform required for $CLOUD cluster provisioning"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check: Cloud CLI authentication
# ---------------------------------------------------------------------------
check_cloud_auth() {
  echo ""
  echo "=== Cloud Authentication ==="

  case "$CLOUD" in
    aws)
      if aws sts get-caller-identity &>/dev/null; then
        log_pass "AWS CLI authenticated"
      else
        log_fail "AWS CLI not authenticated (run: aws configure)"
      fi
      ;;
    azure)
      if az account show &>/dev/null; then
        log_pass "Azure CLI authenticated"
      else
        log_fail "Azure CLI not authenticated (run: az login)"
      fi
      ;;
    gcp)
      if gcloud auth print-identity-token &>/dev/null; then
        log_pass "GCP CLI authenticated"
      else
        log_fail "GCP CLI not authenticated (run: gcloud auth login)"
      fi
      ;;
    oci)
      if oci iam region list &>/dev/null; then
        log_pass "OCI CLI authenticated"
      else
        log_fail "OCI CLI not authenticated (run: oci setup config)"
      fi
      ;;
    alibaba)
      if aliyun ecs DescribeRegions &>/dev/null; then
        log_pass "Alibaba CLI authenticated"
      else
        log_fail "Alibaba CLI not authenticated (run: aliyun configure)"
      fi
      ;;
    bare_metal)
      if kubectl cluster-info &>/dev/null; then
        log_pass "kubectl connected to existing cluster"
      else
        log_fail "kubectl not connected (set KUBECONFIG)"
      fi
      ;;
    *)
      log_fail "Unknown cloud_provider: $CLOUD"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Check: DNS resolution
# ---------------------------------------------------------------------------
check_dns() {
  echo ""
  echo "=== DNS ==="

  if [ -n "$DOMAIN" ]; then
    if host "$DOMAIN" &>/dev/null || nslookup "$DOMAIN" &>/dev/null 2>&1; then
      log_pass "Domain $DOMAIN resolves"
    else
      log_warn "Domain $DOMAIN does not resolve (will be configured during install)"
    fi
  else
    log_warn "No domain configured in katonic.yml"
  fi
}

# ---------------------------------------------------------------------------
# Check: Disk space
# ---------------------------------------------------------------------------
check_disk() {
  echo ""
  echo "=== Disk Space ==="

  local available_gb
  available_gb=$(df -BG /tmp | awk 'NR==2 {gsub(/G/,""); print $4}')

  if [ "$available_gb" -ge 50 ]; then
    log_pass "Disk space: ${available_gb}GB available (50GB minimum)"
  elif [ "$available_gb" -ge 20 ]; then
    log_warn "Disk space: ${available_gb}GB available (50GB recommended)"
  else
    log_fail "Disk space: ${available_gb}GB available (50GB minimum required)"
  fi
}

# ---------------------------------------------------------------------------
# Check: License file
# ---------------------------------------------------------------------------
check_license() {
  echo ""
  echo "=== License ==="

  if [ ! -f "$LICENSE_FILE" ]; then
    log_warn "License file not found: $LICENSE_FILE (platform will run in dev mode)"
    return
  fi

  # Check JSON validity
  if ! python3 -c "import json; json.load(open('$LICENSE_FILE'))" 2>/dev/null; then
    log_fail "License file is not valid JSON"
    return
  fi

  # Check required fields
  local has_payload has_sig
  has_payload=$(python3 -c "
import json
d = json.load(open('$LICENSE_FILE'))
print('yes' if 'payload' in d else 'no')
")
  has_sig=$(python3 -c "
import json
d = json.load(open('$LICENSE_FILE'))
print('yes' if 'signature' in d else 'no')
")

  if [ "$has_payload" = "yes" ] && [ "$has_sig" = "yes" ]; then
    log_pass "License file is valid signed format"
  else
    log_fail "License file missing 'payload' or 'signature' field"
    return
  fi

  # Check expiry
  local expires
  expires=$(python3 -c "
import json
from datetime import datetime, timezone
d = json.load(open('$LICENSE_FILE'))
exp = d['payload'].get('expires_at', '')
if exp:
    dt = datetime.fromisoformat(exp.replace('Z', '+00:00'))
    now = datetime.now(timezone.utc)
    if dt > now:
        print(f'valid (expires {exp})')
    else:
        print(f'expired ({exp})')
else:
    print('no expiry field')
")

  if echo "$expires" | grep -q "^valid"; then
    log_pass "License $expires"
  elif echo "$expires" | grep -q "^expired"; then
    log_fail "License $expires"
  else
    log_warn "License: $expires"
  fi
}

# ---------------------------------------------------------------------------
# Check: Registry connectivity / air-gap bundle
# ---------------------------------------------------------------------------
check_registry() {
  echo ""
  echo "=== Registry / Air-Gap ==="

  if [ "$AIRGAP" = "true" ]; then
    local bundle
    bundle=$(python3 -c "
import yaml
with open('$CONFIG') as f:
    c = yaml.safe_load(f)
print(c.get('image_bundle', '/katonic/images.tar.gz'))
")
    if [ -f "$bundle" ]; then
      local size_gb
      size_gb=$(du -BG "$bundle" | awk '{gsub(/G/,""); print $1}')
      log_pass "Air-gap image bundle found: $bundle (${size_gb}GB)"
    else
      log_fail "Air-gap enabled but image bundle not found: $bundle"
    fi
  else
    if curl -sf --max-time 10 "https://registry.katonic.ai/v2/" &>/dev/null; then
      log_pass "Registry registry.katonic.ai is reachable"
    else
      log_warn "Cannot reach registry.katonic.ai (may need VPN or air-gap mode)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo "============================================"
  echo " Katonic Platform - Pre-flight Checks"
  echo "============================================"
  echo " Config: $CONFIG"

  parse_config

  echo " Cloud:  $CLOUD"
  echo " Domain: $DOMAIN"
  echo " Air-gap: $AIRGAP"

  check_tools
  check_cloud_auth
  check_dns
  check_disk
  check_license
  check_registry

  echo ""
  echo "============================================"
  echo -e " Results: ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}, ${YELLOW}${WARN} warn${NC}"
  echo "============================================"

  if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}Pre-flight checks failed. Fix the issues above before proceeding.${NC}"
    exit 1
  fi

  echo ""
  echo -e "${GREEN}All pre-flight checks passed. Ready to install.${NC}"
}

main "$@"
