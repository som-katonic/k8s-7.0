# Azure (AKS)

AKS cluster creation uses `az aks create` CLI directly (see `ansible/roles/cluster/tasks/aks.yml`).
No Terraform module needed. This is consistent with v6.3 approach and is simpler for Azure.
