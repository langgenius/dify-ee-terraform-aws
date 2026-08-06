variable "environment" {
  description = "Deployment environment (test or prod)"
  type        = string
  validation {
    condition     = contains(["test", "prod"], var.environment)
    error_message = "Environment must be either 'test' or 'prod'."
  }
}

variable "deployment_id" {
  description = "Unique deployment identifier (e.g. 'prod1', 'dev2', 'staging')"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{3,15}$", var.deployment_id))
    error_message = "deployment_id must be 3-15 chars, lowercase alphanumeric and hyphens only."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "vpc_id" {
  description = "Existing VPC ID (optional)"
  type        = string
  default     = ""
}

# Simplified existing VPC subnet configuration
variable "existing_vpc_subnets" {
  description = "Subnet IDs for existing VPC (used when use_existing_vpc=true). Must include at least 2 private subnets across different AZs."
  type = object({
    private = list(string) # Private subnet IDs (minimum 2 for HA)
    public  = list(string) # Public subnet IDs (optional, needed only for internet-facing ELB)
  })
  default = {
    private = []
    public  = []
  }
}

# Automatic subnet tagging for Kubernetes (only applies when using existing VPC)
variable "auto_tag_subnets" {
  description = "Automatically add required Kubernetes tags to existing VPC subnets (kubernetes.io/cluster/*, kubernetes.io/role/*). Only applicable when use_existing_vpc = true. Set to false if subnets are pre-tagged or you lack tag modification permissions. When creating new VPC, tags are always added automatically."
  type        = bool
  default     = true
}

# ELB exposure mode configuration
variable "elb_mode" {
  description = "ELB scheme: 'internet-facing' for public internet access, 'internal' for VPC-internal access only"
  type        = string
  default     = "internet-facing"
  validation {
    condition     = contains(["internet-facing", "internal"], var.elb_mode)
    error_message = "elb_mode must be either 'internet-facing' or 'internal'."
  }
}

# Deprecated: Use existing_vpc_subnets instead
# These are kept for backward compatibility
variable "eks_cluster_subnets" {
  description = "[DEPRECATED] Use existing_vpc_subnets.private instead. Subnet IDs for EKS control plane"
  type        = list(string)
  default     = []
}

variable "eks_nodes_subnets" {
  description = "[DEPRECATED] Use existing_vpc_subnets.private instead. Subnet IDs for EKS worker nodes"
  type        = list(string)
  default     = []
}

variable "redis_subnets" {
  description = "[DEPRECATED] Use existing_vpc_subnets.private instead. Subnet IDs for Redis"
  type        = list(string)
  default     = []
}

variable "rds_subnets" {
  description = "[DEPRECATED] Use existing_vpc_subnets.private instead. Subnet IDs for RDS"
  type        = list(string)
  default     = []
}

variable "opensearch_subnets" {
  description = "[DEPRECATED] Use existing_vpc_subnets.private instead. Subnet IDs for OpenSearch"
  type        = list(string)
  default     = []
}

variable "rds_public_accessible" {
  description = "Make RDS publicly accessible"
  type        = bool
  default     = false
}

variable "aws_eks_chart_repo_url" {
  description = "AWS EKS Helm chart repository URL (for China regions)"
  type        = string
  default     = ""
}

# ──────────────── Helm Chart Configuration ────────────────

variable "dify_namespace" {
  description = "Kubernetes namespace for Dify application"
  type        = string
  default     = "dify"
}

# AWS Load Balancer Controller
variable "install_aws_load_balancer_controller" {
  description = "Install AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "aws_load_balancer_controller_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.6.2"
}

# NGINX Ingress Controller
variable "install_nginx_ingress" {
  description = "Install NGINX Ingress Controller (alternative to ALB)"
  type        = bool
  default     = false
}

variable "nginx_ingress_version" {
  description = "NGINX Ingress Controller Helm chart version"
  type        = string
  default     = "4.8.3"
}


variable "cert_manager_version" {
  description = "Cert-Manager Helm chart version"
  type        = string
  default     = "v1.13.2"
}

# ──────────────── Infrastructure Configuration ────────────────

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.28"
}

variable "eks_arch" {
  description = "EKS worker node architecture. Allowed values: 'amd64' or 'arm64'"
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["amd64", "arm64"], var.eks_arch)
    error_message = "eks_arch must be either 'amd64' or 'arm64'."
  }
}

# Node Group Configuration
# Node configuration can be customized based on the environment and architecture

variable "eks_node_disk_size_test" {
  description = "EKS worker node disk size in GB for test environment"
  type        = number
  default     = 40
}

