#!/bin/bash

# Automatically generate configuration required for Dify deployment

set -e

# Color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check Terraform state
check_terraform_state() {
    # Determine the terraform directory
    TERRAFORM_DIR=""
    if [ -f "terraform.tfstate" ]; then
        TERRAFORM_DIR="."
    elif [ -f "../tf/terraform.tfstate" ]; then
        TERRAFORM_DIR="../tf"
    elif [ -f "./tf/terraform.tfstate" ]; then
        TERRAFORM_DIR="./tf"
    else
        log_error "terraform.tfstate file not found. Please ensure you're running this script from:"
        log_error "  - The terraform directory (cloud/aws/tf/), or"
        log_error "  - The scripts directory (cloud/aws/scripts/), or"
        log_error "  - The aws directory (cloud/aws/)"
        exit 1
    fi
    
    log_info "Found Terraform state in: $TERRAFORM_DIR"
    
    # Check if Terraform state has any errors
    if ! (cd "$TERRAFORM_DIR" && terraform show &>/dev/null); then
        log_error "Terraform state file is corrupted or invalid"
        exit 1
    fi
    
    log_success "Terraform state file validation passed"
}

# Get all Terraform outputs
get_terraform_outputs() {
    log_info "Getting Terraform output information..."
    
    # Basic information
    ENVIRONMENT=$(cd "$TERRAFORM_DIR" && terraform output -raw environment 2>/dev/null || echo "unknown")
    DEPLOYMENT_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw deployment_id 2>/dev/null || echo "unknown")
    AWS_REGION=$(cd "$TERRAFORM_DIR" && terraform output -raw aws_region 2>/dev/null || echo "unknown")
    AWS_ACCOUNT_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw aws_account_id 2>/dev/null || echo "unknown")
    ELB_MODE=$(cd "$TERRAFORM_DIR" && terraform output -raw elb_mode 2>/dev/null || echo "internet-facing")
    
    # EKS information
    CLUSTER_NAME=$(cd "$TERRAFORM_DIR" && terraform output -raw eks_cluster_name 2>/dev/null || echo "")
    CLUSTER_ENDPOINT=$(cd "$TERRAFORM_DIR" && terraform output -raw eks_cluster_endpoint 2>/dev/null || echo "")
    CLUSTER_SECURITY_GROUP_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw eks_cluster_security_group_id 2>/dev/null || echo "")
    
    # Storage information
    S3_BUCKET_NAME=$(cd "$TERRAFORM_DIR" && terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    S3_BUCKET_ARN=$(cd "$TERRAFORM_DIR" && terraform output -raw s3_bucket_arn 2>/dev/null || echo "")
    S3_IAM_ROLE_ARN=$(cd "$TERRAFORM_DIR" && terraform output -raw s3_iam_role_arn 2>/dev/null || echo "")
    
    # ECR information
    ECR_REPOSITORY_URL=$(cd "$TERRAFORM_DIR" && terraform output -raw ecr_repository_url 2>/dev/null || echo "")
    ECR_EE_PLUGIN_REPOSITORY_URL=$(cd "$TERRAFORM_DIR" && terraform output -raw ecr_ee_plugin_repository_url 2>/dev/null || echo "")
    ECR_EE_PLUGIN_REPOSITORY_NAME=$(cd "$TERRAFORM_DIR" && terraform output -raw ecr_ee_plugin_repository_url 2>/dev/null || echo "")
    
    # Database information
    RDS_ENDPOINT=$(cd "$TERRAFORM_DIR" && terraform output -raw rds_endpoint 2>/dev/null || echo "")
    RDS_READER_ENDPOINT=$(cd "$TERRAFORM_DIR" && terraform output -raw rds_reader_endpoint 2>/dev/null || echo "")
    RDS_PORT=$(cd "$TERRAFORM_DIR" && terraform output -raw rds_port 2>/dev/null || echo "5432")
    RDS_DATABASE_NAME=$(cd "$TERRAFORM_DIR" && terraform output -raw rds_database_name 2>/dev/null || echo "dify")
    RDS_USERNAME=$(cd "$TERRAFORM_DIR" && terraform output -raw rds_username 2>/dev/null || echo "postgres")
    
    # Redis information
    REDIS_ENDPOINT=$(cd "$TERRAFORM_DIR" && terraform output -raw redis_endpoint 2>/dev/null || echo "")
    REDIS_PORT=$(cd "$TERRAFORM_DIR" && terraform output -raw redis_port 2>/dev/null || echo "6379")
    
    # OpenSearch information
    OPENSEARCH_ENDPOINT=$(cd "$TERRAFORM_DIR" && terraform output -raw opensearch_endpoint 2>/dev/null || echo "")
    OPENSEARCH_DASHBOARD_ENDPOINT=$(cd "$TERRAFORM_DIR" && terraform output -raw opensearch_dashboard_endpoint 2>/dev/null || echo "")
    
    # Network information
    VPC_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw vpc_id 2>/dev/null || echo "")
    PRIVATE_SUBNET_IDS=$(cd "$TERRAFORM_DIR" && terraform output -json private_subnet_ids 2>/dev/null | jq -r '.[]' | tr '\n' ',' | sed 's/,$//' || echo "")
    PUBLIC_SUBNET_IDS=$(cd "$TERRAFORM_DIR" && terraform output -json public_subnet_ids 2>/dev/null | jq -r '.[]' | tr '\n' ',' | sed 's/,$//' || echo "")
    
    # IRSA role information
    DIFY_EE_S3_ROLE_ARN=$(cd "$TERRAFORM_DIR" && terraform output -raw dify_ee_s3_role_arn 2>/dev/null || echo "")
    DIFY_EE_S3_ECR_ROLE_ARN=$(cd "$TERRAFORM_DIR" && terraform output -raw dify_ee_s3_ecr_role_arn 2>/dev/null || echo "")
    DIFY_EE_ECR_PULL_ROLE_ARN=$(cd "$TERRAFORM_DIR" && terraform output -raw dify_ee_ecr_pull_role_arn 2>/dev/null || echo "")

    # Application secrets (TF-generated, stable across applies)
    PASSWORD_ENCRYPTION_KEY=$(cd "$TERRAFORM_DIR" && terraform output -raw password_encryption_key 2>/dev/null || echo "")
    AGENT_BACKEND_SECRET_KEY=$(cd "$TERRAFORM_DIR" && terraform output -raw agent_backend_secret_key 2>/dev/null || echo "")
    APP_SECRET_KEY=$(cd "$TERRAFORM_DIR" && terraform output -raw app_secret_key 2>/dev/null || echo "")
    
    # ServiceAccount information
    SERVICE_ACCOUNTS_INFO=$(cd "$TERRAFORM_DIR" && terraform output -json dify_ee_service_accounts_info 2>/dev/null || echo "{}")
    
    # Helm deployment status
    HELM_RELEASES_STATUS=$(cd "$TERRAFORM_DIR" && terraform output -json helm_releases_status 2>/dev/null || echo "{}")
    
    log_success "Successfully retrieved all Terraform outputs"
}

