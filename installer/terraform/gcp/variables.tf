variable "gcp_project_id" { type = string }
variable "gcp_region" { type = string; default = "us-central1" }
variable "cluster_name" { type = string }
variable "private_cluster" { type = bool; default = false }
variable "subnet_cidr" { type = string; default = "10.0.0.0/20" }
variable "pod_cidr" { type = string; default = "10.4.0.0/14" }
variable "service_cidr" { type = string; default = "10.8.0.0/20" }

variable "platform_instance_type" { type = string; default = "e2-standard-8" }
variable "platform_min_count" { type = number; default = 3 }
variable "platform_max_count" { type = number; default = 6 }
variable "platform_disk_size" { type = number; default = 128 }

variable "compute_instance_type" { type = string; default = "e2-standard-16" }
variable "compute_min_count" { type = number; default = 2 }
variable "compute_max_count" { type = number; default = 8 }
variable "compute_disk_size" { type = number; default = 128 }

variable "vectordb_instance_type" { type = string; default = "e2-standard-8" }
variable "vectordb_min_count" { type = number; default = 1 }
variable "vectordb_max_count" { type = number; default = 4 }
variable "vectordb_disk_size" { type = number; default = 128 }

variable "gpu_enabled" { type = bool; default = false }
variable "gpu_instance_type" { type = string; default = "a2-highgpu-1g" }
variable "gpu_min_count" { type = number; default = 0 }
variable "gpu_max_count" { type = number; default = 2 }
variable "gpu_disk_size" { type = number; default = 256 }
variable "gpu_accelerator_type" { type = string; default = "nvidia-tesla-a100" }
variable "gpu_accelerator_count" { type = number; default = 1 }

variable "labels" {
  type    = map(string)
  default = { platform = "katonic-v7", managed-by = "terraform" }
}
