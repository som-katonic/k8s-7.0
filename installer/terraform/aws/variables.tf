# ============================================================================
# Katonic v7 - EKS Variables
# ============================================================================

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type = string
}

variable "eks_version" {
  type    = string
  default = "1.30"
}

variable "private_cluster" {
  type    = bool
  default = false
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

# -- Platform nodes --
variable "platform_instance_type" {
  type    = string
  default = "m5.2xlarge"
}
variable "platform_min_count" {
  type    = number
  default = 3
}
variable "platform_max_count" {
  type    = number
  default = 6
}
variable "platform_disk_size" {
  type    = number
  default = 128
}

# -- Compute nodes --
variable "compute_instance_type" {
  type    = string
  default = "m5.4xlarge"
}
variable "compute_min_count" {
  type    = number
  default = 2
}
variable "compute_max_count" {
  type    = number
  default = 8
}
variable "compute_disk_size" {
  type    = number
  default = 128
}

# -- VectorDB nodes --
variable "vectordb_instance_type" {
  type    = string
  default = "m5.2xlarge"
}
variable "vectordb_min_count" {
  type    = number
  default = 1
}
variable "vectordb_max_count" {
  type    = number
  default = 4
}
variable "vectordb_disk_size" {
  type    = number
  default = 128
}

# -- GPU nodes --
variable "gpu_enabled" {
  type    = bool
  default = false
}
variable "gpu_instance_type" {
  type    = string
  default = "p4d.24xlarge"
}
variable "gpu_min_count" {
  type    = number
  default = 0
}
variable "gpu_max_count" {
  type    = number
  default = 2
}
variable "gpu_disk_size" {
  type    = number
  default = 256
}

variable "tags" {
  type = map(string)
  default = {
    Platform = "katonic-v7"
    ManagedBy = "terraform"
  }
}
