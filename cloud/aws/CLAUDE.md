# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Terraform infrastructure-as-code for deploying **Dify Enterprise Edition** on AWS. It provisions a complete EKS-based production environment including networking, compute, databases, storage, and Kubernetes components. The deployment supports both AWS standard regions and AWS China regions.

## Common Commands

### Terraform Operations

All Terraform commands should be run from the `tf/` directory:

```bash
cd tf/

# Initialize Terraform
terraform init

# Plan changes (recommended to save plan to file)
terraform plan -out=tfplan

# Apply changes (using saved plan)
terraform apply tfplan

# Apply directly (not recommended for production)
terraform apply -auto-approve

# Destroy infrastructure
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan

# Check current state
terraform show

# Refresh state
terraform refresh

# View outputs
terraform output
```

### Deployment Workflow Scripts

Execute these scripts in order from the `cloud/aws/` directory:

```bash
# 1. Check AWS permissions before deployment
bash scripts/1_check_aws_permissions.sh

# 2. Verify Terraform deployment status
bash scripts/2_verify_tf_deployment.sh

# 3. Generate post-deployment configuration
bash scripts/3_post_tf_apply.sh

# 4. Generate Dify Helm values file
bash scripts/4_generate_dify_helm.sh

# 5. Create databases (China region only - RDS Data API not supported)
bash scripts/5_create_databases.sh
```

### Helm Operations

```bash
# Add Dify Helm repository
helm repo add dify https://langgenius.github.io/dify-helm
helm repo update

# Search available versions
helm search repo dify/dify

# Install Dify (after generating values.yaml)
helm upgrade -i dify -f values.yaml dify/dify -n dify

# Update existing deployment
helm upgrade dify -f values.yaml dify/dify -n dify
```

### AWS/Kubernetes Operations

```bash
# Configure kubectl for EKS
aws eks update-kubeconfig --region <region> --name <cluster-name>

# Test cluster connectivity
kubectl get nodes

# Check AWS credentials
aws sts get-caller-identity

# Verify EKS cluster
aws eks describe-cluster --name <cluster-name>
```

## Architecture

### High-Level Design

The infrastructure consists of several layers:

1. **Networking Layer**: VPC with public/private subnets across 3 AZs (auto-detected), NAT Gateway, Internet Gateway
2. **Compute Layer**: EKS cluster with managed node groups (supports both amd64 and arm64 architectures)
3. **Data Layer**: Aurora PostgreSQL Serverless v2, ElastiCache Redis, OpenSearch
4. **Storage Layer**: S3 buckets for object storage, ECR repositories for container images
5. **Security Layer**: IRSA (IAM Roles for Service Accounts), Security Groups, OIDC provider

### Key Components

- **EKS Cluster**: Kubernetes 1.28+ with managed node groups
- **Database Services**:
  - Aurora PostgreSQL Serverless v2 with 4 databases: `dify` (main), `enterprise`, `audit`, `dify_plugin_daemon`
  - ElastiCache Redis (cluster mode disabled, single-node for test, master-replica for prod)
  - OpenSearch for vector search
- **IRSA Roles**: Three specialized roles for different service accounts:
  - `dify-api`: S3-only access
  - `dify-plugin-crd`: S3 + ECR push/pull access
  - `dify-plugin-runner`: ECR pull-only access
- **Kubernetes Components**:
  - AWS Load Balancer Controller (manages ALB/NLB)
  - Optional: NGINX Ingress Controller + Cert-Manager

### File Structure

```
tf/
├── variables.tf         # All input variables with validation
├── locals.global.tf     # Global locals (AWS partition, DNS suffix)
├── providers.tf         # AWS, Kubernetes, Helm providers
├── vpc.tf              # VPC, subnets, NAT/IGW, route tables
├── eks.tf              # EKS cluster, node groups, IAM roles
├── irsa.tf             # OIDC provider, IRSA roles and policies
├── kubernetes.tf       # Kubernetes service accounts
├── helm.tf             # Helm chart deployments
├── rds.tf              # Aurora PostgreSQL cluster
├── elasticache.tf      # Redis replication group
├── opensearch.tf       # OpenSearch domain
├── s3.tf               # S3 buckets
├── ecr.tf              # ECR repositories
├── outputs.tf          # All output values
└── terraform.tfvars    # User configuration (not in git)

scripts/
├── 1_check_aws_permissions.sh      # Verify IAM permissions
├── 2_verify_tf_deployment.sh       # Post-deployment validation
├── 3_post_tf_apply.sh              # Generate config files
├── 4_generate_dify_helm.sh         # Generate Helm values
├── 5_create_databases.sh           # Manual DB creation (China only)
└── helm_templates/                 # Helm value templates
```

## Important Configuration Details

### Deployment Identifier

The `deployment_id` variable (3-15 chars, lowercase alphanumeric + hyphens) creates unique resource names:
- EKS cluster: `dify-{deployment_id}-eks-cluster`
- S3 bucket: `dify-{deployment_id}-storage-{account_id}`
- IAM roles: `dify-{deployment_id}-*-role`

This allows multiple deployments in the same AWS account.

### VPC Configuration

Two modes supported:

1. **Create New VPC** (default):
   ```hcl
   use_existing_vpc = false
   vpc_cidr = "10.0.0.0/16"
   ```

2. **Use Existing VPC**:
   ```hcl
   use_existing_vpc = true
   vpc_id = "vpc-xxxxx"
   existing_vpc_subnets = {
     private = ["subnet-xxx", "subnet-yyy"]  # Min 2, different AZs
     public  = ["subnet-aaa", "subnet-bbb"]  # Required if elb_mode = "internet-facing"
   }
   auto_tag_subnets = true  # Auto-tag subnets with Kubernetes tags
   ```

