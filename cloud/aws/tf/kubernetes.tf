# ──────────────── Kubernetes Resource Configuration ────────────────
# 
# This file creates Kubernetes resources required for Dify application, including:
# - Dify namespace
# - IRSA ServiceAccounts (replacing the functionality of irsa_one_click.sh script)
#

# Create namespace for Dify application
resource "kubernetes_namespace" "dify" {
  metadata {
    name = var.dify_namespace
    labels = {
      "app.kubernetes.io/name"       = "dify"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [aws_eks_cluster.main]
}

# ──────────────── IRSA ServiceAccounts ────────────────
# 
# Providing AWS resource access permissions for Dify application, the rest code is maintained in irsa.tf
#

resource "kubernetes_service_account" "dify_plugin_build" {
  metadata {
    name      = "dify-plugin-build-sa"
    namespace = kubernetes_namespace.dify.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_s3_ecr_role.arn
    }
    labels = {
      "app.kubernetes.io/name"       = "dify-plugin-build"
      "app.kubernetes.io/component"  = "plugin-build"
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

resource "kubernetes_service_account" "dify_plugin_build_run" {
  metadata {
    name      = "dify-plugin-build-run-sa"
    namespace = kubernetes_namespace.dify.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_ecr_pull_role.arn
    }
    labels = {
      "app.kubernetes.io/name"       = "dify-plugin-build-run"
      "app.kubernetes.io/component"  = "plugin-build-run"
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

# ──────────────── Namespace for Dify EE (optional) ────────────────
# Uncomment if you want to deploy Dify EE in a separate namespace

# resource "kubernetes_namespace" "dify_ee" {
#   metadata {
#     name = "dify-ee"
#     labels = {
#       "app.kubernetes.io/name"       = "dify-ee"
#       "app.kubernetes.io/managed-by" = "terraform"
#     }
#   }
# }

# # ServiceAccounts in dify-ee namespace
# resource "kubernetes_service_account" "dify_api_ee_ns" {
#   metadata {
#     name      = "dify-api-sa"
#     namespace = kubernetes_namespace.dify_ee.metadata[0].name
#     annotations = {
#       "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_s3_role.arn
#     }
#   }
#   depends_on = [aws_eks_cluster.main]
# }

# resource "kubernetes_service_account" "dify_plugin_crd_ee_ns" {
#   metadata {
#     name      = "dify-plugin-crd-sa"
#     namespace = kubernetes_namespace.dify_ee.metadata[0].name
#     annotations = {
#       "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_s3_ecr_role.arn
#     }
#   }
#   depends_on = [aws_eks_cluster.main]
# }

# resource "kubernetes_service_account" "dify_plugin_runner_ee_ns" {
#   metadata {
#     name      = "dify-plugin-runner-sa"
#     namespace = kubernetes_namespace.dify_ee.metadata[0].name
#     annotations = {
#       "eks.amazonaws.com/role-arn" = aws_iam_role.dify_ee_ecr_pull_role.arn
#     }
#   }
#   depends_on = [aws_eks_cluster.main]
# }