variable "eks_node_disk_size_prod" {
  description = "EKS worker node disk size in GB for production environment"
  type        = number
  default     = 20
}

# Test environment node configuration
variable "eks_test_node_config" {
  description = "EKS node configuration for test environment (by architecture)"
  type = object({
    amd64 = object({
      instance_types = list(string)
      desired_size   = number
      max_size       = number
      min_size       = number
    })
    arm64 = object({
      instance_types = list(string)
      desired_size   = number
      max_size       = number
      min_size       = number
    })
  })
  default = {
    amd64 = {
      instance_types = ["m7a.xlarge"]
      desired_size   = 1
      max_size       = 2
      min_size       = 1
    }
    arm64 = {
      instance_types = ["m7g.xlarge"]
      desired_size   = 1
      max_size       = 2
      min_size       = 1
    }
  }
}

# Production environment node configuration
variable "eks_prod_node_config" {
  description = "EKS node configuration for production environment (by architecture)"
  type = object({
    amd64 = object({
      instance_types = list(string)
      desired_size   = number
      max_size       = number
      min_size       = number
    })
    arm64 = object({
      instance_types = list(string)
      desired_size   = number
      max_size       = number
      min_size       = number
    })
  })
  default = {
    amd64 = {
      instance_types = ["m7a.2xlarge"]
      desired_size   = 6
      max_size       = 10
      min_size       = 6
    }
    arm64 = {
      instance_types = ["m7g.2xlarge"]
      desired_size   = 6
      max_size       = 10
      min_size       = 6
    }
  }
}

# VPC Configuration
variable "use_existing_vpc" {
  description = "Whether to use an existing VPC"
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# availability_zones removed - now automatically fetches the first 3 available zones from the current region

variable "private_subnet_ids" {
  description = "Private subnet IDs (for existing VPC)"
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (for existing VPC)"
  type        = list(string)
  default     = []
}

# Database Configuration (Aurora Serverless v2)
variable "db_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "17.5"
}

variable "db_min_capacity" {
  description = "Aurora Serverless v2 minimum capacity (ACU)"
  type        = number
  default     = 0.5
}

variable "db_max_capacity" {
  description = "Aurora Serverless v2 maximum capacity (ACU)"
  type        = number
  default     = 4
}

variable "db_backup_retention_period" {
  description = "RDS backup retention period in days"
  type        = number
  default     = 7
}

variable "db_backup_window" {
  description = "RDS backup window"
  type        = string
  default     = "03:00-04:00"
}

variable "db_master_password" {
  description = "RDS master password"
  type        = string
  default     = "DifyRdsPassword123!"
  sensitive   = true

  validation {
    condition = (
      length(var.db_master_password) >= 8 &&
      can(regex("^[^/@\"' ]*$", var.db_master_password))
    )
    error_message = "RDS password must be at least 8 characters and cannot contain /, @, \", ', or spaces."
  }
}

# ──────────────── Database Names Configuration ────────────────

variable "db_main_database_name" {
  description = "Main database name for Dify application"
  type        = string
  default     = "dify"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.db_main_database_name))
    error_message = "Database name must start with a letter and contain only lowercase letters, numbers, and underscores."
  }
}

variable "db_enterprise_database_name" {
  description = "Database name for Dify Enterprise features"
  type        = string
  default     = "enterprise"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.db_enterprise_database_name))
    error_message = "Database name must start with a letter and contain only lowercase letters, numbers, and underscores."
  }
}

variable "db_audit_database_name" {
  description = "Database name for Dify audit logging"
  type        = string
  default     = "audit"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.db_audit_database_name))
    error_message = "Database name must start with a letter and contain only lowercase letters, numbers, and underscores."
  }
}

variable "db_plugin_daemon_database_name" {
  description = "Database name for Dify plugin daemon"
  type        = string
  default     = "dify_plugin_daemon"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.db_plugin_daemon_database_name))
    error_message = "Database name must start with a letter and contain only lowercase letters, numbers, and underscores."
  }
}

# Redis Configuration (Cluster Mode Disabled)
# Node count and high availability are automatically set based on the environment:
# - test environment: single node mode (cache.t4g.micro)
# - prod environment: master-replica mode (user-configurable instance type)
variable "redis_node_type" {
  description = "ElastiCache Redis node type (only used for production environment, fixed to cache.t4g.micro for test environment)"
  type        = string
  default     = "cache.r6g.large"
}


variable "redis_engine_version" {
  description = "ElastiCache Redis engine version"
  type        = string
  default     = "7.1"
}

