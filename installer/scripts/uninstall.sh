#!/usr/bin/env bash
# ============================================================================
# Katonic Platform v7 — Uninstall
# ============================================================================
# Removes all platform components. Does NOT delete the K8s cluster itself.
# Usage: ./uninstall.sh [--keep-data]
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

KEEP_DATA=false
if [[ "${1:-}" == "--keep-data" ]]; then
  KEEP_DATA=true
  echo -e "${YELLOW}Keep-data mode: PVCs and databases will NOT be deleted${NC}"
fi

echo ""
echo -e "${RED}============================================${NC}"
echo -e "${RED}  Katonic Platform v7 — UNINSTALL${NC}"
echo -e "${RED}============================================${NC}"
echo ""
echo "This will remove all Katonic platform components."
echo "The Kubernetes cluster itself will NOT be deleted."
echo ""
read -p "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Remove Helm releases
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing Helm releases ---"
for release in katonic-platform katonic-monitoring katonic-infra; do
  if helm list -n katonic-system -q 2>/dev/null | grep -q "^${release}$"; then
    echo "  Removing $release..."
    helm uninstall "$release" -n katonic-system --timeout 5m || true
  fi
done

# Remove tenant Helm releases (one per org environment)
for ns in $(kubectl get namespaces -o name 2>/dev/null | grep "katonic-org-" | sed 's|namespace/||'); do
  echo "  Removing tenant releases in $ns..."
  for rel in $(helm list -n "$ns" -q 2>/dev/null); do
    helm uninstall "$rel" -n "$ns" --timeout 5m || true
  done
done

# ---------------------------------------------------------------------------
# 2. Remove monitoring
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing monitoring ---"
for release in $(helm list -n katonic-monitoring -q 2>/dev/null); do
  helm uninstall "$release" -n katonic-monitoring --timeout 5m || true
done

# ---------------------------------------------------------------------------
# 3. Remove infra services
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing infrastructure services ---"
for release in $(helm list -n katonic-infra -q 2>/dev/null); do
  helm uninstall "$release" -n katonic-infra --timeout 5m || true
done

# ---------------------------------------------------------------------------
# 4. Remove Istio
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing Istio ---"
for release in $(helm list -n istio-system -q 2>/dev/null); do
  helm uninstall "$release" -n istio-system --timeout 5m || true
done

# ---------------------------------------------------------------------------
# 5. Remove MetalLB (if installed)
# ---------------------------------------------------------------------------
if kubectl get namespace metallb-system &>/dev/null; then
  echo ""
  echo "--- Removing MetalLB ---"
  kubectl delete namespace metallb-system --timeout=60s || true
fi

# ---------------------------------------------------------------------------
# 6. Delete namespaces
# ---------------------------------------------------------------------------
echo ""
echo "--- Deleting namespaces ---"
NAMESPACES=("katonic-system" "katonic-monitoring" "katonic-infra" "istio-system")

# Add tenant namespaces
for ns in $(kubectl get namespaces -o name 2>/dev/null | grep "katonic-org-" | sed 's|namespace/||'); do
  NAMESPACES+=("$ns")
done

for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" &>/dev/null; then
    if [[ "$KEEP_DATA" == true ]] && [[ "$ns" == "katonic-infra" ]]; then
      echo -e "  ${YELLOW}SKIP${NC}: $ns (--keep-data)"
    else
      echo "  Deleting namespace $ns..."
      kubectl delete namespace "$ns" --timeout=120s || true
    fi
  fi
done

# ---------------------------------------------------------------------------
# 7. Clean up CRDs (optional)
# ---------------------------------------------------------------------------
echo ""
echo "--- Cleaning up Katonic CRDs ---"
kubectl get crd 2>/dev/null | grep "katonic\|milvus" | awk '{print $1}' | while read -r crd; do
  echo "  Deleting CRD $crd..."
  kubectl delete crd "$crd" || true
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Uninstall complete${NC}"
echo -e "${GREEN}============================================${NC}"
if [[ "$KEEP_DATA" == true ]]; then
  echo -e "${YELLOW}Note: katonic-infra namespace preserved (databases + PVCs intact)${NC}"
fi
echo ""
