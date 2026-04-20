#!/bin/bash

# Dify Enterprise Database Creation Script (Using RDS Data API)
# This script uses the RDS Data API to create additional databases required for Dify Enterprise Edition.
# No direct network connection to the database is needed; operations are performed via AWS API calls.
# This script will be automatically executed during the terraform build process, no manual execution is required, but you can run it manually if needed.

set -e  # Exit immediately on error


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color


print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}


# Parse terraform.tfvars file to get database names
parse_terraform_vars() {
    local tfvars_file="terraform.tfvars"
    
    if [ ! -f "$tfvars_file" ]; then
        print_warning "terraform.tfvars file not found, using default database names"
        return 1
    fi
    
    print_info "Parsing terraform.tfvars file for database names..."
    
    # Extract database names from terraform.tfvars
    # Only extract enterprise, audit, and plugin daemon database names as the main 'dify' database is already created by default
    DB_ENTERPRISE_NAME=$(grep "^db_enterprise_database_name" "$tfvars_file" | sed 's/.*=[ ]*"\([^"]*\)".*/\1/' | tr -d ' ')
    DB_AUDIT_NAME=$(grep "^db_audit_database_name" "$tfvars_file" | sed 's/.*=[ ]*"\([^"]*\)".*/\1/' | tr -d ' ')
    DB_PLUGIN_DAEMON_NAME=$(grep "^db_plugin_daemon_database_name" "$tfvars_file" | sed 's/.*=[ ]*"\([^"]*\)".*/\1/' | tr -d ' ')
    
    # Validate extracted values
    if [ -n "$DB_ENTERPRISE_NAME" ]; then
        print_info "Found enterprise database name: $DB_ENTERPRISE_NAME"
    else
        print_warning "Could not extract enterprise database name from terraform.tfvars"
        DB_ENTERPRISE_NAME="enterprise"
    fi
    
    if [ -n "$DB_AUDIT_NAME" ]; then
        print_info "Found audit database name: $DB_AUDIT_NAME"
    else
        print_warning "Could not extract audit database name from terraform.tfvars"
        DB_AUDIT_NAME="audit"
    fi
    
    if [ -n "$DB_PLUGIN_DAEMON_NAME" ]; then
        print_info "Found plugin daemon database name: $DB_PLUGIN_DAEMON_NAME"
    else
        print_warning "Could not extract plugin daemon database name from terraform.tfvars"
        DB_PLUGIN_DAEMON_NAME="dify_plugin_daemon"
    fi
    
    return 0
}

# Try to load mandatory environment variables from Terraform outputs
load_env_from_terraform_outputs() {
    # Attempt best-effort loading. Do not fail the script here.
    if ! command -v terraform >/dev/null 2>&1; then
        print_warning "terraform not installed, cannot auto-load env vars from outputs"
        return 1
    fi

    if [ ! -f "terraform.tfstate" ] && [ ! -d ".terraform" ]; then
        print_warning "terraform state not found in current directory, skip auto-loading env vars"
        return 1
    fi

    print_info "Loading environment variables from terraform outputs..."

    local loaded_any=0

    if [ -z "$CLUSTER_ARN" ]; then
        local v
        v=$(terraform output -raw rds_cluster_arn 2>/dev/null || true)
        if [ -n "$v" ]; then
            export CLUSTER_ARN="$v"
            print_info "Loaded CLUSTER_ARN from terraform outputs"
            loaded_any=1
        fi
    fi

    if [ -z "$SECRET_ARN" ]; then
        local v
        v=$(terraform output -raw rds_credentials_secret_arn 2>/dev/null || true)
        if [ -n "$v" ]; then
            export SECRET_ARN="$v"
            print_info "Loaded SECRET_ARN from terraform outputs"
            loaded_any=1
        fi
    fi

    if [ -z "$AWS_REGION" ]; then
        local v
        v=$(terraform output -raw aws_region 2>/dev/null || true)
        if [ -n "$v" ]; then
            export AWS_REGION="$v"
            print_info "Loaded AWS_REGION from terraform outputs"
            loaded_any=1
        fi
    fi

    if [ "$loaded_any" -eq 1 ]; then
        return 0
    fi

    return 1
}

