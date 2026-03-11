# ============================================================================
# Katonic v7 - GKE Cluster (GCP)
# ============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# ----------------------------------------------------------------------------
# VPC
# ----------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }
}

# ----------------------------------------------------------------------------
# GKE Cluster
# ----------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.gcp_region

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  # Remove default node pool, we create our own
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = var.private_cluster
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.private_cluster ? "172.16.0.0/28" : null
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.gcp_project_id}.svc.id.goog"
  }

  resource_labels = var.labels
}

# -- Platform node pool --
resource "google_container_node_pool" "platform" {
  name     = "platform"
  location = var.gcp_region
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = var.platform_min_count
    max_node_count = var.platform_max_count
  }

  node_config {
    machine_type = var.platform_instance_type
    disk_size_gb = var.platform_disk_size
    disk_type    = "pd-ssd"

    labels = { role = "platform" }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# -- Compute node pool --
resource "google_container_node_pool" "compute" {
  name     = "compute"
  location = var.gcp_region
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = var.compute_min_count
    max_node_count = var.compute_max_count
  }

  node_config {
    machine_type = var.compute_instance_type
    disk_size_gb = var.compute_disk_size
    disk_type    = "pd-ssd"

    labels = { role = "compute" }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# -- VectorDB node pool --
resource "google_container_node_pool" "vectordb" {
  name     = "vectordb"
  location = var.gcp_region
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = var.vectordb_min_count
    max_node_count = var.vectordb_max_count
  }

  node_config {
    machine_type = var.vectordb_instance_type
    disk_size_gb = var.vectordb_disk_size
    disk_type    = "pd-ssd"

    labels = { role = "vectordb" }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# -- GPU node pool (optional) --
resource "google_container_node_pool" "gpu" {
  count = var.gpu_enabled ? 1 : 0

  name     = "gpu"
  location = var.gcp_region
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = var.gpu_min_count
    max_node_count = var.gpu_max_count
  }

  node_config {
    machine_type = var.gpu_instance_type
    disk_size_gb = var.gpu_disk_size
    disk_type    = "pd-ssd"

    labels = {
      role                     = "gpu"
      "nvidia.com/gpu.present" = "true"
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    guest_accelerator {
      type  = var.gpu_accelerator_type
      count = var.gpu_accelerator_count
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  value = google_container_cluster.primary.endpoint
}

output "cluster_id" {
  value = google_container_cluster.primary.id
}

output "region" {
  value = var.gcp_region
}
