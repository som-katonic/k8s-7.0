#!/usr/bin/env bash
# ===========================================================================
# Mirror MCP catalog images to Katonic staging registry
#
# Run in CI after catalog updates to ensure all MCP server images are
# available in registry.katonic.ai for customer installs.
#
# Usage:
#   ./mirror-mcp-images.sh [catalog.json] [target-registry]
#
# Defaults:
#   catalog: ./mcp-catalog.json
#   registry: registry.katonic.ai
# ===========================================================================
set -euo pipefail

CATALOG="${1:-./mcp-catalog.json}"
TARGET_REGISTRY="${2:-registry.katonic.ai}"
TAG="${MCP_IMAGE_TAG:-latest}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ ! -f "$CATALOG" ]; then
  echo -e "${RED}Catalog file not found: $CATALOG${NC}"
  exit 1
fi

echo "============================================"
echo " MCP Image Mirror"
echo "============================================"
echo " Catalog: $CATALOG"
echo " Target:  $TARGET_REGISTRY"
echo " Tag:     $TAG"
echo ""

TOTAL=0
FAILED=0

# Extract all dockerImage values
jq -r '.[].dockerImage' "$CATALOG" | while read -r image; do
  TOTAL=$((TOTAL + 1))
  SRC="${image}:${TAG}"
  DST="${TARGET_REGISTRY}/${image}:${TAG}"

  echo -n "  [$TOTAL] $SRC -> $DST ... "

  if docker pull "$SRC" >/dev/null 2>&1; then
    docker tag "$SRC" "$DST"
    if docker push "$DST" >/dev/null 2>&1; then
      echo -e "${GREEN}OK${NC}"
    else
      echo -e "${RED}PUSH FAILED${NC}"
      FAILED=$((FAILED + 1))
    fi
  else
    echo -e "${RED}PULL FAILED${NC}"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "============================================"
TOTAL=$(jq '.|length' "$CATALOG")
echo " Mirrored: $TOTAL images"
echo "============================================"
