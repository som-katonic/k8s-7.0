# Katonic Platform Installer v7.0

Production-grade installer for the Katonic AI Platform. Provisions cloud infrastructure,
deploys all platform services, and configures multi-tenancy, TLS, DNS, and monitoring.

## Supported Targets

| Cloud | Cluster Method | GPU Support | Air-Gap |
|-------|---------------|-------------|---------|
| AWS (EKS) | Terraform | A10G, A100, H100 | Yes |
| Azure (AKS) | az CLI | T4, A100, H100 | Yes |
| GCP (GKE) | Terraform | T4, A100, H200 | Yes |
| OCI (OKE) | Terraform | A10, A100 | Yes |
| Alibaba (ACK) | Terraform | T4, A10 | Yes |
| Bare Metal | Existing cluster | Any | Yes |

## Architecture

```
katonic.yml (single config file)
       |
       v
  entrypoint.sh
       |
  +----+----+----+----+
  |         |         |
  v         v         v
Pre-flight  Terraform  Ansible
checks      (cluster)  (services)
  |              |         |
  |         EKS/AKS/   PostgreSQL
  |         GKE/OKE/   Redis
  |         ACK         Milvus
  |              |      Keycloak
  |              |      MinIO
  |              +---+--cert-manager
  |                  |  Istio
  |                  |  Monitoring
  |                  |
  |                  v
  |            Helm Umbrella Chart
  |            (all platform services)
  |                  |
  |                  v
  |            tenant-manager bootstrap
  |            (auto-provisions default org)
  |                  |
  +------------------+
  |
  v
DNS + TLS
  |
  v
Platform Ready
```

## Quick Start

### 1. Configure

```bash
cp katonic.yml.example katonic.yml
# Edit katonic.yml with your settings
```

### 2. Run

```bash
# Docker (recommended)
docker run --rm -it \
  -v $(pwd)/katonic.yml:/katonic/katonic.yml \
  -v ~/.aws:/root/.aws \
  -v $(pwd)/license.json:/katonic/license.json \
  registry.katonic.ai/installer:7.0.0

# Or directly
pip install -r requirements.txt
./entrypoint.sh
```

### 3. Verify

```bash
kubectl get pods -n katonic-system
curl https://your-domain.com/healthz
```

## Configuration Reference

All configuration lives in a single `katonic.yml` file. See
[katonic.yml.example](katonic.yml.example) for the full annotated reference.

Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `cloud_provider` | aws | Target cloud: aws, azure, gcp, oci, alibaba, bare_metal |
| `domain` | (required) | Platform domain name |
| `deployment_mode` | platform | platform (single-tenant) or cloud (multi-tenant) |
| `platform_variant` | Enterprise | Enterprise, Gov, or Distributor |
| `admin_email` | (required) | Initial admin user email |
| `database_mode` | in_cluster | in_cluster (deploy PostgreSQL) or managed (use RDS/CloudSQL) |
| `gpu_enabled` | false | Enable GPU node pool |
| `airgap_enabled` | false | Air-gapped installation mode |
| `backup_enabled` | false | Deploy Velero for automated backups |
| `monitoring_enabled` | true | Deploy kube-prometheus-stack |

## Directory Structure

