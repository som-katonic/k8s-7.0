#!/usr/bin/env bash
# ============================================================================
# Katonic v7 - Pre-flight Checks
# ============================================================================
# Validates cloud credentials, CLI tools, DNS, and cluster name.
# Usage: katonic.sh <CLOUD> <CREATE_CLUSTER>
# ============================================================================

set -euo pipefail

CLOUD="${1:-AWS}"
CREATE_CLUSTER="${2:-True}"
ERRORS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
check_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS + 1)); }
check_warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

echo ""
echo "Pre-flight checks for: $CLOUD (create_cluster=$CREATE_CLUSTER)"
echo "-----------------------------------------------------------"

# ============================================================================
# Common tools
# ============================================================================
echo ""
echo "Checking required tools..."

for tool in kubectl helm terraform ansible-playbook jq python3; do
    if command -v "$tool" &>/dev/null; then
        check_pass "$tool found: $(command -v $tool)"
    else
        check_fail "$tool not found"
    fi
done

# ============================================================================
# Cloud-specific checks
# ============================================================================
echo ""
echo "Checking cloud credentials for: $CLOUD"

case "$CLOUD" in
    AWS)
        if command -v aws &>/dev/null; then
            check_pass "AWS CLI found"
            if aws sts get-caller-identity &>/dev/null; then
                ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
                check_pass "AWS credentials valid (account: $ACCOUNT)"
            else
                check_fail "AWS credentials not configured or expired"
            fi
        else
            check_fail "AWS CLI not found"
        fi
        ;;

    Azure)
        if command -v az &>/dev/null; then
            check_pass "Azure CLI found"
            if az account show &>/dev/null; then
                SUB=$(az account show --query name --output tsv)
                check_pass "Azure logged in (subscription: $SUB)"
            else
                check_fail "Azure not logged in. Run: az login"
            fi
        else
            check_fail "Azure CLI not found"
        fi
        ;;

    GCP)
        if command -v gcloud &>/dev/null; then
            check_pass "GCP CLI found"
            if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
                ACCT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
                check_pass "GCP authenticated ($ACCT)"
            else
                check_fail "GCP not authenticated. Run: gcloud auth login"
            fi
        else
            check_fail "GCP CLI not found"
        fi
        ;;

    OCI)
        if command -v oci &>/dev/null; then
            check_pass "OCI CLI found"
            if oci iam region list &>/dev/null; then
                check_pass "OCI credentials valid"
            else
                check_fail "OCI credentials not configured. Run: oci setup config"
            fi
        else
            check_fail "OCI CLI not found"
        fi
        ;;

    Alibaba|SCCC)
        if command -v aliyun &>/dev/null; then
            check_pass "Alibaba Cloud CLI (aliyun) found"
            if aliyun ecs DescribeRegions &>/dev/null; then
                check_pass "Alibaba Cloud credentials valid"
            else
                check_fail "Alibaba Cloud credentials not configured. Run: aliyun configure"
            fi
        else
            check_fail "Alibaba Cloud CLI not found"
        fi
        if [[ "$CLOUD" == "SCCC" ]]; then
            check_warn "SCCC mode: Ensure Alibaba CLI is configured with me-riyadh endpoint"
        fi
        ;;

    On-Premise)
        check_warn "On-premise mode: Skipping cloud credential checks"
        if kubectl cluster-info &>/dev/null; then
            check_pass "kubectl connected to cluster"
            NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
            check_pass "Cluster has $NODES nodes"
            if [[ "$NODES" -lt 3 ]]; then
                check_warn "Less than 3 nodes — HA not possible"
            fi
            # Check for default StorageClass
            DEFAULT_SC=$(kubectl get storageclass -o json 2>/dev/null | python3 -c "import sys,json; sc=json.load(sys.stdin)['items']; print(next((s['metadata']['name'] for s in sc if s.get('metadata',{}).get('annotations',{}).get('storageclass.kubernetes.io/is-default-class','')=='true'),'none'))" 2>/dev/null || echo "none")
            if [[ "$DEFAULT_SC" != "none" ]]; then
                check_pass "Default StorageClass: $DEFAULT_SC"
            else
                check_warn "No default StorageClass — installer will deploy Longhorn"
            fi
            # Check K8s version
            K8S_VERSION=$(kubectl version -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('serverVersion',{}).get('gitVersion','unknown'))" 2>/dev/null || echo "unknown")
            check_pass "Kubernetes version: $K8S_VERSION"
        else
            check_fail "kubectl cannot connect to cluster. Configure kubeconfig first."
        fi
        ;;

    *)
        check_fail "Unknown cloud provider: $CLOUD"
        check_fail "Valid options: AWS, Azure, GCP, OCI, Alibaba, SCCC, On-Premise"
        ;;
esac

# ============================================================================
# Kubernetes connectivity (if not creating cluster)
# ============================================================================
if [[ "$CREATE_CLUSTER" == "False" ]]; then
    echo ""
    echo "Checking existing cluster connectivity..."
    if kubectl cluster-info &>/dev/null; then
        NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        check_pass "Connected to cluster ($NODES nodes)"

        # Check minimum node count
        if [[ "$NODES" -lt 3 ]]; then
            check_warn "Less than 3 nodes. Minimum 3 recommended for production."
        fi

        # Check Kubernetes version
        K8S_VERSION=$(kubectl version --short 2>/dev/null | grep "Server" | awk '{print $3}' || kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' || echo "unknown")
        check_pass "Kubernetes version: $K8S_VERSION"
    else
        check_fail "Cannot connect to existing cluster. Check kubeconfig."
    fi
fi

# ============================================================================
# DNS checks
# ============================================================================
echo ""
echo "Checking DNS resolution..."

# Basic DNS check
if nslookup google.com &>/dev/null; then
    check_pass "DNS resolution working"
else
    if [[ "${AIR_GAP:-False}" == "True" ]]; then
        check_warn "DNS resolution failed (expected in air-gap mode)"
    else
        check_fail "DNS resolution failed"
    fi
fi

# ============================================================================
# Disk space
# ============================================================================
echo ""
echo "Checking disk space..."

AVAILABLE_GB=$(df -BG /root | tail -1 | awk '{print $4}' | tr -d 'G')
if [[ "$AVAILABLE_GB" -ge 20 ]]; then
    check_pass "Disk space: ${AVAILABLE_GB}GB available"
else
    check_fail "Insufficient disk space: ${AVAILABLE_GB}GB (need 20GB+)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "-----------------------------------------------------------"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}All pre-flight checks passed.${NC}"
    exit 0
else
    echo -e "${RED}${ERRORS} check(s) failed. Fix the issues above and retry.${NC}"
    exit 1
fi
