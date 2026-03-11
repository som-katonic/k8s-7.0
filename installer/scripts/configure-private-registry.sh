#!/usr/bin/env bash
# ============================================================================
# Configure Private Image Registry
# ============================================================================
# Creates image pull secrets across all Katonic namespaces for air-gap
# or custom private registries.
# ============================================================================

set -euo pipefail

REGISTRY=$(python3 -c "import yaml; print(yaml.safe_load(open('/inventory/katonic.yml')).get('image_registry',''))")
USERNAME=$(python3 -c "import yaml; print(yaml.safe_load(open('/inventory/katonic.yml')).get('registry_username',''))")
PASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/inventory/katonic.yml')).get('registry_password',''))")

if [[ -z "$REGISTRY" || -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "[INFO] No custom registry credentials. Using default public registry."
    exit 0
fi

echo "[INFO] Configuring private registry: $REGISTRY"

NAMESPACES="katonic-system katonic-infra katonic-keycloak katonic-monitoring"

for NS in $NAMESPACES; do
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
    kubectl create secret docker-registry katonic-registry \
        --namespace "$NS" \
        --docker-server="$REGISTRY" \
        --docker-username="$USERNAME" \
        --docker-password="$PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "  [OK] Registry secret created in $NS"
done

echo "[OK] Private registry configured for all namespaces"
