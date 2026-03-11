#!/usr/bin/env bash
# ============================================================================
# Katonic AI Platform v7.0 - Installer Entrypoint
# ============================================================================
# This is the main entry point for the installer Docker container.
# It runs pre-flight checks, then hands off to Ansible.
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

INVENTORY_FILE="/inventory/katonic.yml"
LICENSE_FILE=""
PLATFORM_VERSION="${PLATFORM_VERSION:-7.0.0}"

# ============================================================================
# Banner
# ============================================================================
echo ""
echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}  Katonic AI Platform v${PLATFORM_VERSION} Installer${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""

# ============================================================================
# Validate inventory file exists
# ============================================================================
if [[ ! -f "$INVENTORY_FILE" ]]; then
    log_error "Configuration file not found at $INVENTORY_FILE"
    log_error "Mount your config: docker run -v /path/to/inventory:/inventory ..."
    exit 1
fi
log_ok "Configuration file found: $INVENTORY_FILE"

# ============================================================================
# Parse key config values (using python3 for safe YAML parsing)
# ============================================================================
parse_yaml() {
    python3 -c "
import yaml, sys
with open('$INVENTORY_FILE') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('$1', '${2:-}'))
"
}

DEPLOY_ON=$(parse_yaml deploy_on AWS)
CREATE_CLUSTER=$(parse_yaml create_k8s_cluster True)
CLUSTER_NAME=$(parse_yaml cluster_name katonic-v7)
LICENSE_PATH=$(parse_yaml license_file_path /inventory/license.json)
ADMIN_EMAIL=$(parse_yaml admin_email "")
AIR_GAP=$(parse_yaml air_gap False)
ENABLE_CHECKS=$(parse_yaml enable_pre_checks True)
DATABASE_MODE=$(parse_yaml database_mode in-cluster)
OBJECT_STORAGE=$(parse_yaml object_storage_mode auto)

log_info "Cloud provider:     $DEPLOY_ON"
log_info "Create cluster:     $CREATE_CLUSTER"
log_info "Cluster name:       $CLUSTER_NAME"
log_info "Admin email:        $ADMIN_EMAIL"
log_info "Database mode:      $DATABASE_MODE"
log_info "Object storage:     $OBJECT_STORAGE"
log_info "Air-gap mode:       $AIR_GAP"

# ============================================================================
# SCCC normalization: treat as Alibaba with Saudi endpoints
# ============================================================================
EFFECTIVE_CLOUD="$DEPLOY_ON"
if [[ "$DEPLOY_ON" == "SCCC" ]]; then
    EFFECTIVE_CLOUD="Alibaba"
    log_info "SCCC mode: Using Alibaba Cloud APIs with Saudi (me-riyadh) endpoints"
    # Inject SCCC-specific overrides
    export ALIBABA_REGION="me-riyadh"
    export SCCC_MODE="true"
    export DATA_RESIDENCY="saudi-arabia"
fi

# ============================================================================
# Air-gap enforcement
# ============================================================================
if [[ "$AIR_GAP" == "True" ]]; then
    log_warn "Air-gap mode enabled. Enforcing restrictions:"
    log_warn "  - database_mode forced to in-cluster"
    log_warn "  - object_storage_mode forced to minio"
    log_warn "  - tls_mode forced to custom"
    log_warn "  - No external network calls"

    if [[ ! -d "/root/airgap" ]]; then
        log_error "Air-gap mode requires /root/airgap directory with image bundles"
        exit 1
    fi
fi

# ============================================================================
# Validate license file
# ============================================================================
if [[ -n "$LICENSE_PATH" && -f "$LICENSE_PATH" ]]; then
    log_ok "License file found: $LICENSE_PATH"
    # Basic JSON validation
    if ! python3 -c "import json; json.load(open('$LICENSE_PATH'))" 2>/dev/null; then
        log_error "License file is not valid JSON"
        exit 1
    fi
    log_ok "License file is valid JSON"
else
    log_error "License file not found at: $LICENSE_PATH"
    log_error "Obtain a license from your Katonic Solutions Engineer"
    exit 1
fi

# ============================================================================
# Pre-flight checks
# ============================================================================
if [[ "$ENABLE_CHECKS" == "True" ]]; then
    log_info "Running pre-flight checks..."
    bash /root/katonic.sh "$EFFECTIVE_CLOUD" "$CREATE_CLUSTER"
    PREFLIGHT_RESULT=$?
    if [[ $PREFLIGHT_RESULT -ne 0 ]]; then
        log_error "Pre-flight checks failed. Fix the issues above and retry."
        exit 1
    fi
    log_ok "Pre-flight checks passed"
else
    log_warn "Pre-flight checks skipped (enable_pre_checks: False)"
fi

# ============================================================================
# Enhanced on-prem pre-checks (node sizing, storage, kube-system health)
# ============================================================================
if [[ "$DEPLOY_ON" == "On-Premise" && "$ENABLE_CHECKS" == "True" ]]; then
    log_info "Running enhanced on-premise cluster checks..."
    bash /root/scripts/pre-check-onprem.sh
    ONPREM_RESULT=$?
    if [[ $ONPREM_RESULT -ne 0 ]]; then
        log_warn "On-premise checks have warnings/failures — review above"
        # Don't exit — warnings are informational for on-prem
    fi
fi

# ============================================================================
# Configure private registry (air-gap)
# ============================================================================
if [[ "$AIR_GAP" == "True" ]]; then
    log_info "Loading air-gap images into private registry..."
    bash /root/scripts/load-airgap-images.sh
    log_ok "Air-gap images loaded"
fi

# ============================================================================
# Generate Terraform state backend (if configured)
# ============================================================================
log_info "Generating Terraform backend configuration..."
python3 /root/scripts/generate-tf-backend.py "${INVENTORY_FILE}" /root/terraform 2>&1 || true

# ============================================================================
# Run Ansible playbook
# ============================================================================
log_info "Starting Ansible deployment..."
echo ""

cd /root/ansible

ansible-playbook playbook.yml \
    -e "@${INVENTORY_FILE}" \
    -e "platform_version=${PLATFORM_VERSION}" \
    -e "effective_cloud=${EFFECTIVE_CLOUD}" \
    -e "sccc_mode=${SCCC_MODE:-false}" \
    -e "installer_root=/root" \
    "$@"

ANSIBLE_RESULT=$?

echo ""
if [[ $ANSIBLE_RESULT -eq 0 ]]; then
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${GREEN}  Katonic AI Platform v${PLATFORM_VERSION} installed successfully!${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    echo ""
    log_ok "Tenant-manager is bootstrapping the platform."
    log_ok "Admin email will be sent to: $ADMIN_EMAIL"
    echo ""
else
    echo -e "${RED}=======================================================${NC}"
    echo -e "${RED}  Installation failed. Check logs above.${NC}"
    echo -e "${RED}=======================================================${NC}"
    exit 1
fi
