locals {
  # Use new simplified subnet variables with backward compatibility
  # Priority: existing_vpc_subnets > old variables > terraform created subnets
  rds_subnets = (
    length(var.existing_vpc_subnets.private) > 0 ? var.existing_vpc_subnets.private :
    length(var.rds_subnets) > 0 ? var.rds_subnets :
    (local.create_vpc ? aws_subnet.private[*].id : [])
  )
}

# RDS Subnet Group (can be used for Aurora)
# RDS credential storage (Secrets Manager)
# tfsec:ignore:aws-ssm-secret-use-customer-key -- using AWS-managed KMS key for Secrets Manager; CMK rollout tracked separately
resource "aws_secretsmanager_secret" "rds_credentials" {
  name                    = "dify-${var.deployment_id}-rds-credentials"
  description             = "RDS Aurora cluster credentials for Dify"
  recovery_window_in_days = 0 # Force immediate deletion without recovery window

  tags = {
    Name        = "dify-${var.deployment_id}-rds-credentials"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = "postgres"
    password = var.db_master_password
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "dify-${var.deployment_id}-db-subnet-group"
  subnet_ids = local.rds_subnets

  tags = {
    Name        = "dify-${var.deployment_id}-db-subnet-group"
    Environment = var.environment
  }
}

# RDS Security Group (can be used for Aurora)
resource "aws_security_group" "rds" {
  name_prefix = "dify-${var.deployment_id}-rds-"
  description = "Security group for dify-${var.deployment_id} Aurora PostgreSQL cluster"
  vpc_id      = local.vpc_id

  ingress {
    description     = "PostgreSQL traffic from EKS worker nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  # tfsec:ignore:aws-ec2-no-public-egress-sgr -- RDS managed network needs egress for AWS service calls; default 0.0.0.0/0 retained for parity with provider defaults (lifecycle ignore_changes set below)
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Prevent Terraform from trying to revoke default egress rule
  lifecycle {
    ignore_changes = [
      egress,
    ]
  }

  tags = {
    Name        = "dify-${var.deployment_id}-rds-sg"
    Environment = var.environment
  }
}

# Aurora Serverless v2 Cluster
# tfsec:ignore:aws-rds-encrypt-cluster-storage-data -- using default AWS-managed KMS key; CMK migration tracked separately
resource "aws_rds_cluster" "main" {
  cluster_identifier     = "dify-${var.deployment_id}-aurora-postgres"
  engine                 = "aurora-postgresql"
  engine_mode            = "provisioned" # For Serverless v2, use provisioned mode
  engine_version         = var.db_engine_version
  database_name          = var.db_main_database_name
  master_username        = "postgres"
  master_password        = var.db_master_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot          = true
  backup_retention_period      = var.db_backup_retention_period
  preferred_backup_window      = var.db_backup_window
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  # Enable storage encryption
  storage_encrypted = true

  # Enable Data API to support database operations without network
  # Note: Data API is not available in AWS China regions (cn-north-1, cn-northwest-1)
  enable_http_endpoint = local.aws_is_cn_region ? false : true

  # Enable Serverless v2
  serverlessv2_scaling_configuration {
    min_capacity = var.db_min_capacity
    max_capacity = var.db_max_capacity
  }

  tags = {
    Name        = "dify-${var.deployment_id}-aurora-postgres"
    Environment = var.environment
  }
}

# Aurora Serverless v2 instance
# Note: Serverless v2 still requires creating instances, but instance type must be "db.serverless"
# tfsec:ignore:aws-rds-enable-performance-insights-encryption -- Performance Insights uses default AWS-managed key; CMK migration tracked separately
resource "aws_rds_cluster_instance" "main" {
  count              = var.environment == "test" ? 1 : 2 # 1 for test environment, 2 for production environment
  identifier         = "dify-${var.deployment_id}-aurora-instance-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless" # Serverless v2 must use this instance type
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  performance_insights_enabled = var.environment == "prod" ? true : false

  tags = {
    Name        = "dify-${var.deployment_id}-aurora-instance-${count.index + 1}"
    Environment = var.environment
  }
}

# ──────────────── Database Initialization ────────────────
# Create additional databases required by Dify Enterprise
# These databases must be created at the Aurora cluster level
# as Helm charts cannot create databases on external PostgreSQL instances

# Database creation is handled by the null_resource below using RDS Data API

# Use local-exec to create the additional databases via RDS Data API
# Note: This resource is only created in non-China regions where Data API is available
resource "null_resource" "create_additional_databases" {
  count = local.aws_is_cn_region ? 0 : 1

  depends_on = [aws_rds_cluster_instance.main, aws_secretsmanager_secret_version.rds_credentials]

  provisioner "local-exec" {
    command = "bash ${path.module}/create_dify_databases_dataapi.sh"

    environment = {
      CLUSTER_ARN           = aws_rds_cluster.main.arn
      SECRET_ARN            = aws_secretsmanager_secret.rds_credentials.arn
      AWS_REGION            = var.aws_region
      DB_ENTERPRISE_NAME    = var.db_enterprise_database_name
      DB_AUDIT_NAME         = var.db_audit_database_name
      DB_PLUGIN_DAEMON_NAME = var.db_plugin_daemon_database_name
    }
  }

  # Trigger recreation if cluster, secret, or database names change
  triggers = {
    cluster_arn           = aws_rds_cluster.main.arn
    secret_arn            = aws_secretsmanager_secret.rds_credentials.arn
    script_hash           = filemd5("${path.module}/create_dify_databases_dataapi.sh")
    enterprise_db_name    = var.db_enterprise_database_name
    audit_db_name         = var.db_audit_database_name
    plugin_daemon_db_name = var.db_plugin_daemon_database_name
  }
}



# Output Aurora cluster endpoint
output "aurora_cluster_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.main.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "aurora_instance_count" {
  description = "Aurora instance count"
  value       = length(aws_rds_cluster_instance.main)
}

output "aurora_instance_ids" {
  description = "Aurora instance ID list"
  value       = aws_rds_cluster_instance.main[*].id
}

output "rds_credentials_secret_arn" {
  description = "RDS credentials Secrets Manager ARN"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "rds_cluster_arn" {
  description = "Aurora cluster ARN (for Data API)"
  value       = aws_rds_cluster.main.arn
}

output "additional_databases_info" {
  description = "Additional databases information"
  value = {
    plugin_daemon = {
      database_name = var.db_plugin_daemon_database_name
      host          = aws_rds_cluster.main.endpoint
      port          = 5432
      username      = "postgres"
    }
    enterprise = {
      database_name = var.db_enterprise_database_name
      host          = aws_rds_cluster.main.endpoint
      port          = 5432
      username      = "postgres"
    }
    audit = {
      database_name = var.db_audit_database_name
      host          = aws_rds_cluster.main.endpoint
      port          = 5432
      username      = "postgres"
    }
  }
}
