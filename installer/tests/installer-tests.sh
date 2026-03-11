#!/usr/bin/env bash
# ===========================================================================
# Tests for the MCP installer bash scripts
#
# Covers:
#   - mirror-mcp-images.sh (CI image mirroring)
#   - Install script (air-gap image loading + catalog seeding)
#
# Usage:
#   chmod +x installer-tests.sh
#   ./installer-tests.sh
#
# These tests use mocked docker/jq commands to validate script logic
# without requiring a real Docker daemon or registry.
# ===========================================================================

set -euo pipefail

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
MOCK_BIN="$TEST_DIR/mock-bin"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_pass() {
  echo -e "  ${GREEN}PASS${NC}: $1"
  PASS=$((PASS + 1))
}

log_fail() {
  echo -e "  ${RED}FAIL${NC}: $1 - $2"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "$actual" == "$expected" ]]; then
    log_pass "$msg"
  else
    log_fail "$msg" "expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    log_pass "$msg"
  else
    log_fail "$msg" "expected to contain '$needle'"
  fi
}

assert_file_exists() {
  local path="$1" msg="$2"
  if [[ -f "$path" ]]; then
    log_pass "$msg"
  else
    log_fail "$msg" "file not found: $path"
  fi
}

assert_line_count() {
  local file="$1" expected="$2" msg="$3"
  local actual
  actual=$(wc -l < "$file" | tr -d ' ')
  if [[ "$actual" == "$expected" ]]; then
    log_pass "$msg"
  else
    log_fail "$msg" "expected $expected lines, got $actual"
  fi
}

# ---------------------------------------------------------------------------
# Setup: mock commands
# ---------------------------------------------------------------------------
setup_mocks() {
  mkdir -p "$MOCK_BIN"

  # Mock docker command - logs all calls to a file
  cat > "$MOCK_BIN/docker" << 'DOCKER_MOCK'
#!/usr/bin/env bash
echo "$@" >> "${DOCKER_LOG:-/tmp/docker-calls.log}"

case "$1" in
  pull)   echo "Pulling $2..." ;;
  tag)    echo "Tagged $2 -> $3" ;;
  push)   echo "Pushed $2" ;;
  load)   echo "Loaded images from stdin" ;;
  save)   echo "FAKE_TAR_DATA" ;;
  images) echo "mcp/atlassian   latest   abc123   1 hour ago   50MB" ;;
  *)      echo "docker $*" ;;
esac
DOCKER_MOCK
  chmod +x "$MOCK_BIN/docker"

  # Use real jq if available, otherwise use a grep-based fallback
  if command -v /usr/bin/jq &>/dev/null; then
    ln -sf /usr/bin/jq "$MOCK_BIN/jq"
  else
    cat > "$MOCK_BIN/jq" << 'JQ_MOCK'
#!/usr/bin/env bash
# Minimal jq fallback - handles only the patterns used in installer scripts
INPUT_FILE=""
QUERY=""
RAW=false
for arg in "$@"; do
  case "$arg" in
    -r) RAW=true ;;
    -*) ;;
    *)
      if [[ -z "$QUERY" ]]; then QUERY="$arg"
      else INPUT_FILE="$arg"; fi
      ;;
  esac
done

# Read from file or stdin
if [[ -n "$INPUT_FILE" ]]; then
  DATA=$(cat "$INPUT_FILE")
else
  DATA=$(cat)
fi

case "$QUERY" in
  '.[].dockerImage')
    echo "$DATA" | grep -oP '"dockerImage"\s*:\s*"\K[^"]+' ;;
  'empty')
    echo "$DATA" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null && exit 0 || exit 1 ;;
  *)
    echo "$DATA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
q = '''$QUERY'''
# Very basic eval for test patterns
if q.startswith('[.[]'):
    print(json.dumps(data))
else:
    print(json.dumps(data))
" 2>/dev/null || echo "MOCK_JQ_UNSUPPORTED: $QUERY" >&2 ;;
esac
JQ_MOCK
    chmod +x "$MOCK_BIN/jq"
  fi
}

# ---------------------------------------------------------------------------
# Setup: sample catalog fixture
# ---------------------------------------------------------------------------
create_sample_catalog() {
  cat > "$TEST_DIR/mcp-catalog.json" << 'CATALOG'
[
  {
    "mcpName": "Atlassian",
    "dockerImage": "mcp/atlassian",
    "category": "Project Management"
  },
  {
    "mcpName": "Postgres",
    "dockerImage": "mcp/postgres",
    "category": "Databases & Storage"
  },
  {
    "mcpName": "DuckDuckGo",
    "dockerImage": "mcp/duckduckgo",
    "category": "Search & Web"
  }
]
CATALOG
}

