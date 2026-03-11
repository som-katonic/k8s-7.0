# E2E Integration Tests

## Prerequisites

- kubectl configured to target cluster
- Platform installed and running
- curl, jq installed

## Usage

```bash
# Run all suites
PLATFORM_URL=https://ai.company.com \
ADMIN_EMAIL=admin@company.com \
ADMIN_PASSWORD=changeme \
  ./run-e2e.sh

# Run specific suite
./run-e2e.sh health
./run-e2e.sh tenant-isolation
```

## Suites

| Suite | Tests | What it validates |
|-------|-------|-------------------|
| health | 7+ | All pods running, health endpoints return 200 |
| auth | 3 | Admin login, JWT claims, invalid credentials rejected |
| tenant-manager | 3 | Default org, RBAC roles seeded, license status |
| tenant-isolation | 5 | Create 2 orgs, verify data isolation (cloud mode only) |
| agent-lifecycle | 4 | CRUD: create, read, update, delete agent |
| upgrade | 2 | Pod stability check (prep for idempotent re-install) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| PLATFORM_URL | (required) | Base URL of the platform |
| ADMIN_EMAIL | admin@company.com | Admin user email |
| ADMIN_PASSWORD | changeme | Admin user password |
| KEYCLOAK_URL | {PLATFORM_URL}/auth | Keycloak base URL |
