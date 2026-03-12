#!/usr/bin/env bash
# =============================================================================
# Katonic 7.0 — Helm Deploy Script
# =============================================================================
# Usage:  ./helm-deploy.sh <command> [options]
#
# Commands:
#   deploy      Full install / upgrade  (creates secrets, configmap, then Helm)
#   upgrade     Re-run Helm upgrade only (secrets/configmap already exist)
#   template    Dry-run render to stdout
#   lint        Lint the Helm chart
#   diff        Show what would change (requires helm-diff plugin)
#   status      Show pods, deployments, PVCs, Istio resources
#   logs        Tail logs for a service  (--service <name>)
#   restart     Rolling restart all deployments
#   uninstall   Remove Helm release, keep PVCs
#   purge       Remove Helm release + delete all PVCs  ⚠ DESTRUCTIVE
#
# Options:
#   --domain     Your platform domain  e.g. platform.mycompany.com  [REQUIRED]
#   --env        dev | staging | production  (default: production)
#   --registry   Image registry prefix  e.g. "katonic.azurecr.io/"
#   --tag        Image tag  (default: latest)
#   --cert       Path to TLS .crt file  (default: ./platform.crt)
#   --key        Path to TLS .key file  (default: ./platform.key)
#   --dry-run    Helm server dry-run — no changes applied
#   --debug      Verbose Helm output
#   --service    Service name for logs command
#
# CI/CD env vars (skip interactive prompts when set):
#   KATONIC_DB_PASSWORD        Postgres password
#   KATONIC_CLICKHOUSE_PASS    ClickHouse password
#   KATONIC_KC_ADMIN_PASS      Keycloak bootstrap admin password
#   KATONIC_KC_CLIENT_SECRET   Keycloak client secret
#   KATONIC_ADMIN_EMAIL        Platform super-admin email
#   KATONIC_ADMIN_PASSWORD     Platform super-admin password
#   KATONIC_REGISTRY_USER      Registry username
#   KATONIC_REGISTRY_PASS      Registry password
#   KATONIC_SMTP_PASS          SMTP password  (only needed if smtp.enabled=true)
# =============================================================================
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/helm/katonic"
VALUES_FILE="$CHART_DIR/values.yaml"

# ── Defaults ──────────────────────────────────────────────────────────────────
RELEASE_NAME="katonic"
NAMESPACE="katonic"
ENV="production"
DOMAIN=""
REGISTRY=""
TAG="latest"
CERT_FILE="$SCRIPT_DIR/platform.crt"
KEY_FILE="$SCRIPT_DIR/platform.key"
DRY_RUN=false
DEBUG_FLAG=""
SERVICE=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
heading() { echo -e "\n${BOLD}$*${NC}"; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)       ENV="$2";       shift 2 ;;
    --domain)    DOMAIN="$2";    shift 2 ;;
    --registry)  REGISTRY="$2";  shift 2 ;;
    --tag)       TAG="$2";       shift 2 ;;
    --cert)      CERT_FILE="$2"; shift 2 ;;
    --key)       KEY_FILE="$2";  shift 2 ;;
    --dry-run)   DRY_RUN=true;   shift   ;;
    --debug)     DEBUG_FLAG="--debug"; shift ;;
    --service)   SERVICE="$2";   shift 2 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

case "$ENV" in dev|staging|production) ;; *) error "Unknown env '$ENV'. Use: dev|staging|production" ;; esac

