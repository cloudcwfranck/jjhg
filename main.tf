provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "production-eks-vpc"
  }
}

resource "aws_subnet" "eks_private_subnet" {
  count                   = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  availability_zone       = [for az in data.aws_availability_zones.available.names : az][count.index]
  map_public_ip_on_launch = false
  tags = {
    Name = "production-eks-private-subnet-${count.index}"
  }
}

resource "aws_eks_cluster" "production_eks" {
  name     = "production-eks"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = aws_subnet.eks_private_subnet[*].id
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "eks.amazonaws.com"
        },
      },
    ],
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_eks_node_group" "managed_node_group" {
  cluster_name    = aws_eks_cluster.production_eks.name
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.eks_private_subnet[*].id

  scaling_config {
    desired_size = 2
    max_size     = 5
    min_size     = 1
  }

  depends_on = [
    aws_eks_cluster.production_eks,
  ]
}

resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
      },
    ],
  })
}

resource "aws_iam_role_policy_attachment" "eks_work_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_cloudwatch_log_group" "eks_log_group" {
  name              = "/aws/eks/production" 
  retention_in_days = 90
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "production-eks"
  cluster_version = "1.27"
  node_groups = {
    eks-workers = {
      desired_capacity = 2
      max_capacity     = 5
      min_capacity     = 1
      instance_type    = "t3.medium"
    }
  }
  manage_aws_auth = true
  vpc_id          = aws_vpc.eks_vpc.id
  subnets         = aws_subnet.eks_private_subnet[*].id
}

module "kubectl" {
  source  = "registry.terraform.io/gavinbunney/kubectl"
  version = "1.18.0"

  cluster_name    = module.eks.cluster_name
  kubeconfig_path = module.eks.kubeconfig_file

  apply = {
    command = "apply"
    arguments = "-f install-helm.yaml"
  }

  output = {
    joins = "."
  }
}

resource "helm_release" "metrics_server" {
  name        = "metrics-server"
  repository  = "https://kubernetes-sigs.github.io/metrics-server/"
  chart       = "metrics-server"

  set {
    name  = "extraArgs.kubelet-insecure-tls"
    value = "true"
  }
}

data "aws_availability_zones" "available" {}
