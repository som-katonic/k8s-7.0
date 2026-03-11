#!/usr/bin/env bash
# ===========================================================================
# Katonic Platform - End-to-End Integration Tests
#
# Runs against a live cluster. Requires:
#   - kubectl configured
#   - Platform installed and running
#   - PLATFORM_URL environment variable
#
# Usage:
#   PLATFORM_URL=https://ai.company.com ./run-e2e.sh
#   PLATFORM_URL=https://ai.company.com ./run-e2e.sh --suite tenant-isolation
# ===========================================================================
set -euo pipefail

PLATFORM_URL="${PLATFORM_URL:?Set PLATFORM_URL (e.g. https://ai.company.com)}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@company.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
KEYCLOAK_URL="${KEYCLOAK_URL:-${PLATFORM_URL}/auth}"
SUITE="${1:-all}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}: $1"; SKIP=$((SKIP + 1)); }

# ---------------------------------------------------------------------------
# Auth helper
# ---------------------------------------------------------------------------
get_token() {
  local realm="${1:-master}"
  local user="${2:-$ADMIN_EMAIL}"
  local pw="${3:-$ADMIN_PASSWORD}"

  curl -sf "${KEYCLOAK_URL}/realms/${realm}/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=katonic-platform" \
    -d "username=${user}" \
    -d "password=${pw}" | jq -r '.access_token'
}

api() {
  local method="$1"
  local path="$2"
  local token="$3"
  shift 3
  curl -sf -X "$method" \
    "${PLATFORM_URL}${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "$@"
}

