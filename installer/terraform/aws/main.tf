# ============================================================================
# Katonic v7 - EKS Cluster (AWS)
# ============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ----------------------------------------------------------------------------
# Data sources
# ----------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# ----------------------------------------------------------------------------
# VPC
# ----------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 3)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${var.cluster_name}"    = "owned"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${var.cluster_name}"    = "owned"
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# EKS Cluster
# ----------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.eks_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = !var.private_cluster
  cluster_endpoint_private_access = true

  # EBS CSI driver (for gp3 storage class)
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }

  eks_managed_node_groups = {
    platform = {
      name           = "platform"
      instance_types = [var.platform_instance_type]
      min_size       = var.platform_min_count
      max_size       = var.platform_max_count
      desired_size   = var.platform_min_count
      disk_size      = var.platform_disk_size

      labels = {
        role = "platform"
      }
    }

    compute = {
      name           = "compute"
      instance_types = [var.compute_instance_type]
      min_size       = var.compute_min_count
      max_size       = var.compute_max_count
      desired_size   = var.compute_min_count
      disk_size      = var.compute_disk_size

      labels = {
        role = "compute"
      }
    }

    vectordb = {
      name           = "vectordb"
      instance_types = [var.vectordb_instance_type]
      min_size       = var.vectordb_min_count
      max_size       = var.vectordb_max_count
      desired_size   = var.vectordb_min_count
      disk_size      = var.vectordb_disk_size

      labels = {
        role = "vectordb"
      }
    }
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# GPU Node Group (optional)
# ----------------------------------------------------------------------------
resource "aws_iam_role" "gpu_nodes" {
  count = var.gpu_enabled ? 1 : 0

  name = "${var.cluster_name}-gpu-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "gpu_worker" {
  count      = var.gpu_enabled ? 1 : 0
  role       = aws_iam_role.gpu_nodes[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "gpu_cni" {
  count      = var.gpu_enabled ? 1 : 0
  role       = aws_iam_role.gpu_nodes[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "gpu_ecr" {
  count      = var.gpu_enabled ? 1 : 0
  role       = aws_iam_role.gpu_nodes[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "gpu" {
  count = var.gpu_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  node_group_name = "gpu"
  node_role_arn   = aws_iam_role.gpu_nodes[0].arn
  subnet_ids      = module.vpc.private_subnets

  instance_types = [var.gpu_instance_type]
  ami_type       = "AL2_x86_64_GPU"

  scaling_config {
    desired_size = var.gpu_min_count
    max_size     = var.gpu_max_count
    min_size     = var.gpu_min_count
  }

  disk_size = var.gpu_disk_size

  labels = {
    role                        = "gpu"
    "nvidia.com/gpu.present"    = "true"
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# EBS CSI Driver IRSA
# ----------------------------------------------------------------------------
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_id" {
  value = module.eks.cluster_id
}

output "region" {
  value = var.aws_region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