# ── Resolve domain ────────────────────────────────────────────────────────────
resolve_domain() {
  if [[ -z "$DOMAIN" ]]; then
    local yaml_domain
    yaml_domain=$(grep '^domain:' "$VALUES_FILE" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
    if [[ -z "$yaml_domain" || "$yaml_domain" == "preview.katonic.ai" ]]; then
      echo ""
      warn "No --domain provided and values.yaml still has the default placeholder."
      read -rp "  Enter your platform domain (e.g. platform.mycompany.com): " DOMAIN
      [[ -n "$DOMAIN" ]] || error "Domain is required."
    else
      DOMAIN="$yaml_domain"
      info "Domain from values.yaml: $DOMAIN"
    fi
  fi
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  command -v helm    >/dev/null 2>&1 || error "helm not found — https://helm.sh/docs/intro/install/"
  command -v kubectl >/dev/null 2>&1 || error "kubectl not found"
  command -v base64  >/dev/null 2>&1 || error "base64 not found"

  [[ -d "$CHART_DIR"  ]] || error "Chart directory not found: $CHART_DIR"
  [[ -f "$VALUES_FILE" ]] || error "Values file not found: $VALUES_FILE"

  if [[ "$COMMAND" != "template" && "$COMMAND" != "lint" ]]; then
    kubectl cluster-info >/dev/null 2>&1 \
      || error "Cannot reach Kubernetes cluster — check your kubeconfig"
    info "Cluster:     $(kubectl config current-context)"
  fi

  info "Helm:        $(helm version --short)"
  info "Chart:       $CHART_DIR"
  info "Environment: $ENV"
  info "Domain:      ${DOMAIN:-not set}"
  info "Registry:    ${REGISTRY:-DockerHub (default)}"
  info "Tag:         $TAG"
}

# ── Collect all secrets interactively (or from env vars) ─────────────────────
declare -A SECRETS   # key=k8s-secret-key  value=plaintext

collect_secrets() {
  heading "━━ Collecting credentials ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Secrets are written to the 'platform-secret' Kubernetes Secret."
  echo "  They are NEVER stored in values.yaml or any file."
  echo "  Set the CI/CD env vars listed in the script header to skip prompts."
  echo ""

  # Helper: prompt for password with confirmation; or read from env var
  prompt_pass() {
    local key="$1" label="$2" envvar="$3" min="${4:-12}"
    if [[ -n "${!envvar:-}" ]]; then
      SECRETS[$key]="${!envvar}"
      info "  $label: (from env \$$envvar)"
      return
    fi
    local val confirm
    while true; do
      read -rsp "  $label (min ${min} chars): " val; echo ""
      [[ ${#val} -ge $min ]] || { warn "Too short. Minimum $min characters."; continue; }
      read -rsp "  Confirm $label: " confirm; echo ""
      [[ "$val" == "$confirm" ]] && break || warn "Mismatch — try again."
    done
    SECRETS[$key]="$val"
  }

  # Helper: prompt for plain value; or read from env var
  prompt_val() {
    local key="$1" label="$2" envvar="$3" default="${4:-}"
    if [[ -n "${!envvar:-}" ]]; then
      SECRETS[$key]="${!envvar}"
      info "  $label: (from env \$$envvar)"
      return
    fi
    local val
    read -rp "  $label${default:+ [$default]}: " val
    SECRETS[$key]="${val:-$default}"
  }

  # ── Postgres ────────────────────────────────────────────────────────────────
  step "PostgreSQL"
  SECRETS[POSTGRES_USER]="platform"
  SECRETS[POSTGRES_DB]="platform"
  info "  User: platform  |  DB: platform  (fixed)"
  prompt_pass POSTGRES_PASSWORD "Postgres password" KATONIC_DB_PASSWORD 12

  # ── ClickHouse ──────────────────────────────────────────────────────────────
  step "ClickHouse"
  prompt_pass CLICKHOUSE_PASSWORD "ClickHouse password" KATONIC_CLICKHOUSE_PASS 12

  # ── Keycloak bootstrap admin (used only by Keycloak pod itself) ─────────────
  step "Keycloak bootstrap admin  (Keycloak pod internal admin)"
  SECRETS[KEYCLOAK_ADMIN_USER]="admin"
  info "  Admin user: admin  (fixed)"
  prompt_pass KEYCLOAK_ADMIN_PASSWORD "Keycloak bootstrap admin password" KATONIC_KC_ADMIN_PASS 12

  # ── Keycloak client secret ──────────────────────────────────────────────────
  step "Keycloak API client secret"
  if [[ -n "${KATONIC_KC_CLIENT_SECRET:-}" ]]; then
    SECRETS[KEYCLOAK_CLIENT_SECRET]="$KATONIC_KC_CLIENT_SECRET"
    info "  Client secret: (from env)"
  else
    # Auto-generate if not provided
    local gen_secret
    gen_secret=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
    read -rp "  Keycloak client secret [auto-generate]: " val
    SECRETS[KEYCLOAK_CLIENT_SECRET]="${val:-$gen_secret}"
    [[ -z "$val" ]] && info "  Auto-generated client secret."
  fi

  # ── Platform super-admin (created in Keycloak by seed-keycloak job) ─────────
  step "Platform super-admin user  (login to Katonic platform)"
  prompt_val  KATONIC_ADMIN_EMAIL    "Admin email"    KATONIC_ADMIN_EMAIL    "admin@katonic.ai"
  prompt_pass KATONIC_ADMIN_PASSWORD "Admin password" KATONIC_ADMIN_PASSWORD 12

  # ── SMTP (optional) ─────────────────────────────────────────────────────────
  local smtp_enabled
  smtp_enabled=$(grep 'smtp:' "$VALUES_FILE" -A1 | grep 'enabled:' | awk '{print $2}' || echo "false")
  if [[ "$smtp_enabled" == "true" ]]; then
    step "SMTP password  (smtp.enabled=true in values.yaml)"
    prompt_pass SMTP_PASSWORD "SMTP password" KATONIC_SMTP_PASS 6
  fi
}

# ── Write platform-secret ─────────────────────────────────────────────────────
create_platform_secret() {
  step "Creating / updating platform-secret"

  local args=()
  for key in "${!SECRETS[@]}"; do
    args+=("--from-literal=${key}=${SECRETS[$key]}")
  done

  # Delete and recreate (idempotent, avoids partial patch issues)
  kubectl delete secret platform-secret -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl create secret generic platform-secret \
    -n "$NAMESPACE" \
    "${args[@]}"

  info "platform-secret created with ${#SECRETS[@]} keys."
}

# ── Write platform-config ConfigMap ──────────────────────────────────────────
create_platform_configmap() {
  step "Creating / updating platform-config ConfigMap"

  local smtp_enabled smtp_host smtp_port smtp_user smtp_from smtp_ssl smtp_auth
  smtp_enabled=$(grep -A20 '^smtp:' "$VALUES_FILE" | grep 'enabled:' | awk '{print $2}' || echo "false")
  smtp_host=$(grep -A20 '^smtp:' "$VALUES_FILE" | grep 'host:' | awk '{print $2}' | tr -d '"' || echo "")
  smtp_port=$(grep -A20 '^smtp:' "$VALUES_FILE" | grep 'port:' | awk '{print $2}' || echo "465")
  smtp_user=$(grep -A20 '^smtp:' "$VALUES_FILE" | grep 'user:' | awk '{print $2}' | tr -d '"' || echo "")
  smtp_from=$(grep -A20 '^smtp:' "$VALUES_FILE" | grep 'from:' | awk '{print $2}' | tr -d '"' || echo "support@katonic.ai")
  smtp_ssl=$(grep -A20 '^smtp:' "$VALUES_FILE"  | grep 'ssl:'  | awk '{print $2}' || echo "true")
  smtp_auth=$(grep -A20 '^smtp:' "$VALUES_FILE" | grep 'auth:' | awk '{print $2}' || echo "true")

  local workspace_timeout
  workspace_timeout=$(grep '^workspaceTimeoutHours:' "$VALUES_FILE" | awk '{print $2}' | tr -d '"' || echo "12")

  kubectl delete configmap platform-config -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl create configmap platform-config \
    -n "$NAMESPACE" \
    --from-literal=POSTGRES_HOST=postgres \
    --from-literal=POSTGRES_PORT=5432 \
    --from-literal=POSTGRES_DB=platform \
    --from-literal=KEYCLOAK_SERVER_URL="https://${DOMAIN}/auth" \
    --from-literal=KEYCLOAK_REALM=platform \
    --from-literal=KEYCLOAK_AUDIENCE=platform-api \
    --from-literal=KEYCLOAK_ISSUER="https://${DOMAIN}/auth/realms/platform" \
    --from-literal=MILVUS_URI="http://milvus:19530" \
    --from-literal=PLATFORM_ENVIRONMENT="$ENV" \
    --from-literal=ADMIN_API_URL="http://admin-api:8000" \
    --from-literal=WORKSPACE_TIMEOUT_HOURS="$workspace_timeout" \
    --from-literal=SMTP_ENABLED="$smtp_enabled" \
    --from-literal=SMTP_HOST="$smtp_host" \
    --from-literal=SMTP_PORT="$smtp_port" \
    --from-literal=SMTP_USER="$smtp_user" \
    --from-literal=SMTP_FROM="$smtp_from" \
    --from-literal=SMTP_SSL="$smtp_ssl" \
    --from-literal=SMTP_AUTH="$smtp_auth"

  info "platform-config ConfigMap created."
  info "  KEYCLOAK_ISSUER  = https://${DOMAIN}/auth/realms/platform"
  info "  SMTP_ENABLED     = $smtp_enabled"
  info "  WORKSPACE_TIMEOUT= ${workspace_timeout}h"
}

# ── Create imagePullSecret for registry ──────────────────────────────────────
create_registry_secret() {
  step "Creating / updating dockerhub-secret (imagePullSecret)"

  local reg_server reg_user reg_pass

  if [[ -n "${KATONIC_REGISTRY_USER:-}" && -n "${KATONIC_REGISTRY_PASS:-}" ]]; then
    reg_user="$KATONIC_REGISTRY_USER"
    reg_pass="$KATONIC_REGISTRY_PASS"
    info "  Registry credentials from env."
  else
    echo ""
    echo "  Docker registry credentials are needed to pull Katonic images."
    echo "  Registry: ${REGISTRY:-registry-1.docker.io}"
    read -rp "  Registry username: " reg_user
    read -rsp "  Registry password: " reg_pass; echo ""
  fi

  if [[ -n "$REGISTRY" ]]; then
    # Strip trailing slash for server URL
    reg_server="${REGISTRY%/}"
  else
    reg_server="registry-1.docker.io"
  fi

  kubectl delete secret dockerhub-secret -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl create secret docker-registry dockerhub-secret \
    -n "$NAMESPACE" \
    --docker-server="$reg_server" \
    --docker-username="$reg_user" \
    --docker-password="$reg_pass"

  info "dockerhub-secret created for server: $reg_server"
}

# ── Create TLS secret for Istio Gateway ──────────────────────────────────────
create_tls_secret() {
  step "Creating / updating kt-certs TLS secret (Istio Gateway)"

  # Check if already exists and not being forced
  if kubectl get secret kt-certs -n istio-system >/dev/null 2>&1; then
    info "kt-certs already exists in istio-system — skipping."
    info "  To replace: kubectl delete secret kt-certs -n istio-system"
    return
  fi

  # Find cert/key files
  if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
    echo ""
    warn "TLS certificate files not found at default paths:"
    warn "  cert: $CERT_FILE"
    warn "  key:  $KEY_FILE"
    echo ""
    echo "  Options:"
    echo "  1. Place your .crt and .key files in the same directory as this script"
    echo "     and name them platform.crt and platform.key"
    echo "  2. Pass paths explicitly: --cert /path/to/cert.crt --key /path/to/key.key"
    echo "  3. Use a self-signed cert for testing (NOT for production)"
    echo ""
    read -rp "  Generate self-signed certificate for testing? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      CERT_FILE="/tmp/katonic-selfsigned.crt"
      KEY_FILE="/tmp/katonic-selfsigned.key"
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=${DOMAIN}/O=Katonic" \
        -addext "subjectAltName=DNS:${DOMAIN}" \
        2>/dev/null
      warn "Self-signed cert generated. Replace with a real cert for production."
    else
      warn "Skipping kt-certs creation. Istio Gateway will not serve HTTPS until this is created."
      warn "Run when ready:"
      warn "  kubectl create secret tls kt-certs --cert=<cert.crt> --key=<cert.key> -n istio-system"
      return
    fi
  fi

  kubectl create secret tls kt-certs \
    --cert="$CERT_FILE" \
    --key="$KEY_FILE" \
    -n istio-system

  info "kt-certs TLS secret created in istio-system."
}

# ── Build Helm --set overrides ────────────────────────────────────────────────
build_set_args() {
  local sets=()

  [[ -n "$DOMAIN" ]] && sets+=("--set" "domain=${DOMAIN}")

  if [[ -n "$REGISTRY" ]]; then
    local services=(adminApi agentApi agentRuntime aiGateway evalEngine
                    governanceProxy guardrailsEngine knowledgeEngine mcpGateway
                    modelDeploymentService observability platformBackend
                    remoteConnections workspaceService)
    for svc in "${services[@]}"; do
      local svc_name
      svc_name=$(echo "$svc" | sed 's/\([A-Z]\)/-\L\1/g' | sed 's/^-//')
      sets+=("--set" "${svc}.image.repository=${REGISTRY}${svc_name}")
    done
    sets+=("--set" "frontend.image.repository=${REGISTRY}katonic-frontend")
    sets+=("--set" "image.seedAll=${REGISTRY}seed-all:${TAG}")
  fi

  if [[ "$TAG" != "latest" ]]; then
    local img_svcs=(adminApi agentApi agentRuntime aiGateway evalEngine
                    governanceProxy guardrailsEngine knowledgeEngine mcpGateway
                    modelDeploymentService observability platformBackend
                    remoteConnections workspaceService)
    for svc in "${img_svcs[@]}"; do
      sets+=("--set" "${svc}.image.tag=${TAG}")
    done
    sets+=("--set" "frontend.image.tag=${TAG}")
  fi

  case "$ENV" in
    dev)
      sets+=("--set" "global.imagePullPolicy=Always")
      sets+=("--set" "knowledgeEngine.debug=true")
      sets+=("--set" "governanceProxy.resources.requests.memory=256Mi")
      sets+=("--set" "guardrailsEngine.resources.requests.memory=256Mi")
      ;;
    staging)
      sets+=("--set" "global.imagePullPolicy=Always")
      ;;
    production)
      [[ -n "$REGISTRY" ]] && sets+=("--set" "global.imagePullPolicy=Always")
      ;;
  esac

  echo "${sets[@]+${sets[@]}}"
}

# ── Helm lint ─────────────────────────────────────────────────────────────────
cmd_lint() {
  step "Linting Helm chart"
  helm lint "$CHART_DIR" --values "$VALUES_FILE" $DEBUG_FLAG
  info "Lint passed."
}

# ── Helm template (dry-run render) ───────────────────────────────────────────
cmd_template() {
  step "Rendering templates (dry-run)"
  local set_args; set_args=$(build_set_args)
  helm template "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" \
    ${set_args} $DEBUG_FLAG
}

# ── Full deploy ───────────────────────────────────────────────────────────────
cmd_deploy() {
  resolve_domain
  preflight
  cmd_lint

  # ── Namespace + Istio label ──────────────────────────────────────────────
  step "Ensuring namespace '$NAMESPACE'"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

  # ── Secrets & ConfigMap ──────────────────────────────────────────────────
  collect_secrets
  create_platform_secret
  create_platform_configmap
  create_registry_secret
  create_tls_secret

  # ── Helm install/upgrade ─────────────────────────────────────────────────
  step "Running helm upgrade --install"
  local set_args; set_args=$(build_set_args)
  local dry_run_flag=""
  $DRY_RUN && dry_run_flag="--dry-run=server" && step "DRY RUN — no changes will be applied"

  helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" \
    ${set_args} \
    --timeout 10m \
    --atomic \
    --cleanup-on-fail \
    --wait \
    ${dry_run_flag} \
    $DEBUG_FLAG

  $DRY_RUN && { info "Dry-run complete."; return; }

  # ── Wait for infra ───────────────────────────────────────────────────────
  step "Waiting for infrastructure StatefulSets"
  for sts in postgres redis clickhouse; do
    info "  Waiting for $sts..."
    kubectl rollout status statefulset/$sts -n "$NAMESPACE" --timeout=240s \
      || warn "$sts not ready — check: kubectl logs statefulset/$sts -n $NAMESPACE"
  done

  step "Waiting for Keycloak"
  kubectl rollout status deployment/keycloak -n "$NAMESPACE" --timeout=300s \
    || warn "Keycloak not ready yet"

  # ── Seed jobs ────────────────────────────────────────────────────────────
  local set_args_local; set_args_local=$(build_set_args)

  step "Running seed-keycloak job  (realm + super admin)"
  kubectl delete job seed-keycloak -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  helm template "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" --values "$VALUES_FILE" ${set_args_local} \
    --show-only templates/jobs/seed-keycloak.yaml | kubectl apply -f -
  kubectl wait --for=condition=complete job/seed-keycloak -n "$NAMESPACE" --timeout=300s \
    || warn "seed-keycloak timed out — check: kubectl logs job/seed-keycloak -n $NAMESPACE"

  step "Running seed-all job  (platform database)"
  kubectl delete job seed-all -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  helm template "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" --values "$VALUES_FILE" ${set_args_local} \
    --show-only templates/jobs/seed-all.yaml | kubectl apply -f -
  kubectl wait --for=condition=complete job/seed-all -n "$NAMESPACE" --timeout=300s \
    || warn "seed-all timed out — check: kubectl logs job/seed-all -n $NAMESPACE"

  step "Running migration job"
  kubectl delete job migrate-add-starred-chats -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  helm template "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" --values "$VALUES_FILE" ${set_args_local} \
    --show-only templates/jobs/migrate-add-starred-chats.yaml | kubectl apply -f -
  kubectl wait --for=condition=complete job/migrate-add-starred-chats \
    -n "$NAMESPACE" --timeout=120s || warn "Migration timed out"

  # ── Restart for Istio sidecar injection ─────────────────────────────────
  step "Restarting deployments (Istio sidecar injection)"
  kubectl rollout restart deployment -n "$NAMESPACE"

  step "Waiting for all services"
  local backends=(admin-api agent-api agent-runtime ai-gateway eval-engine
                  governance-proxy guardrails-engine knowledge-engine mcp-gateway
                  model-deployment-service observability platform-backend
                  remote-connections workspace-service katonic-frontend keycloak)
  for svc in "${backends[@]}"; do
    kubectl rollout status deployment/$svc -n "$NAMESPACE" --timeout=300s \
      || warn "$svc not ready yet"
  done

  echo ""
  info "✅  Katonic 7.0 deployment complete!"
  cmd_status
  cmd_urls
}

# ── Upgrade only (skip secret/configmap creation) ────────────────────────────
cmd_upgrade() {
  resolve_domain
  preflight
  cmd_lint
  step "Helm upgrade (skipping secret/configmap creation)"
  local set_args; set_args=$(build_set_args)
  helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" \
    ${set_args} \
    --timeout 10m --atomic --cleanup-on-fail --wait \
    $DEBUG_FLAG
  info "Upgrade complete."
}

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
  step "Release status"
  helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || warn "Release not found"

  echo ""; info "=== Pods ===";         kubectl get pods        -n "$NAMESPACE" -o wide 2>/dev/null || echo "  (none)"
  echo ""; info "=== Deployments ===";  kubectl get deployments -n "$NAMESPACE" 2>/dev/null        || echo "  (none)"
  echo ""; info "=== StatefulSets ==="; kubectl get statefulsets -n "$NAMESPACE" 2>/dev/null       || echo "  (none)"
  echo ""; info "=== PVCs ===";         kubectl get pvc          -n "$NAMESPACE" 2>/dev/null       || echo "  (none)"
  echo ""; info "=== Istio ===";
  kubectl get virtualservices,destinationrules,gateways,peerauthentication \
    -n "$NAMESPACE" 2>/dev/null || echo "  (none)"
}