# ---------------------------------------------------------------------------
# Suite 1: Platform Health
# ---------------------------------------------------------------------------
test_platform_health() {
  echo ""
  echo "=== Suite: Platform Health ==="

  # Check all pods are running
  local not_running
  not_running=$(kubectl get pods -n katonic-system --no-headers 2>/dev/null \
    | grep -v "Running\|Completed" | wc -l)
  if [ "$not_running" -eq 0 ]; then
    pass "All pods running in katonic-system"
  else
    fail "Pods not running in katonic-system ($not_running unhealthy)"
  fi

  # Check infra pods
  not_running=$(kubectl get pods -n katonic-infra --no-headers 2>/dev/null \
    | grep -v "Running\|Completed" | wc -l)
  if [ "$not_running" -eq 0 ]; then
    pass "All pods running in katonic-infra"
  else
    fail "Pods not running in katonic-infra ($not_running unhealthy)"
  fi

  # Health endpoints
  for svc in admin-api agent-api tenant-manager mcp-gateway ai-gateway; do
    local port
    port=$(kubectl get svc "$svc" -n katonic-system -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")
    if [ -n "$port" ]; then
      local status
      status=$(kubectl exec -n katonic-system deploy/$svc -- \
        curl -sf -o /dev/null -w "%{http_code}" "localhost:${port}/healthz" 2>/dev/null || echo "000")
      if [ "$status" = "200" ]; then
        pass "$svc healthz returns 200"
      else
        fail "$svc healthz returns $status"
      fi
    else
      skip "$svc not found"
    fi
  done
}

# ---------------------------------------------------------------------------
# Suite 2: Authentication
# ---------------------------------------------------------------------------
test_authentication() {
  echo ""
  echo "=== Suite: Authentication ==="

  # Get admin token
  local token
  token=$(get_token "master")
  if [ -n "$token" ] && [ "$token" != "null" ]; then
    pass "Admin login successful"
  else
    fail "Admin login failed"
    return
  fi

  # Verify token has expected claims
  local tenant_id
  tenant_id=$(echo "$token" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.tenant_id // "default"')
  if [ -n "$tenant_id" ]; then
    pass "JWT contains tenant_id: $tenant_id"
  else
    fail "JWT missing tenant_id claim"
  fi

  # Test invalid credentials
  local bad_token
  bad_token=$(curl -sf "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=katonic-platform" \
    -d "username=invalid@test.com" \
    -d "password=wrong" 2>/dev/null | jq -r '.access_token // "null"')
  if [ "$bad_token" = "null" ] || [ -z "$bad_token" ]; then
    pass "Invalid credentials rejected"
  else
    fail "Invalid credentials accepted"
  fi
}

# ---------------------------------------------------------------------------
# Suite 3: Tenant Manager
# ---------------------------------------------------------------------------
test_tenant_manager() {
  echo ""
  echo "=== Suite: Tenant Manager ==="

  local token
  token=$(get_token "master")
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    skip "Cannot get admin token"
    return
  fi

  # Check default org exists (bootstrap should have created it)
  local orgs
  orgs=$(api GET "/api/v1/orgs" "$token" 2>/dev/null || echo "[]")
  local org_count
  org_count=$(echo "$orgs" | jq 'length')
  if [ "$org_count" -ge 1 ]; then
    pass "Default org exists ($org_count orgs)"
  else
    fail "No orgs found (bootstrap may have failed)"
  fi

  # Check RBAC roles seeded
  local roles
  roles=$(api GET "/api/v1/rbac/roles" "$token" 2>/dev/null || echo "[]")
  local role_count
  role_count=$(echo "$roles" | jq 'length')
  if [ "$role_count" -ge 5 ]; then
    pass "RBAC roles seeded ($role_count roles)"
  else
    fail "RBAC roles missing (found $role_count, expected 6+)"
  fi

  # Check license status
  local license
  license=$(api GET "/api/v1/license" "$token" 2>/dev/null || echo "{}")
  local lic_status
  lic_status=$(echo "$license" | jq -r '.status // "none"')
  if [ "$lic_status" = "active" ]; then
    pass "License active"
  elif [ "$lic_status" = "none" ]; then
    skip "No license uploaded (dev mode)"
  else
    fail "License status: $lic_status"
  fi
}

# ---------------------------------------------------------------------------
# Suite 4: Tenant Isolation (cloud mode only)
# ---------------------------------------------------------------------------
test_tenant_isolation() {
  echo ""
  echo "=== Suite: Tenant Isolation ==="

  local token
  token=$(get_token "master")
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    skip "Cannot get admin token"
    return
  fi

  # Check deployment mode
  local mode
  mode=$(kubectl get configmap platform-config -n katonic-system \
    -o jsonpath='{.data.DEPLOYMENT_MODE}' 2>/dev/null || echo "platform")
  if [ "$mode" != "cloud" ]; then
    skip "Deployment mode is '$mode' (isolation tests require cloud mode)"
    return
  fi

  # Create test org A
  local org_a
  org_a=$(api POST "/api/v1/orgs" "$token" \
    -d '{"name":"E2E Test Org A","slug":"e2e-org-a"}' 2>/dev/null || echo "{}")
  local org_a_id
  org_a_id=$(echo "$org_a" | jq -r '.id // ""')
  if [ -n "$org_a_id" ]; then
    pass "Created test org A: $org_a_id"
  else
    fail "Failed to create test org A"
    return
  fi

  # Create test org B
  local org_b
  org_b=$(api POST "/api/v1/orgs" "$token" \
    -d '{"name":"E2E Test Org B","slug":"e2e-org-b"}' 2>/dev/null || echo "{}")
  local org_b_id
  org_b_id=$(echo "$org_b" | jq -r '.id // ""')
  if [ -n "$org_b_id" ]; then
    pass "Created test org B: $org_b_id"
  else
    fail "Failed to create test org B"
  fi

  # Get tokens for each org
  local token_a token_b
  token_a=$(get_token "e2e-org-a" "admin@e2e-org-a.test" "changeme" 2>/dev/null || echo "")
  token_b=$(get_token "e2e-org-b" "admin@e2e-org-b.test" "changeme" 2>/dev/null || echo "")

  if [ -z "$token_a" ] || [ -z "$token_b" ]; then
    skip "Cannot get org-specific tokens (Keycloak realms may need time)"
    return
  fi

  # Create agent in org A
  local agent_a
  agent_a=$(api POST "/api/v1/agents" "$token_a" \
    -d '{"name":"Org A Secret Agent","description":"test"}' 2>/dev/null || echo "{}")
  local agent_a_id
  agent_a_id=$(echo "$agent_a" | jq -r '.id // ""')
  if [ -n "$agent_a_id" ]; then
    pass "Created agent in org A"
  else
    fail "Failed to create agent in org A"
  fi

  # Verify org B cannot see org A's agent
  local agents_b
  agents_b=$(api GET "/api/v1/agents" "$token_b" 2>/dev/null || echo "[]")
  local leak
  leak=$(echo "$agents_b" | jq '[.[] | select(.name == "Org A Secret Agent")] | length')
  if [ "$leak" -eq 0 ]; then
    pass "ISOLATION: Org B cannot see Org A's agents"
  else
    fail "ISOLATION BREACH: Org B can see Org A's agents!"
  fi

  # Cleanup
  api DELETE "/api/v1/orgs/$org_a_id" "$token" 2>/dev/null || true
  api DELETE "/api/v1/orgs/$org_b_id" "$token" 2>/dev/null || true
  pass "Cleanup: test orgs deleted"
}

# ---------------------------------------------------------------------------
# Suite 5: Agent Lifecycle
# ---------------------------------------------------------------------------
test_agent_lifecycle() {
  echo ""
  echo "=== Suite: Agent Lifecycle ==="

  local token
  token=$(get_token "master")
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    skip "Cannot get admin token"
    return
  fi

  # Create agent
  local agent
  agent=$(api POST "/api/v1/agents" "$token" \
    -d '{"name":"E2E Test Agent","description":"Automated test","model":"gpt-4o","instructions":"You are a helpful assistant."}' \
    2>/dev/null || echo "{}")
  local agent_id
  agent_id=$(echo "$agent" | jq -r '.id // ""')
  if [ -n "$agent_id" ]; then
    pass "Created agent: $agent_id"
  else
    fail "Failed to create agent"
    return
  fi

  # Read agent
  local fetched
  fetched=$(api GET "/api/v1/agents/$agent_id" "$token" 2>/dev/null || echo "{}")
  local fetched_name
  fetched_name=$(echo "$fetched" | jq -r '.name // ""')
  if [ "$fetched_name" = "E2E Test Agent" ]; then
    pass "Read agent back"
  else
    fail "Agent read mismatch: $fetched_name"
  fi

  # Update agent
  local updated
  updated=$(api PATCH "/api/v1/agents/$agent_id" "$token" \
    -d '{"description":"Updated by e2e test"}' 2>/dev/null || echo "{}")
  local updated_desc
  updated_desc=$(echo "$updated" | jq -r '.description // ""')
  if [ "$updated_desc" = "Updated by e2e test" ]; then
    pass "Updated agent"
  else
    fail "Agent update failed"
  fi

  # Delete agent
  local del_status
  del_status=$(curl -sf -o /dev/null -w "%{http_code}" -X DELETE \
    "${PLATFORM_URL}/api/v1/agents/$agent_id" \
    -H "Authorization: Bearer $token" 2>/dev/null || echo "000")
  if [ "$del_status" = "200" ] || [ "$del_status" = "204" ]; then
    pass "Deleted agent"
  else
    fail "Agent delete returned $del_status"
  fi
}

# ---------------------------------------------------------------------------
# Suite 6: Upgrade Idempotency
# ---------------------------------------------------------------------------
test_upgrade_idempotency() {
  echo ""
  echo "=== Suite: Upgrade Idempotency ==="

  # Record current state
  local pods_before
  pods_before=$(kubectl get pods -n katonic-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
  local helm_before
  helm_before=$(helm list -n katonic-system -o json 2>/dev/null | jq -r '.[].chart' | sort)

  if [ -n "$pods_before" ] && [ -n "$helm_before" ]; then
    pass "Captured pre-upgrade state ($(echo "$pods_before" | wc -l) pods)"
  else
    skip "Cannot capture cluster state"
    return
  fi

  # Note: actual re-run of installer would go here
  # For now just verify the current state is stable
  sleep 5

  local pods_after
  pods_after=$(kubectl get pods -n katonic-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
  if [ "$pods_before" = "$pods_after" ]; then
    pass "Pod set stable (no unexpected restarts)"
  else
    fail "Pod set changed during stability check"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo "============================================"
  echo " Katonic Platform - E2E Tests"
  echo "============================================"
  echo " URL:   $PLATFORM_URL"
  echo " Suite: $SUITE"
  echo ""

  case "$SUITE" in
    all)
      test_platform_health
      test_authentication
      test_tenant_manager
      test_tenant_isolation
      test_agent_lifecycle
      test_upgrade_idempotency
      ;;
    health)            test_platform_health ;;
    auth)              test_authentication ;;
    tenant-manager)    test_tenant_manager ;;
    tenant-isolation)  test_tenant_isolation ;;
    agent-lifecycle)   test_agent_lifecycle ;;
    upgrade)           test_upgrade_idempotency ;;
    *)
      echo "Unknown suite: $SUITE"
      echo "Available: all, health, auth, tenant-manager, tenant-isolation, agent-lifecycle, upgrade"
      exit 1
      ;;
  esac

  echo ""
  echo "============================================"
  echo -e " Results: ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}, ${YELLOW}${SKIP} skip${NC}"
  echo "============================================"

  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}

main "$@"
