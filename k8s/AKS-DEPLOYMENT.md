# Katonic Platform - AKS (Azure Kubernetes Service) Deployment Guide

## Prerequisites

- **Azure CLI** (`az`) v2.50+ logged in
- **kubectl** configured to talk to your AKS cluster
- **Docker** with buildx support (for cross-platform builds)
- **kustomize** v5.4+ (or use `kubectl -k`)
- **istioctl** v1.26+ (included in `k8s/istio-1.26.0/bin/`)
- An **AKS cluster** running (e.g., `katonic-platform-test-cluster`)
- An **Azure Container Registry** (ACR) attached to the cluster
- **Istio** default profile installed on the cluster (`istiod` + `istio-ingressgateway`)

```bash
# Login to Azure
az login

# Set AKS credentials
az aks get-credentials \
  --resource-group NewDevOpsTesting \
  --name katonic-platform-test-cluster

# Verify connection
kubectl get nodes

# Install Istio default profile (if not already installed)
k8s/istio-1.26.0/bin/istioctl install --set profile=default
```

---

## Quick Start

```bash
cd k8s

# 1. Login to ACR
az acr login --name katonic

# 2. Build and push all images to ACR
./deploy-aks.sh build

# 3. Deploy to AKS (production overlay)
./deploy-aks.sh deploy

# 4. Check pod status
./deploy-aks.sh status

# 5. Get access URL
./deploy-aks.sh urls
```

---

## deploy-aks.sh Commands

| Command | Description |
|---------|-------------|
| `./deploy-aks.sh build` | Build all 16 service images and push to ACR |
| `./deploy-aks.sh build <service>` | Build and push a single service (e.g., `admin-api`) |
| `./deploy-aks.sh deploy` | Deploy platform using `production` overlay |
| `./deploy-aks.sh status` | Show all pods, services, statefulsets, deployments, PVCs, Istio resources |
| `./deploy-aks.sh urls` | Print the external access URL (Istio ingress gateway IP) |
| `./deploy-aks.sh restart` | Rolling restart of all deployments (pulls fresh images) |
| `./deploy-aks.sh teardown` | Delete the entire `katonic` namespace |

---

## Azure Setup (One-Time)

### 1. Create ACR (if not exists)

```bash
az acr create \
  --resource-group NewDevOpsTesting \
  --name katonic \
  --sku Basic
```

### 2. Attach ACR to AKS

This allows AKS nodes to pull images from ACR without explicit credentials:

```bash
az aks update \
  --resource-group NewDevOpsTesting \
  --name katonic-platform-test-cluster \
  --attach-acr katonic
```

### 3. TLS Certificate (for HTTPS)

The Istio gateway uses a TLS secret `kt-certs` in the `istio-system` namespace for HTTPS termination on `preview.katonic.ai`:

```bash
# Create the TLS secret (replace with your actual cert/key files)
kubectl create secret tls kt-certs \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n istio-system
```

### 4. DNS Configuration

Point your domain to the Istio ingress gateway external IP:

```bash
# Get the external IP
kubectl -n istio-system get svc istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Add an A record: `preview.katonic.ai` -> `<EXTERNAL_IP>`

### 5. GitHub Secrets (for CI/CD automation)

Configure these in your repo's Settings > Secrets and variables > Actions:

**Secrets:**

| Secret | How to get it |
|--------|---------------|
| `AZURE_CREDENTIALS` | `az ad sp create-for-rbac --sdk-auth --role contributor --scopes /subscriptions/<sub-id>` |
| `ACR_USERNAME` | `az acr credential show --name katonic --query username -o tsv` |
| `ACR_PASSWORD` | `az acr credential show --name katonic --query "passwords[0].value" -o tsv` |

**Variables:**

| Variable | Value |
|----------|-------|
| `ACR_REGISTRY` | `katonic.azurecr.io` |
| `AKS_CLUSTER_NAME` | `katonic-platform-test-cluster` |
| `AKS_RESOURCE_GROUP` | `NewDevOpsTesting` |
| `PLATFORM_DOMAIN` | `preview.katonic.ai` |

---

## Building & Pushing Images to ACR

### Build all images

```bash
# Login to ACR first
az acr login --name katonic

