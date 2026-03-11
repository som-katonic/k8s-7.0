variable "oci_region" { type = string; default = "us-ashburn-1" }
variable "oci_compartment_ocid" { type = string }
variable "cluster_name" { type = string }
variable "k8s_version" { type = string; default = "v1.30.1" }
variable "private_cluster" { type = bool; default = false }
variable "vcn_cidr" { type = string; default = "10.0.0.0/16" }

variable "platform_instance_type" { type = string; default = "VM.Standard.E4.Flex" }
variable "platform_ocpus" { type = number; default = 8 }
variable "platform_memory_gb" { type = number; default = 64 }
variable "platform_min_count" { type = number; default = 3 }

variable "compute_instance_type" { type = string; default = "VM.Standard.E4.Flex" }
variable "compute_ocpus" { type = number; default = 16 }
variable "compute_memory_gb" { type = number; default = 128 }
variable "compute_min_count" { type = number; default = 2 }

variable "vectordb_instance_type" { type = string; default = "VM.Standard.E4.Flex" }
variable "vectordb_ocpus" { type = number; default = 8 }
variable "vectordb_memory_gb" { type = number; default = 64 }
variable "vectordb_min_count" { type = number; default = 1 }

variable "gpu_enabled" { type = bool; default = false }