```
katonic-installer/
  README.md                             # This file
  katonic.yml.example                   # Annotated example configuration
  Dockerfile                            # Installer container (Ubuntu + all CLIs)
  entrypoint.sh                         # Main entrypoint with YAML parsing
  katonic.sh                            # CLI helper script
  requirements.txt                      # Python dependencies

  ansible/
    ansible.cfg                         # Ansible config (yaml callback, roles path)
    playbook.yml                        # Main orchestration playbook
    inventory/
      katonic.yml                       # Dynamic inventory from config
    roles/
      cluster/
        tasks/
          eks.yml                       # AWS: Terraform VPC + EKS + 4 node pools
          aks.yml                       # Azure: az CLI cluster + 4 node pools
          gke.yml                       # GCP: Terraform VPC + GKE + 4 node pools
          oke.yml                       # OCI: Terraform VCN + OKE + 3 node pools
          ack.yml                       # Alibaba: Terraform VPC + ACK + 4 node pools
          existing.yml                  # Bare metal: skip cluster creation
          verify.yml                    # Post-creation cluster verification
        files/
          cluster-autoscaler-aws.yaml   # AWS cluster autoscaler manifest
        templates/
          eks-tfvars.j2                 # Terraform vars for EKS
          gke-tfvars.j2                 # Terraform vars for GKE
          oke-tfvars.j2                 # Terraform vars for OKE
          ack-tfvars.j2                 # Terraform vars for ACK
      infra/tasks/
        postgresql.yml                  # PostgreSQL via Bitnami Helm
        redis.yml                       # Redis via Bitnami Helm
        milvus.yml                      # Milvus standalone or distributed
        minio.yml                       # MinIO object storage
        keycloak.yml                    # Keycloak via Bitnami Helm
        managed-db-aws.yml             # AWS RDS managed database
        managed-db-azure.yml           # Azure Database for PostgreSQL
        managed-db-gcp.yml            # GCP Cloud SQL
        managed-db-oci.yml            # OCI Database Service
        managed-db-alibaba.yml        # Alibaba ApsaraDB
        object-storage-aws.yml        # S3 bucket creation
        object-storage-azure.yml      # Azure Blob container
        object-storage-gcp.yml        # GCS bucket
        object-storage-oci.yml        # OCI Object Storage
        object-storage-alibaba.yml    # Alibaba OSS
      certmanager/tasks/main.yml       # cert-manager + ClusterIssuers
      istio/tasks/main.yml             # Istio mesh + Gateway
      storage/tasks/main.yml           # Cloud-specific StorageClasses
      dns/tasks/main.yml               # DNS record creation (Route53 + stubs)
      tls/tasks/main.yml               # TLS: HTTP-01 (single) + DNS-01 (wildcard)
      monitoring/tasks/main.yml        # kube-prometheus-stack
      gpu/tasks/main.yml               # NVIDIA device plugin + GPU config
      backup/tasks/main.yml            # Velero backup operator
      platform/tasks/main.yml          # Deploy all services via Helm umbrella chart
      status/tasks/main.yml            # Post-install health verification

  terraform/
    aws/
      main.tf                          # VPC, EKS, node groups, EBS CSI, IRSA
      variables.tf                     # Input variables
      backend.tf.example               # S3 state backend template
    azure/
      README.md                        # Azure uses az CLI, not Terraform
    gcp/
      main.tf                          # VPC, GKE, node pools, Workload Identity
      variables.tf
      backend.tf.example               # GCS state backend template
    oci/
      main.tf                          # VCN, OKE, node pools
      variables.tf
      backend.tf.example               # S3-compatible state backend
    alibaba/
      main.tf                          # VPC, ACK, node pools, SCCC
      variables.tf
      backend.tf.example               # OSS state backend
    modules/                            # Shared Terraform modules (future)

  charts/
    katonic-platform/                   # Umbrella Helm chart
      Chart.yaml                       # Chart metadata + dependency on tenant-manager
      values.yaml                      # Default values for all 17+ services
      values-cloud.yaml                # Multi-tenant overrides
      templates/
        _helpers.tpl                   # Shared template functions
        namespace.yaml                 # katonic-system namespace
        platform-config.yaml           # Shared ConfigMap (DB URLs, service endpoints)
      charts/
        tenant-manager/                # Tenant-manager subchart
          Chart.yaml
          values.yaml
          templates/
            deployment.yaml            # Deployment with all env vars
            service.yaml               # ClusterIP service on 8015
            rbac.yaml                  # ClusterRole for namespace management
            serviceaccount.yaml        # ServiceAccount with RBAC binding

  scripts/
    pre-flight.sh                      # Pre-install validation (tools, auth, DNS, disk, license)
    mirror-mcp-images.sh               # CI: pull + tag + push MCP catalog images
    seed-mcp-catalog.js                # Node.js: seed MCP servers into MongoDB
    load-airgap-images.sh              # Customer: load image tarball into private registry
    configure-private-registry.sh      # Configure image pull secrets for private registry

  tests/
    README.md                          # Test documentation
    installer-tests.sh                 # Bash tests: mirroring, air-gap, catalog validation
    seed-mcp-catalog.test.js           # Jest: catalog seeding with mongodb-memory-server
    build-mcp-catalog.test.js          # Jest: catalog entry construction
    package.json                       # Test dependencies (jest, mongodb-memory-server)

  docs/
    architecture.md                    # Service architecture, data flow, namespace layout
    air-gap-guide.md                   # Complete air-gapped installation walkthrough
    upgrade-guide.md                   # Version upgrade procedures and rollback
    troubleshooting.md                 # Common issues, diagnostics, log collection
```

