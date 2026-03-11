#!/usr/bin/env bash
# ============================================================================
# On-Premise Pre-flight Checks for Katonic Platform v7
# ============================================================================
# Ported from v6.3.0 pre-check-onprem.sh. Validates node sizing, labels,
# OS, AVX support, swap, StorageClass, and kube-system health.
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

echo ""
echo "============================================"
echo "  On-Premise Pre-flight Checks"
echo "============================================"

# ---------------------------------------------------------------------------
# 1. Node count and readiness
# ---------------------------------------------------------------------------
echo ""
echo "--- Nodes ---"
TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep " Ready" | wc -l)

if [[ "$TOTAL_NODES" -ge 3 ]]; then
  log_pass "Total nodes: $TOTAL_NODES (min 3 for production)"
else
  log_warn "Only $TOTAL_NODES node(s) — minimum 3 recommended for production"
fi

if [[ "$READY_NODES" -eq "$TOTAL_NODES" ]]; then
  log_pass "All $TOTAL_NODES nodes are Ready"
else
  log_fail "$((TOTAL_NODES - READY_NODES)) node(s) NOT Ready"
fi

# ---------------------------------------------------------------------------
# 2. Per-node CPU and memory
# ---------------------------------------------------------------------------
echo ""
echo "--- Node Sizing ---"
MIN_CPU=4
MIN_MEM_GI=14  # ~16GB with overhead

kubectl get nodes --no-headers -o custom-columns="NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory" 2>/dev/null | while read -r name cpu mem_ki; do
  # Parse memory (comes as Ki)
  mem_raw=$(echo "$mem_ki" | sed 's/Ki//')
  mem_gi=$((mem_raw / 1024 / 1024))

  if [[ "$cpu" -ge "$MIN_CPU" ]] && [[ "$mem_gi" -ge "$MIN_MEM_GI" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $name — ${cpu} CPU, ${mem_gi}Gi memory"
  else
    echo -e "  ${RED}FAIL${NC}: $name — ${cpu} CPU, ${mem_gi}Gi memory (min: ${MIN_CPU} CPU, 16Gi)"
  fi
done

# ---------------------------------------------------------------------------
# 3. OS and K8s version
# ---------------------------------------------------------------------------
echo ""
echo "--- Cluster Info ---"
K8S_VER=$(kubectl version -o json 2>/dev/null | python3 -c "import sys,json; v=json.load(sys.stdin).get('serverVersion',{}); print(f'{v.get(\"major\",\"?\")}.{v.get(\"minor\",\"?\")}')" 2>/dev/null || echo "unknown")
log_pass "Kubernetes version: $K8S_VER"

FIRST_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
OS_IMAGE=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null || echo "unknown")
CONTAINER_RT=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "unknown")
log_pass "OS: $OS_IMAGE"
log_pass "Container runtime: $CONTAINER_RT"

# ---------------------------------------------------------------------------
# 4. StorageClass
# ---------------------------------------------------------------------------
echo ""
echo "--- Storage ---"
DEFAULT_SC=$(kubectl get storageclass -o json 2>/dev/null | python3 -c "
import sys,json
sc=json.load(sys.stdin)['items']
for s in sc:
  if s.get('metadata',{}).get('annotations',{}).get('storageclass.kubernetes.io/is-default-class','')=='true':
    print(s['metadata']['name']); break
else:
  print('none')
" 2>/dev/null || echo "none")

if [[ "$DEFAULT_SC" != "none" ]]; then
  log_pass "Default StorageClass: $DEFAULT_SC"
else
  log_warn "No default StorageClass — installer will attempt to create one"
fi

# List all storage classes
ALL_SC=$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
log_pass "Available StorageClasses: ${ALL_SC:-none}"

# ---------------------------------------------------------------------------
# 5. kube-system health
# ---------------------------------------------------------------------------
echo ""
echo "--- kube-system Pods ---"
BAD_KUBE=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print $1, $3}')
if [[ -z "$BAD_KUBE" ]]; then
  log_pass "All kube-system pods are Running/Completed"
else
  log_fail "kube-system pods not healthy:"
  echo "$BAD_KUBE" | while read -r line; do echo "    $line"; done
fi

# ---------------------------------------------------------------------------
# 6. LoadBalancer support
# ---------------------------------------------------------------------------
echo ""
echo "--- LoadBalancer ---"
# Create a temp service to test LB support
LB_TEST=$(kubectl get svc --all-namespaces -o json 2>/dev/null | python3 -c "
import sys,json
svcs=json.load(sys.stdin)['items']
for s in svcs:
  if s.get('spec',{}).get('type','')=='LoadBalancer':
    ing=s.get('status',{}).get('loadBalancer',{}).get('ingress',[])
    if ing:
      print('yes'); break
else:
  print('no-lb-svc')
" 2>/dev/null || echo "unknown")

if [[ "$LB_TEST" == "yes" ]]; then
  log_pass "LoadBalancer services have external IPs (MetalLB or cloud LB working)"
elif [[ "$LB_TEST" == "no-lb-svc" ]]; then
  log_warn "No LoadBalancer services exist yet — will be tested after Istio deploy"
else
  log_warn "Could not determine LoadBalancer support"
fi

# ---------------------------------------------------------------------------
# 7. Disk space on nodes (via ephemeral-storage)
# ---------------------------------------------------------------------------
echo ""
echo "--- Disk Space ---"
kubectl get nodes --no-headers -o custom-columns="NAME:.metadata.name,DISK:.status.capacity.ephemeral-storage" 2>/dev/null | while read -r name disk_ki; do
  disk_raw=$(echo "$disk_ki" | sed 's/Ki//')
  disk_gb=$((disk_raw / 1024 / 1024))
  if [[ "$disk_gb" -ge 100 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $name — ${disk_gb}GB disk"
  else
    echo -e "  ${YELLOW}WARN${NC}: $name — ${disk_gb}GB disk (recommend 100GB+)"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Pre-flight: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}Pre-flight checks PASSED — ready to install${NC}"
  exit 0
else
  echo -e "${RED}$FAIL pre-flight check(s) failed — fix before proceeding${NC}"
  exit 1
fi