check_env_vars() {
    print_info "Checking environment variables..."
    
    required_vars=("CLUSTER_ARN" "SECRET_ARN" "AWS_REGION")
    missing_vars=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        print_warning "Missing env vars: ${missing_vars[*]}"
        print_info "Attempting to auto-load from terraform outputs..."
        if ! load_env_from_terraform_outputs; then
            for var in "${missing_vars[@]}"; do
                if [ -z "${!var}" ]; then
                    print_error "Environment variable $var is not set"
                fi
            done
            exit 1
        fi
    fi
    
    # Try to parse database names from terraform.tfvars first
    if ! parse_terraform_vars; then
        # Fall back to environment variables or defaults if terraform.tfvars parsing fails
        DB_ENTERPRISE_NAME="${DB_ENTERPRISE_NAME:-enterprise}"
        DB_AUDIT_NAME="${DB_AUDIT_NAME:-audit}"
        DB_PLUGIN_DAEMON_NAME="${DB_PLUGIN_DAEMON_NAME:-dify_plugin_daemon}"
        
        print_info "Using default database names"
    fi
    
    print_info "Database names to be created:"
    print_info "  - Enterprise: $DB_ENTERPRISE_NAME"
    print_info "  - Audit: $DB_AUDIT_NAME"
    print_info "  - Plugin Daemon: $DB_PLUGIN_DAEMON_NAME"
    
    print_info "Environment variable check completed"
}

# Check AWS CLI and permissions
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not installed"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured or invalid"
        exit 1
    fi
    
    # Ensure jq is available for JSON parsing
    if ! command -v jq &> /dev/null; then
        print_error "jq not installed"
        exit 1
    fi

    print_info "AWS CLI check completed"
}

# Wait for Aurora cluster to be available
wait_for_cluster() {
    print_info "Waiting for Aurora cluster to be available..."
    
    max_attempts=60 # Maximum 60 attempts, 30 seconds each, total maximum wait time about 30 minutes
    attempt=1
    
    # Derive cluster identifier from ARN if needed
    local cluster_identifier="$CLUSTER_ARN"
    if [[ "$CLUSTER_ARN" == arn:*:rds:*:*:cluster:* ]]; then
        cluster_identifier="${CLUSTER_ARN##*:}"
    fi

    while [ $attempt -le $max_attempts ]; do
        cluster_status=$(aws rds describe-db-clusters \
            --region "$AWS_REGION" \
            --db-cluster-identifier "$cluster_identifier" \
            --query 'DBClusters[0].Status' \
            --output text 2>/dev/null || echo "not-found")
        
        if [ "$cluster_status" = "available" ]; then
            print_info "Aurora cluster status: available"
            return 0
        else
            print_warning "Aurora cluster status: $cluster_status, waiting... ($attempt/$max_attempts)"
            sleep 30
            ((attempt++))
        fi
    done
    
    print_error "Aurora cluster wait timeout"
    exit 1
}

# Execute SQL using RDS Data API
execute_sql() {
    local sql_statement="$1"
    local database_name="${2:-postgres}"
    
    print_info "Executing SQL: $sql_statement"
    
    local result
    result=$(aws rds-data execute-statement \
        --region "$AWS_REGION" \
        --resource-arn "$CLUSTER_ARN" \
        --secret-arn "$SECRET_ARN" \
        --database "$database_name" \
        --sql "$sql_statement" \
        --output json 2>&1)
    
    if [ $? -eq 0 ]; then
        print_info "SQL execution successful"
        return 0
    else
        print_error "SQL execution failed: $result"
        return 1
    fi
}