# ── URLs ──────────────────────────────────────────────────────────────────────
cmd_urls() {
  local d="${DOMAIN:-$(grep '^domain:' "$VALUES_FILE" | awk '{print $2}' | tr -d '"' || echo 'your-domain')}"
  step "Platform URLs"
  echo ""
  echo "  🌐  https://${d}              — Platform home"
  echo "  💬  https://${d}/ace          — ACE workspace"
  echo "  🤖  https://${d}/studio/agents — Agent Studio"
  echo "  📊  https://${d}/dashboard    — Operations Dashboard"
  echo "  🔑  https://${d}/auth/admin   — Keycloak admin console"
  echo ""

  local ip=""
  ip=$(kubectl get svc istio-ingressgateway -n istio-system \
       -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [[ -n "$ip" ]]; then
    info "Istio ingress IP: $ip"
    echo ""
    echo "  ── DNS record required ──────────────────────────────────────"
    echo "  Create an A record:"
    echo "    ${d}  →  ${ip}"
    echo ""
    echo "  To test before DNS propagates:"
    echo "    curl -k --resolve ${d}:443:${ip} https://${d}/healthz"
    echo "  ─────────────────────────────────────────────────────────────"
  else
    # Check if pending — could be on-premise without cloud LB
    local lb_status
    lb_status=$(kubectl get svc istio-ingressgateway -n istio-system \
                -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null || true)
    if [[ -z "$lb_status" ]]; then
      warn "No LoadBalancer IP assigned to istio-ingressgateway."
      echo ""
      echo "  If you are on a bare-metal / on-premise cluster without a cloud"
      echo "  LoadBalancer, you need MetalLB:"
      echo ""
      echo "    helm repo add metallb https://metallb.github.io/metallb"
      echo "    helm install metallb metallb/metallb -n metallb-system --create-namespace"
      echo ""
      echo "  Then configure an IPAddressPool and L2Advertisement for your LAN subnet."
      echo "  Once MetalLB assigns an IP, re-run:  ./helm-deploy.sh urls"
    else
      echo "  Run: kubectl get svc istio-ingressgateway -n istio-system"
    fi
  fi
}

# ── Logs ─────────────────────────────────────────────────────────────────────
cmd_logs() {
  [[ -z "$SERVICE" ]] && error "Use --service <name>  e.g. --service admin-api"
  kubectl logs -n "$NAMESPACE" "deployment/$SERVICE" --tail=150 -f
}

# ── Diff ─────────────────────────────────────────────────────────────────────
cmd_diff() {
  helm plugin list 2>/dev/null | grep -q diff \
    || error "helm-diff not installed: helm plugin install https://github.com/databus23/helm-diff"
  resolve_domain
  local set_args; set_args=$(build_set_args)
  helm diff upgrade "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" --values "$VALUES_FILE" ${set_args} $DEBUG_FLAG
}

# ── Restart ───────────────────────────────────────────────────────────────────
cmd_restart() {
  step "Rolling restart of all deployments in '$NAMESPACE'"
  kubectl rollout restart deployment -n "$NAMESPACE"
  info "Restart triggered. Watch: kubectl get pods -n $NAMESPACE -w"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
  warn "This removes the Helm release '$RELEASE_NAME' but KEEPS PVCs (data safe)."
  read -rp "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" $DEBUG_FLAG || true
  info "Release removed. PVCs retained."
}

# ── Purge ─────────────────────────────────────────────────────────────────────
cmd_purge() {
  warn "⚠️  DESTRUCTIVE — removes the release AND deletes all PVCs (all data lost)."
  read -rp "Type 'yes-delete-everything' to confirm: " ans
  [[ "$ans" == "yes-delete-everything" ]] || { info "Cancelled."; exit 0; }
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" $DEBUG_FLAG || true
  kubectl delete pvc --all -n "$NAMESPACE" || true
  kubectl delete namespace "$NAMESPACE" --timeout=60s || true
  info "Purge complete."
}

# ── Help ──────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF

${BOLD}Katonic 7.0 — Helm Deploy Script${NC}

${BOLD}USAGE${NC}
  $0 <command> [options]

${BOLD}COMMANDS${NC}
  deploy      Full install:  creates secrets/configmap → Helm install → seed jobs
  upgrade     Helm upgrade only  (secrets/configmap already exist)
  template    Render all manifests to stdout  (no cluster needed)
  lint        Lint the Helm chart
  diff        What would change vs current release  (needs helm-diff plugin)
  status      Pods, deployments, PVCs, Istio resources
  logs        Tail logs for a service  (--service <name>)
  urls        Show platform URLs and DNS instructions
  restart     Rolling restart all deployments
  uninstall   Remove Helm release, keep PVCs
  purge       Remove Helm release + delete all PVCs  ⚠ DESTRUCTIVE

${BOLD}OPTIONS${NC}
  --domain     Platform domain  e.g. platform.mycompany.com  [REQUIRED for deploy]
  --env        dev | staging | production  (default: production)
  --registry   Image registry prefix  e.g. "katonic.azurecr.io/"
  --tag        Image tag  (default: latest)
  --cert       TLS certificate .crt file  (default: ./platform.crt)
  --key        TLS private key .key file  (default: ./platform.key)
  --dry-run    Helm server dry-run — no changes applied
  --debug      Verbose Helm output
  --service    Service name for the logs command

${BOLD}CI/CD ENV VARS  (skip interactive prompts)${NC}
  KATONIC_DB_PASSWORD        Postgres password
  KATONIC_CLICKHOUSE_PASS    ClickHouse password
  KATONIC_KC_ADMIN_PASS      Keycloak bootstrap admin password
  KATONIC_KC_CLIENT_SECRET   Keycloak client secret
  KATONIC_ADMIN_EMAIL        Platform super-admin email
  KATONIC_ADMIN_PASSWORD     Platform super-admin password
  KATONIC_REGISTRY_USER      Registry username
  KATONIC_REGISTRY_PASS      Registry password
  KATONIC_SMTP_PASS          SMTP password  (only if smtp.enabled=true)

${BOLD}EXAMPLES${NC}

  # First deploy — prompts for all credentials
  $0 deploy --domain platform.mycompany.com --env production

  # Deploy with ACR images at a specific tag + TLS cert
  $0 deploy --domain platform.mycompany.com \\
            --registry katonic.azurecr.io/ --tag v7.0.1 \\
            --cert ./certs/platform.crt --key ./certs/platform.key

  # CI/CD pipeline  (no prompts)
  export KATONIC_DB_PASSWORD="\$DB_PASS"
  export KATONIC_CLICKHOUSE_PASS="\$CH_PASS"
  export KATONIC_KC_ADMIN_PASS="\$KC_PASS"
  export KATONIC_KC_CLIENT_SECRET="\$KC_SECRET"
  export KATONIC_ADMIN_EMAIL="admin@mycompany.com"
  export KATONIC_ADMIN_PASSWORD="\$ADMIN_PASS"
  export KATONIC_REGISTRY_USER="\$REG_USER"
  export KATONIC_REGISTRY_PASS="\$REG_PASS"
  $0 deploy --domain platform.mycompany.com \\
            --registry katonic.azurecr.io/ --tag \$BUILD_TAG

  # Preview render output
  $0 template --domain platform.mycompany.com > /tmp/rendered.yaml

  # Show what a tag bump would change
  $0 diff --domain platform.mycompany.com --tag v7.0.2

  # Tail logs
  $0 logs --service governance-proxy

  # Remove platform (keep data)
  $0 uninstall

EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$COMMAND" in
  deploy)    cmd_deploy    ;;
  upgrade)   cmd_upgrade   ;;
  template)  cmd_template  ;;
  lint)      cmd_lint      ;;
  diff)      cmd_diff      ;;
  status)    cmd_status    ;;
  logs)      cmd_logs      ;;
  urls)      cmd_urls      ;;
  restart)   cmd_restart   ;;
  uninstall) cmd_uninstall ;;
  purge)     cmd_purge     ;;
  help|--help|-h) cmd_help ;;
  *) error "Unknown command '$COMMAND'. Run '$0 help'." ;;
esac
