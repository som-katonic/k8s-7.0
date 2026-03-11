variable "alibaba_region" { type = string; default = "cn-hangzhou" }
variable "cluster_name" { type = string }
variable "k8s_version" { type = string; default = "1.30.1-aliyun.1" }
variable "private_cluster" { type = bool; default = false }
variable "vpc_cidr" { type = string; default = "10.0.0.0/16" }
variable "pod_cidr" { type = string; default = "172.20.0.0/16" }
variable "service_cidr" { type = string; default = "172.21.0.0/20" }

variable "platform_instance_type" { type = string; default = "ecs.g7.2xlarge" }
variable "platform_min_count" { type = number; default = 3 }
variable "platform_max_count" { type = number; default = 6 }
variable "platform_disk_size" { type = number; default = 128 }

variable "compute_instance_type" { type = string; default = "ecs.g7.4xlarge" }
variable "compute_min_count" { type = number; default = 2 }
variable "compute_max_count" { type = number; default = 8 }
variable "compute_disk_size" { type = number; default = 128 }

variable "vectordb_instance_type" { type = string; default = "ecs.g7.2xlarge" }
variable "vectordb_min_count" { type = number; default = 1 }
variable "vectordb_max_count" { type = number; default = 4 }
variable "vectordb_disk_size" { type = number; default = 128 }

variable "gpu_enabled" { type = bool; default = false }
variable "gpu_instance_type" { type = string; default = "ecs.gn7-c13g1.4xlarge" }
variable "gpu_min_count" { type = number; default = 0 }
variable "gpu_max_count" { type = number; default = 2 }
variable "gpu_disk_size" { type = number; default = 256 }

variable "tags" {
  type    = map(string)
  default = { Platform = "katonic-v7", ManagedBy = "terraform" }
}
