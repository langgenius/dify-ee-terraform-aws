#!/bin/bash

# Dify Enterprise Database Creation Script (Kubernetes Pod Method)
# This script starts a temporary Pod in the EKS cluster to connect to RDS and create required databases.
# Useful for China regions where RDS Data API is not supported or available.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Image configuration
# Default to postgres:15-alpine which is available in the private registry
# In China, we use the private registry image directly
DB_CLIENT_IMAGE="${DB_CLIENT_IMAGE:-g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/postgres:15-alpine}"

# User suggested busybox image for connectivity checks (optional usage)
# BUSYBOX_IMAGE="g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/busybox"

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse terraform.tfvars file to get database names (reusing logic from existing scripts)
parse_terraform_vars() {
    local tfvars_file="../tf/terraform.tfvars"
    
    if [ ! -f "$tfvars_file" ]; then
        print_warning "terraform.tfvars file not found at $tfvars_file, using default database names"
        return 1
    fi
    
    print_info "Parsing terraform.tfvars file for database names..."
    
    DB_ENTERPRISE_NAME=$(grep "^db_enterprise_database_name" "$tfvars_file" | sed 's/.*=[ ]*"\([^"]*\)".*/\1/' | tr -d ' ')
    DB_AUDIT_NAME=$(grep "^db_audit_database_name" "$tfvars_file" | sed 's/.*=[ ]*"\([^"]*\)".*/\1/' | tr -d ' ')
    DB_PLUGIN_DAEMON_NAME=$(grep "^db_plugin_daemon_database_name" "$tfvars_file" | sed 's/.*=[ ]*"\([^"]*\)".*/\1/' | tr -d ' ')
    
    # Defaults if not found
    DB_ENTERPRISE_NAME="${DB_ENTERPRISE_NAME:-enterprise}"
    DB_AUDIT_NAME="${DB_AUDIT_NAME:-audit}"
    DB_PLUGIN_DAEMON_NAME="${DB_PLUGIN_DAEMON_NAME:-dify_plugin_daemon}"
    
    return 0
}

get_rds_credentials() {
    print_info "Retrieving RDS credentials from Terraform outputs..."
    
    cd ../tf
    
    # Check if terraform exists
    if ! command -v terraform &> /dev/null; then
        print_error "terraform command not found"
        exit 1
    fi
    
    RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
    RDS_USERNAME=$(terraform output -raw rds_username)
    SECRET_ARN=$(terraform output -raw rds_credentials_secret_arn)
    AWS_REGION=$(terraform output -raw aws_region)
    
    cd ../scripts

    if [ -z "$RDS_ENDPOINT" ] || [ -z "$SECRET_ARN" ]; then
        print_error "Failed to get RDS endpoint or Secret ARN from terraform outputs"
        exit 1
    fi
    
    print_info "RDS Endpoint: $RDS_ENDPOINT"
    print_info "Fetching password from Secrets Manager ($SECRET_ARN)..."
    
    if ! command -v aws &> /dev/null; then
        print_error "aws cli not found"
        exit 1
    fi
    
    # Retrieve password from Secrets Manager
    # The secret is a JSON string: {"username":"...","password":"..."}
    RDS_PASSWORD=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_ARN" \
        --region "$AWS_REGION" \
        --query 'SecretString' \
        --output text | jq -r .password)
        
    if [ -z "$RDS_PASSWORD" ] || [ "$RDS_PASSWORD" == "null" ]; then
        print_error "Failed to retrieve password from Secrets Manager"
        exit 1
    fi
}

wait_for_pod_ready() {
    local pod_name="$1"
    print_info "Waiting for pod $pod_name to be ready..."
    kubectl wait --for=condition=Ready pod/$pod_name --timeout=60s
}

create_databases_in_one_pod() {
    local databases=("${@}")
    local pod_name="db-create-all-$(date +%s)"
    
    print_info "Creating databases: ${databases[*]} using single pod $pod_name..."
    
    # Construct the script to be executed inside the pod
    # Add initial delay and banner to ensure logs are captured despite kubectl stream issues
    local psql_script="sleep 2; echo '--- Starting Database Operations ---';"
    for db in "${databases[@]}"; do
        psql_script+="
echo \"Checking database $db...\"
exists=\$(psql -h $RDS_ENDPOINT -U $RDS_USERNAME -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname = '$db'\")
if [ \"\$exists\" = \"1\" ]; then
    echo \"Database $db already exists.\"
else
    echo \"Creating database $db...\"
    psql -h $RDS_ENDPOINT -U $RDS_USERNAME -d postgres -c \"CREATE DATABASE \\\"$db\\\"\"
fi
"
    done

    # Execute the script in a single pod
    if kubectl run "$pod_name" \
        --image="$DB_CLIENT_IMAGE" \
        --restart=Never \
        --rm -i \
        --env="PGPASSWORD=$RDS_PASSWORD" \
        -- sh -c "$psql_script" 2>&1; then
        print_info "Database operations completed successfully"
    else
        print_error "Failed to perform database operations"
        return 1
    fi
}

main() {
    check_dependencies
    
    parse_terraform_vars
    
    get_rds_credentials
    
    DATABASES=("$DB_ENTERPRISE_NAME" "$DB_AUDIT_NAME" "$DB_PLUGIN_DAEMON_NAME")
    
    print_info "Starting database creation for: ${DATABASES[*]}"
    print_info "Using image: $DB_CLIENT_IMAGE"
    
    # Verify Kubernetes connection
    if ! kubectl get nodes &>/dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Check kubeconfig."
        exit 1
    fi
    
    create_databases_in_one_pod "${DATABASES[@]}"
    
    print_info "All operations completed."
}

check_dependencies() {
    for cmd in kubectl terraform aws jq; do
        if ! command -v $cmd &> /dev/null; then
            print_error "$cmd is required but not installed."
            exit 1
        fi
    done
}

main "$@"

