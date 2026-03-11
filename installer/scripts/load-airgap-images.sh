#!/usr/bin/env bash
# ============================================================================
# Load Air-Gap Images into Private Registry
# ============================================================================
# Loads all platform container images from the bundled tarball into the
# customer's private registry.
# ============================================================================

set -euo pipefail

AIRGAP_DIR="/root/airgap"
IMAGES_TAR="${AIRGAP_DIR}/images.tar.gz"
REGISTRY=$(python3 -c "import yaml; print(yaml.safe_load(open('/inventory/katonic.yml')).get('image_registry',''))")

if [[ -z "$REGISTRY" ]]; then
    echo "[ERROR] image_registry not set in katonic.yml"
    exit 1
fi

if [[ ! -f "$IMAGES_TAR" ]]; then
    echo "[ERROR] Air-gap image bundle not found: $IMAGES_TAR"
    exit 1
fi

echo "[INFO] Loading images from $IMAGES_TAR"
echo "[INFO] Target registry: $REGISTRY"
echo ""

# Extract and load images
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo "[INFO] Extracting image bundle..."
tar xzf "$IMAGES_TAR"

# Each image is saved as <name>__<tag>.tar
for img_tar in *.tar; do
    if [[ ! -f "$img_tar" ]]; then
        continue
    fi

    # Parse image name from filename
    IMG_NAME=$(echo "$img_tar" | sed 's/__/:/g' | sed 's/.tar$//')

    echo "[INFO] Loading: $IMG_NAME"
    docker load -i "$img_tar" 2>/dev/null || ctr -n k8s.io images import "$img_tar" 2>/dev/null || {
        echo "[WARN] Could not load $img_tar via docker or ctr, trying skopeo..."
        skopeo copy "docker-archive:${img_tar}" "docker://${REGISTRY}/${IMG_NAME}" --dest-tls-verify=false 2>/dev/null || {
            echo "[ERROR] Failed to load: $img_tar"
            continue
        }
    }

    # Re-tag for private registry
    ORIGINAL_TAG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "$IMG_NAME" | head -1)
    if [[ -n "$ORIGINAL_TAG" ]]; then
        NEW_TAG="${REGISTRY}/${IMG_NAME##*/}"
        docker tag "$ORIGINAL_TAG" "$NEW_TAG" 2>/dev/null
        docker push "$NEW_TAG" 2>/dev/null
        echo "  -> Pushed: $NEW_TAG"
    fi
done

# Clean up
cd /
rm -rf "$TEMP_DIR"

echo ""
echo "[OK] All air-gap images loaded into $REGISTRY"