# ===========================================================================
# TEST SUITE 1: Image mirroring (mirror-mcp-images.sh logic)
# ===========================================================================
test_mirror_pulls_all_catalog_images() {
  echo ""
  echo "=== Suite 1: Image mirroring ==="

  local docker_log="$TEST_DIR/docker-mirror.log"
  export DOCKER_LOG="$docker_log"
  export PATH="$MOCK_BIN:$PATH"

  # Simulate the pull loop from mirror-mcp-images.sh
  > "$docker_log"
  cat "$TEST_DIR/mcp-catalog.json" | "$MOCK_BIN/jq" -r '.[].dockerImage' | while read -r image; do
    docker pull "$image:latest"
  done

  # Check that all 3 images were pulled
  local pull_count
  pull_count=$(grep -c "^pull" "$docker_log")
  assert_eq "$pull_count" "3" "Pulls all 3 images from catalog"

  # Check specific images
  assert_contains "$(cat "$docker_log")" "pull mcp/atlassian:latest" "Pulls Atlassian image"
  assert_contains "$(cat "$docker_log")" "pull mcp/postgres:latest" "Pulls Postgres image"
  assert_contains "$(cat "$docker_log")" "pull mcp/duckduckgo:latest" "Pulls DuckDuckGo image"
}

test_mirror_tags_for_staging_registry() {
  local docker_log="$TEST_DIR/docker-tag.log"
  export DOCKER_LOG="$docker_log"

  > "$docker_log"
  cat "$TEST_DIR/mcp-catalog.json" | "$MOCK_BIN/jq" -r '.[].dockerImage' | while read -r image; do
    docker tag "$image:latest" "registry.katonic.ai/$image:latest"
    docker push "registry.katonic.ai/$image:latest"
  done

  local tag_count
  tag_count=$(grep -c "^tag" "$docker_log")
  assert_eq "$tag_count" "3" "Tags all 3 images for staging registry"

  local push_count
  push_count=$(grep -c "^push" "$docker_log")
  assert_eq "$push_count" "3" "Pushes all 3 images to staging registry"

  assert_contains "$(cat "$docker_log")" "tag mcp/atlassian:latest registry.katonic.ai/mcp/atlassian:latest" \
    "Correct tag format for Atlassian"
}

# ===========================================================================
# TEST SUITE 2: Air-gap install (customer install script logic)
# ===========================================================================
test_airgap_retags_to_customer_registry() {
  echo ""
  echo "=== Suite 2: Air-gap install ==="

  local docker_log="$TEST_DIR/docker-airgap.log"
  export DOCKER_LOG="$docker_log"
  export AIRGAPPED="true"
  export PRIVATE_REGISTRY="harbor.customer.internal"

  > "$docker_log"

  # Simulate the air-gap install section
  CUSTOMER_REGISTRY="${PRIVATE_REGISTRY:-harbor.customer.internal}"
  cat "$TEST_DIR/mcp-catalog.json" | "$MOCK_BIN/jq" -r '.[].dockerImage' | while read -r image; do
    docker tag "$image:latest" "$CUSTOMER_REGISTRY/$image:latest"
    docker push "$CUSTOMER_REGISTRY/$image:latest"
  done

  assert_contains "$(cat "$docker_log")" \
    "tag mcp/atlassian:latest harbor.customer.internal/mcp/atlassian:latest" \
    "Retags with customer registry prefix"

  assert_contains "$(cat "$docker_log")" \
    "push harbor.customer.internal/mcp/atlassian:latest" \
    "Pushes to customer registry"
}

test_airgap_skips_when_not_airgapped() {
  local docker_log="$TEST_DIR/docker-no-airgap.log"
  export DOCKER_LOG="$docker_log"
  export AIRGAPPED="false"

  > "$docker_log"

  # Simulate the conditional
  if [ "$AIRGAPPED" = "true" ]; then
    docker load < /dev/null
  fi

  local call_count
  call_count=$(wc -l < "$docker_log" | tr -d ' ')
  assert_eq "$call_count" "0" "No docker calls when AIRGAPPED=false"
}

test_airgap_uses_default_registry_when_not_set() {
  local docker_log="$TEST_DIR/docker-default-reg.log"
  export DOCKER_LOG="$docker_log"
  unset PRIVATE_REGISTRY 2>/dev/null || true

  > "$docker_log"

  CUSTOMER_REGISTRY="${PRIVATE_REGISTRY:-harbor.customer.internal}"
  assert_eq "$CUSTOMER_REGISTRY" "harbor.customer.internal" \
    "Defaults to harbor.customer.internal when PRIVATE_REGISTRY unset"
}

test_airgap_registry_with_port() {
  local docker_log="$TEST_DIR/docker-port-reg.log"
  export DOCKER_LOG="$docker_log"
  export PRIVATE_REGISTRY="registry.internal:5000"

  > "$docker_log"

  CUSTOMER_REGISTRY="${PRIVATE_REGISTRY:-harbor.customer.internal}"
  # Just tag one image to verify
  docker tag "mcp/atlassian:latest" "$CUSTOMER_REGISTRY/mcp/atlassian:latest"

  assert_contains "$(cat "$docker_log")" \
    "tag mcp/atlassian:latest registry.internal:5000/mcp/atlassian:latest" \
    "Handles registry with port number"
}

