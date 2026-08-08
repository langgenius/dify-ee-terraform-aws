locals {
  create_vpc = !var.use_existing_vpc
  vpc_id     = local.create_vpc ? aws_vpc.main[0].id : var.vpc_id

  # Regional NAT Gateway is not available in the AWS China partition, so fall back to zonal there.
  nat_availability_mode = local.aws_is_cn_region ? "zonal" : var.nat_availability_mode
  create_zonal_nat      = local.create_vpc && local.nat_availability_mode == "zonal"
  create_regional_nat   = local.create_vpc && local.nat_availability_mode == "regional"

  # Automatically fetch the first 3 available zones from the current region
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)

  # Determine actual private and public subnets to use
  # Priority: existing_vpc_subnets > old variables (for backward compatibility) > terraform created subnets
  actual_private_subnets = (
    length(var.existing_vpc_subnets.private) > 0 ? var.existing_vpc_subnets.private :
    length(var.private_subnet_ids) > 0 ? var.private_subnet_ids :
    local.create_vpc ? aws_subnet.private[*].id : []
  )

  actual_public_subnets = (
    length(var.existing_vpc_subnets.public) > 0 ? var.existing_vpc_subnets.public :
    length(var.public_subnet_ids) > 0 ? var.public_subnet_ids :
    local.create_vpc ? aws_subnet.public[*].id : []
  )
}

# VPC (only created if use_existing_vpc is false)
# tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs -- VPC Flow Logs not provisioned here; enable via central logging stack if required
resource "aws_vpc" "main" {
  count                = local.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "dify-${var.deployment_id}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = {
    Name        = "dify-${var.deployment_id}-igw"
    Environment = var.environment
  }
}

# Public Subnets
# Hosts the internet-facing ALB and NAT gateway; neither relies on map_public_ip_on_launch,
# so keep it off to avoid auto-assigning public IPs to any EC2 placed here.
resource "aws_subnet" "public" {
  count                   = local.create_vpc ? length(local.availability_zones) : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                     = "dify-${var.deployment_id}-public-${count.index + 1}"
    Environment              = var.environment
    "kubernetes.io/role/elb" = "1"
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  count             = local.create_vpc ? length(local.availability_zones) : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.availability_zones[count.index]

  tags = {
    Name                              = "dify-${var.deployment_id}-private-${count.index + 1}"
    Environment                       = var.environment
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# NAT Gateway
# Two availability modes, selected by var.nat_availability_mode:
#   - zonal    (default): one NAT Gateway in the first public subnet, shared by all private subnets.
#                         Cheapest, but outbound traffic is a single-AZ SPOF.
#   - regional          : one Regional NAT Gateway that AWS spreads across AZs automatically,
#                         following workload ENIs. No public subnet or EIP to manage.
resource "aws_eip" "nat" {
  count  = local.create_zonal_nat ? 1 : 0
  domain = "vpc"

  tags = {
    Name        = "dify-${var.deployment_id}-nat-eip"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "main" {
  count         = local.create_zonal_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id # Use the first public subnet

  tags = {
    Name        = "dify-${var.deployment_id}-nat"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

# Regional NAT Gateway (automatic mode: AWS manages zonal expansion and the EIPs)
resource "aws_nat_gateway" "regional" {
  count             = local.create_regional_nat ? 1 : 0
  vpc_id            = aws_vpc.main[0].id
  availability_mode = "regional"

  tags = {
    Name        = "dify-${var.deployment_id}-nat-regional"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

locals {
  # Single NAT Gateway ID regardless of availability mode; null when using an existing VPC.
  nat_gateway_id = (
    local.create_regional_nat ? aws_nat_gateway.regional[0].id :
    local.create_zonal_nat ? aws_nat_gateway.main[0].id :
    null
  )
}

# Route Tables
resource "aws_route_table" "public" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = {
    Name        = "dify-${var.deployment_id}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table" "private" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  # Both modes expose a single NAT Gateway ID, so the route wiring is identical.
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = local.nat_gateway_id
  }

  tags = {
    Name        = "dify-${var.deployment_id}-private-rt"
    Environment = var.environment
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = local.create_vpc ? length(local.availability_zones) : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  count          = local.create_vpc ? length(local.availability_zones) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id # All private subnets use the same route table
}

# ──────────────── Tags for Existing VPC Resources ────────────────
# When using an existing VPC, we need to add Kubernetes cluster tags to VPC and subnets
# These tags are required for AWS Load Balancer Controller and EKS to work properly
# Set auto_tag_subnets = false to skip automatic tagging if subnets are pre-tagged or you lack permissions

# Tag existing VPC with cluster information (only if using existing VPC and auto_tag_subnets is enabled)
resource "aws_ec2_tag" "existing_vpc_cluster_tag" {
  count       = !local.create_vpc && var.vpc_id != "" && var.auto_tag_subnets ? 1 : 0
  resource_id = var.vpc_id
  key         = "kubernetes.io/cluster/${local.cluster_name}"
  value       = "shared"

  depends_on = [aws_eks_cluster.main]
}

# Tag existing public subnets with cluster and ELB role tags
resource "aws_ec2_tag" "existing_public_subnet_cluster_tags" {
  count       = !local.create_vpc && var.auto_tag_subnets ? length(local.actual_public_subnets) : 0
  resource_id = local.actual_public_subnets[count.index]
  key         = "kubernetes.io/cluster/${local.cluster_name}"
  value       = "shared"

  depends_on = [aws_eks_cluster.main]
}

resource "aws_ec2_tag" "existing_public_subnet_elb_tags" {
  count       = !local.create_vpc && var.auto_tag_subnets ? length(local.actual_public_subnets) : 0
  resource_id = local.actual_public_subnets[count.index]
  key         = "kubernetes.io/role/elb"
  value       = "1"

  depends_on = [aws_eks_cluster.main]
}

# Tag existing private subnets with cluster and internal-ELB role tags
resource "aws_ec2_tag" "existing_private_subnet_cluster_tags" {
  count       = !local.create_vpc && var.auto_tag_subnets ? length(local.actual_private_subnets) : 0
  resource_id = local.actual_private_subnets[count.index]
  key         = "kubernetes.io/cluster/${local.cluster_name}"
  value       = "shared"

  depends_on = [aws_eks_cluster.main]
}

resource "aws_ec2_tag" "existing_private_subnet_internal_elb_tags" {
  count       = !local.create_vpc && var.auto_tag_subnets ? length(local.actual_private_subnets) : 0
  resource_id = local.actual_private_subnets[count.index]
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"

  depends_on = [aws_eks_cluster.main]
}