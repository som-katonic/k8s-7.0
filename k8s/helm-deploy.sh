#!/usr/bin/env bash
# =============================================================================
# helm-deploy.sh — Katonic 7.0 platform installer
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
NAMESPACE="katonic"
RELEASE="katonic"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm/katonic"
# Bundled Istio 1.26.0 Helm charts — place the istio-1.26.0 folder here:
ISTIO_INSTALLER_DIR="${SCRIPT_DIR}/istio-installer/istio-1.26.0"
DOMAIN=""
SKIP_ISTIO=false
DRY_RUN=false

# Istio image hub — Katonic mirrors Istio images under quay.io/katonic
ISTIO_HUB="quay.io/katonic"
ISTIO_TAG="1.26.0"

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <command> [flags]

Commands:
  deploy      Full install / upgrade
  upgrade     Helm upgrade only (secrets/configmap already exist)
  delete      Uninstall release and namespace
  status      Show rollout status of all deployments

Flags:
  --domain      <fqdn>     Platform FQDN (required for deploy)  e.g. platform.acme.com
  --namespace   <ns>       Kubernetes namespace  (default: katonic)
  --release     <name>     Helm release name      (default: katonic)
  --skip-istio             Skip Istio install step (already installed on cluster)
  --dry-run                Helm --dry-run (template preview, no apply)
  --help                   Show this message

Istio installer:
  Place the istio-1.26.0 release folder at:
    <repo-root>/istio-installer/istio-1.26.0/
  The script uses its bundled Helm charts to install Istio before Katonic.

Environment variables (CI/CD — skip interactive prompts):
  KATONIC_POSTGRES_URL     Full postgres:// DSN  e.g. postgres://user:pass@host:5432/db
  KATONIC_REDIS_URL        redis://host:6379
  KATONIC_CLICKHOUSE_PASS  ClickHouse password
  KATONIC_DOCKERHUB_USER   DockerHub username
  KATONIC_DOCKERHUB_TOKEN  DockerHub token / password
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
COMMAND=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    deploy|upgrade|delete|status) COMMAND="$1"; shift ;;
    --domain)      DOMAIN="$2";    shift 2 ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --release)     RELEASE="$2";   shift 2 ;;
    --skip-istio)  SKIP_ISTIO=true; shift ;;
    --dry-run)     DRY_RUN=true;   shift ;;
    --help|-h)     usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

[[ -z "$COMMAND" ]] && { usage; exit 1; }

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prereqs() {
  for cmd in kubectl helm python3; do
    command -v "$cmd" &>/dev/null || { err "$cmd not found in PATH"; exit 1; }
  done
}

