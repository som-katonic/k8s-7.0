# Troubleshooting Guide

## Quick Diagnostics

```bash
# Overall pod status
kubectl get pods -n katonic-system -o wide
kubectl get pods -n katonic-infra -o wide
kubectl get pods -n katonic-keycloak -o wide

# Events (shows scheduling failures, pull errors, etc.)
kubectl get events -n katonic-system --sort-by='.lastTimestamp' | tail -20

# Health check all services
for svc in admin-api observability guardrails-engine governance-proxy \
           agent-api agent-runtime mcp-gateway ai-gateway \
           knowledge-engine tenant-manager; do
  PORT=$(kubectl get svc "$svc" -n katonic-system -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
  if [ -n "$PORT" ]; then
    STATUS=$(kubectl exec -n katonic-system deploy/$svc -- \
      curl -sf "localhost:${PORT}/healthz" 2>/dev/null && echo "OK" || echo "DOWN")
    printf "  %-25s %s\n" "$svc" "$STATUS"
  fi
done
```

## Common Issues

### Pods stuck in Pending

**Cause:** Insufficient cluster resources or node affinity/taint mismatch.

```bash
# Check why
kubectl describe pod <pod-name> -n katonic-system | grep -A 5 Events

# Check node resources
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"
```

**Fix:** Scale up the node pool in katonic.yml and re-run installer, or remove
taints if the nodes exist but pods cannot schedule.

### Pods in CrashLoopBackOff

**Cause:** Application error on startup, usually configuration or connectivity.

```bash
# Check logs
kubectl logs -n katonic-system deploy/<service> --previous --tail=50

# Common causes:
# - "connection refused" to PostgreSQL/Redis/Keycloak = infra not ready
# - "authentication failed" = wrong credentials in secrets
# - "migration failed" = database schema issue
```

**Fix for database connectivity:**
```bash
# Verify PostgreSQL is running
kubectl get pods -n katonic-infra -l app.kubernetes.io/name=postgresql

# Test connection
kubectl run pg-test --rm -it --image=postgres:16 -n katonic-infra -- \
  psql "postgresql://platform:PASSWORD@postgresql:5432/platform" -c "SELECT 1"
```

### Keycloak not starting

**Cause:** Database not created before Keycloak starts (fixed in v7 review, BUG-3).

```bash
# Check Keycloak logs
kubectl logs -n katonic-keycloak deploy/keycloak --tail=50

# Verify keycloak database exists
kubectl exec -n katonic-infra deploy/postgresql -c postgresql -- \
  psql -U postgres -c "\l" | grep keycloak
```

**Fix:** Create the database manually:
```bash
kubectl exec -n katonic-infra deploy/postgresql -c postgresql -- \
  psql -U postgres -c "CREATE DATABASE keycloak OWNER platform;"
```

### tenant-manager bootstrap fails

**Cause:** Keycloak not reachable or license file invalid.

```bash
kubectl logs -n katonic-system deploy/tenant-manager --tail=100 | grep -i "bootstrap\|error\|fail"
```

**Fix:** Check Keycloak connectivity:
```bash
kubectl exec -n katonic-system deploy/tenant-manager -- \
  curl -sf "http://keycloak.katonic-keycloak.svc.cluster.local:8080/realms/master"
```

### TLS certificate not issued

**Cause:** cert-manager challenge failed.

```bash
# Check certificate status
kubectl get certificates -A
kubectl describe certificate <name> -n katonic-system

# Check challenge status
kubectl get challenges -A
kubectl describe challenge <name>

# cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager --tail=50
```

**For wildcard certs (DNS-01):** Verify cloud DNS credentials are correct
and the DNS zone is accessible.

**For single-domain (HTTP-01):** Verify the domain resolves to the cluster
load balancer IP and port 80 is open.

### Milvus connection refused

```bash
# Check Milvus pod
kubectl get pods -n katonic-infra -l app.kubernetes.io/name=milvus

# Check Milvus logs
kubectl logs -n katonic-infra deploy/milvus --tail=50

# Test connectivity from platform namespace
kubectl run milvus-test --rm -it --image=curlimages/curl -n katonic-system -- \
  curl -sf "http://milvus.katonic-infra.svc.cluster.local:19530/api/v1/health"
```

### GPU nodes not detected

```bash
# Check GPU nodes
kubectl get nodes -l nvidia.com/gpu.present=true

# Check NVIDIA device plugin
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds

# Check available GPU resources
kubectl describe nodes | grep -A 3 "nvidia.com/gpu"
```

**Fix:** Ensure NVIDIA device plugin is installed:
```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.15.0/nvidia-device-plugin.yml
```

## Log Collection

For support tickets, collect diagnostic info:

```bash
# Full diagnostic dump
mkdir -p /tmp/katonic-diag
kubectl get all -A -o wide > /tmp/katonic-diag/resources.txt
kubectl get events -A --sort-by='.lastTimestamp' > /tmp/katonic-diag/events.txt

for ns in katonic-system katonic-infra katonic-keycloak; do
  for pod in $(kubectl get pods -n "$ns" -o name); do
    kubectl logs -n "$ns" "$pod" --tail=200 > "/tmp/katonic-diag/${ns}-${pod##*/}.log" 2>&1
  done
done

tar czf katonic-diag-$(date +%Y%m%d).tar.gz -C /tmp katonic-diag/
```

## Contact Support

Email: support@katonic.ai
Include: diagnostic bundle, katonic.yml (with secrets redacted), installer version.