# OpenSearch Configuration
variable "opensearch_instance_type" {
  description = "OpenSearch instance type"
  type        = string
  default     = "t3.small.search"
}

variable "opensearch_instance_count" {
  description = "Number of OpenSearch instances"
  type        = number
  default     = 1
}

variable "opensearch_ebs_volume_size" {
  description = "OpenSearch EBS volume size in GB"
  type        = number
  default     = 20
}

variable "opensearch_engine_version" {
  description = "OpenSearch engine version"
  type        = string
  default     = "OpenSearch_2.19"
}

variable "opensearch_master_user_name" {
  description = "OpenSearch master user name"
  type        = string
  default     = "admin"
}

variable "opensearch_master_user_password" {
  description = "OpenSearch master user password"
  type        = string
  default     = "DifyOpenSearchPass123!"
  sensitive   = true

  validation {
    condition = (
      length(var.opensearch_master_user_password) >= 8 &&
      can(regex("^[^/@\"' ]*$", var.opensearch_master_user_password))
    )
    error_message = "opensearch_master_user_password must be at least 8 characters and cannot contain /, @, \", ', or spaces."
  }

}

# Storage Configuration
variable "s3_versioning_enabled" {
  description = "Enable S3 versioning"
  type        = bool
  default     = true
}

# ECR Configuration

variable "ecr_image_tag_mutability" {
  description = "ECR image tag mutability"
  type        = string
  default     = "MUTABLE"
}

# ──────────────── Autoscaling Configuration ────────────────

# ──────────────── Metrics Server ────────────────
variable "install_metrics_server" {
  description = "Install Metrics Server for HPA support. Required if enable_hpa = true."
  type        = bool
  default     = false
}

variable "metrics_server_version" {
  description = "Metrics Server Helm chart version"
  type        = string
  default     = "3.12.0"
}

variable "metrics_server_chart_repo" {
  description = "Metrics Server Helm repository URL (override for AWS China region)"
  type        = string
  default     = "https://kubernetes-sigs.github.io/metrics-server/"
}

variable "metrics_server_image_registry" {
  description = "Metrics Server image registry (override for AWS China region, e.g., registry.aliyuncs.com/google_containers)"
  type        = string
  default     = "registry.k8s.io"
}

variable "metrics_server_replicas" {
  description = "Number of Metrics Server replicas (2 recommended for production with PodDisruptionBudget)"
  type        = number
  default     = 2

  validation {
    condition     = var.metrics_server_replicas >= 1 && var.metrics_server_replicas <= 10
    error_message = "metrics_server_replicas must be between 1 and 10."
  }
}

# ──────────────── Cluster Autoscaler ────────────────
variable "install_cluster_autoscaler" {
  description = "Install Cluster Autoscaler for automatic node scaling. Requires node group max_size > min_size."
  type        = bool
  default     = false
}

variable "cluster_autoscaler_version" {
  description = "Cluster Autoscaler Helm chart version"
  type        = string
  default     = "9.35.0"
}

variable "cluster_autoscaler_image_tag" {
  description = "Cluster Autoscaler image tag (must match EKS cluster version, e.g., v1.28.5 for EKS 1.28)"
  type        = string
  default     = "v1.28.5"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.cluster_autoscaler_image_tag))
    error_message = "cluster_autoscaler_image_tag must be in format v1.28.5 (semantic version with 'v' prefix)."
  }
}

variable "cluster_autoscaler_chart_repo" {
  description = "Cluster Autoscaler Helm repository URL (override for AWS China region)"
  type        = string
  default     = "https://kubernetes.github.io/autoscaler"
}

variable "cluster_autoscaler_image_registry" {
  description = "Cluster Autoscaler image registry (override for AWS China region, e.g., registry.aliyuncs.com/google_containers)"
  type        = string
  default     = "registry.k8s.io"
}

variable "cluster_autoscaler_scale_down_delay" {
  description = "How long after scale up before considering scale down (e.g., '10m', '5m')"
  type        = string
  default     = "10m"

  validation {
    condition     = can(regex("^[0-9]+[mh]$", var.cluster_autoscaler_scale_down_delay))
    error_message = "cluster_autoscaler_scale_down_delay must be in format '10m' or '1h' (number + 'm' or 'h')."
  }
}

