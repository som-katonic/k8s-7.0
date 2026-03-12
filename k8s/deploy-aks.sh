#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Katonic Platform - AKS Deployment Script
# Usage: ./deploy-aks.sh [command]
#   Commands: build | deploy | status | urls | restart | teardown
# ─────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="katonic"
REGISTRY="${ACR_REGISTRY:-katonic.azurecr.io}"
OVERLAY="production"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# Services that use root build context (need platform-core/ and their own dir)
ROOT_CONTEXT_SERVICES=(
  admin-api
  agent-api
  agent-runtime
  observability
  guardrails-engine
  governance-proxy
  knowledge-engine
)

# Services that use their own directory as build context
SERVICE_CONTEXT_SERVICES=(
  mcp-gateway
  model-deployment-service
  workspace-service
  remote-connections
  platform-backend
  eval-engine
)

# ai-gateway uses root context but dockerfile is in ai-gateway-v2/
AI_GATEWAY_SERVICE="ai-gateway"
AI_GATEWAY_DOCKERFILE="ai-gateway-v2/Dockerfile"

# katonic-frontend: K8s image name is "katonic-frontend" but source dir is "platform-frontend"
FRONTEND_SERVICE="katonic-frontend"
FRONTEND_DOCKERFILE="platform-frontend/Dockerfile"
FRONTEND_CONTEXT="platform-frontend"

# seed-all: uses root context with Dockerfile.seed
SEED_SERVICE="seed-all"
SEED_DOCKERFILE="Dockerfile.seed"

ALL_SERVICES=("${ROOT_CONTEXT_SERVICES[@]}" "${SERVICE_CONTEXT_SERVICES[@]}" "$AI_GATEWAY_SERVICE" "$FRONTEND_SERVICE" "$SEED_SERVICE")