# Build all 16 services (cross-compiled for linux/amd64)
./deploy-aks.sh build
```

### Build a single image

```bash
./deploy-aks.sh build admin-api
./deploy-aks.sh build katonic-frontend
./deploy-aks.sh build seed-all
```

### Manual build (without script)

```bash
# From repo root -- services using root context
docker buildx build \
  --platform linux/amd64 \
  -t katonic.azurecr.io/admin-api:latest \
  -f admin-api/Dockerfile . --push

# Frontend (source dir is platform-frontend, image name is katonic-frontend)
docker buildx build \
  --platform linux/amd64 \
  -t katonic.azurecr.io/katonic-frontend:latest \
  -f platform-frontend/Dockerfile platform-frontend/ --push

# Seed job (root context, Dockerfile.seed)
docker buildx build \
  --platform linux/amd64 \
  -t katonic.azurecr.io/seed-all:latest \
  -f Dockerfile.seed . --push
```

### Verify images in ACR

```bash
az acr repository list --name katonic -o table
az acr repository show-tags --name katonic --repository admin-api -o table
```

---

## Accessing Services

### HTTPS via Istio Ingress Gateway (Primary)

External traffic enters through the Istio ingress gateway with TLS termination via `kt-gateway`, which routes to `katonic-frontend` via VirtualService:

```
https://preview.katonic.ai
```

| Zone | URL |
|------|-----|
| ACE (chat workspace) | https://preview.katonic.ai/ace |
| Run (ops dashboard) | https://preview.katonic.ai/dashboard |
| Studio (agent builder) | https://preview.katonic.ai/studio/agents |
| Marketplace (catalog) | https://preview.katonic.ai/marketplace |

> **Note:** HTTP requests on port 80 are automatically redirected to HTTPS (301). All external traffic flows through the Istio ingress gateway with TLS 1.2/1.3.

### kubectl port-forward (alternative)

```bash
kubectl port-forward -n katonic svc/katonic-frontend 3000:3000
kubectl port-forward -n katonic svc/admin-api 8000:8000
kubectl port-forward -n katonic svc/platform-backend 3002:3002
```

---

## Manifest Structure

```
k8s/
├── base/                              # Shared base manifests
│   ├── namespace.yaml
│   ├── configmap.yaml                 # platform-config (service URLs, infra config)
│   ├── secret.yaml                    # platform-secret (DB credentials, keys)
│   ├── kustomization.yaml
│   ├── pdb.yaml                       # PodDisruptionBudgets (17 services)
│   ├── infra/
│   │   ├── postgres.yaml              # PostgreSQL 16 StatefulSet + init SQL
│   │   ├── redis.yaml                 # Redis 7 StatefulSet
│   │   └── clickhouse.yaml            # ClickHouse 24.3 StatefulSet (4Gi memory)
│   ├── backends/                      # 13 backend Deployments
│   ├── frontends/
│   │   └── katonic-frontend.yaml      # Unified UI (nginx + SPA)
│   ├── jobs/
│   │   └── seed-all.yaml              # Database & catalog seeding Job
│   ├── istio/                         # Istio service mesh resources
│   │   ├── gateway.yaml               # kt-gateway (HTTPS 443 + HTTP→HTTPS redirect)
│   │   ├── virtual-services.yaml      # Traffic routing rules
│   │   ├── destination-rules.yaml     # mTLS + circuit breaking (17 rules)
│   │   └── peer-authentication.yaml   # Namespace-wide PERMISSIVE mTLS
│   └── optional/
│       └── milvus.yaml                # etcd + MinIO + Milvus stack
├── overlays/
│   ├── aks/                           # AKS-specific resources
│   │   ├── kustomization.yaml
│   │   └── katonic-frontend.yaml      # ClusterIP Service + Deployment (ACR image)
│   ├── minikube/                      # Local dev (NodePort, reduced resources)
│   │   ├── kustomization.yaml
│   │   └── nodeport-services.yaml
│   └── production/                    # AKS production overlay
│       └── kustomization.yaml         # ACR images, Always pull, HA patches
├── istio-1.26.0/                      # Istio CLI tools & manifests
│   ├── bin/istioctl                   # istioctl binary (gitignored)
│   ├── manifests/                     # Istio Helm charts & profiles
│   └── samples/                       # Sample configurations
├── deploy.sh                          # Minikube deploy script
├── deploy-aks.sh                      # AKS deploy script
├── README.md                          # Minikube deployment guide
└── AKS-DEPLOYMENT.md                  # This file
```

---

## Production Overlay Patches

The `k8s/overlays/production/kustomization.yaml` applies these patches on top of the base:

| Patch | What it does |
|-------|-------------|
| `imagePullSecrets: []` | Removes Docker Hub secrets (ACR uses managed identity) |
| `imagePullPolicy: Always` | Forces image pull on every deploy (mutable tags) |
| `images:` section | Remaps `katonic/<svc>:latest` to `katonic.azurecr.io/<svc>:latest` |

> **Note:** The katonic-frontend LoadBalancer patch is commented out since external access flows through the Istio ingress gateway with HTTPS. To re-enable direct LoadBalancer access, uncomment the patch in `kustomization.yaml`.

---

## Services Overview

### Infrastructure (StatefulSets with PVCs)

| Service | Image | Port | PVC Size | Memory Limit |
|---------|-------|------|----------|--------------|
| PostgreSQL | `postgres:16-alpine` | 5432 | 5Gi | 1Gi |
| Redis | `redis:7-alpine` | 6379 | 1Gi | 256Mi |
| ClickHouse | `clickhouse/clickhouse-server:24.3` | 8123, 9000 | 5Gi | 4Gi |

### Backend Deployments (from ACR)

| Service | ACR Image | Port | Health Endpoint |
|---------|-----------|------|-----------------|
| admin-api | `katonic.azurecr.io/admin-api` | 8000 | `/v1/health` |
| agent-api | `katonic.azurecr.io/agent-api` | 8000 | `/v1/health` |
| agent-runtime | `katonic.azurecr.io/agent-runtime` | 8000 | `/v1/health` |
| ai-gateway | `katonic.azurecr.io/ai-gateway` | 8010 | `/healthz` |
| governance-proxy | `katonic.azurecr.io/governance-proxy` | 8000 | `/v1/health/live` |
| guardrails-engine | `katonic.azurecr.io/guardrails-engine` | 8000 | `/health` |
| knowledge-engine | `katonic.azurecr.io/knowledge-engine` | 8011 | `/v1/health/live` |
| mcp-gateway | `katonic.azurecr.io/mcp-gateway` | 8009 | `/v1/health` |
| model-deployment-service | `katonic.azurecr.io/model-deployment-service` | 8012 | `/health` |
| observability | `katonic.azurecr.io/observability` | 8000 | `/healthz` |
| platform-backend | `katonic.azurecr.io/platform-backend` | 3002 | `/platform/api/health` |
| remote-connections | `katonic.azurecr.io/remote-connections` | 8014 | `/health` |
| workspace-service | `katonic.azurecr.io/workspace-service` | 8013 | `/health` |

### Frontend

| Service | ACR Image | Port | Container |
|---------|-----------|------|-----------|
| katonic-frontend | `katonic.azurecr.io/katonic-frontend` | 3000 | nginx (static SPA + API proxy) |

### Seed Job

| Service | ACR Image | Purpose |
|---------|-----------|---------|
| seed-all | `katonic.azurecr.io/seed-all` | Seeds databases, providers, MCP catalog, models |

### Optional (Milvus Stack)

| Service | Port | PVC Size |
|---------|------|----------|
| etcd | 2379 | 2Gi |
| MinIO | 9000, 9001 | 5Gi |
| Milvus | 19530 | 5Gi |

---

## CI/CD Pipeline

The platform uses a 3-stage GitHub Actions pipeline:

```
Merge to main
  -> CI: Test & Lint (ci-test.yml)
     -> CI: Build & Push Images (ci-build-images.yml)  ->  ACR
        -> CD: Deploy to Production (cd-deploy-production.yml)  ->  AKS
```

### Pipeline Flow

1. **ci-test.yml** - Runs on push to `main`, tags, and PRs
   - Python tests (pytest) for 11 backend services
   - Frontend build check (`katonic-frontend` via npm)
   - K8s manifest validation (kustomize build for minikube + production)
   - Dockerfile linting (hadolint)

2. **ci-build-images.yml** - Triggers after tests pass
   - Builds all 16 images in parallel (13 backends + katonic-frontend + seed-all + ai-gateway)
   - Pushes to `katonic.azurecr.io` with branch/tag + sha + latest tags
   - Cross-compiled for `linux/amd64`

3. **cd-deploy-production.yml** - Triggers after images are built
   - Azure Login + AKS context setup
   - Updates image tags via kustomize
   - Configures Istio Gateway/VirtualService domain (`preview.katonic.ai`)
   - Applies production overlay
   - Restarts deployments for Istio sidecar injection
   - Verifies deployment health (pods, services, Istio resources)
   - Posts deployment summary + DNS configuration
   - Notifies via Slack/Discord (if configured)

### Manual Deployment

You can trigger the CD workflow manually from the Actions tab:

```bash
gh workflow run "CD: Deploy to Production Kubernetes" \
  --field tag=main \
  --field environment=production \
  --field dry_run=false
```

---

## Istio Service Mesh

The platform uses **Istio 1.26** (default profile) for service mesh capabilities: TLS termination, mTLS encryption, traffic management, circuit breaking, and observability.

### Architecture

```
External Traffic (HTTPS)
       │
       ▼