# Extract database names (enterprise/audit/plugin_daemon)
get_database_names() {
    log_info "Extracting database names (enterprise/audit/plugin_daemon)..."

    # Try Terraform outputs first (additional_databases_info)
    local addl_json
    addl_json=$(cd "$TERRAFORM_DIR" && terraform output -json additional_databases_info 2>/dev/null || echo "")
    if [ -n "$addl_json" ] && echo "$addl_json" | jq -e . >/dev/null 2>&1; then
        DB_ENTERPRISE_NAME=$(echo "$addl_json" | jq -r '.enterprise.database_name // ""' 2>/dev/null)
        DB_AUDIT_NAME=$(echo "$addl_json" | jq -r '.audit.database_name // ""' 2>/dev/null)
        DB_PLUGIN_DAEMON_NAME=$(echo "$addl_json" | jq -r '.plugin_daemon.database_name // ""' 2>/dev/null)
        log_info "Loaded database names from Terraform outputs when available"
    fi

    # Fallback to terraform.tfvars if any is missing
    if [ -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        if [ -z "$DB_ENTERPRISE_NAME" ]; then
            DB_ENTERPRISE_NAME=$(grep "^db_enterprise_database_name" "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"\([^" ]*\)".*/\1/' | head -1 || echo "")
        fi
        if [ -z "$DB_AUDIT_NAME" ]; then
            DB_AUDIT_NAME=$(grep "^db_audit_database_name" "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"\([^" ]*\)".*/\1/' | head -1 || echo "")
        fi
        if [ -z "$DB_PLUGIN_DAEMON_NAME" ]; then
            DB_PLUGIN_DAEMON_NAME=$(grep "^db_plugin_daemon_database_name" "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"\([^" ]*\)".*/\1/' | head -1 || echo "")
        fi
        log_info "Loaded database names from terraform.tfvars when available"
    fi

    # Fallback to variables.tf defaults if still missing
    if [ -z "$DB_ENTERPRISE_NAME" ] || [ -z "$DB_AUDIT_NAME" ] || [ -z "$DB_PLUGIN_DAEMON_NAME" ]; then
        if [ -f "../tf/variables.tf" ]; then
            if [ -z "$DB_ENTERPRISE_NAME" ]; then
                DB_ENTERPRISE_NAME=$(grep -A3 'variable "db_enterprise_database_name"' ../tf/variables.tf | grep "default" | sed 's/.*= *"\([^" ]*\)".*/\1/' | head -1 || echo "")
            fi
            if [ -z "$DB_AUDIT_NAME" ]; then
                DB_AUDIT_NAME=$(grep -A3 'variable "db_audit_database_name"' ../tf/variables.tf | grep "default" | sed 's/.*= *"\([^" ]*\)".*/\1/' | head -1 || echo "")
            fi
            if [ -z "$DB_PLUGIN_DAEMON_NAME" ]; then
                DB_PLUGIN_DAEMON_NAME=$(grep -A3 'variable "db_plugin_daemon_database_name"' ../tf/variables.tf | grep "default" | sed 's/.*= *"\([^" ]*\)".*/\1/' | head -1 || echo "")
            fi
            log_info "Loaded database names from variables.tf defaults when available"
        fi
    fi

    # Final defaults
    DB_ENTERPRISE_NAME=${DB_ENTERPRISE_NAME:-enterprise}
    DB_AUDIT_NAME=${DB_AUDIT_NAME:-audit}
    DB_PLUGIN_DAEMON_NAME=${DB_PLUGIN_DAEMON_NAME:-dify_plugin_daemon}

    log_success "Database names resolved: enterprise=$DB_ENTERPRISE_NAME, audit=$DB_AUDIT_NAME, plugin_daemon=$DB_PLUGIN_DAEMON_NAME"
}

# Extract passwords from Terraform variables
get_database_passwords() {
    log_info "Extracting database password information..."
    
    # Try to get RDS password from Terraform variables first
    if [ -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        RDS_PASSWORD=$(grep "^db_master_password" "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"\([^"]*\)".*/\1/' | head -1 || echo "")
        if [ -z "$RDS_PASSWORD" ]; then
            # Fallback to default value from variables.tf
            RDS_PASSWORD=$(grep -A1 "variable \"db_master_password\"" ../tf/variables.tf | grep "default" | sed 's/.*= *"\([^"]*\)".*/\1/' || echo "")
            if [ -z "$RDS_PASSWORD" ]; then
                RDS_PASSWORD="DifyRdsPassword123!"  # Final fallback
                log_warning "Could not extract RDS password from terraform.tfvars or variables.tf, using fallback password"
            else
                log_info "Using RDS password from variables.tf default value"
            fi
        else
            log_info "Using RDS password from terraform.tfvars"
        fi
    else
        # Fallback to default value from variables.tf
        if [ -f "../tf/variables.tf" ]; then
            RDS_PASSWORD=$(grep -A1 "variable \"db_master_password\"" ../tf/variables.tf | grep "default" | sed 's/.*= *"\([^"]*\)".*/\1/' || echo "")
            if [ -z "$RDS_PASSWORD" ]; then
                RDS_PASSWORD="DifyRdsPassword123!"
                log_warning "Could not extract RDS password from variables.tf, using fallback password"
            else
                log_info "Using RDS password from variables.tf default value"
            fi
        else
            RDS_PASSWORD="DifyRdsPassword123!"
            log_warning "terraform.tfvars and variables.tf not found, using fallback password"
        fi
    fi
    
    # Try to get OpenSearch password from Terraform variables
    if [ -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        OPENSEARCH_PASSWORD=$(grep "^opensearch_master_user_password" "$TERRAFORM_DIR/terraform.tfvars" | sed 's/.*= *"\([^"]*\)".*/\1/' | head -1 || echo "")
        if [ -z "$OPENSEARCH_PASSWORD" ]; then
            # Fallback to default value from variables.tf
            OPENSEARCH_PASSWORD=$(grep -A1 "variable \"opensearch_master_user_password\"" ../tf/variables.tf | grep "default" | sed 's/.*= *"\([^"]*\)".*/\1/' || echo "")
            if [ -z "$OPENSEARCH_PASSWORD" ]; then
                OPENSEARCH_PASSWORD="DifyOpenSearchPass123!"  # Final fallback
                log_warning "Could not extract OpenSearch password from terraform.tfvars or variables.tf, using fallback password"
            else
                log_info "Using OpenSearch password from variables.tf default value"
            fi
        else
            log_info "Using OpenSearch password from terraform.tfvars"
        fi
    else
        # Fallback to default value from variables.tf
        if [ -f "../tf/variables.tf" ]; then
            OPENSEARCH_PASSWORD=$(grep -A1 "variable \"opensearch_master_user_password\"" ../tf/variables.tf | grep "default" | sed 's/.*= *"\([^"]*\)".*/\1/' || echo "")
            if [ -z "$OPENSEARCH_PASSWORD" ]; then
                OPENSEARCH_PASSWORD="DifyOpenSearchPass123!"
                log_warning "Could not extract OpenSearch password from variables.tf, using fallback password"
            else
                log_info "Using OpenSearch password from variables.tf default value"
            fi
        else
            OPENSEARCH_PASSWORD="DifyOpenSearchPass123!"
            log_warning "terraform.tfvars and variables.tf not found, using fallback password"
        fi
    fi
    
    log_success "Database password information extraction completed"
}

# Generate Terraform output log
generate_output_log() {
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local output_log_file="$(dirname "$TERRAFORM_DIR")/secret/out_${timestamp}.log"
    
    log_info "Generating Terraform output log..."
    
    {
        echo "# Terraform Output Log"
        echo "# Generated at: $(date)"
        echo "# ========================================"
        echo
        cd "$TERRAFORM_DIR" && terraform output && cd - > /dev/null
        echo
        echo "# ========================================"
        echo "# Sensitive Information"
        echo "# ========================================"
        echo
        echo "RDS_PASSWORD = \"$RDS_PASSWORD\""
        echo "OPENSEARCH_PASSWORD = \"$OPENSEARCH_PASSWORD\""
        echo
        echo "# =========================================="
        echo "# IRSA Role ARNs (for Helm values annotations)"
        echo "# =========================================="
        echo "DIFY_EE_S3_ROLE_ARN = \"$DIFY_EE_S3_ROLE_ARN\""
        echo "DIFY_EE_S3_ECR_ROLE_ARN = \"$DIFY_EE_S3_ECR_ROLE_ARN\""
        echo "DIFY_EE_ECR_PULL_ROLE_ARN = \"$DIFY_EE_ECR_PULL_ROLE_ARN\""
        echo
        echo "# =========================================="
        echo "# Database Names"
        echo "# =========================================="
        echo "db_enterprise_database_name = \"$DB_ENTERPRISE_NAME\""
        echo "db_audit_database_name = \"$DB_AUDIT_NAME\""
        echo "db_plugin_daemon_database_name = \"$DB_PLUGIN_DAEMON_NAME\""
    } > "$output_log_file"
    
    chmod 600 "$output_log_file"
    log_success "Output log generated: $output_log_file"
}

# Generate .env format configuration file
generate_env_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local env_file="$(dirname "$TERRAFORM_DIR")/secret/config_${timestamp}.env"
    
    log_info "Generating .env format configuration file..."
    
    # Generate .env format configuration file
    cat > "$env_file" << EOF
# Dify Enterprise Edition Environment Configuration
# Generated at: $(date)
# Environment: $ENVIRONMENT

# Basic Information
ENVIRONMENT=$ENVIRONMENT
DEPLOYMENT_ID=$DEPLOYMENT_ID
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
ELB_MODE=$ELB_MODE

# EKS Cluster Information
CLUSTER_NAME=$CLUSTER_NAME
CLUSTER_ENDPOINT=$CLUSTER_ENDPOINT
CLUSTER_SECURITY_GROUP_ID=$CLUSTER_SECURITY_GROUP_ID

# Network Information
VPC_ID=$VPC_ID
PRIVATE_SUBNET_IDS=$PRIVATE_SUBNET_IDS
PUBLIC_SUBNET_IDS=$PUBLIC_SUBNET_IDS

# Storage Information
S3_BUCKET_NAME=$S3_BUCKET_NAME
S3_BUCKET_ARN=$S3_BUCKET_ARN
S3_IAM_ROLE_ARN=$S3_IAM_ROLE_ARN

# ECR Container Registry Information
ECR_REPOSITORY_URL=$ECR_REPOSITORY_URL
ECR_EE_PLUGIN_REPOSITORY_URL=$ECR_EE_PLUGIN_REPOSITORY_URL
ECR_EE_PLUGIN_REPOSITORY_NAME=$ECR_EE_PLUGIN_REPOSITORY_NAME

# Database Information
RDS_ENDPOINT=$RDS_ENDPOINT
RDS_READER_ENDPOINT=$RDS_READER_ENDPOINT
RDS_PORT=$RDS_PORT
RDS_DATABASE_NAME=$RDS_DATABASE_NAME
RDS_USERNAME=$RDS_USERNAME
RDS_PASSWORD=$RDS_PASSWORD
DB_ENTERPRISE_NAME=$DB_ENTERPRISE_NAME
DB_AUDIT_NAME=$DB_AUDIT_NAME
DB_PLUGIN_DAEMON_NAME=$DB_PLUGIN_DAEMON_NAME

# Redis Cache Information
REDIS_ENDPOINT=$REDIS_ENDPOINT
REDIS_PORT=$REDIS_PORT

# OpenSearch Information
OPENSEARCH_ENDPOINT=$OPENSEARCH_ENDPOINT
OPENSEARCH_DASHBOARD_ENDPOINT=$OPENSEARCH_DASHBOARD_ENDPOINT
OPENSEARCH_USERNAME=admin
OPENSEARCH_PASSWORD=$OPENSEARCH_PASSWORD

# IRSA Role Information
DIFY_EE_S3_ROLE_ARN=$DIFY_EE_S3_ROLE_ARN
DIFY_EE_S3_ECR_ROLE_ARN=$DIFY_EE_S3_ECR_ROLE_ARN
DIFY_EE_ECR_PULL_ROLE_ARN=$DIFY_EE_ECR_PULL_ROLE_ARN

# Application Secrets (TF-managed, stable across applies)
PASSWORD_ENCRYPTION_KEY=$PASSWORD_ENCRYPTION_KEY
AGENT_BACKEND_SECRET_KEY=$AGENT_BACKEND_SECRET_KEY
APP_SECRET_KEY=$APP_SECRET_KEY
EOF

    chmod 600 "$env_file"
    log_success ".env configuration file generated: $env_file"
}

# Generate Dify deployment configuration file
generate_dify_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local config_file="$(dirname "$TERRAFORM_DIR")/secret/dify_deployment_config_${timestamp}.txt"
    
    log_info "Generating Dify deployment configuration file..."
    
    # Generate detailed configuration file
    cat > "$config_file" << EOF
# ========================================
# Dify Enterprise Edition Deployment Configuration
# Generated at: $(date)
# Environment: $ENVIRONMENT
# ========================================

## Basic Information
ENVIRONMENT=$ENVIRONMENT
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID

## EKS Cluster Information
CLUSTER_NAME=$CLUSTER_NAME
CLUSTER_ENDPOINT=$CLUSTER_ENDPOINT
CLUSTER_SECURITY_GROUP_ID=$CLUSTER_SECURITY_GROUP_ID

## Network Information
VPC_ID=$VPC_ID
PRIVATE_SUBNET_IDS=$PRIVATE_SUBNET_IDS
PUBLIC_SUBNET_IDS=$PUBLIC_SUBNET_IDS

## Storage Information
S3_BUCKET_NAME=$S3_BUCKET_NAME
S3_BUCKET_ARN=$S3_BUCKET_ARN
S3_IAM_ROLE_ARN=$S3_IAM_ROLE_ARN

## ECR Container Registry Information
ECR_REPOSITORY_URL=$ECR_REPOSITORY_URL
ECR_EE_PLUGIN_REPOSITORY_URL=$ECR_EE_PLUGIN_REPOSITORY_URL
ECR_EE_PLUGIN_REPOSITORY_NAME=$ECR_EE_PLUGIN_REPOSITORY_NAME

## Database Information (including sensitive info)
RDS_ENDPOINT=$RDS_ENDPOINT
RDS_READER_ENDPOINT=$RDS_READER_ENDPOINT
RDS_PORT=$RDS_PORT
RDS_DATABASE_NAME=$RDS_DATABASE_NAME
RDS_USERNAME=$RDS_USERNAME
RDS_PASSWORD=$RDS_PASSWORD
ENTERPRISE_DB_NAME=$DB_ENTERPRISE_NAME
AUDIT_DB_NAME=$DB_AUDIT_NAME
PLUGIN_DAEMON_DB_NAME=$DB_PLUGIN_DAEMON_NAME

## Redis Cache Information
REDIS_ENDPOINT=$REDIS_ENDPOINT
REDIS_PORT=$REDIS_PORT

## OpenSearch Information (including sensitive info)
OPENSEARCH_ENDPOINT=$OPENSEARCH_ENDPOINT
OPENSEARCH_DASHBOARD_ENDPOINT=$OPENSEARCH_DASHBOARD_ENDPOINT
OPENSEARCH_USERNAME=admin
OPENSEARCH_PASSWORD=$OPENSEARCH_PASSWORD

## IRSA Role Information
DIFY_EE_S3_ROLE_ARN=$DIFY_EE_S3_ROLE_ARN
DIFY_EE_S3_ECR_ROLE_ARN=$DIFY_EE_S3_ECR_ROLE_ARN
DIFY_EE_ECR_PULL_ROLE_ARN=$DIFY_EE_ECR_PULL_ROLE_ARN

## ServiceAccount Information
# For detailed information, see: terraform output dify_ee_service_accounts_info

## Helm Deployment Status
# For detailed information, see: terraform output helm_releases_status

# ========================================
# Deployment Command Reference
# ========================================

## 1. Update kubeconfig
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

## 2. Verify cluster connection
kubectl get nodes

## 3. Add Dify Helm repository
helm repo add dify https://langgenius.github.io/dify-helm
helm repo update

## 4. Deploy using custom values.yaml
# helm upgrade -i dify -f values.yaml dify/dify -n dify

# ========================================
# Important Reminders
# ========================================
# 1. This file contains sensitive information, please handle with care
# 2. Do not commit this file to version control systems
# 3. Consider deleting this file after deployment
# 4. Regularly rotate database passwords and API keys
EOF

    chmod 600 "$config_file"
    log_success "Configuration file generated: $config_file"
}

# Main execution
echo "=============================================================="
echo "  Dify Enterprise Edition Deployment Configuration Generator"
echo "=============================================================="
echo

# Ensure secret directory exists
mkdir -p "../secret"

# Check Terraform state
check_terraform_state

# Get Terraform outputs
get_terraform_outputs

# Get database passwords
get_database_passwords

# Get database names (enterprise/audit/plugin daemon)
get_database_names

echo
log_info "Starting to generate deployment configuration files..."
echo

# Generate configuration files
generate_output_log
generate_dify_config
generate_env_config

echo
log_success "All configuration files generated successfully!"
echo

echo "Generated files:"
echo "  - ../secret/out_*.log                         (Terraform output log)"
echo "  - ../secret/dify_deployment_config_*.txt      (Dify deployment configuration)"
echo "  - ../secret/config_*.env                      (.env format configuration)"
echo
log_warning "Important reminders:"
echo "  1. These files contain sensitive information, please handle with care"
echo "  2. Do not commit these files to version control systems"
echo "  3. Please modify default keys and domains before deployment"
echo "  4. Please delete sensitive files securely after use"
echo
echo "Next steps:"
echo "  1. Create your own Helm values.yaml file based on the configuration information"
echo "  2. Modify domain and secrets in values.yaml"
echo "  3. Run helm upgrade -i dify -f values.yaml dify/dify -n dify to deploy Dify (note: install in dify namespace, not default)"
echo