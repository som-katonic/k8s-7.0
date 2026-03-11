#!/usr/bin/env bash
# ============================================================================
# Post-Install Validation for Katonic Platform v7
# ============================================================================
# Ported from v6.3.0 post-check.sh, adapted for v7 namespace/service layout.
# Checks every expected namespace, deployment, statefulset, job, and PVC.
# ============================================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

log_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
log_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
log_warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; WARN=$((WARN + 1)); }

# ---------------------------------------------------------------------------
# Check namespace exists
# ---------------------------------------------------------------------------
check_ns() {
  if kubectl get namespace "$1" &>/dev/null; then
    log_pass "Namespace $1 exists"
    return 0
  else
    log_fail "Namespace $1 NOT FOUND"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Check resource is running (deployment, statefulset, daemonset)
# ---------------------------------------------------------------------------
check_resource() {
  local type=$1 ns=$2 name=$3
  local status
  status=$(kubectl get "$type" -n "$ns" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$status" -ge 1 ]]; then
    log_pass "$type/$name in $ns (${status} ready)"
  else
    # Check if it exists at all
    if kubectl get "$type" -n "$ns" "$name" &>/dev/null; then
      log_fail "$type/$name in $ns exists but NOT READY"
    else
      log_fail "$type/$name in $ns NOT FOUND"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check PVC is bound
# ---------------------------------------------------------------------------
check_pvc() {
  local ns=$1 name=$2
  local phase
  phase=$(kubectl get pvc -n "$ns" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$phase" == "Bound" ]]; then
    log_pass "PVC $name in $ns is Bound"
  elif [[ -n "$phase" ]]; then
    log_fail "PVC $name in $ns is $phase (not Bound)"
  else
    log_warn "PVC $name in $ns not found"
  fi
}

# ---------------------------------------------------------------------------
# Check Istio ingress has External IP
# ---------------------------------------------------------------------------
check_ingress() {
  local ip
  ip=$(kubectl get svc istio-ingress -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "$ip" ]]; then
    log_pass "Istio ingress has external endpoint: $ip"
  else
    log_fail "Istio ingress has NO external IP/hostname — LoadBalancer pending"
  fi
}

echo ""
echo "============================================"
echo "  Katonic Platform v7 — Post-Install Check"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Core namespaces
# ---------------------------------------------------------------------------
echo "--- Namespaces ---"
CORE_NS=("katonic-system" "katonic-infra" "katonic-monitoring" "istio-system" "cert-manager")
for ns in "${CORE_NS[@]}"; do
  check_ns "$ns"
done

# ---------------------------------------------------------------------------
# 2. katonic-system services (platform core)
# ---------------------------------------------------------------------------
echo ""
echo "--- katonic-system (Platform Services) ---"
check_resource deployment katonic-system tenant-manager
check_resource deployment katonic-system ace-bff
check_resource deployment katonic-system model-deployment

# Distributor console (only in cloud/distributor mode)
if kubectl get deployment -n katonic-system distributor-console &>/dev/null; then
  check_resource deployment katonic-system distributor-console
  log_pass "Distributor mode detected — distributor-console is deployed"
else
  log_warn "distributor-console not deployed (Enterprise/single-tenant mode)"
fi

# Employee workspace
if kubectl get deployment -n katonic-system employee-workspace &>/dev/null; then
  check_resource deployment katonic-system employee-workspace
fi

# ---------------------------------------------------------------------------
# 3. katonic-infra (shared services)
# ---------------------------------------------------------------------------
echo ""
echo "--- katonic-infra (Shared Services) ---"
check_resource statefulset katonic-infra postgresql 2>/dev/null || \
  check_resource deployment katonic-infra postgresql 2>/dev/null || \
  log_warn "PostgreSQL not found in katonic-infra (may be managed DB)"

check_resource statefulset katonic-infra redis 2>/dev/null || \
  check_resource deployment katonic-infra redis 2>/dev/null || \
  log_warn "Redis not found"

check_resource statefulset katonic-infra keycloak 2>/dev/null || \
  check_resource deployment katonic-infra keycloak 2>/dev/null || \
  log_warn "Keycloak not found in katonic-infra (check katonic-keycloak ns)"

# Milvus
if kubectl get namespace milvus-operator &>/dev/null || kubectl get deployment -n katonic-infra -l app=milvus 2>/dev/null | grep -q milvus; then
  log_pass "Milvus components detected"
else
  log_warn "Milvus not found — vector DB may not be deployed"
fi

# MinIO
if kubectl get statefulset -n katonic-infra minio &>/dev/null || kubectl get deployment -n katonic-infra minio &>/dev/null; then
  log_pass "MinIO detected"
else
  log_warn "MinIO not found (may be using cloud object storage)"
fi

# ClickHouse
if kubectl get statefulset -n katonic-infra clickhouse &>/dev/null; then
  log_pass "ClickHouse detected"
else
  log_warn "ClickHouse not found"
fi

# MongoDB
if kubectl get statefulset -n katonic-infra mongodb &>/dev/null; then
  log_pass "MongoDB detected"
else
  log_warn "MongoDB not found"
fi

# ---------------------------------------------------------------------------
# 4. Istio
# ---------------------------------------------------------------------------
echo ""
echo "--- istio-system ---"
check_resource deployment istio-system istiod
check_resource deployment istio-system istio-ingress 2>/dev/null || \
  check_resource deployment istio-system istio-ingressgateway 2>/dev/null || \
  log_fail "Istio ingress gateway not found"
check_ingress

# ---------------------------------------------------------------------------
# 5. cert-manager
# ---------------------------------------------------------------------------
echo ""
echo "--- cert-manager ---"
check_resource deployment cert-manager cert-manager
check_resource deployment cert-manager cert-manager-webhook

# ---------------------------------------------------------------------------
# 6. Monitoring
# ---------------------------------------------------------------------------
echo ""
echo "--- katonic-monitoring ---"
if check_ns katonic-monitoring 2>/dev/null; then
  # Prometheus
  if kubectl get statefulset -n katonic-monitoring -l app.kubernetes.io/name=prometheus 2>/dev/null | grep -q prometheus; then
    log_pass "Prometheus is running"
  else
    log_warn "Prometheus statefulset not found"
  fi
  # Grafana
  if kubectl get deployment -n katonic-monitoring -l app.kubernetes.io/name=grafana 2>/dev/null | grep -q grafana; then
    log_pass "Grafana is running"
  else
    log_warn "Grafana not found"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Tenant namespaces (if any orgs have been created)
# ---------------------------------------------------------------------------
echo ""
echo "--- Tenant Namespaces ---"
TENANT_NS=$(kubectl get namespaces -o name 2>/dev/null | grep "katonic-org-" | sed 's|namespace/||' || echo "")
if [[ -n "$TENANT_NS" ]]; then
  for ns in $TENANT_NS; do
    log_pass "Tenant namespace: $ns"
  done
else
  log_warn "No tenant namespaces found (no orgs created yet)"
fi

# ---------------------------------------------------------------------------
# 8. PVCs
# ---------------------------------------------------------------------------
echo ""
echo "--- PersistentVolumeClaims ---"
PENDING_PVC=$(kubectl get pvc --all-namespaces --field-selector=status.phase!=Bound -o name 2>/dev/null | wc -l)
TOTAL_PVC=$(kubectl get pvc --all-namespaces -o name 2>/dev/null | wc -l)
BOUND_PVC=$((TOTAL_PVC - PENDING_PVC))
if [[ "$PENDING_PVC" -eq 0 ]]; then
  log_pass "All $TOTAL_PVC PVCs are Bound"
else
  log_fail "$PENDING_PVC of $TOTAL_PVC PVCs are NOT Bound"
  kubectl get pvc --all-namespaces --field-selector=status.phase!=Bound 2>/dev/null | head -10
fi

# ---------------------------------------------------------------------------
# 9. Pods in CrashLoopBackOff or Error
# ---------------------------------------------------------------------------
echo ""
echo "--- Pod Health ---"
BAD_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide 2>/dev/null | grep -v "NAMESPACE" | grep -v "Completed" | wc -l)
if [[ "$BAD_PODS" -eq 0 ]]; then
  log_pass "No pods in error state"
else
  log_warn "$BAD_PODS pods not in Running/Succeeded state:"
  kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | grep -v "Completed" | head -10
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}Platform validation PASSED${NC}"
  exit 0
else
  echo -e "${RED}Platform validation has $FAIL failure(s) — review above${NC}"
  exit 1
fi
