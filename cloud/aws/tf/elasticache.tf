locals {
  # Use new simplified subnet variables with backward compatibility
  # Priority: existing_vpc_subnets > old variables > terraform created subnets
  redis_subnets = (
    length(var.existing_vpc_subnets.private) > 0 ? var.existing_vpc_subnets.private :
    length(var.redis_subnets) > 0 ? var.redis_subnets :
    (local.create_vpc ? aws_subnet.private[*].id : [])
  )

  # Environment-specific Redis configuration
  redis_config = var.environment == "test" ? {
    num_cache_clusters         = 1                 # Single node mode
    automatic_failover_enabled = false             # Disable automatic failover
    multi_az_enabled           = false             # Disable Multi-AZ
    node_type                  = "cache.t4g.micro" # Small instance type
    } : {
    num_cache_clusters         = 2                   # Primary-replica mode
    automatic_failover_enabled = true                # Enable automatic failover
    multi_az_enabled           = true                # Enable Multi-AZ
    node_type                  = var.redis_node_type # Use configured instance type
  }
}

# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "main" {
  name       = "dify-${var.deployment_id}-redis-subnet-group"
  subnet_ids = local.redis_subnets

  tags = {
    Name        = "dify-${var.deployment_id}-redis-subnet-group"
    Environment = var.environment
  }
}

# ElastiCache Security Group
resource "aws_security_group" "redis" {
  name_prefix = "dify-${var.deployment_id}-redis"
  description = "Security group for dify-${var.deployment_id} ElastiCache Redis"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Redis traffic from EKS worker nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  # tfsec:ignore:aws-ec2-no-public-egress-sgr -- ElastiCache nodes need outbound for AWS API calls (snapshot to S3, KMS, CW logs) routed via NAT
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "dify-${var.deployment_id}-redis-sg"
    Environment = var.environment
  }
}

# ElastiCache Parameter Group
resource "aws_elasticache_parameter_group" "redis" {
  name   = "dify-${var.deployment_id}-redis-params"
  family = "redis7" # Valid parameter group family for Redis 7.x
}

# ElastiCache Redis Replication Group (Cluster Mode Disabled)
# Auto-configure based on environment: test=single node, prod=primary-replica
resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "dify-${var.deployment_id}-redis"
  description          = "Redis ${var.environment} environment for dify-${var.deployment_id}"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = local.redis_config.node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis.name

  # Configure number of nodes based on environment
  num_cache_clusters = local.redis_config.num_cache_clusters

  # Explicitly disable cluster mode
  num_node_groups         = null
  replicas_per_node_group = null

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  # Encryption at rest and in transit. Clients must connect via TLS (rediss://), so the
  # generated Helm values set externalRedis.useSSL: true. Toggling these on an existing
  # replication group forces recreation — schedule a maintenance window.
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # Configure high availability features based on environment
  automatic_failover_enabled = local.redis_config.automatic_failover_enabled
  multi_az_enabled           = local.redis_config.multi_az_enabled

  # Backup configuration
  snapshot_retention_limit = var.environment == "test" ? 0 : 3
  snapshot_window          = "03:00-05:00"
  maintenance_window       = "sun:05:00-sun:07:00"

  tags = {
    Name        = "dify-${var.deployment_id}-redis"
    Environment = var.environment
    Mode        = var.environment == "test" ? "single-node" : "primary-replica"
  }
}
