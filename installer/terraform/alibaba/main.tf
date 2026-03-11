# ============================================================================
# Katonic v7 - ACK Cluster (Alibaba Cloud / SCCC)
# ============================================================================
# SCCC uses the same provider with me-riyadh region.
# ============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.220"
    }
  }
}

provider "alicloud" {
  region = var.alibaba_region
}

# ----------------------------------------------------------------------------
# Data sources
# ----------------------------------------------------------------------------
data "alicloud_zones" "available" {
  available_resource_creation = "VSwitch"
}

# ----------------------------------------------------------------------------
# VPC + VSwitches
# ----------------------------------------------------------------------------
resource "alicloud_vpc" "main" {
  vpc_name   = "${var.cluster_name}-vpc"
  cidr_block = var.vpc_cidr
}

resource "alicloud_vswitch" "zone_a" {
  vpc_id       = alicloud_vpc.main.id
  cidr_block   = cidrsubnet(var.vpc_cidr, 4, 0)
  zone_id      = data.alicloud_zones.available.zones[0].id
  vswitch_name = "${var.cluster_name}-vsw-a"
}

resource "alicloud_vswitch" "zone_b" {
  vpc_id       = alicloud_vpc.main.id
  cidr_block   = cidrsubnet(var.vpc_cidr, 4, 1)
  zone_id      = data.alicloud_zones.available.zones[1].id
  vswitch_name = "${var.cluster_name}-vsw-b"
}

# ----------------------------------------------------------------------------
# NAT Gateway (for private nodes)
# ----------------------------------------------------------------------------
resource "alicloud_nat_gateway" "main" {
  vpc_id           = alicloud_vpc.main.id
  nat_gateway_name = "${var.cluster_name}-nat"
  payment_type     = "PayAsYouGo"
  nat_type         = "Enhanced"
  vswitch_id       = alicloud_vswitch.zone_a.id
}

resource "alicloud_eip_address" "nat" {
  address_name = "${var.cluster_name}-nat-eip"
  payment_type = "PayAsYouGo"
}

resource "alicloud_eip_association" "nat" {
  allocation_id = alicloud_eip_address.nat.id
  instance_id   = alicloud_nat_gateway.main.id
  instance_type = "Nat"
}

resource "alicloud_snat_entry" "zone_a" {
  snat_table_id     = alicloud_nat_gateway.main.snat_table_ids[0]
  source_vswitch_id = alicloud_vswitch.zone_a.id
  snat_ip           = alicloud_eip_address.nat.ip_address
}

resource "alicloud_snat_entry" "zone_b" {
  snat_table_id     = alicloud_nat_gateway.main.snat_table_ids[0]
  source_vswitch_id = alicloud_vswitch.zone_b.id
  snat_ip           = alicloud_eip_address.nat.ip_address
}

# ----------------------------------------------------------------------------
# ACK Managed Kubernetes Cluster
# ----------------------------------------------------------------------------
resource "alicloud_cs_managed_kubernetes" "main" {
  name         = var.cluster_name
  version      = var.k8s_version
  worker_vswitch_ids = [alicloud_vswitch.zone_a.id, alicloud_vswitch.zone_b.id]

  pod_cidr       = var.pod_cidr
  service_cidr   = var.service_cidr
  slb_internet_enabled = !var.private_cluster

  new_nat_gateway = false
  is_enterprise_security_group = true

  addons {
    name = "flannel"
  }
  addons {
    name = "csi-plugin"
  }
  addons {
    name = "csi-provisioner"
  }

  tags = var.tags
}

# -- Platform node pool --
resource "alicloud_cs_kubernetes_node_pool" "platform" {
  cluster_id  = alicloud_cs_managed_kubernetes.main.id
  name        = "platform"
  vswitch_ids = [alicloud_vswitch.zone_a.id, alicloud_vswitch.zone_b.id]

  instance_types       = [var.platform_instance_type]
  system_disk_category = "cloud_essd"
  system_disk_size     = var.platform_disk_size

  desired_size = var.platform_min_count

  scaling_config {
    min_size = var.platform_min_count
    max_size = var.platform_max_count
  }

  labels = { role = "platform" }
}

# -- Compute node pool --
resource "alicloud_cs_kubernetes_node_pool" "compute" {
  cluster_id  = alicloud_cs_managed_kubernetes.main.id
  name        = "compute"
  vswitch_ids = [alicloud_vswitch.zone_a.id, alicloud_vswitch.zone_b.id]

  instance_types       = [var.compute_instance_type]
  system_disk_category = "cloud_essd"
  system_disk_size     = var.compute_disk_size

  desired_size = var.compute_min_count

  scaling_config {
    min_size = var.compute_min_count
    max_size = var.compute_max_count
  }

  labels = { role = "compute" }
}

# -- VectorDB node pool --
resource "alicloud_cs_kubernetes_node_pool" "vectordb" {
  cluster_id  = alicloud_cs_managed_kubernetes.main.id
  name        = "vectordb"
  vswitch_ids = [alicloud_vswitch.zone_a.id]

  instance_types       = [var.vectordb_instance_type]
  system_disk_category = "cloud_essd"
  system_disk_size     = var.vectordb_disk_size

  desired_size = var.vectordb_min_count

  scaling_config {
    min_size = var.vectordb_min_count
    max_size = var.vectordb_max_count
  }

  labels = { role = "vectordb" }
}

# -- GPU node pool (optional) --
resource "alicloud_cs_kubernetes_node_pool" "gpu" {
  count = var.gpu_enabled ? 1 : 0

  cluster_id  = alicloud_cs_managed_kubernetes.main.id
  name        = "gpu"
  vswitch_ids = [alicloud_vswitch.zone_a.id]

  instance_types       = [var.gpu_instance_type]
  system_disk_category = "cloud_essd"
  system_disk_size     = var.gpu_disk_size

  desired_size = var.gpu_min_count

  scaling_config {
    min_size = var.gpu_min_count
    max_size = var.gpu_max_count
  }

  labels = {
    role                     = "gpu"
    "nvidia.com/gpu.present" = "true"
  }

  taints {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NoSchedule"
  }
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "cluster_name" {
  value = alicloud_cs_managed_kubernetes.main.name
}

output "cluster_id" {
  value = alicloud_cs_managed_kubernetes.main.id
}

output "region" {
  value = var.alibaba_region
}
