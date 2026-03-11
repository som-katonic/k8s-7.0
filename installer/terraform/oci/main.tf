# ============================================================================
# Katonic v7 - OKE Cluster (Oracle Cloud)
# ============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  region = var.oci_region
}

# ----------------------------------------------------------------------------
# VCN (Virtual Cloud Network)
# ----------------------------------------------------------------------------
resource "oci_core_vcn" "main" {
  compartment_id = var.oci_compartment_ocid
  display_name   = "${var.cluster_name}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = replace(var.cluster_name, "-", "")
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-nat"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "public"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "private"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_nat_gateway.nat.id
  }
}

resource "oci_core_security_list" "k8s" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "k8s-seclist"

  ingress_security_rules {
    protocol = "6"
    source   = var.vcn_cidr
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "k8s_endpoint" {
  compartment_id    = var.oci_compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  display_name      = "k8s-endpoint"
  cidr_block        = cidrsubnet(var.vcn_cidr, 8, 0)
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.k8s.id]
}

resource "oci_core_subnet" "node_pool" {
  compartment_id    = var.oci_compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  display_name      = "node-pool"
  cidr_block        = cidrsubnet(var.vcn_cidr, 4, 1)
  route_table_id    = oci_core_route_table.private.id
  security_list_ids = [oci_core_security_list.k8s.id]
}

resource "oci_core_subnet" "lb" {
  compartment_id    = var.oci_compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  display_name      = "loadbalancer"
  cidr_block        = cidrsubnet(var.vcn_cidr, 8, 2)
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.k8s.id]
}

# ----------------------------------------------------------------------------
# OKE Cluster
# ----------------------------------------------------------------------------
resource "oci_containerengine_cluster" "main" {
  compartment_id = var.oci_compartment_ocid
  name           = var.cluster_name
  vcn_id         = oci_core_vcn.main.id

  kubernetes_version = var.k8s_version

  endpoint_config {
    is_public_ip_enabled = !var.private_cluster
    subnet_id            = oci_core_subnet.k8s_endpoint.id
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.lb.id]
  }
}

# -- Platform node pool --
resource "oci_containerengine_node_pool" "platform" {
  compartment_id     = var.oci_compartment_ocid
  cluster_id         = oci_containerengine_cluster.main.id
  name               = "platform"
  kubernetes_version = var.k8s_version

  node_shape = var.platform_instance_type

  node_shape_config {
    ocpus         = var.platform_ocpus
    memory_in_gbs = var.platform_memory_gb
  }

  node_config_details {
    size = var.platform_min_count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.node_pool.id
    }
  }

  initial_node_labels {
    key   = "role"
    value = "platform"
  }
}

# -- Compute node pool --
resource "oci_containerengine_node_pool" "compute" {
  compartment_id     = var.oci_compartment_ocid
  cluster_id         = oci_containerengine_cluster.main.id
  name               = "compute"
  kubernetes_version = var.k8s_version

  node_shape = var.compute_instance_type

  node_shape_config {
    ocpus         = var.compute_ocpus
    memory_in_gbs = var.compute_memory_gb
  }

  node_config_details {
    size = var.compute_min_count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.node_pool.id
    }
  }

  initial_node_labels {
    key   = "role"
    value = "compute"
  }
}

# -- VectorDB node pool --
resource "oci_containerengine_node_pool" "vectordb" {
  compartment_id     = var.oci_compartment_ocid
  cluster_id         = oci_containerengine_cluster.main.id
  name               = "vectordb"
  kubernetes_version = var.k8s_version

  node_shape = var.vectordb_instance_type

  node_shape_config {
    ocpus         = var.vectordb_ocpus
    memory_in_gbs = var.vectordb_memory_gb
  }

  node_config_details {
    size = var.vectordb_min_count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.node_pool.id
    }
  }

  initial_node_labels {
    key   = "role"
    value = "vectordb"
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_compartment_ocid
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "cluster_name" {
  value = oci_containerengine_cluster.main.name
}

output "cluster_id" {
  value = oci_containerengine_cluster.main.id
}

output "region" {
  value = var.oci_region
}