## Installation Phases

### Phase 1: Pre-flight

Validates: cloud CLI authentication, required tools (kubectl, helm, terraform, jq),
DNS resolution, disk space (50 GB min), license file, registry connectivity.

### Phase 2: Cluster Provisioning

Creates K8s cluster with node pools via Terraform (AWS/GCP/OCI/Alibaba) or az CLI (Azure).
Skipped for bare_metal.

Node pools: platform (3x, control plane), compute (2x, workloads), vectordb (1x, Milvus),
gpu (0+, model serving).

### Phase 3: Infrastructure

Deploys into dedicated namespaces via Helm:

| Component | Namespace | Chart |
|-----------|-----------|-------|
| cert-manager | cert-manager | jetstack/cert-manager |
| Istio | istio-system | istio/istiod + istio/gateway |
| PostgreSQL | katonic-infra | bitnami/postgresql |
| Redis | katonic-infra | bitnami/redis |
| Milvus | katonic-infra | milvus/milvus |
| MinIO | katonic-infra | minio/minio |
| Keycloak | katonic-keycloak | bitnami/keycloak |
| Prometheus + Grafana | katonic-monitoring | prometheus-community/kube-prometheus-stack |
| Velero | velero | vmware-tanzu/velero (when backup_enabled) |

### Phase 4: Platform Services

Deploys all Katonic services into `katonic-system` via the umbrella Helm chart:

| Service | Port | Role |
|---------|------|------|
| governance-proxy | 8003 | Tool governance, PII masking, audit |
| admin-api | 8004 | Agent/provider/policy CRUD |
| observability | 8005 | Analytics, cost tracking, Langfuse |
| guardrails-engine | 8006 | Input/output safety |
| agent-api | 8007 | Chat sessions, AG-UI streaming |
| agent-runtime | 8008 | Agent execution (ADK), MCP bridge |
| mcp-gateway | 8009 | MCP server discovery, tool routing |
| ai-gateway | 8010 | LLM routing, BYOK, rate limiting |
| knowledge-engine | 8011 | RAG: connectors, ingestion, vector search |
| model-deployment | 8012 | vLLM model serving, GPU management |
| workspace-service | 8013 | Workspace management |
| remote-connections | 8014 | Third-party MCP, OpenAPI import |
| tenant-manager | 8015 | Org lifecycle, RBAC, licensing, audit |
| ops-console | 3000 | Operations dashboard (RUN) |
| agent-studio | 3001 | Agent builder (BUILD) |
| ace-bff | 3002 | Chat BFF (Socket.IO) |
| employee-workspace | 3010 | AI chat workspace (ACE) |
| marketplace | 80 | Marketplace hub (DISCOVER) |
| distributor-console | 3020 | Distributor admin console (cloud mode only) |

### Phase 5: DNS + TLS

Creates DNS records and provisions TLS certificates. Single domain uses HTTP-01 challenge.
Wildcard (multi-tenant) uses DNS-01 with per-cloud solver.

### Phase 6: Bootstrap