variable "cluster_autoscaler_scale_down_unneeded_time" {
  description = "How long a node should be unneeded before scale down (e.g., '10m', '5m')"
  type        = string
  default     = "10m"

  validation {
    condition     = can(regex("^[0-9]+[mh]$", var.cluster_autoscaler_scale_down_unneeded_time))
    error_message = "cluster_autoscaler_scale_down_unneeded_time must be in format '10m' or '1h' (number + 'm' or 'h')."
  }
}

# ──────────────── HPA Configuration ────────────────
variable "enable_hpa" {
  description = "Enable Horizontal Pod Autoscaler for Dify deployments. IMPORTANT: Requires install_metrics_server = true. Terraform cannot validate cross-variable dependencies, so ensure Metrics Server is enabled before enabling HPA."
  type        = bool
  default     = false
}

variable "hpa_config" {
  description = <<-EOT
    HPA configuration for each Dify deployment. Each entry configures autoscaling for a specific component.

    - enabled: Whether to create HPA for this component
    - deployment_name: Custom deployment name (optional, defaults to 'dify-{key}')
    - min_replicas: Minimum number of pod replicas
    - max_replicas: Maximum number of pod replicas
    - target_cpu_utilization: Target CPU utilization percentage (0-100)
    - target_memory_utilization: Target memory utilization percentage (0-100, optional)
    - scale_down_stabilization_window: Seconds to wait before scaling down (optional, default 300)
    - scale_up_stabilization_window: Seconds to wait before scaling up (optional, default 0)

    IMPORTANT: When HPA is enabled, you should set static replicas to 1 in Helm values.yaml
    and let HPA manage the actual replica count. HPA conflicts with static replica settings.

    IMPORTANT: HPA requires Deployments to have resource requests defined (cpu/memory).
    Without resource requests, HPA cannot calculate utilization and will not scale.

    CRITICAL: workerBeat must ALWAYS have enabled = false. It is a singleton service that
    manages Celery beat scheduling and MUST run exactly 1 replica. Running multiple replicas
    will cause duplicate task execution and data corruption. Keep it at 1 replica in Helm values.
  EOT

  type = map(object({
    enabled                         = bool
    deployment_name                 = optional(string, "")
    min_replicas                    = number
    max_replicas                    = number
    target_cpu_utilization          = number
    target_memory_utilization       = optional(number)
    scale_down_stabilization_window = optional(number, 300)
    scale_up_stabilization_window   = optional(number, 0)
  }))

  default = {
    api = {
      enabled                   = true
      min_replicas              = 2
      max_replicas              = 10
      target_cpu_utilization    = 70
      target_memory_utilization = 80
    }
    worker = {
      enabled                = true
      min_replicas           = 2
      max_replicas           = 20
      target_cpu_utilization = 70
    }
    workerBeat = {
      enabled                = false # CRITICAL: Must NEVER be enabled - singleton service
      deployment_name        = "dify-worker-beat"
      min_replicas           = 1
      max_replicas           = 1 # Must always be 1 - this is a singleton
      target_cpu_utilization = 70
    }
    web = {
      enabled                = true
      min_replicas           = 2
      max_replicas           = 8
      target_cpu_utilization = 70
    }
    sandbox = {
      enabled                = true
      min_replicas           = 1
      max_replicas           = 10
      target_cpu_utilization = 80
    }
    enterprise = {
      enabled                = false
      min_replicas           = 1
      max_replicas           = 4
      target_cpu_utilization = 70
    }
    gateway = {
      enabled                = false
      min_replicas           = 1
      max_replicas           = 4
      target_cpu_utilization = 70
    }
    plugin_daemon = {
      enabled                = false
      deployment_name        = "dify-plugin-daemon"
      min_replicas           = 1
      max_replicas           = 4
      target_cpu_utilization = 70
    }
    plugin_connector = {
      enabled                = false
      deployment_name        = "dify-plugin-connector"
      min_replicas           = 1
      max_replicas           = 4
      target_cpu_utilization = 70
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.hpa_config : v.min_replicas >= 1 && v.min_replicas <= v.max_replicas
    ])
    error_message = "For all HPA configs: min_replicas must be >= 1 and <= max_replicas."
  }

  validation {
    condition = alltrue([
      for k, v in var.hpa_config : v.target_cpu_utilization > 0 && v.target_cpu_utilization <= 100
    ])
    error_message = "For all HPA configs: target_cpu_utilization must be between 1 and 100."
  }

  validation {
    condition = alltrue([
      for k, v in var.hpa_config : v.target_memory_utilization == null ? true : (v.target_memory_utilization > 0 && v.target_memory_utilization <= 100)
    ])
    error_message = "For all HPA configs: target_memory_utilization (if set) must be between 1 and 100."
  }
}