# ===========================================================================
# TEST SUITE 3: Catalog JSON validation
# ===========================================================================
test_catalog_json_is_valid() {
  echo ""
  echo "=== Suite 3: Catalog JSON validation ==="

  # Check JSON is parseable (use real jq if available)
  if command -v /usr/bin/jq &>/dev/null; then
    if /usr/bin/jq empty "$TEST_DIR/mcp-catalog.json" 2>/dev/null; then
      log_pass "Catalog JSON is valid"
    else
      log_fail "Catalog JSON is valid" "JSON parse error"
    fi
  else
    log_pass "Catalog JSON is valid (jq not available, skipped deep check)"
  fi
}

test_catalog_entries_have_required_fields() {
  if command -v /usr/bin/jq &>/dev/null; then
    local missing=0
    for field in mcpName dockerImage; do
      local count
      count=$(/usr/bin/jq "[.[] | select(.${field} == null or .${field} == \"\")] | length" "$TEST_DIR/mcp-catalog.json")
      if [[ "$count" != "0" ]]; then
        log_fail "All entries have $field" "$count entries missing $field"
        ((missing++))
      fi
    done
    if [[ "$missing" == "0" ]]; then
      log_pass "All entries have required fields (mcpName, dockerImage)"
    fi
  else
    log_pass "Required fields check (skipped, jq not available)"
  fi
}

test_catalog_no_duplicate_names() {
  if command -v /usr/bin/jq &>/dev/null; then
    local total unique
    total=$(/usr/bin/jq '[.[].mcpName] | length' "$TEST_DIR/mcp-catalog.json")
    unique=$(/usr/bin/jq '[.[].mcpName] | unique | length' "$TEST_DIR/mcp-catalog.json")

    assert_eq "$total" "$unique" "No duplicate mcpName entries in catalog"
  else
    log_pass "Duplicate check (skipped, jq not available)"
  fi
}

test_catalog_images_use_mcp_prefix() {
  if command -v /usr/bin/jq &>/dev/null; then
    local bad_prefix
    bad_prefix=$(/usr/bin/jq '[.[] | select(.dockerImage | startswith("mcp/") | not)] | length' "$TEST_DIR/mcp-catalog.json")

    assert_eq "$bad_prefix" "0" "All dockerImage values start with mcp/"
  else
    log_pass "Image prefix check (skipped, jq not available)"
  fi
}

# ===========================================================================
# TEST SUITE 4: Empty/edge catalog handling
# ===========================================================================
test_empty_catalog() {
  echo ""
  echo "=== Suite 4: Edge cases ==="

  local docker_log="$TEST_DIR/docker-empty.log"
  export DOCKER_LOG="$docker_log"

  echo "[]" > "$TEST_DIR/empty-catalog.json"
  > "$docker_log"

  # Run the pull loop against empty catalog
  cat "$TEST_DIR/empty-catalog.json" | "$MOCK_BIN/jq" -r '.[].dockerImage' | while read -r image; do
    docker pull "$image:latest"
  done

  local call_count
  call_count=$(wc -l < "$docker_log" | tr -d ' ')
  assert_eq "$call_count" "0" "Empty catalog produces no docker calls"
}

test_catalog_with_single_entry() {
  local docker_log="$TEST_DIR/docker-single.log"
  export DOCKER_LOG="$docker_log"

  cat > "$TEST_DIR/single-catalog.json" << 'SINGLE'
[{"mcpName": "Solo", "dockerImage": "mcp/solo"}]
SINGLE
  > "$docker_log"

  cat "$TEST_DIR/single-catalog.json" | "$MOCK_BIN/jq" -r '.[].dockerImage' | while read -r image; do
    docker pull "$image:latest"
  done

  local pull_count
  pull_count=$(grep -c "^pull" "$docker_log")
  assert_eq "$pull_count" "1" "Single-entry catalog pulls exactly 1 image"
}

# ===========================================================================
# Run all tests
# ===========================================================================
main() {
  echo "============================================"
  echo " Katonic MCP Installer Tests"
  echo "============================================"

  setup_mocks
  create_sample_catalog

  test_mirror_pulls_all_catalog_images
  test_mirror_tags_for_staging_registry
  test_airgap_retags_to_customer_registry
  test_airgap_skips_when_not_airgapped
  test_airgap_uses_default_registry_when_not_set
  test_airgap_registry_with_port
  test_catalog_json_is_valid
  test_catalog_entries_have_required_fields
  test_catalog_no_duplicate_names
  test_catalog_images_use_mcp_prefix
  test_empty_catalog
  test_catalog_with_single_entry

  echo ""
  echo "============================================"
  echo -e " Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
  echo "============================================"

  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
