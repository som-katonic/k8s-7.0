# Platform Upgrade Guide

## Overview

The Katonic Platform installer is designed to be idempotent. Running a newer
version of the installer against an existing deployment will upgrade only
the components that changed, preserving data and configuration.

## Pre-Upgrade Checklist

- [ ] Back up PostgreSQL databases (platform, keycloak)
- [ ] Back up Milvus vector data
- [ ] Back up MinIO/S3 objects
- [ ] Note current Helm release versions: `helm list -A`
- [ ] Verify new license covers the target version
- [ ] Read the release notes for breaking changes
- [ ] Schedule maintenance window (services restart during upgrade)

## Standard Upgrade

### 1. Update configuration

```bash
# Update the image tag in katonic.yml
vim katonic.yml
# Change: image_tag: "7.1.0"
```

### 2. Run the installer

```bash
docker run --rm -it \
  -v $(pwd)/katonic.yml:/katonic/katonic.yml \
  -v $(pwd)/license.json:/katonic/license.json \
  registry.katonic.ai/installer:7.1.0
```

The installer will:
- Skip cluster provisioning (Terraform detects no changes)
- Upgrade infrastructure Helm releases if chart versions changed
- Upgrade platform services with new image tags
- Run database migrations via tenant-manager bootstrap
- Verify all services are healthy

### 3. Verify

```bash
# Check pod versions
kubectl get pods -n katonic-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Health check
curl https://your-domain.com/healthz

# Check tenant-manager bootstrap completed
kubectl logs -n katonic-system deploy/tenant-manager --tail=20 | grep -i bootstrap
```

## Rolling Back

### Helm rollback (per-service)

```bash
# List revisions
helm history tenant-manager -n katonic-system

# Roll back
helm rollback tenant-manager 3 -n katonic-system
```

### Full rollback

Re-run the previous installer version:

```bash
docker run --rm -it \
  -v $(pwd)/katonic.yml:/katonic/katonic.yml \
  registry.katonic.ai/installer:7.0.0
```

## Database Migration Considerations

Tenant-manager runs Alembic migrations on startup. These are forward-only.
If a database migration has been applied, rolling back the application
without rolling back the database may cause schema mismatches.

For critical environments:
1. Take a PostgreSQL snapshot before upgrading
2. If rollback needed, restore the snapshot first
3. Then roll back the Helm releases

## Zero-Downtime Upgrades

For production environments that require zero downtime:

1. Ensure `replicaCount >= 2` for all user-facing services
2. The Helm chart uses `RollingUpdate` strategy by default
3. Readiness probes prevent traffic to pods that are not ready
4. Agent sessions using WebSocket/SSE will reconnect automatically

Services that may briefly interrupt:
- `tenant-manager` (single replica, runs migrations on startup)
- `model-deployment` (GPU model reloading)

## Version Compatibility Matrix

| Installer | Platform | K8s | PostgreSQL | Keycloak |
|-----------|----------|-----|------------|----------|
| 7.0.x | 7.0.x | 1.28-1.30 | 16.x | 24.x |
| 7.1.x | 7.1.x | 1.29-1.31 | 16.x | 24.x |

## Air-Gap Upgrades

For air-gapped environments, prepare a new image bundle for the target
version and follow the same process as the initial air-gap install.
See [air-gap-guide.md](air-gap-guide.md) for image preparation steps.
