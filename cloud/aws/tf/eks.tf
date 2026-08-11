locals {
  cluster_name = "dify-${var.deployment_id}-eks-cluster"

  # Priority: existing_vpc_subnets > old variables > terraform created subnets
  cluster_subnets = (
    length(var.existing_vpc_subnets.private) > 0 ? var.existing_vpc_subnets.private :
    length(var.eks_cluster_subnets) > 0 ? var.eks_cluster_subnets :
    (local.create_vpc ? aws_subnet.private[*].id : [])
  )

  node_subnets = (
    length(var.existing_vpc_subnets.private) > 0 ? var.existing_vpc_subnets.private :
    length(var.eks_nodes_subnets) > 0 ? var.eks_nodes_subnets :
    (local.create_vpc ? aws_subnet.private[*].id : [])
  )

  # Environment-specific disk size configuration
  node_disk_size = var.environment == "test" ? var.eks_node_disk_size_test : var.eks_node_disk_size_prod

  # Environment-specific node configuration, switches with architecture
  # Configuration is loaded from eks_test_node_config or eks_prod_node_config variables
  node_config = var.environment == "test" ? (
    var.eks_arch == "amd64" ? var.eks_test_node_config.amd64 : var.eks_test_node_config.arm64
    ) : (
    var.eks_arch == "amd64" ? var.eks_prod_node_config.amd64 : var.eks_prod_node_config.arm64
  )
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          # Note: EKS service principal uses amazonaws.com even in AWS China regions
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Node Group IAM Role
resource "aws_iam_role" "eks_node_group" {
  name = "${local.cluster_name}-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.${local.dns_suffix}"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

# KMS key for EKS secret envelope encryption
resource "aws_kms_key" "eks_secrets" {
  description             = "Envelope encryption key for ${local.cluster_name} Kubernetes secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = {
    Name        = "${local.cluster_name}-secrets-kms"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# Control-plane log group, pre-created so Terraform owns it.
# When enabled_cluster_log_types is set, EKS auto-creates
# /aws/eks/<cluster>/cluster OUTSIDE Terraform on first log delivery —
# never-expiring retention, survives terraform destroy, bills silently.
# Creating it here first (EKS reuses an existing group) puts it in state:
# retention is enforced and destroy removes it. The cluster resource must
# depend on it, or EKS wins the race and creates its own.
# Destroy caveat: TF deletes this group before the cluster finishes deleting;
# EKS may flush final control-plane logs afterward and re-create a small
# orphan group — the teardown orphan scan (SKILL.md B.5) still checks for it.
# Upgrading an EXISTING deployment: EKS already auto-created this group outside
# Terraform, so the first apply fails with ResourceAlreadyExistsException.
# Adopt it first:
#   terraform import aws_cloudwatch_log_group.eks_cluster /aws/eks/dify-<deployment_id>-eks-cluster/cluster
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.eks_log_retention_days

  tags = {
    Name        = "/aws/eks/${local.cluster_name}/cluster"
    Environment = var.environment
  }
}

# EKS Cluster
# tfsec:ignore:aws-eks-no-public-cluster-access -- public endpoint is gated on elb_mode == "internet-facing"
# tfsec:ignore:aws-eks-no-public-cluster-access-to-cidr -- public_access_cidrs tightening tracked separately; default allow is intentional in internet-facing mode
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  vpc_config {
    subnet_ids = local.cluster_subnets

    # Configure endpoint access based on ELB mode
    # - internet-facing: Enable public endpoint for easier access, also enable private for pod communication
    # - internal: Only enable private endpoint for VPC-internal access
    endpoint_private_access = true
    endpoint_public_access  = var.elb_mode == "internet-facing" ? true : false
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    # Log group must exist before EKS starts logging, or EKS creates its own
    # unmanaged /aws/eks/<cluster>/cluster group (see aws_cloudwatch_log_group above).
    aws_cloudwatch_log_group.eks_cluster,
  ]

  tags = {
    Name        = local.cluster_name
    Environment = var.environment
  }
}

# EKS Nodes Security Group
resource "aws_security_group" "eks_nodes" {
  name_prefix = "${local.cluster_name}-nodes-"
  description = "Security group for ${local.cluster_name} worker nodes"
  vpc_id      = local.vpc_id

  ingress {
    description = "Node-to-node communication on all ephemeral TCP ports"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Control plane to node kubelet/extension API ports"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  ingress {
    description     = "Control plane to node webhook/HTTPS"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  # tfsec:ignore:aws-ec2-no-public-egress-sgr -- nodes need outbound access to pull images, reach AWS APIs and external dependencies via NAT
  egress {
    description = "Allow all outbound traffic (NAT-routed for private subnets)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.cluster_name}-nodes-sg"
    Environment = var.environment
  }
}

# Launch Template for EKS Nodes
# Used to explicitly specify the node security group, ensuring that our custom security group is used instead of the cluster's default security group
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${local.cluster_name}-nodes-"

  vpc_security_group_ids = [
    aws_security_group.eks_nodes.id,
    aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  ]

  # Enforce IMDSv2 on worker nodes; hop limit 2 lets pods reach IMDS through one extra network hop
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # EBS volume configuration
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = local.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      {
        Name        = "dify-${var.deployment_id}-node"
        Environment = var.environment
      },
      # Cluster Autoscaler discovery tags (optional, for EC2 instance visibility)
      var.install_cluster_autoscaler ? {
        "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
        "k8s.io/cluster-autoscaler/enabled"               = "true"
      } : {}
    )
  }

  tags = {
    Name        = "${local.cluster_name}-nodes-launch-template"
    Environment = var.environment
  }
}

# EKS Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = local.node_subnets

  # Pin the node AMI Kubernetes version to the control plane version so
  # cluster upgrades also roll the nodes (otherwise nodes silently stay on
  # the version the group was created with, drifting toward the kubelet
  # n-3 skew limit).
  version = var.cluster_version

  scaling_config {
    desired_size = local.node_config.desired_size
    max_size     = local.node_config.max_size
    min_size     = local.node_config.min_size
  }

  instance_types = local.node_config.instance_types
  ami_type       = var.eks_arch == "amd64" ? "AL2023_x86_64_STANDARD" : "AL2023_ARM_64_STANDARD"

  # Use launch template to specify node security group
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]

  # CRITICAL: Cluster Autoscaler discovery tags MUST be on the Node Group (ASG level)
  # These tags on the ASG itself allow CA to discover and manage this node group
  tags = merge(
    {
      Name        = "dify-${var.deployment_id}-nodes"
      Environment = var.environment
    },
    var.install_cluster_autoscaler ? {
      "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
      "k8s.io/cluster-autoscaler/enabled"               = "true"
    } : {}
  )
}

# ──────────────── Cluster tags on module-created VPC resources ────────────────
# The kubernetes.io/cluster/<name> = "shared" tag for the module-created VPC and
# subnets is set INLINE in vpc.tf (aws_vpc.main / aws_subnet.public|private.tags).
# It must not also be managed here via aws_ec2_tag: two owners of the same tag key
# make every plan flap (aws_ec2_tag re-adds it, the inline tags strip it).
# For an existing VPC (use_existing_vpc = true), tags are managed in vpc.tf via
# aws_ec2_tag.existing_* and controlled by the auto_tag_subnets variable.
