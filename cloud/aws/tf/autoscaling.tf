# ──────────────── Autoscaling Components ────────────────
# This file contains all autoscaling-related resources:
# - Metrics Server: Provides CPU/memory metrics for HPA
# - Cluster Autoscaler: Automatically scales EKS node groups
# - HPA: Automatically scales Dify pod replicas

# ──────────────── Locals for Autoscaling ────────────────
locals {
  # HPA configurations - filter enabled deployments
  hpa_configs = {
    for k, v in var.hpa_config : k => merge(v, {
      # Use custom deployment name if provided, otherwise use "dify-{key}"
      deployment_name = v.deployment_name != "" ? v.deployment_name : "dify-${k}"
    }) if var.enable_hpa && v.enabled
  }
}

# ──────────────── Metrics Server ────────────────
# Provides resource metrics (CPU/memory) required by HPA
# Must be installed before HPA can function

resource "helm_release" "metrics_server" {
  count = var.install_metrics_server ? 1 : 0

  name       = "metrics-server"
  repository = var.metrics_server_chart_repo
  chart      = "metrics-server"
  version    = var.metrics_server_version
  namespace  = "kube-system"

  # Production configuration: 2 replicas for HA
  set {
    name  = "replicas"
    value = var.environment == "prod" ? var.metrics_server_replicas : 1
  }

  # EKS-specific kubelet configuration
  # Use InternalIP to avoid issues with node name resolution
  set {
    name  = "args[0]"
    value = "--kubelet-preferred-address-types=InternalIP"
  }

  # Allow insecure TLS for kubelet (common in EKS with self-signed certs)
  set {
    name  = "args[1]"
    value = "--kubelet-insecure-tls"
  }

  # Override image registry for AWS China region
  set {
    name  = "image.repository"
    value = "${var.metrics_server_image_registry}/metrics-server/metrics-server"
  }

  # Enable PodDisruptionBudget for production
  dynamic "set" {
    for_each = var.environment == "prod" ? [1] : []
    content {
      name  = "podDisruptionBudget.enabled"
      value = "true"
    }
  }

  dynamic "set" {
    for_each = var.environment == "prod" ? [1] : []
    content {
      name  = "podDisruptionBudget.minAvailable"
      value = "1"
    }
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_eks_node_group.main
  ]
}

# ──────────────── Cluster Autoscaler IRSA ────────────────
# IAM Role for Service Accounts (IRSA) for Cluster Autoscaler

data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
  count = var.install_cluster_autoscaler ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    # CRITICAL: Conditions must exactly match the ServiceAccount
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name               = "dify-${var.deployment_id}-cluster-autoscaler-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role[0].json

  tags = {
    Name        = "dify-${var.deployment_id}-cluster-autoscaler-role"
    Environment = var.environment
  }
}

# Cluster Autoscaler IAM Policy
resource "aws_iam_policy" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name        = "dify-${var.deployment_id}-cluster-autoscaler-policy"
  description = "Policy for Cluster Autoscaler to manage ASG scaling"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions", # CRITICAL: Required for Launch Template
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "dify-${var.deployment_id}-cluster-autoscaler-policy"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  role       = aws_iam_role.cluster_autoscaler[0].name
  policy_arn = aws_iam_policy.cluster_autoscaler[0].arn
}

# ──────────────── Cluster Autoscaler Helm Release ────────────────
resource "helm_release" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name       = "cluster-autoscaler"
  repository = var.cluster_autoscaler_chart_repo
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_version
  namespace  = "kube-system"

  # Explicitly set cluster name for auto-discovery
  set {
    name  = "autoDiscovery.clusterName"
    value = local.cluster_name
  }

  # Set AWS region
  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  # Pin image version to match EKS cluster version
  set {
    name  = "image.tag"
    value = var.cluster_autoscaler_image_tag
  }

  # Override image registry for AWS China
  set {
    name  = "image.repository"
    value = "${var.cluster_autoscaler_image_registry}/autoscaling/cluster-autoscaler"
  }

  # IRSA configuration
  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  # Explicitly set IRSA annotation (critical for IRSA to work)
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cluster_autoscaler[0].arn
  }

  # Scale down configuration
  set {
    name  = "extraArgs.scale-down-delay-after-add"
    value = var.cluster_autoscaler_scale_down_delay
  }

  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = var.cluster_autoscaler_scale_down_unneeded_time
  }

  # Additional recommended settings
  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.cluster_autoscaler
  ]
}

# ──────────────── Horizontal Pod Autoscalers ────────────────
# Create HPA resources for each enabled Dify deployment

resource "kubernetes_horizontal_pod_autoscaler_v2" "dify" {
  for_each = local.hpa_configs

  metadata {
    name      = "dify-${each.key}-hpa"
    namespace = "dify"
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = each.value.deployment_name
    }

    min_replicas = each.value.min_replicas
    max_replicas = each.value.max_replicas

    # CPU metric (always present)
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = each.value.target_cpu_utilization
        }
      }
    }

    # Memory metric (conditional - only if target_memory_utilization is set)
    dynamic "metric" {
      for_each = each.value.target_memory_utilization != null ? [1] : []
      content {
        type = "Resource"
        resource {
          name = "memory"
          target {
            type                = "Utilization"
            average_utilization = each.value.target_memory_utilization
          }
        }
      }
    }

    # Scaling behavior (conditional - only if stabilization windows are set)
    dynamic "behavior" {
      for_each = each.value.scale_down_stabilization_window != null || each.value.scale_up_stabilization_window != null ? [1] : []
      content {
        scale_down {
          stabilization_window_seconds = each.value.scale_down_stabilization_window

          policy {
            period_seconds = 60
            type           = "Percent"
            value          = 10 # Scale down by max 10% of current replicas per minute
          }

          policy {
            period_seconds = 60
            type           = "Pods"
            value          = 2 # Scale down by max 2 pods per minute
          }

          select_policy = "Min" # Use the policy that results in slower scale down
        }

        scale_up {
          stabilization_window_seconds = each.value.scale_up_stabilization_window

          policy {
            period_seconds = 60
            type           = "Percent"
            value          = 50 # Scale up by max 50% of current replicas per minute
          }

          policy {
            period_seconds = 60
            type           = "Pods"
            value          = 4 # Scale up by max 4 pods per minute
          }

          select_policy = "Max" # Use the policy that results in faster scale up
        }
      }
    }
  }

  # HPA resources are created before Dify Helm deployment
  # Kubernetes will gracefully handle this until the target deployment exists
  depends_on = [
    helm_release.metrics_server
  ]
}