# ── Build: build and push images to ACR ──
cmd_build() {
  local TARGET="${1:-all}"

  # Verify ACR login
  if ! docker login "$REGISTRY" --get-login > /dev/null 2>&1; then
    info "Logging into ACR..."
    az acr login --name "$(echo "$REGISTRY" | cut -d. -f1)" 2>/dev/null || \
      error "Failed to login to ACR. Run: az acr login --name katonic"
  fi

  if [ "$TARGET" != "all" ]; then
    _build_service "$TARGET"
    return
  fi

  info "Building all ${#ALL_SERVICES[@]} services for linux/amd64..."
  echo ""

  local FAILED=()
  for svc in "${ALL_SERVICES[@]}"; do
    _build_service "$svc" || FAILED+=("$svc")
  done

  echo ""
  if [ ${#FAILED[@]} -eq 0 ]; then
    info "All ${#ALL_SERVICES[@]} images built and pushed to $REGISTRY"
  else
    error "Failed to build: ${FAILED[*]}"
    return 1
  fi
}

_build_service() {
  local svc="$1"
  local context dockerfile

  step "Building $svc..."

  if [ "$svc" = "$AI_GATEWAY_SERVICE" ]; then
    context="$ROOT_DIR"
    dockerfile="$ROOT_DIR/$AI_GATEWAY_DOCKERFILE"
  elif [ "$svc" = "$FRONTEND_SERVICE" ]; then
    context="$ROOT_DIR/$FRONTEND_CONTEXT"
    dockerfile="$ROOT_DIR/$FRONTEND_DOCKERFILE"
  elif [ "$svc" = "$SEED_SERVICE" ]; then
    context="$ROOT_DIR"
    dockerfile="$ROOT_DIR/$SEED_DOCKERFILE"
  elif printf '%s\n' "${ROOT_CONTEXT_SERVICES[@]}" | grep -qx "$svc"; then
    context="$ROOT_DIR"
    dockerfile="$ROOT_DIR/$svc/Dockerfile"
  else
    context="$ROOT_DIR/$svc"
    dockerfile="$ROOT_DIR/$svc/Dockerfile"
  fi

  if [ ! -f "$dockerfile" ]; then
    error "Dockerfile not found: $dockerfile"
    return 1
  fi

  docker buildx build \
    --platform linux/amd64 \
    -t "$REGISTRY/$svc:latest" \
    -f "$dockerfile" \
    "$context" \
    --push 2>&1 | tail -5

  info "$svc pushed to $REGISTRY/$svc:latest"
}

# ── Deploy: apply production overlay ──
cmd_deploy() {
  info "Deploying overlay: $OVERLAY"

  # Verify cluster connectivity
  step "Verifying cluster connectivity..."
  kubectl cluster-info > /dev/null 2>&1 || {
    error "Cannot connect to AKS cluster. Run: az aks get-credentials --resource-group <rg> --name <cluster>"
    return 1
  }

  # Validate manifests
  step "Validating manifests (dry-run)..."
  kubectl apply -k "$SCRIPT_DIR/overlays/$OVERLAY" --dry-run=server 2>&1 | head -20 || true
  echo ""

  # Apply
  step "Applying manifests..."
  kubectl apply -k "$SCRIPT_DIR/overlays/$OVERLAY"

  # Wait for infrastructure (no sidecars — stays 1/1)
  echo ""
  step "Waiting for infrastructure..."
  kubectl rollout status statefulset/postgres   -n "$NAMESPACE" --timeout=180s 2>/dev/null || warn "postgres not ready yet"
  kubectl rollout status statefulset/redis      -n "$NAMESPACE" --timeout=60s  2>/dev/null || warn "redis not ready yet"
  kubectl rollout status statefulset/clickhouse -n "$NAMESPACE" --timeout=120s 2>/dev/null || warn "clickhouse not ready yet"

  # ── Run seed job (creates DBs, tables, upserts LLM providers/models) ──
  echo ""
  step "Running seed-all job (databases, tables, LLM providers & models)..."
  kubectl delete job seed-all -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  kubectl apply -f "$SCRIPT_DIR/base/jobs/seed-all.yaml"
  if kubectl wait --for=condition=complete job/seed-all -n "$NAMESPACE" --timeout=180s 2>/dev/null; then
    info "seed-all job completed — providers & models seeded."
  else
    warn "seed-all job did not complete within 180s — check: kubectl logs job/seed-all -n $NAMESPACE"
  fi

  # Restart deployments to inject Istio sidecars (only Deployments, NOT StatefulSets)
  step "Restarting deployments for Istio sidecar injection..."
  kubectl rollout restart deployment -n "$NAMESPACE"

  # Wait for backends (with sidecar — should become 2/2)
  step "Waiting for backend services (with Istio sidecars)..."
  for svc in admin-api ai-gateway guardrails-engine governance-proxy \
             agent-api agent-runtime mcp-gateway platform-backend \
             knowledge-engine model-deployment-service workspace-service \
             remote-connections observability eval-engine; do
    kubectl rollout status deployment/$svc -n "$NAMESPACE" --timeout=300s 2>/dev/null || \
      warn "$svc not ready yet"
  done

  # Wait for frontend
  step "Waiting for frontend (with Istio sidecar)..."
  kubectl rollout status deployment/katonic-frontend -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
    warn "katonic-frontend not ready yet"

  # Verify sidecar injection
  echo ""
  step "Verifying Istio sidecar injection..."
  local INJECTED
  INJECTED=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null | grep -c "istio-proxy" || true)
  info "Pods with istio-proxy sidecar: $INJECTED"

  echo ""
  info "Deployment complete!"
  echo ""
  cmd_urls
}

# ── Status: show all resources ──
cmd_status() {
  echo ""
  info "=== Pods ==="
  kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "No pods found"
  echo ""
  info "=== Services ==="
  kubectl get svc -n "$NAMESPACE" 2>/dev/null || echo "No services found"
  echo ""
  info "=== StatefulSets ==="
  kubectl get statefulsets -n "$NAMESPACE" 2>/dev/null || echo "No statefulsets found"
  echo ""
  info "=== Deployments ==="
  kubectl get deployments -n "$NAMESPACE" 2>/dev/null || echo "No deployments found"
  echo ""
  info "=== PVCs ==="
  kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "No PVCs found"
  echo ""
  info "=== Istio Resources ==="
  echo "--- VirtualServices ---"
  kubectl get virtualservices -n "$NAMESPACE" 2>/dev/null || echo "No VirtualServices found"
  echo "--- DestinationRules ---"
  kubectl get destinationrules -n "$NAMESPACE" 2>/dev/null || echo "No DestinationRules found"
  echo "--- Gateways ---"
  kubectl get gateways -n "$NAMESPACE" 2>/dev/null || echo "No Gateways found"
  echo "--- PeerAuthentication ---"
  kubectl get peerauthentication -n "$NAMESPACE" 2>/dev/null || echo "No PeerAuthentication found"
  echo ""
  info "=== Istio Ingress Gateway ==="
  kubectl get svc istio-ingressgateway -n istio-system 2>/dev/null || echo "Istio ingress gateway not found"
}

# ── URLs: show access URLs ──
cmd_urls() {
  local EXTERNAL_IP

  # Get Istio ingress gateway IP (external traffic entry point)
  EXTERNAL_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [ -z "$EXTERNAL_IP" ]; then
    warn "Istio ingress gateway IP not yet assigned. Waiting..."
    for i in $(seq 1 12); do
      sleep 5
      EXTERNAL_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      [ -n "$EXTERNAL_IP" ] && break
    done
  fi

  if [ -n "$EXTERNAL_IP" ]; then
    info "AKS access URLs (Istio Ingress Gateway):"
    echo ""
    echo "  Katonic Platform:         http://$EXTERNAL_IP"
    echo "    /ace            ACE chat workspace"
    echo "    /dashboard      Run operations dashboard"
    echo "    /studio/agents  Agent Studio"
    echo "    /marketplace    Marketplace catalog"
    echo ""
    echo "  Istio Ingress Gateway IP: $EXTERNAL_IP"
    echo ""

    # Show Istio mesh status
    info "Istio mesh status:"
    kubectl get pods -n "$NAMESPACE" -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,CONTAINERS:.spec.containers[*].name' 2>/dev/null | head -20
    echo ""
    info "Istio VirtualServices:"
    kubectl get virtualservices -n "$NAMESPACE" 2>/dev/null || echo "  (none)"
  else
    warn "Istio ingress gateway IP not available yet."
    echo "  Run: kubectl get svc istio-ingressgateway -n istio-system"
  fi
}

# ── Restart: rolling restart all deployments ──
cmd_restart() {
  info "Rolling restart of all deployments..."
  kubectl rollout restart deployment -n "$NAMESPACE"
  echo ""
  info "All deployments restarted. Pods will pull fresh images."
  echo "  Run './deploy-aks.sh status' to monitor progress."
}

# ── Teardown: remove everything ──
cmd_teardown() {
  warn "This will DELETE all resources in namespace '$NAMESPACE'."
  read -rp "Continue? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    info "Deleting namespace '$NAMESPACE'..."
    kubectl delete namespace "$NAMESPACE" --timeout=120s 2>/dev/null || true
    info "Teardown complete."
  else
    info "Cancelled."
  fi
}

# ── Main ──
case "${1:-help}" in
  build)    cmd_build "${2:-all}" ;;
  deploy)   cmd_deploy ;;
  status)   cmd_status ;;
  urls)     cmd_urls ;;
  restart)  cmd_restart ;;
  teardown) cmd_teardown ;;
  *)
    echo "Katonic Platform - AKS Deployment Script"
    echo ""
    echo "Usage: $0 {build|deploy|status|urls|restart|teardown}"
    echo ""
    echo "Commands:"
    echo "  build [service]    Build and push images to ACR (all or one service)"
    echo "  deploy             Deploy platform using production overlay"
    echo "  status             Show all resources in katonic namespace"
    echo "  urls               Show the Istio ingress gateway access URL"
    echo "  restart            Rolling restart all deployments (pull fresh images)"
    echo "  teardown           Delete everything in katonic namespace"
    echo ""
    echo "Environment variables:"
    echo "  ACR_REGISTRY       ACR hostname (default: katonic.azurecr.io)"
    echo ""
    echo "Examples:"
    echo "  $0 build                  # Build and push all ${#ALL_SERVICES[@]} images"
    echo "  $0 build admin-api        # Build and push only admin-api"
    echo "  $0 deploy                 # Deploy to AKS"
    echo "  $0 restart                # Pull fresh images without redeploying manifests"
    ;;
esac