# Check if database exists
check_database_exists() {
    local db_name="$1"
    
    local sql="SELECT 1 FROM pg_database WHERE datname = '$db_name';"
    
    local result
    result=$(aws rds-data execute-statement \
        --region "$AWS_REGION" \
        --resource-arn "$CLUSTER_ARN" \
        --secret-arn "$SECRET_ARN" \
        --database "postgres" \
        --sql "$sql" \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        # Check if the returned records array has data
        local record_count
        record_count=$(echo "$result" | jq '.records | length')
        
        if [ "$record_count" -gt 0 ]; then
            return 0  # Database exists
        else
            return 1  # Database does not exist
        fi
    else
        return 1  # Query failed, assume database does not exist
    fi
}

# Create database function
create_database_if_not_exists() {
    local db_name="$1"
    
    print_info "Checking database: $db_name"
    
    if check_database_exists "$db_name"; then
        print_warning "Database $db_name already exists, skipping creation"
        return 0
    fi
    
    print_info "Creating database: $db_name"
    
    local sql="CREATE DATABASE \"$db_name\";"
    
    if execute_sql "$sql" "postgres"; then
        print_info "Database $db_name created successfully"
        return 0
    else
        print_error "Database $db_name creation failed"
        return 1
    fi
}

# Check if region is in China
check_china_region() {
    print_info "Checking AWS region..."
    
    # China regions start with 'cn-'
    if [[ "$AWS_REGION" == cn-* ]]; then
        print_error "RDS Data API is not supported in China Region, please create database manually."
        exit 0
    fi
    
    print_info "Region check completed"
}

# Main function
main() {
    print_info "Starting Dify Enterprise database creation (using RDS Data API)..."
    
    # Check environment variables
    check_env_vars
    
    # Check if region is in China
    check_china_region
    
    # Check AWS CLI and permissions
    check_aws_cli
    
    # Wait for cluster to be available
    wait_for_cluster
    
    # Create required databases
    # Note: Database names are now dynamically loaded from terraform.tfvars
    # These names will match exactly what Helm values expect
    databases=("$DB_ENTERPRISE_NAME" "$DB_AUDIT_NAME" "$DB_PLUGIN_DAEMON_NAME")
    
    failed_databases=()
    
    for db in "${databases[@]}"; do
        if ! create_database_if_not_exists "$db"; then
            failed_databases+=("$db")
        fi
    done
    
    if [ ${#failed_databases[@]} -eq 0 ]; then
        print_info "All databases created successfully!"
        
        # Output connection information
        print_info "Database connection information:"
        echo "  Cluster ARN: $CLUSTER_ARN"
        echo "  Secret ARN: $SECRET_ARN"
        echo "  Region: $AWS_REGION"
        echo "  Created databases:"
        for db in "${databases[@]}"; do
            echo "    - $db"
        done
    else
        print_error "The following databases failed to create: ${failed_databases[*]}"
        exit 1
    fi
}

# Script help information
show_help() {
    cat << EOF
Dify Enterprise Database Creation Script (RDS Data API)

Usage:
    $0 [options]

Environment Variables:
    CLUSTER_ARN  - Aurora cluster ARN (required)
    SECRET_ARN   - ARN of database credentials stored in Secrets Manager (required)
    AWS_REGION   - AWS region (required)
    
    Optional Environment Variables (fallback if terraform.tfvars not found):
    DB_ENTERPRISE_NAME     - Enterprise database name (default: enterprise)
    DB_AUDIT_NAME          - Audit database name (default: audit)
    DB_PLUGIN_DAEMON_NAME  - Plugin daemon database name (default: dify_plugin_daemon)

Example:
    export CLUSTER_ARN="arn:aws:rds:us-east-2:123456789012:cluster:my-cluster"
    export SECRET_ARN="arn:aws:secretsmanager:us-east-2:123456789012:secret:rds-db-credentials/cluster-123456/postgres"
    export AWS_REGION="us-east-2"
    $0

Notes:
    - This script uses RDS Data API, no network connection to database required
    - AWS CLI must be configured with appropriate permissions
    - Aurora cluster must have Data API enabled (enable_http_endpoint = true)
    - Database credentials must be stored in AWS Secrets Manager
    - Database names are automatically loaded from terraform.tfvars file if present
    - If terraform.tfvars is not found, falls back to environment variables or defaults

Options:
    -h, --help   Show this help information

EOF
}

# Handle command line arguments
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        main
        ;;
    *)
        print_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac
