# Katonic Platform - Kubernetes Deployment Guide (Minikube)

> **Deploying to AKS?** See [AKS-DEPLOYMENT.md](AKS-DEPLOYMENT.md) for Azure Kubernetes Service deployment.

## Prerequisites

- **minikube** v1.30+ with Docker driver
- **kubectl** configured to talk to your cluster
- **Docker** for building images
- Minimum **4 CPUs, 8 GB RAM** allocated to minikube

```bash
minikube start --cpus=4 --memory=8192 --driver=docker
```

---

## Quick Start

```bash
cd k8s

# 1. Setup namespace + Docker registry secret
./deploy.sh setup

# 2. Deploy all services (default overlay: minikube)
./deploy.sh deploy

# 3. Check pod status
./deploy.sh status

# 4. Get access URLs
./deploy.sh urls
```

---

## deploy.sh Commands

| Command | Description |
|---------|-------------|
| `./deploy.sh setup` | Create `katonic` namespace + Docker Hub registry secret |
| `./deploy.sh deploy [overlay]` | Deploy platform (default: `minikube`) |
| `./deploy.sh milvus` | Deploy optional Milvus vector DB stack |
| `./deploy.sh status` | Show all pods, services, statefulsets, deployments, PVCs |
| `./deploy.sh urls` | Print access URLs |
| `./deploy.sh teardown` | Delete the entire `katonic` namespace |

---

## Docker Credentials

Add your Docker Hub credentials to `.env` in the project root:

```
DOCKER_USERNAME=your-username
DOCKER_PASSWORD=your-token
```

`deploy.sh setup` reads these to create the `dockerhub-secret` image pull secret.

---

## Building Images for Minikube

Point your shell at minikube's Docker daemon to build locally:

```bash
eval $(minikube docker-env)

# Build all services (from repo root)
make build

# Or build individual services
docker build -t katonic/admin-api:latest -f admin-api/Dockerfile .
docker build -t katonic/katonic-frontend:latest platform-frontend/
```

All deployments use `imagePullPolicy: IfNotPresent`, so locally built images take priority.

---

## Accessing Services

### Option 1: minikube tunnel (recommended)

```bash
minikube tunnel
```

Then visit http://localhost:30000 -- the unified UI with all zones:

| Zone | URL |
|------|-----|
| ACE (chat workspace) | http://localhost:30000/ace |
| Run (ops dashboard) | http://localhost:30000/dashboard |
| Studio (agent builder) | http://localhost:30000/studio/agents |
| Marketplace (catalog) | http://localhost:30000/marketplace |
| Admin API | http://localhost:30004 |
| Platform Backend | http://localhost:30002 |

### Option 2: minikube service

```bash
minikube service katonic-frontend-nodeport -n katonic
```

### Option 3: kubectl port-forward

```bash
kubectl port-forward -n katonic svc/katonic-frontend 3000:3000
kubectl port-forward -n katonic svc/platform-backend 3002:3002
kubectl port-forward -n katonic svc/admin-api 8000:8000
```

---

## Manifest Structure

```
k8s/
├── base/
│   ├── namespace.yaml
│   ├── configmap.yaml              # platform-config (service URLs, infra config)
│   ├── secret.yaml                 # platform-secret (DB credentials, keys)
│   ├── kustomization.yaml
│   ├── pdb.yaml                    # PodDisruptionBudgets (17 services)
│   ├── infra/
│   │   ├── postgres.yaml           # PostgreSQL 16 StatefulSet + init SQL
│   │   ├── redis.yaml              # Redis 7 StatefulSet
│   │   └── clickhouse.yaml         # ClickHouse 24.3 StatefulSet + init SQL
│   ├── backends/
│   │   ├── admin-api.yaml
│   │   ├── agent-api.yaml
│   │   ├── agent-runtime.yaml
│   │   ├── ai-gateway.yaml
│   │   ├── governance-proxy.yaml
│   │   ├── guardrails-engine.yaml
│   │   ├── knowledge-engine.yaml
│   │   ├── mcp-gateway.yaml
│   │   ├── model-deployment-service.yaml
│   │   ├── observability.yaml
│   │   ├── platform-backend.yaml
│   │   ├── remote-connections.yaml
│   │   └── workspace-service.yaml
│   ├── frontends/
│   │   └── katonic-frontend.yaml   # Unified UI (nginx + SPA)
│   ├── jobs/
│   │   └── seed-all.yaml           # Database & catalog seeding Job
│   └── optional/
│       └── milvus.yaml             # etcd + MinIO + Milvus stack
├── overlays/
│   ├── minikube/
│   │   ├── kustomization.yaml      # Resource patches for 8GB VM
│   │   └── nodeport-services.yaml  # NodePort services for external access
│   └── production/
│       └── kustomization.yaml      # AKS: ACR images, Always pull
├── deploy.sh                        # Minikube deploy script
├── deploy-aks.sh                    # AKS deploy script
├── README.md                        # This file (minikube guide)
└── AKS-DEPLOYMENT.md               # AKS deployment guide
```

---

## Services Overview

### Infrastructure (StatefulSets with PVCs)

| Service | Port | Minikube Memory | PVC Size |
|---------|------|-----------------|----------|
| PostgreSQL | 5432 | 256Mi / 768Mi | 2Gi |
| Redis | 6379 | 64Mi / 256Mi | 1Gi |
| ClickHouse | 8123, 9000 | 512Mi / 1Gi | 5Gi |

### Backend Deployments

| Service | Port | Health Endpoint | Minikube Memory |
|---------|------|-----------------|-----------------|
| admin-api | 8000 | `/v1/health` | 128Mi / 384Mi |
| agent-api | 8000 | `/v1/health` | 128Mi / 384Mi |
| agent-runtime | 8000 | `/v1/health` | 128Mi / 384Mi |
| ai-gateway | 8010 | `/healthz` | 256Mi / 512Mi |
| governance-proxy | 8000 | `/v1/health/live` | 768Mi / 1536Mi |
| guardrails-engine | 8000 | `/health` | 768Mi / 1536Mi |
| knowledge-engine | 8011 | `/v1/health/live` | 256Mi / 512Mi |
| mcp-gateway | 8009 | `/v1/health` | 64Mi / 256Mi |
| model-deployment-service | 8012 | `/health` | 128Mi / 384Mi |
| observability | 8000 | `/healthz` | 128Mi / 384Mi |
| platform-backend | 3002 | `/platform/api/health` | 128Mi / 384Mi |
| remote-connections | 8014 | `/health` | 64Mi / 256Mi |
| workspace-service | 8013 | `/health` | 128Mi / 384Mi |

### Frontend

| Service | Port | Container | Minikube Memory |
|---------|------|-----------|-----------------|
| katonic-frontend | 3000 | nginx (static SPA + API proxy) | 32Mi / 128Mi |

### Optional (Milvus Stack)

| Service | Port | PVC Size |
|---------|------|----------|
| etcd | 2379 | 2Gi |
| MinIO | 9000, 9001 | 5Gi |
| Milvus | 19530 | 5Gi |

Deploy with: `./deploy.sh milvus`

---

## NodePort Assignments

| Service | NodePort |
|---------|----------|
| katonic-frontend | 30000 |
| Admin API | 30004 |
| Platform Backend | 30002 |

---

## Minikube Resource Budget

Total memory for 8GB VM (all 17 pods):

| Category | Requests | Limits |
|----------|----------|--------|
| Infrastructure (3) | 832Mi | 2Gi |
| NLP services (2) | 1536Mi | 3Gi |
| Medium backends (3) | 640Mi | 1.4Gi |
| Light backends (8) | 896Mi | 2.8Gi |
| Frontend (1) | 32Mi | 128Mi |
| **Total** | **~3.9Gi** | **~9.3Gi** |

Requests use ~47% of the 8.4GB allocatable. Limits are overcommitted (normal for dev).

---

## Troubleshooting

### POSTGRES_PORT env var collision

Kubernetes auto-injects service-linked environment variables. All deployments include `enableServiceLinks: false` to prevent this.

### OOMKilled on NLP services

`governance-proxy` and `guardrails-engine` load spaCy + Presidio NLP models at startup. They use:
- `startupProbe` with 10-minute tolerance (30s initial + 60 failures x 10s)
- 768Mi request / 1536Mi limit in minikube overlay

If they still OOM, the VM may not have enough total memory. Check with `minikube ssh "free -m"`.

### ClickHouse probe failures

ClickHouse needs generous probe timeouts in resource-constrained environments. Base manifests use `timeoutSeconds: 5` and `failureThreshold: 6`.

### Checking logs

```bash
kubectl logs -n katonic deployment/agent-api --tail=50
kubectl logs -n katonic deployment/governance-proxy -f
kubectl logs -n katonic deployment/guardrails-engine --previous
```

### Force restart a service

```bash
kubectl rollout restart deployment/<service-name> -n katonic
```

### Full reset

```bash
./deploy.sh teardown
./deploy.sh deploy
```