# ── Secret collection ─────────────────────────────────────────────────────────
collect_secrets() {
  info "Collecting deployment secrets..."

  # ── PostgreSQL ──
  if [[ -z "${KATONIC_POSTGRES_URL:-}" ]]; then
    echo ""
    echo "Enter the external PostgreSQL connection URL."
    echo "  Format: postgres://USER:PASSWORD@HOST:PORT/DBNAME"
    read -rsp "  POSTGRES_URL: " KATONIC_POSTGRES_URL
    echo ""
  fi

  # Validate it looks like a postgres URL
  if [[ ! "$KATONIC_POSTGRES_URL" =~ ^postgres(ql)?:// ]]; then
    err "KATONIC_POSTGRES_URL must start with postgres:// or postgresql://"
    exit 1
  fi

  # Parse host / port / db / user / pass from URL using Python
  read -r PG_HOST PG_PORT PG_DB PG_USER PG_PASS < <(python3 - "$KATONIC_POSTGRES_URL" <<'PYEOF'
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
print(u.hostname, u.port or 5432, u.path.lstrip('/'), u.username or '', u.password or '')
PYEOF
  )

  # ── Redis ──
  if [[ -z "${KATONIC_REDIS_URL:-}" ]]; then
    echo "Enter Redis URL (default: redis://redis:6379):"
    read -r _redis
    KATONIC_REDIS_URL="${_redis:-redis://redis:6379}"
  fi

  # ── ClickHouse ──
  if [[ -z "${KATONIC_CLICKHOUSE_PASS:-}" ]]; then
    read -rsp "ClickHouse password: " KATONIC_CLICKHOUSE_PASS
    echo ""
  fi

  # ── DockerHub (for image pull secret) ──
  if [[ -z "${KATONIC_DOCKERHUB_USER:-}" ]]; then
    read -rp "DockerHub username: " KATONIC_DOCKERHUB_USER
  fi
  if [[ -z "${KATONIC_DOCKERHUB_TOKEN:-}" ]]; then
    read -rsp "DockerHub token/password: " KATONIC_DOCKERHUB_TOKEN
    echo ""
  fi

  # ── Auto-generate crypto secrets ──
  GATEWAY_FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null \
    || python3 -c "import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")
  JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  RC_ENCRYPTION_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")

  success "Secrets collected."
}

# ── Namespace + imagePullSecret ───────────────────────────────────────────────
ensure_namespace() {
  kubectl get namespace "$NAMESPACE" &>/dev/null || {
    info "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
    kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite
  }
}

create_pull_secret() {
  info "Creating/updating DockerHub pull secret..."
  kubectl create secret docker-registry dockerhub-secret \
    --namespace "$NAMESPACE" \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="$KATONIC_DOCKERHUB_USER" \
    --docker-password="$KATONIC_DOCKERHUB_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# ── platform-config ConfigMap ────────────────────────────────────────────────
# NOTE: The ConfigMap is now a Helm template (templates/configmap.yaml).
# This function is kept only for out-of-band updates or pre-Helm bootstrap.
create_platform_configmap() {
  info "ConfigMap 'platform-config' is managed by Helm (templates/configmap.yaml)."
  info "Values flow: --set domain / --set postgres.host|port|db"
}

# ── platform-secret ───────────────────────────────────────────────────────────
create_platform_secret() {
  info "Creating/updating platform-secret..."

  # DATABASE_URL and POSTGRES_URL are the same full DSN
  # KE_POSTGRES_DSN uses the same DSN (knowledge-engine dialect)
  kubectl create secret generic platform-secret \
    --namespace "$NAMESPACE" \
    --from-literal=POSTGRES_URL="$KATONIC_POSTGRES_URL" \
    --from-literal=DATABASE_URL="$KATONIC_POSTGRES_URL" \
    --from-literal=KE_POSTGRES_DSN="$KATONIC_POSTGRES_URL" \
    --from-literal=REDIS_URL="$KATONIC_REDIS_URL" \
    --from-literal=KE_REDIS_URL="$KATONIC_REDIS_URL" \
    --from-literal=CLICKHOUSE_PASSWORD="$KATONIC_CLICKHOUSE_PASS" \
    --from-literal=CLICKHOUSE_USER="default" \
    --from-literal=GATEWAY_FERNET_KEY="$GATEWAY_FERNET_KEY" \
    --from-literal=JWT_SECRET="$JWT_SECRET" \
    --from-literal=RC_ENCRYPTION_KEY="$RC_ENCRYPTION_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  success "platform-secret applied."
}

# ── Install Istio using bundled Helm charts ───────────────────────────────────
apply_istio_system() {
  if [[ "$SKIP_ISTIO" == "true" ]]; then
    info "--skip-istio set; assuming Istio is already installed."
    return 0
  fi

  # Validate installer directory exists
  if [[ ! -d "$ISTIO_INSTALLER_DIR" ]]; then
    err "Istio installer not found at: $ISTIO_INSTALLER_DIR"
    err "Expected structure: istio-installer/istio-1.26.0/manifests/charts/"
    err "Place the istio-1.26.0 folder under istio-installer/ in the repo root."
    exit 1
  fi

  local BASE_CHART="${ISTIO_INSTALLER_DIR}/manifests/charts/base"
  local ISTIOD_CHART="${ISTIO_INSTALLER_DIR}/manifests/charts/istio-control/istio-discovery"
  local GATEWAY_CHART="${ISTIO_INSTALLER_DIR}/manifests/charts/gateway"

  for chart_path in "$BASE_CHART" "$ISTIOD_CHART" "$GATEWAY_CHART"; do
    [[ -d "$chart_path" ]] || {
      err "Required Istio chart not found: $chart_path"
      exit 1
    }
  done

  info "Creating istio-system namespace..."
  kubectl get namespace istio-system &>/dev/null \
    || kubectl create namespace istio-system

  # ── 1. Base (CRDs + ValidatingWebhook) ──────────────────────────────────────
  info "Installing Istio base (CRDs)..."
  helm upgrade --install istio-base "$BASE_CHART" \
    --namespace istio-system \
    --set defaultRevision=default \
    --wait --timeout 5m

  # ── 2. istiod (control plane) ────────────────────────────────────────────────
  info "Installing istiod (control plane)..."
  helm upgrade --install istiod "$ISTIOD_CHART" \
    --namespace istio-system \
    --set global.hub="${ISTIO_HUB}" \
    --set global.tag="${ISTIO_TAG}" \
    --set global.imagePullPolicy=IfNotPresent \
    --set pilot.autoscaleEnabled=true \
    --set pilot.autoscaleMin=1 \
    --set pilot.autoscaleMax=3 \
    --wait --timeout 10m

  info "Waiting for istiod rollout..."
  kubectl rollout status deployment/istiod -n istio-system --timeout=300s || {
    err "istiod did not become ready within 5 minutes."
    kubectl get pods -n istio-system
    exit 1
  }

  # ── 3. Ingress Gateway ───────────────────────────────────────────────────────
  info "Installing Istio ingressgateway..."
  helm upgrade --install istio-ingressgateway "$GATEWAY_CHART" \
    --namespace istio-system \
    --set global.hub="${ISTIO_HUB}" \
    --set global.tag="${ISTIO_TAG}" \
    --set global.imagePullPolicy=IfNotPresent \
    --set service.type=LoadBalancer \
    --set autoscaling.enabled=true \
    --set autoscaling.minReplicas=1 \
    --set autoscaling.maxReplicas=5 \
    --wait --timeout 5m

  # ── Label katonic namespace for sidecar injection ─────────────────────────
  info "Enabling sidecar injection on namespace ${NAMESPACE}..."
  kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite 2>/dev/null || true

  success "Istio 1.26.0 installed successfully."
}

# ── Wait helpers ──────────────────────────────────────────────────────────────
wait_for_deployment() {
  local name=$1
  info "Waiting for deployment/$name ..."
  kubectl rollout status deployment/"$name" -n "$NAMESPACE" --timeout=300s
}

run_job_and_wait() {
  local job_name=$1
  info "Waiting for job/$job_name ..."
  kubectl wait --for=condition=complete job/"$job_name" \
    -n "$NAMESPACE" --timeout=300s 2>/dev/null \
    || kubectl wait --for=condition=failed job/"$job_name" \
    -n "$NAMESPACE" --timeout=300s 2>/dev/null \
    || warn "Job $job_name did not complete within timeout — check logs."
}

# ── Helm install/upgrade ──────────────────────────────────────────────────────
run_helm() {
  [[ -z "$DOMAIN" ]] && { err "--domain is required for deploy/upgrade"; exit 1; }

  local helm_flags=(
    upgrade --install "$RELEASE" "$CHART_DIR"
    --namespace "$NAMESPACE"
    --create-namespace
    --set "domain=${DOMAIN}"
    --set "postgres.host=${PG_HOST:-localhost}"
    --set "postgres.port=${PG_PORT:-5432}"
    --set "postgres.db=${PG_DB:-platform}"
    --set "postgres.user=${PG_USER:-postgres}"
    --atomic
    --timeout 15m
  )

  [[ "$DRY_RUN" == "true" ]] && helm_flags+=(--dry-run)

  info "Running: helm ${helm_flags[*]}"
  helm "${helm_flags[@]}"
}

# ── Post-deploy checks ────────────────────────────────────────────────────────
post_deploy_checks() {
  info "Checking core deployments..."
  local deps=(admin-api agent-api ai-gateway knowledge-engine katonic-frontend platform-backend)
  for dep in "${deps[@]}"; do
    wait_for_deployment "$dep" || warn "Deployment $dep not yet ready — check: kubectl get pods -n $NAMESPACE"
  done

  info "Waiting for seed-all job..."
  run_job_and_wait "seed-all" || true

  info "Waiting for migrate-add-starred-chats job..."
  run_job_and_wait "migrate-add-starred-chats" || true
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_deploy() {
  check_prereqs
  collect_secrets
  ensure_namespace
  create_pull_secret
  create_platform_secret
  apply_istio_system
  run_helm
  [[ "$DRY_RUN" == "false" ]] && post_deploy_checks
  echo ""
  success "======================================================"
  success " Katonic 7.0 deployed successfully!"
  success " Platform URL: https://${DOMAIN}"
  success "======================================================"
}

cmd_upgrade() {
  check_prereqs
  [[ -z "$DOMAIN" ]] && { err "--domain is required"; exit 1; }
  run_helm
  [[ "$DRY_RUN" == "false" ]] && post_deploy_checks
}

cmd_delete() {
  warn "This will delete the Helm release '$RELEASE' and namespace '$NAMESPACE'."
  read -rp "Type 'yes' to confirm: " confirm
  [[ "$confirm" != "yes" ]] && { info "Aborted."; exit 0; }
  helm uninstall "$RELEASE" --namespace "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  info "Istio system namespace is NOT removed automatically."
  success "Release deleted."
}

cmd_status() {
  info "=== Pods ==="
  kubectl get pods -n "$NAMESPACE" -o wide
  echo ""
  info "=== Deployments ==="
  kubectl get deployments -n "$NAMESPACE"
  echo ""
  info "=== Jobs ==="
  kubectl get jobs -n "$NAMESPACE"
  echo ""
  info "=== Istio Gateway ==="
  kubectl get svc istio-ingressgateway -n istio-system 2>/dev/null || warn "Istio ingressgateway not found"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$COMMAND" in
  deploy)  cmd_deploy  ;;
  upgrade) cmd_upgrade ;;
  delete)  cmd_delete  ;;
  status)  cmd_status  ;;
esac


