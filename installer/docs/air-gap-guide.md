# Air-Gap Installation Guide

This guide covers installing the Katonic AI Platform in environments without internet access.

## Prerequisites

You need a connected machine (build station) to prepare the air-gap bundle, and the
target environment with a private container registry (Harbor, Nexus, or similar).

## Step 1: Prepare Image Bundle (Connected Machine)

### 1a. Collect all platform images

```bash
# Generate the full image list
cat > image-list.txt << 'EOF'
registry.katonic.ai/katonic/admin-api:7.0.0
registry.katonic.ai/katonic/observability:7.0.0
registry.katonic.ai/katonic/guardrails-engine:7.0.0
registry.katonic.ai/katonic/governance-proxy:7.0.0
registry.katonic.ai/katonic/agent-api:7.0.0
registry.katonic.ai/katonic/agent-runtime:7.0.0
registry.katonic.ai/katonic/mcp-gateway:7.0.0
registry.katonic.ai/katonic/ai-gateway:7.0.0
registry.katonic.ai/katonic/knowledge-engine:7.0.0
registry.katonic.ai/katonic/model-deployment-service:7.0.0
registry.katonic.ai/katonic/workspace-service:7.0.0
registry.katonic.ai/katonic/remote-connections:7.0.0
registry.katonic.ai/katonic/tenant-manager:7.0.0
registry.katonic.ai/katonic/ace-bff:7.0.0
registry.katonic.ai/katonic/ops-console:7.0.0
registry.katonic.ai/katonic/employee-workspace:7.0.0
registry.katonic.ai/katonic/agent-studio:7.0.0
registry.katonic.ai/katonic/marketplace:7.0.0
EOF
```

### 1b. Pull and save

```bash
# Pull all images
while read -r img; do
  docker pull "$img"
done < image-list.txt

# Save to tarball
docker save $(cat image-list.txt) | gzip > katonic-images-7.0.0.tar.gz
```

### 1c. Mirror MCP catalog images (if using MCP marketplace)

```bash
./scripts/mirror-mcp-images.sh mcp-catalog.json registry.katonic.ai
docker save $(jq -r '.[].dockerImage' mcp-catalog.json | sed 's/$/:latest/') \
  | gzip > mcp-images-7.0.0.tar.gz
```

### 1d. Save infrastructure images

```bash
# These are pulled by Helm during infra deployment
cat > infra-images.txt << 'EOF'
bitnami/postgresql:16.2.0
bitnami/redis:7.2.4
bitnami/keycloak:24.0.1
milvusdb/milvus:v2.4.0
minio/minio:RELEASE.2024-01-01T00-00-00Z
quay.io/jetstack/cert-manager-controller:v1.14.0
quay.io/jetstack/cert-manager-webhook:v1.14.0
quay.io/jetstack/cert-manager-cainjector:v1.14.0
istio/pilot:1.20.3
istio/proxyv2:1.20.3
EOF

while read -r img; do docker pull "$img"; done < infra-images.txt
docker save $(cat infra-images.txt) | gzip > infra-images-7.0.0.tar.gz
```

### 1e. Save installer container

```bash
docker pull registry.katonic.ai/installer:7.0.0
docker save registry.katonic.ai/installer:7.0.0 | gzip > installer-7.0.0.tar.gz
```

## Step 2: Transfer to Air-Gapped Environment

Copy these files to the target machine:
- `installer-7.0.0.tar.gz` (installer container)
- `katonic-images-7.0.0.tar.gz` (platform images)
- `infra-images-7.0.0.tar.gz` (infrastructure images)
- `mcp-images-7.0.0.tar.gz` (MCP catalog images, optional)
- `katonic.yml` (your config file)
- `license.json` (your license file)

## Step 3: Configure

Set these fields in `katonic.yml`:

```yaml
airgap_enabled: true
private_registry: "harbor.internal:5000"   # Your private registry
image_bundle: "/katonic/katonic-images-7.0.0.tar.gz"
```

## Step 4: Load Images into Private Registry

```bash
# Load installer
docker load < installer-7.0.0.tar.gz

# Load and retag all platform images
./scripts/load-airgap-images.sh \
  --bundle katonic-images-7.0.0.tar.gz \
  --registry harbor.internal:5000

# Load and retag infra images
./scripts/load-airgap-images.sh \
  --bundle infra-images-7.0.0.tar.gz \
  --registry harbor.internal:5000

# Load and retag MCP images (optional)
./scripts/load-airgap-images.sh \
  --bundle mcp-images-7.0.0.tar.gz \
  --registry harbor.internal:5000
```

## Step 5: Install

```bash
docker run --rm -it \
  -v $(pwd)/katonic.yml:/katonic/katonic.yml \
  -v $(pwd)/license.json:/katonic/license.json \
  -v ~/.kube/config:/root/.kube/config \
  registry.katonic.ai/installer:7.0.0
```

The installer detects `airgap_enabled: true` and automatically:
- Configures all Helm charts to pull from `private_registry`
- Creates `imagePullSecret` if registry credentials are provided
- Seeds the MCP catalog with rewritten image paths

## Container Runtime Compatibility

The default `docker load` works with Docker. For other runtimes:

| Runtime | Command |
|---------|---------|
| Docker | `docker load < images.tar.gz` |
| containerd | `ctr -n k8s.io images import images.tar.gz` |
| CRI-O | `skopeo copy docker-archive:images.tar.gz containers-storage:IMAGE` |

The `load-airgap-images.sh` script auto-detects the runtime and uses the
appropriate command.

## Troubleshooting

### Images not found after loading

Check that images were pushed to the correct registry path:
```bash
curl -s https://harbor.internal:5000/v2/_catalog | jq .
```

### Helm cannot pull charts

For air-gap Helm charts, either:
1. Use the bundled chart archive in the installer container
2. Host a ChartMuseum instance in your private registry

### Certificate errors with private registry

If using a self-signed cert for Harbor:
```bash
# Copy CA to all nodes
scp harbor-ca.crt node:/etc/docker/certs.d/harbor.internal:5000/ca.crt
# Or for containerd
scp harbor-ca.crt node:/etc/containerd/certs.d/harbor.internal:5000/ca.crt
```
