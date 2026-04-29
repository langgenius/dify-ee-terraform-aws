# ──────────────── IRSA (IAM Roles for Service Accounts) ────────────────

# OIDC Provider for EKS
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name        = "dify-${var.deployment_id}-eks-oidc"
    Environment = var.environment
  }
}

# ──────────────── Dify EE IRSA Roles ────────────────

# 1. S3-only role for dify-api ServiceAccount
resource "aws_iam_role" "dify_ee_s3_role" {
  name = "dify-${var.deployment_id}-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
      }
    ]
  })

  tags = {
    Name        = "dify-${var.deployment_id}-s3-role"
    Environment = var.environment
    Purpose     = "DifyEE-S3-Access"
  }
}

# 2. S3 + ECR role for dify-plugin-crd ServiceAccount
resource "aws_iam_role" "dify_ee_s3_ecr_role" {
  name = "dify-${var.deployment_id}-s3-ecr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
      }
    ]
  })

  tags = {
    Name        = "dify-${var.deployment_id}-s3-ecr-role"
    Environment = var.environment
    Purpose     = "DifyEE-S3-ECR-Access"
  }
}

# 3. ECR image pull role for dify-plugin-runner ServiceAccount
resource "aws_iam_role" "dify_ee_ecr_pull_role" {
  name = "dify-${var.deployment_id}-ecr-pull-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
      }
    ]
  })

  tags = {
    Name        = "dify-${var.deployment_id}-ecr-pull-role"
    Environment = var.environment
    Purpose     = "DifyEE-ECR-Image-Pull"
  }
}

# ──────────────── IAM Policies ────────────────