┌──────────────────────────┐
│  Istio Ingress GW        │  preview.katonic.ai:443 (TLS 1.2-1.3)
│  (istio-system ns)       │  HTTP:80 → HTTPS redirect (301)
│  Gateway: kt-gateway     │  TLS cert: kt-certs
└──────────┬───────────────┘
           │ VirtualService: katonic-ingress
           ▼
┌──────────────────────────┐
│    katonic-frontend      │  :3000 (nginx SPA + API proxy)
│    [istio-proxy]         │
└──────────┬───────────────┘
           │ nginx proxy_pass
           ▼
┌─────────────────────────────────────────────┐
│           Backend Services (13)              │
│  Each pod: [app-container] + [istio-proxy]  │
│  mTLS between all mesh services             │
└─────────────────┬───────────────────────────┘
                  │ plaintext (PERMISSIVE)
                  ▼
┌─────────────────────────────────────────────┐
│        Infrastructure (3 StatefulSets)       │
│  postgres, redis, clickhouse                 │
│  NO sidecar — excluded from mesh             │
└─────────────────────────────────────────────┘
```

### Istio Resources

| Resource | Name | Namespace | Purpose |
|----------|------|-----------|---------|
| **Gateway** | `kt-gateway` | `istio-system` | HTTPS termination (TLS 1.2-1.3, `kt-certs`), HTTP→HTTPS redirect |
| **VirtualService** | `katonic-ingress` | `katonic` | Routes `preview.katonic.ai/*` to katonic-frontend:3000 |
| **VirtualService** | `ai-gateway-internal` | `katonic` | 300s timeout for LLM inference calls |
| **VirtualService** | `agent-runtime-internal` | `katonic` | 300s timeout for agent execution |
| **DestinationRule** (x17) | Per-service | `katonic` | mTLS policy + circuit breaking + connection pooling |
| **PeerAuthentication** | `katonic-default` | `katonic` | Namespace-wide `PERMISSIVE` mTLS |

### TLS Configuration

The gateway supports TLS 1.2 and 1.3 with these cipher suites:

- `ECDHE-ECDSA-AES128-GCM-SHA256`
- `ECDHE-ECDSA-AES256-GCM-SHA384`
- `ECDHE-RSA-AES128-GCM-SHA256`
- `ECDHE-RSA-AES256-GCM-SHA384`
- `ECDHE-RSA-CHACHA20-POLY1305`

### Sidecar Injection

| Component | Sidecar | READY | Why |
|-----------|---------|-------|-----|
| 14 Deployments (backends + frontend) | `istio-proxy` | 2/2 | Full mesh benefits: mTLS, observability, circuit breaking |
| 3 StatefulSets (postgres, redis, clickhouse) | excluded | 1/1 | Proprietary TCP protocols, no mesh value, avoids connection drain issues |

Sidecar exclusion is controlled via pod annotation:
```yaml
annotations:
  sidecar.istio.io/inject: "false"
```

### mTLS Configuration

- **Mode:** `PERMISSIVE` (accepts both mTLS and plaintext)
- **App-to-App:** Automatic mTLS via `ISTIO_MUTUAL` DestinationRules
- **App-to-Infra:** Plaintext (infra has `tls.mode: DISABLE`)
- **Upgrade to STRICT:** Once validated, edit `peer-authentication.yaml` to set `mode: STRICT`

### Circuit Breaking

All application DestinationRules include outlier detection:

| Parameter | Standard Services | AI/LLM Services |
|-----------|-------------------|------------------|
| Max connections | 100 | 200 |
| Idle timeout | default | 300s |
| Consecutive 5xx errors | 5 | 5 |
| Ejection time | 30s | 30s |
| Max ejection % | 50% | 50% |

### Verifying Istio

```bash
# Check sidecar injection (should see 2/2 for deployments, 1/1 for statefulsets)
kubectl get pods -n katonic

# Check Istio resources in katonic namespace
kubectl get virtualservices,destinationrules,peerauthentication -n katonic

# Check Istio Gateway in istio-system namespace
kubectl get gateways -n istio-system

# Check ingress gateway external IP
kubectl get svc istio-ingressgateway -n istio-system

# View istio-proxy logs for a specific pod
kubectl logs -n katonic deployment/admin-api -c istio-proxy --tail=20

# Test HTTPS access
curl -v https://preview.katonic.ai/

# Test HTTP→HTTPS redirect
curl -v http://preview.katonic.ai/

# Verify TLS certificate
openssl s_client -connect preview.katonic.ai:443 -servername preview.katonic.ai </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
```

### Istio CLI Tools

The `istioctl` binary is available at `k8s/istio-1.26.0/bin/istioctl`:

```bash
# Check Istio mesh status
k8s/istio-1.26.0/bin/istioctl proxy-status

# Analyze mesh configuration for issues
k8s/istio-1.26.0/bin/istioctl analyze -n katonic

# Install/upgrade Istio default profile
k8s/istio-1.26.0/bin/istioctl install --set profile=default
```

### Rollback (Remove Istio)

To remove Istio integration while keeping services running:

```bash
# Remove sidecar injection label
kubectl label namespace katonic istio-injection-

# Restart deployments to remove sidecars
kubectl rollout restart deployment -n katonic

# Optionally delete Istio resources
kubectl delete virtualservices,destinationrules,peerauthentication --all -n katonic
kubectl delete gateways --all -n istio-system

# Re-enable direct LoadBalancer (uncomment patch in production kustomization.yaml)
```

---

## Auto-Healing & High Availability

The platform is configured for automatic self-healing and high availability in production.

### Startup Probes

All 17 services have **startup probes** that prevent Kubernetes from killing slow-starting pods. The liveness probe only activates after the startup probe succeeds.

| Service Type | Startup Budget | Examples |
|-------------|----------------|----------|
| Standard backends | 300s (5 min) | admin-api, agent-api, platform-backend |
| Heavy backends | 600s (10 min) | knowledge-engine, governance-proxy, guardrails-engine |
| Frontend | 150s | katonic-frontend |
| Infrastructure | 150-300s | postgres, redis, clickhouse |

### Replica Counts (Production)

All services run single replicas to minimize cost on a 1-node cluster. HA replica patches are pre-configured but commented out in `k8s/overlays/production/kustomization.yaml` -- uncomment when ready to scale:

| Tier | Services | Current | HA (uncomment) |
|------|----------|---------|-----------------|
| **Critical** | katonic-frontend, platform-backend, admin-api | 1 | 2 |
| **Important** | ai-gateway, agent-api, agent-runtime | 1 | 2 |
| **Supporting** | 8 other backends | 1 | 1 |
| **Infrastructure** | postgres, redis, clickhouse | 1 | 1 |

### PodDisruptionBudgets

All 17 services have PDBs with `minAvailable: 1`:

```bash
# Check PDB status
kubectl get pdb -n katonic

# With 1 replica: ALLOWED DISRUPTIONS = 0 (blocks voluntary eviction)
# With 2 replicas: ALLOWED DISRUPTIONS = 1 (allows 1 pod disruption)
```

### Self-Healing Behavior

| Scenario | What Happens |
|----------|-------------|
| Pod crashes | Kubernetes restarts it immediately (restartPolicy: Always) |
| Slow startup | Startup probe gives 5-10 min before killing (prevents CrashLoopBackOff) |
| Transient failure | Liveness probe allows 5 failures (75s) before restarting |
| Node drain/upgrade | PDB blocks eviction if it would take service to 0 pods |
| Resource pressure | AKS cluster autoscaler adds nodes when pods are Pending |

### Enabling HA (Multi-Replica)

When ready to scale for zero-downtime, uncomment the replica patches in `k8s/overlays/production/kustomization.yaml`:

```bash
# After uncommenting:
kubectl apply -k k8s/overlays/production
# This will scale 6 critical services to 2 replicas (17 -> 23 pods)
# AKS autoscaler will add nodes if needed
```

### Testing Self-Healing

```bash
# Kill a pod and watch it auto-restart
kubectl delete pod -n katonic -l app=admin-api --force --grace-period=0
kubectl get pods -n katonic -l app=admin-api -w
# Pod will be recreated within seconds
```

---

## Seed Job

The `seed-all` Job seeds the platform databases with initial data:

- Creates 3 databases: `katonic_platform`, `katonic`, `knowledge_engine`
- Creates all required tables via SQLAlchemy models
- Seeds 14 AI providers and 28 LLM models
- Seeds 30 MCP server images (foundation catalog)

```bash
# Run the seed job (included in deploy)
kubectl apply -f k8s/base/jobs/seed-all.yaml

# Check seed job status
kubectl get jobs -n katonic
kubectl logs job/seed-all -n katonic

# If stuck due to Istio sidecar (shows 1/2 NotReady after completion):
kubectl exec seed-all-<pod-id> -n katonic -c istio-proxy \
  -- curl -s -X POST http://localhost:15020/quitquitquit
```

---

## Docker Image Optimization

All Python backend images use **multi-stage builds** to minimize image size:

| Optimization | Services | Savings |
|-------------|----------|---------|
| Multi-stage (remove build-essential + spaCy build tools) | governance-proxy, guardrails-engine | ~200MB each |
| Multi-stage (remove gcc, g++, cmake) | knowledge-engine | ~250MB |
| Multi-stage (remove gcc) | model-deployment-service, workspace-service, remote-connections | ~100MB each |
| `.dockerignore` | All 16 services | Faster builds |
| `python:3.x-slim` base | All Python services | vs full python image |
| `node:20-alpine` + `nginx:1.27-alpine` | katonic-frontend, platform-backend | ~50-100MB final |

---

## Troubleshooting

### ImagePullBackOff

ACR isn't attached to AKS. Fix:

```bash
az aks update \
  --resource-group NewDevOpsTesting \
  --name katonic-platform-test-cluster \
  --attach-acr katonic
```

### PostgreSQL CrashLoopBackOff (lost+found)

AKS managed disks create a `lost+found` directory at the mount root. The `PGDATA` env var must point to a subdirectory:

```yaml
- name: PGDATA
  value: "/var/lib/postgresql/data/pgdata"
```

This is already configured in `k8s/base/infra/postgres.yaml`.

### ClickHouse OOMKilled

ClickHouse 24.3 requires at least 4Gi memory on AKS. If it crashes with exit code 137:

```bash
# Verify memory limits
kubectl get sts clickhouse -n katonic -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# Should show: 4Gi
```

### Services failing to connect to PostgreSQL

If backend services start before PostgreSQL is ready, they'll crash and enter CrashLoopBackOff. Wait for PostgreSQL to be ready, then restart the failing pods:

```bash
# Wait for postgres
kubectl wait --for=condition=ready pod -l app=postgres -n katonic --timeout=120s

# Restart failing deployments
kubectl rollout restart deployment -n katonic
```

### Pods showing 1/1 instead of 2/2 (missing sidecar)

If deployment pods show 1/1 instead of 2/2, the Istio sidecar wasn't injected:

```bash
# Verify namespace has injection label
kubectl get ns katonic --show-labels | grep istio-injection

# Restart deployments to trigger sidecar injection
kubectl rollout restart deployment -n katonic
```

### 503 errors between services (Istio mTLS)

If services get 503 errors when calling each other through the mesh:

```bash
# Check istio-proxy logs for the failing pod
kubectl logs -n katonic deployment/<service> -c istio-proxy --tail=50

# Verify DestinationRules exist
kubectl get destinationrules -n katonic

# Check if PeerAuthentication is PERMISSIVE
kubectl get peerauthentication -n katonic -o yaml
```

### Checking logs

```bash
# Application logs
kubectl logs -n katonic deployment/admin-api --tail=50
kubectl logs -n katonic deployment/governance-proxy -f
kubectl logs -n katonic deployment/knowledge-engine --previous

# Istio sidecar logs
kubectl logs -n katonic deployment/admin-api -c istio-proxy --tail=50
```

### Force restart a service

```bash
kubectl rollout restart deployment/<service-name> -n katonic
```

### Full reset

```bash
./deploy-aks.sh teardown
./deploy-aks.sh deploy
```

---

## Key Differences: Minikube vs AKS

| Aspect | Minikube | AKS (Production) |
|--------|----------|-------------------|
| Image registry | Local Docker daemon | Azure Container Registry (ACR) |
| Image pull | `IfNotPresent` (local) | `Always` (from ACR) |
| Service access | NodePort (30000) | Istio ingress gateway (HTTPS 443) |
| TLS | None | TLS 1.2-1.3 via kt-gateway |
| Domain | `localhost:30000` | `preview.katonic.ai` |
| Service mesh | None | Istio (mTLS, circuit breaking, traffic mgmt) |
| Image pull auth | Docker Hub secret | ACR managed identity |
| Resources | Reduced (8GB VM) | Base limits (production) |
| Build target | `docker build` | `docker buildx --platform linux/amd64` |
| PGDATA | Default | `/var/lib/postgresql/data/pgdata` (managed disk) |
| Pod containers | 1 per pod | 2 per pod (app + istio-proxy sidecar) |
| Inter-service security | Plaintext | mTLS (automatic via Istio) |