**Critical**: When using existing VPC with `auto_tag_subnets = false`, manually add these tags:
- VPC: `kubernetes.io/cluster/dify-{deployment_id}-eks-cluster = shared`
- Private subnets: `kubernetes.io/role/internal-elb = 1`
- Public subnets: `kubernetes.io/role/elb = 1`

### ELB Exposure Mode

- `elb_mode = "internet-facing"`: Public internet access (requires public subnets)
- `elb_mode = "internal"`: VPC-internal only (private access)

EKS endpoint access is automatically configured based on `elb_mode`.

### Environment-Specific Scaling

Node configuration automatically selects based on `environment` and `eks_arch`:

**Test Environment**:
- amd64: 1-2 nodes of m7a.xlarge (4 vCPU, 16GB RAM)
- arm64: 1-2 nodes of m7g.xlarge (4 vCPU, 16GB RAM)
- Redis: Single node (cache.t4g.micro), no failover

**Production Environment**:
- amd64: 6-10 nodes of m7a.2xlarge (8 vCPU, 32GB RAM)
- arm64: 6-10 nodes of m7g.2xlarge (8 vCPU, 32GB RAM)
- Redis: Master-replica, automatic failover, Multi-AZ

### AWS China Region Specifics

1. **Instance Types**: Use m6i/m6a (amd64) or m6g (arm64) instead of m7 series
2. **Image Registry**: Must configure China region image mirrors in Helm values
3. **RDS Data API**: Not supported - use `scripts/5_create_databases.sh` to manually create databases
4. **DNS Suffix**: Automatically uses `amazonaws.com.cn` via `locals.global.tf`
5. **Helm Repo**: Set `aws_eks_chart_repo_url` for AWS Load Balancer Controller

### IRSA (IAM Roles for Service Accounts)

The infrastructure creates three specialized IRSA roles:

1. **dify-ee-s3-role** → Used by:
   - `dify-api` ServiceAccount (primary user)
   - `dify-plugin-connector` ServiceAccount
   - Permissions: S3 full access to Dify bucket

2. **dify-ee-s3-ecr-role** → Used by:
   - `dify-plugin-crd` ServiceAccount
   - `dify-plugin-build` ServiceAccount (compatibility alias)
   - Permissions: S3 full access + ECR push/pull

3. **dify-ee-ecr-pull-role** → Used by:
   - `dify-plugin-runner` ServiceAccount
   - `dify-plugin-build-run` ServiceAccount (compatibility alias)
   - Permissions: ECR pull-only

All service accounts are created by Terraform in the `dify` namespace. **Important**: If you need to reinstall Dify, run Terraform first to recreate service accounts, then Helm. Do NOT just `helm uninstall` and reinstall - this causes SA configuration drift.

### Database Configuration

Four databases are created in Aurora PostgreSQL:
- `dify` - Main application database
- `enterprise` - Enterprise features
- `audit` - Audit logging
- `dify_plugin_daemon` - Plugin management

**Important**: Database names must match exactly what Helm values expect. Do not change these without updating corresponding Helm configurations.

### Generated Files

Scripts generate files in the `secret/` directory (gitignored):
- `config_*.env` - Environment variables
- `dify_deployment_config_*.txt` - Deployment summary
- `deployment_verification_*.txt` - Validation report
- `helm_values_*/` - Generated Helm values files
- `out_*.log` - Script execution logs

All generated files have 600 permissions for security.

## Modifying Infrastructure

### Adding New Variables

1. Add to `variables.tf` with validation rules
2. Add to `terraform.tfvars.example` with documentation
3. Update relevant resource files (eks.tf, rds.tf, etc.)
4. Add to `outputs.tf` if needed by scripts
5. Update this CLAUDE.md

### Architecture Patterns

- **Locals**: Use `locals.global.tf` for cross-file shared values (AWS partition, DNS suffix)
- **Resource Naming**: Follow pattern `dify-{deployment_id}-{resource-type}`
- **Tagging**: Always include `Environment` and `Name` tags
- **Conditionals**: Check `local.create_vpc` for VPC resource creation
- **Regions**: Use `local.aws_partition` and `local.dns_suffix` for region-agnostic ARNs

### AWS China Compatibility

When adding AWS resources, ensure:
- ARNs use `local.aws_partition` (resolves to `aws` or `aws-cn`)
- Service endpoints use `local.dns_suffix` (resolves to `amazonaws.com` or `amazonaws.com.cn`)
- EKS service principal uses `eks.amazonaws.com` (same in all regions)
- EC2 service principal uses `ec2.${local.dns_suffix}`

## Troubleshooting

### Common Issues

**Terraform State**: State is stored locally by default. For production, configure S3 backend with DynamoDB locking (see README TODO section).

**Service Account Drift**: If plugins fail to install after reinstalling Dify, the service accounts are out of sync. Run `terraform apply` first to recreate SAs, then reinstall Helm.

**VPC Subnet Tags**: If ALB is not provisioning correctly, check that subnets have proper Kubernetes tags. Enable `auto_tag_subnets = true` or add tags manually.

**China Region Images**: After running `4_generate_dify_helm.sh`, manually edit connector image configuration in `secret/values.yaml` to use China region mirrors. See README for examples.

### Validation

Use the verification script to check resource status:
```bash
bash scripts/2_verify_tf_deployment.sh
```

This generates a report in `secret/deployment_verification_*.txt` with:
- EKS cluster status
- Node group health
- Database connectivity
- Security group rules
- Service account annotations
