# Katonic Platform Architecture

## Namespace Layout

```
katonic-system        # All platform services (22 backend + 5 frontend)
katonic-infra         # PostgreSQL, Redis, Milvus, MinIO, ClickHouse, MongoDB, Temporal
katonic-keycloak      # Keycloak authentication server
katonic-monitoring    # Prometheus, Grafana, Alertmanager
cert-manager          # TLS certificate management
istio-system          # Service mesh + API gateway
velero                # Backup operator (when enabled)
```

In multi-tenant (cloud) mode, each organization also gets:
```
tenant-{org-slug}-dev     # Development environment
tenant-{org-slug}-prod    # Production environment
```

## Service Architecture

```
                         Internet
                            |
                       [Istio Gateway]
                            |
     +----------+-----------+-----------+-----------+
     |          |           |           |           |
 ops-console  employee-ws  agent-studio  marketplace  distributor-console
 (RUN)        (ACE)        (BUILD)      (DISCOVER)    (DISTRIBUTE)
     |          |           |                          |
     +-----+---+-----+-----+           tenant-manager-+
           |         |
      [ace-bff]  [admin-api]----[public-api-gateway]
           |         |
  +--------+---------+--------+
  |        |         |        |
agent-api ai-gateway mcp-gateway katonic-mcp-server
  |        |         |
agent-    |     remote-connections
runtime   |
  |       +--[eval-engine]--[prompt-optimizer]
  |       |
  +---+---+---+
      |       |
knowledge  guardrails-engine
-engine       |
  |       governance-proxy
  |           |
  +----+   observability    [ops-hub]  [autoscaler]
  |    |       |
Milvus MinIO  ClickHouse    [resource-manager]--[gpu-slicing]
                |
        +-------+-------+
        |               |
    PostgreSQL        Redis       MongoDB
        |
    Keycloak
```

## Data Flow

### Chat request (user sends message)

1. User browser -> Istio Gateway -> employee-workspace (React SPA)
2. employee-workspace -> ace-bff (Socket.IO/AG-UI)
3. ace-bff -> agent-api (create session, stream events)
4. agent-api -> agent-runtime (execute agent via ADK)
5. agent-runtime -> ai-gateway (LLM call with provider routing)
6. agent-runtime -> mcp-gateway -> MCP server containers (tool execution)
7. agent-runtime -> knowledge-engine -> Milvus (RAG vector search)
8. All calls pass through governance-proxy (PII masking, audit, approvals)
9. All calls checked by guardrails-engine (input/output safety)
10. observability records latency, cost, token usage to ClickHouse

### Organization provisioning (admin creates org)

1. distributor-console (or ops-console) -> tenant-manager `POST /api/v1/orgs`
2. tenant-manager checks license limits
3. tenant-manager creates org record in PostgreSQL
4. tenant-manager creates Keycloak realm via REST API
5. tenant-manager creates realm roles (org_admin, ai_engineer, etc.)
6. tenant-manager creates admin user in Keycloak
7. tenant-manager creates environments (dev, prod)
8. Each environment gets K8s namespace + Helm release
9. Audit log records entire operation

## Authentication Flow

```
User -> Keycloak login page (per-org realm)
     -> JWT issued with claims: tenant_id, roles, teams
     -> JWT sent to platform services
     -> TenantMiddleware extracts tenant_id
     -> TenantIsolation routes queries to correct PG schema
     -> RBAC middleware checks permissions
```

## Database Layout

### Control Plane (shared PostgreSQL)

Used by admin-api and tenant-manager:

| Table | Owner |
|-------|-------|
| organizations | tenant-manager |
| environments | tenant-manager |
| roles, permissions, role_permissions | tenant-manager |
| org_roles | tenant-manager |
| licenses | tenant-manager |
| provisioning_tasks, task_steps | tenant-manager |
| audit_log | tenant-manager |
| providers | admin-api |
| agents | admin-api |
| policies | admin-api |
| mcp_configs | admin-api |

### Per-Tenant Schema (cloud mode)

In multi-tenant mode, each org gets a PostgreSQL schema (`tenant_{slug}`)
containing its own copies of the per-tenant tables (agents, providers, etc.).
The control plane tables remain in the public schema.

## Port Assignments

| Port | Service | Protocol | Health Path |
|------|---------|----------|-------------|
| 80   | marketplace | HTTP | `/` |
| 3000 | ops-console | HTTP | `/` |
| 3001 | agent-studio | HTTP | `/` |
| 3002 | ace-bff | HTTP/WS | `/healthz` |
| 3010 | employee-workspace | HTTP | `/` |
| 3020 | distributor-console | HTTP | `/` |
| 8000 | tenant-manager | HTTP | `/healthz` |
| 8000 | gpu-slicing | HTTP | `/health` |
| 8003 | governance-proxy | HTTP | `/healthz` |
| 8004 | admin-api | HTTP | `/healthz` |
| 8005 | observability | HTTP | `/healthz` |
| 8006 | guardrails-engine | HTTP | `/healthz` |
| 8007 | agent-api | HTTP | `/healthz` |
| 8008 | agent-runtime | HTTP | `/healthz` |
| 8009 | mcp-gateway | HTTP | `/healthz` |
| 8010 | ai-gateway | HTTP | `/healthz` |
| 8011 | knowledge-engine | HTTP | `/healthz` |
| 8012 | model-deployment | HTTP | `/healthz` |
| 8013 | workspace-service | HTTP | `/healthz` |
| 8014 | remote-connections | HTTP | `/healthz` |
| 8015 | eval-engine | HTTP | `/healthz` |
| 8016 | public-api-gateway | HTTP | `/health` |
| 8017 | katonic-mcp-server | HTTP | `/health` |
| 8018 | ops-hub | HTTP | `/health` |
| 8019 | prompt-optimizer | HTTP | `/health` |
| 8020 | autoscaler | HTTP | `/healthz` |
| 8021 | resource-manager | HTTP | `/v1/health` |

### Infrastructure Ports

| Port | Service | Protocol | Purpose |
|------|---------|----------|---------|
| 5432 | PostgreSQL | TCP | Relational database |
| 6379 | Redis | TCP | Cache, pub/sub |
| 7233 | Temporal | gRPC | Workflow orchestration |
| 8123 | ClickHouse | HTTP | Analytics database |
| 9000 | MinIO | HTTP | Object storage |
| 19530 | Milvus | gRPC | Vector database |
| 27017 | MongoDB | TCP | Document database |

## Infrastructure Components

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 16.x | Relational data (orgs, agents, config) |
| Redis | 7.2.x | Caching, pub/sub, rate limiting, GPU TTL |
| Milvus | 2.4.x | Vector database for RAG |
| MinIO | Latest | Object storage (documents, models) |
| ClickHouse | 24.x | Analytics, observability, cost tracking |
| MongoDB | 7.x | Chat history (ace-bff), ops-hub data |
| MLflow | 2.x | Model registry, experiment tracking |
| Temporal | 1.24.x | Workflow orchestration (knowledge sync, graph cleanup) |
| Keycloak | 24.x | Authentication, per-org realms |
| Istio | 1.20.x | Service mesh, API gateway, mTLS |
| cert-manager | 1.14.x | TLS certificate management |
| kube-prometheus-stack | Latest | Monitoring (Prometheus, Grafana) |