tenant-manager automatically on first startup:
1. Creates database tables (Alembic migrations)
2. Seeds 6 RBAC roles with 30 permissions
3. Creates default organization
4. Provisions Keycloak realm + admin user
5. Creates dev + prod environments
6. Uploads license file

## Deployment Modes

### Enterprise (Single-Tenant)

```yaml
deployment_mode: "platform"
platform_variant: "Enterprise"
```

One organization, auto-provisioned. All services see `tenant_id=default`.
Suitable for banks, enterprises, government.

### Distributor (Multi-Tenant)

```yaml
deployment_mode: "cloud"
platform_variant: "Distributor"
multi_tenancy:
  max_orgs: 50
```

Multiple organizations, each with isolated Keycloak realm, PostgreSQL schema,
and K8s namespace(s). The distributor-console frontend (port 3020) is automatically
enabled for org lifecycle, GPU, billing, and RBAC management.
Suitable for telcos, MSPs, SaaS providers.

### Government (Air-Gapped)

```yaml
deployment_mode: "platform"
platform_variant: "Gov"
airgap_enabled: true
```

Air-gapped, single-tenant, maximum isolation.

## Air-Gap Installation

See [docs/air-gap-guide.md](docs/air-gap-guide.md) for complete walkthrough.

Quick summary:
1. Build image bundle on connected machine
2. Transfer bundle + installer to air-gapped environment
3. Set `airgap_enabled: true` and `private_registry` in katonic.yml
4. Load images: `./scripts/load-airgap-images.sh --bundle images.tar.gz --registry harbor.internal`
5. Run installer

## Upgrading

See [docs/upgrade-guide.md](docs/upgrade-guide.md).

```bash
# Update image_tag in katonic.yml, re-run installer (idempotent)
docker run --rm -it \
  -v $(pwd)/katonic.yml:/katonic/katonic.yml \
  registry.katonic.ai/installer:7.1.0
```

## Development

### Run tests

```bash
# Bash installer tests
chmod +x tests/installer-tests.sh && ./tests/installer-tests.sh

# JavaScript catalog tests
cd tests && npm install && npx jest

# Ansible syntax check
cd ansible && ansible-playbook playbook.yml --syntax-check

# Terraform validate (per cloud)
cd terraform/aws && terraform init && terraform validate
```

### Build installer container

```bash
docker build -t katonic-installer:dev .
```

## Known Issues from Code Review

The v7 installer underwent two code reviews (REVIEW.md, v7-installer-review.md)
that identified and fixed 26 bugs total. Key items that remain as design considerations:

1. **Terraform state** - Each module includes `backend.tf.example` but defaults to local state.
   Configure a remote backend (S3/GCS/AzureRM) before production use.
2. **SMTP password** - Passed via `helm --set`. Production should use K8s Secret references.
3. **DNS stubs** - Only AWS Route53 is fully automated. Azure/GCP/OCI/Alibaba DNS roles
   print manual CLI commands.
4. **NetworkPolicy** - No inter-namespace isolation by default. Add policies for Gov/Distributor
   compliance requirements.

## Relationship to Platform Repo

This installer is a separate repo from the Katonic platform codebase. The contract:

| What | Platform repo | Installer repo |
|------|--------------|----------------|
| Docker images | Built by CI, pushed to registry | Referenced by image tag in Helm values |
| Port assignments | Defined in each service config.py | Matched in Helm chart Service specs |
| Env var names | Defined in each service config.py | Set in Helm chart Deployment templates |
| Health endpoints | /healthz, /readyz in each service | Used by readiness/liveness probes |
| DB init SQL | infra/init-db.sql | Copied into PostgreSQL init container |

A release:
1. Platform team tags v7.x.y, CI pushes images to `registry.katonic.ai/katonic/*:7.x.y`
2. Installer team updates `values.yaml` imageTag, tags installer v7.x.y
3. Customer runs installer, it pulls matching images

## License

Proprietary. See LICENSE file.