# ──────────────── Plugin HPA Configuration (chart >= 3.10.0) ────────────────
variable "enable_plugin_hpa" {
  description = <<-EOT
    Enable Horizontal Pod Autoscaler for Dify plugin pods (DifyPlugin custom resources).

    Plugin pods are managed by dify-crd-controller through the DifyPlugin CRD
    (enterprise.dify.ai/v1), not by a plain Deployment, so their HPAs target the
    DifyPlugin resource via the Kubernetes /scale subresource.

    REQUIREMENTS:
    - Dify EE Helm chart >= 3.10.0 (community appVersion 1.14.1, released 2026-05-27).
      This is the first chart whose DifyPlugin CRD ships the /scale subresource;
      3.9.x CRDs only have the status subresource (the change was reverted on the
      3.9 release branch). The capability is verified against the live CRD at plan
      time - a clear precondition error is raised if the cluster does not support it.
      For older charts use the CronJob workaround in cloud/aws/plugin-hpa/ instead.
    - install_metrics_server = true (Terraform cannot validate cross-variable
      dependencies; ensure Metrics Server is enabled).
    - Plugin pods must have CPU resource requests for utilization-based scaling.

    DISCOVERY & DRIFT: DifyPlugin resources are auto-discovered from the cluster at
    plan time. Plugins installed via the Enterprise console AFTER the last
    `terraform apply` are NOT covered until the next apply - re-run `terraform apply`
    after installing new plugins.
  EOT
  type        = bool
  default     = false
}

variable "plugin_hpa_defaults" {
  description = "Default HPA settings applied to every auto-discovered DifyPlugin resource. Override per plugin via plugin_hpa_overrides."

  type = object({
    min_replicas                    = optional(number, 1)
    max_replicas                    = optional(number, 4)
    target_cpu_utilization          = optional(number, 70)
    target_memory_utilization       = optional(number)
    scale_down_stabilization_window = optional(number, 300)
    scale_up_stabilization_window   = optional(number, 0)
  })

  default = {}

  validation {
    condition     = var.plugin_hpa_defaults.min_replicas >= 1 && var.plugin_hpa_defaults.min_replicas <= var.plugin_hpa_defaults.max_replicas
    error_message = "plugin_hpa_defaults: min_replicas must be >= 1 and <= max_replicas."
  }

  validation {
    condition     = var.plugin_hpa_defaults.target_cpu_utilization > 0 && var.plugin_hpa_defaults.target_cpu_utilization <= 100
    error_message = "plugin_hpa_defaults: target_cpu_utilization must be between 1 and 100."
  }

  validation {
    condition     = var.plugin_hpa_defaults.target_memory_utilization == null ? true : (var.plugin_hpa_defaults.target_memory_utilization > 0 && var.plugin_hpa_defaults.target_memory_utilization <= 100)
    error_message = "plugin_hpa_defaults: target_memory_utilization (if set) must be between 1 and 100."
  }
}

variable "plugin_hpa_overrides" {
  description = <<-EOT
    Per-plugin overrides for plugin HPA, keyed by DifyPlugin resource name
    (kubectl get difyplugins.enterprise.dify.ai -n dify). Only set the fields you
    want to change; unset fields fall back to plugin_hpa_defaults.
    Set enabled = false to exclude a discovered plugin from autoscaling.
  EOT

  type = map(object({
    enabled                         = optional(bool, true)
    min_replicas                    = optional(number)
    max_replicas                    = optional(number)
    target_cpu_utilization          = optional(number)
    target_memory_utilization       = optional(number)
    scale_down_stabilization_window = optional(number)
    scale_up_stabilization_window   = optional(number)
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.plugin_hpa_overrides : v.min_replicas == null ? true : v.min_replicas >= 1
    ])
    error_message = "plugin_hpa_overrides: min_replicas (if set) must be >= 1."
  }

  validation {
    condition = alltrue([
      for k, v in var.plugin_hpa_overrides : v.target_cpu_utilization == null ? true : (v.target_cpu_utilization > 0 && v.target_cpu_utilization <= 100)
    ])
    error_message = "plugin_hpa_overrides: target_cpu_utilization (if set) must be between 1 and 100."
  }

  validation {
    condition = alltrue([
      for k, v in var.plugin_hpa_overrides : v.target_memory_utilization == null ? true : (v.target_memory_utilization > 0 && v.target_memory_utilization <= 100)
    ])
    error_message = "plugin_hpa_overrides: target_memory_utilization (if set) must be between 1 and 100."
  }
}