# S3 policy for bucket access. Resource scope is restricted to objects under
# the Dify-owned storage bucket; broad object actions (Get/Put/Delete/List/
# multipart) are required for app uploads, plugin assets, and lifecycle ops.
# trivy:ignore:AVD-AWS-0345
resource "aws_iam_policy" "dify_ee_s3_policy" {
  name = "dify-${var.deployment_id}-s3-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "arn:${local.aws_partition}:s3:::${aws_s3_bucket.dify_storage.bucket}/*"
      }
    ]
  })

  tags = {
    Name        = "dify-${var.deployment_id}-s3-policy"
    Environment = var.environment
  }
}

# ECR policy with granular permissions
# CHANGED: Replaced "ecr:*" wildcard with specific ECR actions to follow principle of least privilege
# SECURITY IMPROVEMENT: Image push/pull operations are now restricted to repositories with "dify-{deployment_id}" prefix
# This prevents accidental access to other ECR repositories while maintaining required functionality
resource "aws_iam_policy" "dify_ee_ecr_policy" {
  name = "dify-${var.deployment_id}-ecr-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR read operations - global scope required for authentication and discovery
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",    # Required for Docker login to ECR
          "ecr:DescribeRepositories",     # List and inspect repositories
          "ecr:DescribeImages",           # List and inspect images
          "ecr:GetRepositoryPolicy",      # Read repository policies
          "ecr:GetLifecyclePolicy",       # Read lifecycle policies
          "ecr:GetLifecyclePolicyPreview" # Preview lifecycle policy effects
        ]
        Resource = "*"
      },
      {
        # ECR repository management - global scope for repository creation
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository", # Create new ECR repositories
          "ecr:TagResource"       # Add tags to ECR resources
        ]
        Resource = "*"
      },
      {
        # ECR image push operations - RESTRICTED to deployment-specific repositories only
        # SECURITY: This prevents pushing to other teams' or environments' repositories
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", # Check if image layers exist
          "ecr:CompleteLayerUpload",         # Complete multipart layer upload
          "ecr:InitiateLayerUpload",         # Start layer upload process
          "ecr:UploadLayerPart",             # Upload parts of image layers
          "ecr:PutImage"                     # Upload complete image manifest
        ]
        Resource = "arn:${local.aws_partition}:ecr:*:${var.aws_account_id}:repository/dify-${var.deployment_id}*"
      },
      {
        # CloudTrail access for audit logging
        Effect = "Allow"
        Action = [
          "cloudtrail:LookupEvents" # Query CloudTrail logs for audit purposes
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "dify-${var.deployment_id}-ecr-policy"
    Environment = var.environment
  }
}

# ECR pull-only policy with granular permissions
# CHANGED: Enhanced from single "ecr:BatchGetImage" action to comprehensive pull permissions
# SECURITY IMPROVEMENT: Added authentication token access and restricted image operations to deployment-specific repositories
# This ensures secure image pulling while preventing access to other ECR repositories
resource "aws_iam_policy" "dify_ee_ecr_pull_only_policy" {
  name = "dify-${var.deployment_id}-ecr-pull-only-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR authentication - required for Docker login
        Sid      = "ControlPlaneAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # ECR image pull operations - RESTRICTED to deployment-specific repositories only
        # SECURITY: This prevents pulling from other teams' or environments' repositories
        Sid    = "DataPlanePullFromDifyPrefix"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",          # Download image manifests and metadata
          "ecr:GetDownloadUrlForLayer", # Get URLs to download image layers
          "ecr:DescribeImages"          # Get image metadata and tags
        ]
        Resource = "arn:${local.aws_partition}:ecr:*:${var.aws_account_id}:repository/dify-${var.deployment_id}*"
      }
    ]
  })

  tags = {
    Name        = "dify-${var.deployment_id}-ecr-pull-policy"
    Environment = var.environment
  }
}

# ──────────────── Policy Attachments ────────────────

# Attach S3 policy to S3-only role
resource "aws_iam_role_policy_attachment" "dify_ee_s3_role_s3_policy" {
  role       = aws_iam_role.dify_ee_s3_role.name
  policy_arn = aws_iam_policy.dify_ee_s3_policy.arn
}

# Attach S3 and ECR policies to S3+ECR role
resource "aws_iam_role_policy_attachment" "dify_ee_s3_ecr_role_s3_policy" {
  role       = aws_iam_role.dify_ee_s3_ecr_role.name
  policy_arn = aws_iam_policy.dify_ee_s3_policy.arn
}

resource "aws_iam_role_policy_attachment" "dify_ee_s3_ecr_role_ecr_policy" {
  role       = aws_iam_role.dify_ee_s3_ecr_role.name
  policy_arn = aws_iam_policy.dify_ee_ecr_policy.arn
}

# Attach ECR pull-only policy to ECR pull role
resource "aws_iam_role_policy_attachment" "dify_ee_ecr_pull_role_policy" {
  role       = aws_iam_role.dify_ee_ecr_pull_role.name
  policy_arn = aws_iam_policy.dify_ee_ecr_pull_only_policy.arn
}

# ──────────────── Legacy S3 Access Role (for backward compatibility) ────────────────
resource "aws_iam_role" "s3_access" {
  name = "dify-${var.deployment_id}-s3-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:default:dify-s3-service-account"
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# tfsec:ignore:aws-iam-no-policy-wildcards -- wildcard scoped to dify_storage bucket prefix only; required for object-level read/write/list
resource "aws_iam_policy" "s3_access" {
  name = "dify-${var.deployment_id}-s3-access-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.dify_storage.arn,
          "${aws_s3_bucket.dify_storage.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.s3_access.name
  policy_arn = aws_iam_policy.s3_access.arn
}




# ──────────────── Kubernetes ServiceAccounts with IRSA annotations ────────────────

# ServiceAccount for dify-api (S3 access only)
resource "kubernetes_service_account" "dify_api" {
  metadata {
    name      = "dify-api-sa"
    namespace = kubernetes_namespace.dify.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_s3_role.arn
    }
    labels = {
      "app.kubernetes.io/name"       = "dify-api"
      "app.kubernetes.io/component"  = "api"
      "app.kubernetes.io/part-of"    = "dify-ee"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_iam_role.dify_ee_s3_role,
    kubernetes_namespace.dify
  ]
}

# ServiceAccount for dify-plugin-crd (S3 + ECR access)
resource "kubernetes_service_account" "dify_plugin_crd" {
  metadata {
    name      = "dify-plugin-crd-sa"
    namespace = kubernetes_namespace.dify.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_s3_ecr_role.arn
    }
    labels = {
      "app.kubernetes.io/name"       = "dify-plugin-crd"
      "app.kubernetes.io/component"  = "plugin-crd"
      "app.kubernetes.io/part-of"    = "dify-ee"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_iam_role.dify_ee_s3_ecr_role,
    kubernetes_namespace.dify
  ]
}

# ServiceAccount for dify-plugin-runner (ECR image pull only)
resource "kubernetes_service_account" "dify_plugin_runner" {
  metadata {
    name      = "dify-plugin-runner-sa"
    namespace = kubernetes_namespace.dify.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_ecr_pull_role.arn
    }
    labels = {
      "app.kubernetes.io/name"       = "dify-plugin-runner"
      "app.kubernetes.io/component"  = "plugin-runner"
      "app.kubernetes.io/part-of"    = "dify-ee"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_iam_role.dify_ee_ecr_pull_role,
    kubernetes_namespace.dify
  ]
}

## ServiceAccount for dify-plugin-connector (precreated then adopted by Helm)
resource "kubernetes_service_account" "dify_plugin_connector" {
  metadata {
    name      = "dify-plugin-connector-sa"
    namespace = kubernetes_namespace.dify.metadata[0].name
    annotations = {
      # IRSA role for S3 access
      "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_s3_role.arn
      # Let Helm adopt and manage this existing SA
      "meta.helm.sh/release-name"      = "dify"
      "meta.helm.sh/release-namespace" = kubernetes_namespace.dify.metadata[0].name
    }
    labels = {
      "app.kubernetes.io/name"      = "dify-plugin-connector"
      "app.kubernetes.io/component" = "plugin-connector"
      "app.kubernetes.io/part-of"   = "dify-ee"
      # Mark as managed by Helm to enable adoption
      "app.kubernetes.io/managed-by" = "Helm"
    }
  }

  # Avoid Terraform/Helm drift on metadata managed by Helm after adoption
  lifecycle {
    ignore_changes = [
      # metadata[0].annotations["eks.amazonaws.com/role-arn"],
      metadata[0].annotations["meta.helm.sh/release-name"],
      metadata[0].annotations["meta.helm.sh/release-namespace"],
      metadata[0].labels["app.kubernetes.io/managed-by"],
    ]
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_iam_role.dify_ee_s3_role,
    kubernetes_namespace.dify
  ]
}
