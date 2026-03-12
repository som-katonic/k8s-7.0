#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Katonic Platform - Kubernetes Deployment Script
# Usage: ./deploy.sh [command]
#   Commands: setup | deploy | milvus | status | urls | teardown
# ─────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="katonic"

# Load Docker credentials from .env
if [ -f "$ROOT_DIR/.env" ]; then
  export $(grep -v '^#' "$ROOT_DIR/.env" | xargs)
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Setup: create namespace + Docker registry secret ──
cmd_setup() {
  info "Creating namespace '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  if [ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKER_PASSWORD:-}" ]; then
    info "Creating Docker Hub registry secret..."
    kubectl create secret docker-registry dockerhub-secret \
      --namespace="$NAMESPACE" \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="$DOCKER_USERNAME" \
      --docker-password="$DOCKER_PASSWORD" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    warn "DOCKER_USERNAME/DOCKER_PASSWORD not set in .env — skipping registry secret"
  fi

  info "Setup complete."
}

# ── Deploy: apply kustomize overlay ──
cmd_deploy() {
  local OVERLAY="${1:-minikube}"
  info "Deploying overlay: $OVERLAY"

  # Ensure setup was run
  cmd_setup

  # Validate manifests first
  info "Validating manifests (dry-run)..."
  kubectl apply -k "$SCRIPT_DIR/overlays/$OVERLAY" --dry-run=server 2>&1 | head -30
  echo ""

  info "Applying manifests..."
  kubectl apply -k "$SCRIPT_DIR/overlays/$OVERLAY"

  info "Waiting for infrastructure to be ready..."
  kubectl rollout status statefulset/postgres -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  kubectl rollout status statefulset/redis    -n "$NAMESPACE" --timeout=60s  2>/dev/null || true
  kubectl rollout status statefulset/clickhouse -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

  # ── Run seed job (creates DBs, tables, upserts LLM providers/models) ──
  info "Running seed-all job..."
  kubectl delete job seed-all -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  kubectl apply -f "$SCRIPT_DIR/base/jobs/seed-all.yaml"
  if kubectl wait --for=condition=complete job/seed-all -n "$NAMESPACE" --timeout=180s 2>/dev/null; then
    info "seed-all job completed successfully."
  else
    warn "seed-all job did not complete within 180s — check logs: kubectl logs job/seed-all -n $NAMESPACE"
  fi

  info "Waiting for backend services..."
  for svc in admin-api ai-gateway guardrails-engine governance-proxy \
             agent-api agent-runtime mcp-gateway platform-backend \
             knowledge-engine model-deployment-service workspace-service \
             remote-connections observability eval-engine; do
    kubectl rollout status deployment/$svc -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
      warn "$svc not ready yet (may need image push)"
  done

  info "Waiting for frontend..."
  kubectl rollout status deployment/katonic-frontend -n "$NAMESPACE" --timeout=60s 2>/dev/null || \
    warn "katonic-frontend not ready yet"

  echo ""
  info "Deployment complete! Run './deploy.sh status' to check pod status."
}

# ── Deploy Milvus stack (optional) ──
cmd_milvus() {
  info "Deploying Milvus vector DB stack..."
  kubectl apply -f "$SCRIPT_DIR/base/optional/milvus.yaml"
  info "Milvus stack deployed. Waiting for pods..."
  kubectl rollout status statefulset/etcd   -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  kubectl rollout status statefulset/minio  -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  kubectl rollout status statefulset/milvus -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  info "Milvus stack ready."
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
}

# ── URLs: show access URLs for minikube ──
cmd_urls() {
  info "NodePort access URLs (use 'minikube tunnel' first):"
  local IP
  IP=$(minikube ip 2>/dev/null || echo "localhost")
  echo "  Ops Console (all zones):  http://$IP:30000"
  echo "    /ace            ACE chat workspace"
  echo "    /dashboard      Run operations dashboard"
  echo "    /studio/agents  Agent Studio"
  echo "    /marketplace    Marketplace catalog"
  echo "  Admin API:                http://$IP:30004"
  echo "  Platform Backend:         http://$IP:30002"
  echo ""
  info "Or use: minikube service katonic-frontend-nodeport -n katonic"
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
  setup)    cmd_setup ;;
  deploy)   cmd_deploy "${2:-minikube}" ;;
  milvus)   cmd_milvus ;;
  status)   cmd_status ;;
  urls)     cmd_urls ;;
  teardown) cmd_teardown ;;
  *)
    echo "Usage: $0 {setup|deploy [overlay]|milvus|status|urls|teardown}"
    echo ""
    echo "Commands:"
    echo "  setup              Create namespace + Docker registry secret"
    echo "  deploy [overlay]   Deploy platform (default: minikube)"
    echo "  milvus             Deploy optional Milvus vector DB stack"
    echo "  status             Show all resources"
    echo "  urls               Show access URLs"
    echo "  teardown           Delete everything"
    ;;
esac
