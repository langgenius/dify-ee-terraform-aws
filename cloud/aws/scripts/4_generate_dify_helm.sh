#!/bin/bash

# Automatically generate values.yaml for Dify Enterprise Edition deployment

set -eo pipefail

# Enable debug mode if DEBUG=1
if [ "${DEBUG:-0}" = "1" ]; then
    set -x
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
SECRET_DIR="${BASE_DIR}/secret"
HELM_TEMPLATES_DIR="${SCRIPT_DIR}/helm_templates"

# Watchdog service URL for fetching Helm chart metadata
DIFY_HELM_WATCHDOG_URL="${DIFY_HELM_WATCHDOG_URL:-https://helm-watchdog.dify.ai}"
WATCHDOG_VERSION_LIMIT=5
WATCHDOG_SKIP_PATHS=("redis" "qdrant")
WATCHDOG_AMD64_ONLY_PATHS=("web.logoConfig" "enterpriseAudit" "enterprise" "plugin_manager" "gateway" "plugin_connector" "plugin_controller")
CN_IMAGE_MIRROR_PREFIX="g-hsod9681-docker.pkg.coding.net/dify-artifact/dify"
DEFAULT_CLUSTER_ARCH="amd64"
WATCHDOG_FORCE_ARM64_TAGS=0
CLUSTER_ARCHITECTURE=""

# Color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

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
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Error handler
on_error() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line $line_number with exit code $exit_code"
    exit $exit_code
}

# Set error trap
trap 'on_error $LINENO' ERR

# Function to display interactive menu
show_menu() {
    local options=("$@")
    local selected=0
    local max_index=$((${#options[@]} - 1))
    
    # Hide cursor
    tput civis >&2
    
    while true; do
        clear >&2
        echo -e "${BOLD}${BLUE}Please select using arrow keys and press Enter:${NC}" >&2
        echo >&2
        
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then
                echo -e "${GREEN}> ${options[$i]}${NC}" >&2
            else
                echo "  ${options[$i]}" >&2
            fi
        done
        
        # Read single key press
        read -rsn1 key
        
        # Handle arrow keys
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                '[A') # Up arrow
                    ((selected--))
                    if [ $selected -lt 0 ]; then
                        selected=$max_index
                    fi
                    ;;
                '[B') # Down arrow
                    ((selected++))
                    if [ $selected -gt $max_index ]; then
                        selected=0
                    fi
                    ;;
            esac
        elif [[ $key == "" ]]; then # Enter key
            break
        fi
    done
    
    # Show cursor again
    tput cnorm >&2
    
    # Output selected index and return success
    echo "$selected"
    return 0
}

# Function to find all env files in secret directory
find_env_files() {
    local env_files=()
    
    if [ ! -d "$SECRET_DIR" ]; then
        log_error "Secret directory not found: $SECRET_DIR"
        exit 1
    fi
    
    while IFS= read -r -d '' file; do
        env_files+=("$(basename "$file")")
    done < <(find "$SECRET_DIR" -maxdepth 1 -name "*.env" -type f -print0 | sort -z)
    
    if [ ${#env_files[@]} -eq 0 ]; then
        log_error "No .env files found in $SECRET_DIR"
        exit 1
    fi
    
    echo "${env_files[@]}"
}

# Function to load environment variables from selected file
load_env_file() {
    local env_file="$1"
    local env_path="${SECRET_DIR}/${env_file}"
    
    if [ ! -f "$env_path" ]; then
        log_error "Environment file not found: $env_path"
        exit 1
    fi
    
    log_info "Loading environment variables from: $env_file"
    
    # Export variables from env file
    set -a
    source "$env_path"
    set +a
    
    log_success "Environment variables loaded successfully"
}

# Function to get AWS certificates
get_aws_certificates() {
    local certificates=()
    local cert_info
    
    # Get certificate list from AWS (no logging here to avoid polluting the output)
    cert_info=$(aws acm list-certificates --region "${AWS_REGION}" --certificate-statuses ISSUED 2>/dev/null || echo "")
    
    if [ -z "$cert_info" ] || [ "$(echo "$cert_info" | jq '.CertificateSummaryList | length')" -eq 0 ]; then
        return 1
    fi
    
    # Parse certificates
    while IFS= read -r line; do
        local domain=$(echo "$line" | jq -r '.DomainName')
        local arn=$(echo "$line" | jq -r '.CertificateArn')
        certificates+=("$domain | $arn")
    done < <(echo "$cert_info" | jq -c '.CertificateSummaryList[]')
    
    # Return certificates array properly
    printf '%s\n' "${certificates[@]}"
}

# Function to replace placeholders in template
replace_template() {
    local template_file="$1"
    local output_file="$2"
    local cert_arn="$3"
    local use_tls="$4"
    
    log_info "Processing template: $(basename "$template_file")"
    
    # Extract domain from certificate or use a default
    local domain="${DOMAIN_NAME:-}"
    if [ -n "$cert_arn" ]; then
        # Extract domain from certificate selection
        domain=$(echo "$cert_arn" | cut -d'|' -f1 | xargs)
        cert_arn=$(echo "$cert_arn" | cut -d'|' -f2 | xargs)
        # Remove wildcard if present
        domain=${domain#\*.}
    fi
    
    # If still no domain, use a default
    if [ -z "$domain" ]; then
        domain="dify.local"
    fi
    
    # Create a temporary file for sed operations
    local temp_file=$(mktemp)local
    if ! cp "$template_file" "$temp_file"; then
        log_error "Failed to copy template file: $template_file"
        return 1
    fi
    
    # Generate a random secret key if not provided
    if [ -z "${APP_SECRET_KEY:-}" ]; then
        APP_SECRET_KEY=$(openssl rand -base64 42)
    fi
    
    # Prepare AWS service suffix (used for ECR repo URL and ARN rendering).
    # S3 endpoint is intentionally hardcoded to "" in templates — setting it
    # propagates to kaniko's S3_ENDPOINT env and misroutes STS AssumeRoleWithWebIdentity.
    local region="${AWS_REGION:-us-east-1}"
    local aws_service_suffix="amazonaws.com"
    if [[ "$region" == cn-* ]]; then
        aws_service_suffix="amazonaws.com.cn"
    fi

    # Replace placeholders with default values for undefined variables
    sed -i.bak "s|{{local_domain}}|${domain}|g" "$temp_file"
    sed -i.bak "s|{{region}}|${AWS_REGION:-us-east-1}|g" "$temp_file"
    sed -i.bak "s|{{awsservice_suffix}}|${aws_service_suffix}|g" "$temp_file"
    sed -i.bak "s|{{account_id}}|${AWS_ACCOUNT_ID:-}|g" "$temp_file"
    sed -i.bak "s|{{cluster_name}}|${CLUSTER_NAME:-}|g" "$temp_file"
    sed -i.bak "s|{{deployment_id}}|${DEPLOYMENT_ID:-}|g" "$temp_file"
    sed -i.bak "s|{{secret_key}}|${APP_SECRET_KEY}|g" "$temp_file"
    
    # S3 related ({{s3_endpoint}} is intentionally absent — templates hardcode "")
    sed -i.bak "s|{{s3_bucket}}|${S3_BUCKET_NAME:-}|g" "$temp_file"
    sed -i.bak "s|{{s3_bucket_name}}|${S3_BUCKET_NAME:-}|g" "$temp_file"
    sed -i.bak "s|{{bucket_name}}|${S3_BUCKET_NAME:-}|g" "$temp_file"
    
    # RDS related
    sed -i.bak "s|{{rds_endpoint}}|${RDS_ENDPOINT:-}|g" "$temp_file"
    sed -i.bak "s|{{rds_address}}|${RDS_ENDPOINT:-}|g" "$temp_file"
    sed -i.bak "s|{{rds_reader_endpoint}}|${RDS_READER_ENDPOINT:-}|g" "$temp_file"
    sed -i.bak "s|{{rds_port}}|${RDS_PORT:-5432}|g" "$temp_file"
    sed -i.bak "s|{{rds_database}}|${RDS_DATABASE_NAME:-}|g" "$temp_file"
    sed -i.bak "s|{{rds_username}}|${RDS_USERNAME:-}|g" "$temp_file"
    sed -i.bak "s|{{rds_password}}|${RDS_PASSWORD:-}|g" "$temp_file"
    
    # Database names related
    sed -i.bak "s|{{rds_main_database_name}}|${RDS_MAIN_DATABASE_NAME:-dify}|g" "$temp_file"
    sed -i.bak "s|{{rds_enterprise_database_name}}|${RDS_ENTERPRISE_DATABASE_NAME:-enterprise}|g" "$temp_file"
    sed -i.bak "s|{{rds_audit_database_name}}|${RDS_AUDIT_DATABASE_NAME:-audit}|g" "$temp_file"
    sed -i.bak "s|{{rds_plugin_daemon_database_name}}|${RDS_PLUGIN_DAEMON_DATABASE_NAME:-dify_plugin_daemon}|g" "$temp_file"
    
    # Redis related
    sed -i.bak "s|{{redis_endpoint}}|${REDIS_ENDPOINT:-}|g" "$temp_file"
    sed -i.bak "s|{{redis_address}}|${REDIS_ENDPOINT:-}|g" "$temp_file"
    sed -i.bak "s|{{redis_port}}|${REDIS_PORT:-6379}|g" "$temp_file"
    
    # OpenSearch related
    sed -i.bak "s|{{opensearch_endpoint}}|${OPENSEARCH_ENDPOINT:-}|g" "$temp_file"
    sed -i.bak "s|{{opensearch_address}}|${OPENSEARCH_ENDPOINT:-}|g" "$temp_file"
    sed -i.bak "s|{{opensearch_username}}|${OPENSEARCH_USERNAME:-}|g" "$temp_file"
    sed -i.bak "s|{{opensearch_user}}|${OPENSEARCH_USERNAME:-}|g" "$temp_file"
    sed -i.bak "s|{{opensearch_password}}|${OPENSEARCH_PASSWORD:-}|g" "$temp_file"
    
    # ECR related
    sed -i.bak "s|{{ecr_repository_url}}|${ECR_REPOSITORY_URL:-}|g" "$temp_file"
    sed -i.bak "s|{{ecr_ee_plugin_repository_url}}|${ECR_EE_PLUGIN_REPOSITORY_URL:-}|g" "$temp_file"
    
    # IAM roles
    sed -i.bak "s|{{dify_ee_s3_role_arn}}|${DIFY_EE_S3_ROLE_ARN:-}|g" "$temp_file"
    sed -i.bak "s|{{dify_ee_s3_ecr_role_arn}}|${DIFY_EE_S3_ECR_ROLE_ARN:-}|g" "$temp_file"
    
    # TLS configuration
    sed -i.bak "s|{{isUseTLS}}|${use_tls:-false}|g" "$temp_file"
    
    # ELB mode configuration
    sed -i.bak "s|{{elb_mode}}|${ELB_MODE:-internet-facing}|g" "$temp_file"
    
    # Handle certificate ARN
    if [ -n "$cert_arn" ]; then
        # Determine ARN prefix based on region (China regions use aws-cn)
        local arn_prefix="aws"
        if [[ "${AWS_REGION:-}" == cn-* ]]; then
            arn_prefix="aws-cn"
        fi
        
        # Ensure cert_arn has the correct prefix for the region
        if [[ "$cert_arn" == arn:aws:* ]] && [ "$arn_prefix" = "aws-cn" ]; then
            # Fix incorrect arn:aws prefix for China regions
            cert_arn="${cert_arn/arn:aws:/arn:aws-cn:}"
            log_info "Corrected certificate ARN prefix for China region: $cert_arn"
        elif [[ "$cert_arn" == arn:aws-cn:* ]] && [ "$arn_prefix" = "aws" ]; then
            # Fix incorrect arn:aws-cn prefix for non-China regions
            cert_arn="${cert_arn/arn:aws-cn:/arn:aws:}"
            log_info "Corrected certificate ARN prefix for standard region: $cert_arn"
        fi
        
        # Extract certificate UUID from ARN - more flexible pattern
        local cert_uuid=$(echo "$cert_arn" | grep -oE '[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}' || true)
        if [ -n "$cert_uuid" ]; then
            sed -i.bak "s|{{cert_uuid}}|${cert_uuid}|g" "$temp_file"
            # Also replace the ARN prefix placeholder to match the region
            sed -i.bak "s|arn:aws:acm:|arn:${arn_prefix}:acm:|g" "$temp_file"
            sed -i.bak "s|arn:aws-cn:acm:|arn:${arn_prefix}:acm:|g" "$temp_file"
        else
            log_warning "Could not extract certificate UUID from ARN, using full ARN"
            # Replace the entire certificate line with the full ARN
            sed -i.bak "s|arn:aws:acm:{{region}}:{{account_id}}:certificate/{{cert_uuid}}|${cert_arn}|g" "$temp_file"
            sed -i.bak "s|arn:aws-cn:acm:{{region}}:{{account_id}}:certificate/{{cert_uuid}}|${cert_arn}|g" "$temp_file"
        fi
    else
        # Remove the certificate line if no certificate is selected
        sed -i.bak "/alb.ingress.kubernetes.io\/certificate-arn:/d" "$temp_file"
    fi
    
    # Clean up backup files
    rm -f "${temp_file}.bak"
    
    # Move to output location
    mv "$temp_file" "$output_file"
    
    log_success "Generated: $(basename "$output_file")"
}

# Determine EKS cluster architecture from env or Terraform defaults
detect_cluster_architecture() {
    if [ -n "${EKS_ARCH:-}" ]; then
        echo "${EKS_ARCH}"
        return 0
    fi
    if [ -n "${eks_arch:-}" ]; then
        echo "${eks_arch}"
        return 0
    fi
    local tfvars_file="${BASE_DIR}/tf/terraform.tfvars"
    if [ -f "$tfvars_file" ]; then
        local value
        value=$(grep -E '^[[:space:]]*eks_arch[[:space:]]*=' "$tfvars_file" | head -1 | sed 's/.*=[[:space:]]*//' | cut -d'#' -f1 | tr -d ' "')
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    echo "$DEFAULT_CLUSTER_ARCH"
}

# Helper to convert dotted YAML paths into yq-friendly expressions
build_yq_path() {
    local raw_path="$1"
    local expr=""
    local IFS='.'
    read -ra parts <<< "$raw_path"
    for part in "${parts[@]}"; do
        [ -z "$part" ] && continue
        local segment=""
        if [[ "$part" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            segment=".$part"
        else
            local escaped="${part//\\/\\\\}"
            escaped="${escaped//\"/\\\"}"
            segment=".[\"$escaped\"]"
        fi
        expr="${expr}${segment}"
    done
    echo "$expr"
}

# Collect generated values files to be updated
list_generated_values_files() {
    local dir="$1"
    local -a values_files=()
    while IFS= read -r -d '' file; do
        values_files+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f -name "values.*.yaml" -print0 | sort -z)
    if [ ${#values_files[@]} -eq 0 ]; then
        return 1
    fi
    printf '%s\n' "${values_files[@]}"
}

# Prompt user to select watchdog version (returns "version|appVersion")
prompt_watchdog_version() {
    local versions_json="$1"
    local rows
    if ! rows=$(echo "$versions_json" | jq -r --argjson limit "$WATCHDOG_VERSION_LIMIT" '.versions | ( .[:$limit] // [] )[] | "\(.version)\t\(.appVersion // "n/a")\t\(.createTime // "")"'); then
        return 1
    fi
    if [ -z "$rows" ]; then
        return 1
    fi
    local -a rows_array=()
    while IFS= read -r row; do
        [ -n "$row" ] && rows_array+=("$row")
    done <<< "$rows"
    local -a options=()
    local -a versions=()
    local -a app_versions=()
    for row in "${rows_array[@]}"; do
        IFS=$'\t' read -r version app create <<< "$row"
        [ -z "$version" ] && continue
        versions+=("$version")
        app_versions+=("$app")
        local label="Version ${version} (App ${app})"
        if [ -n "$create" ] && [ "$create" != "null" ]; then
            label="${label} - ${create}"
        fi
        options+=("$label")
    done
    if [ ${#versions[@]} -eq 0 ]; then
        return 1
    fi
    echo >&2
    log_info "Select the Dify Helm version to source image tags from:" >&2
    local selected_index
    selected_index=$(show_menu "${options[@]}")
    clear >&2
    echo "${versions[$selected_index]}|${app_versions[$selected_index]}"
}

# Apply watchdog image metadata to the selected values file using yq
apply_watchdog_images_to_file() {
    local values_file="$1"
    local images_json="$2"
    local rows
    if ! rows=$(echo "$images_json" | jq -r '.images[]? | "\(.path)\t\(.repository)\t\(.tag)"'); then
        return 1
    fi
    if [ -z "$rows" ]; then
        log_warning "Watchdog response did not contain any image metadata."
        return 1
    fi
    local temp_file
    temp_file=$(mktemp)
    if ! cp "$values_file" "$temp_file"; then
        log_error "Failed to create temporary copy of $values_file"
        rm -f "$temp_file"
        return 1
    fi
    local updated=0
    local -a image_lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && image_lines+=("$line")
    done <<< "$rows"
    for entry in "${image_lines[@]}"; do
        IFS=$'\t' read -r path repo tag <<< "$entry"
        [ -z "$path" ] && continue
        local skip_entry=0
        for skip_path in "${WATCHDOG_SKIP_PATHS[@]}"; do
            if [ "$path" = "$skip_path" ]; then
                skip_entry=1
                log_info "Skipping image update for ${path} (manual configuration required)."
                break
            fi
        done
        if [ $skip_entry -eq 1 ]; then
            continue
        fi
        local final_repo="$repo"
        local final_tag="$tag"
        if [[ "${AWS_REGION:-}" == cn* ]]; then
            if [[ "$final_repo" == langgenius/* ]]; then
                local suffix="${final_repo#langgenius/}"
                final_repo="${CN_IMAGE_MIRROR_PREFIX}/${suffix}"
            elif [ "$path" = "ssrfProxy" ]; then
                final_repo="${CN_IMAGE_MIRROR_PREFIX}/squid"
            fi
        fi
        if [ "$WATCHDOG_FORCE_ARM64_TAGS" -eq 1 ]; then
            for amd_path in "${WATCHDOG_AMD64_ONLY_PATHS[@]}"; do
                if [ "$path" = "$amd_path" ] && [[ "$final_tag" != *-arm64 ]]; then
                    final_tag="${final_tag}-arm64"
                    break
                fi
            done
        fi
        local yq_path
        yq_path=$(build_yq_path "$path")
        if [ -z "$yq_path" ]; then
            log_warning "Skipping invalid image path: $path"
            continue
        fi
        local repo_escaped="${final_repo//\\/\\\\}"
        repo_escaped="${repo_escaped//\"/\\\"}"
        local tag_escaped="${final_tag//\\/\\\\}"
        tag_escaped="${tag_escaped//\"/\\\"}"
        yq eval --inplace "${yq_path}.image.repository = \"${repo_escaped}\"" "$temp_file"
        yq eval --inplace "${yq_path}.image.tag = \"${tag_escaped}\"" "$temp_file"
        yq eval --inplace "(${yq_path}.image.tag style=\"double\")" "$temp_file"
        ((updated++))
    done
    if [ $updated -eq 0 ]; then
        rm -f "$temp_file"
        log_warning "No image entries were applied to $values_file"
        return 1
    fi
    mv "$temp_file" "$values_file"
    return 0
}

# Wrapper orchestrating the dify-helm-watchdog interaction phase
run_watchdog_stage() {
    local values_dir="$1"
    log_info "Starting dify-helm-watchdog image synchronization stage..."
    local values_output
    if ! values_output=$(list_generated_values_files "$values_dir"); then
        log_warning "No generated values files found in $values_dir. Skipping image synchronization."
        return 0
    fi
    local -a values_files=()
    while IFS= read -r file; do
        [ -n "$file" ] && values_files+=("$file")
    done <<< "$values_output"
    if [ ${#values_files[@]} -eq 0 ]; then
        log_warning "Failed to identify generated values files in $values_dir."
        return 0
    fi
    log_info "Will update ${#values_files[@]} generated values file(s) with image metadata."
    local versions_json
    if ! versions_json=$(curl -sS --fail "${DIFY_HELM_WATCHDOG_URL}/api/v1/versions"); then
        log_warning "Failed to fetch versions from ${DIFY_HELM_WATCHDOG_URL}. Skipping watchdog stage."
        return 0
    fi
    local version_selection
    if ! version_selection=$(prompt_watchdog_version "$versions_json"); then
        log_warning "Could not determine a version from watchdog response. Skipping image synchronization."
        return 0
    fi
    local selected_version="${version_selection%%|*}"
    local selected_app_version="${version_selection#*|}"
    if [ "$selected_app_version" = "$version_selection" ]; then
        selected_app_version="n/a"
    fi
    log_info "Fetching image metadata for version ${selected_version}..."
    local images_json
    if ! images_json=$(curl -sS --fail "${DIFY_HELM_WATCHDOG_URL}/api/v1/versions/${selected_version}/images?format=json"); then
        log_warning "Failed to fetch image metadata for version ${selected_version}."
        return 0
    fi
    local updated_count=0
    for file in "${values_files[@]}"; do
        if apply_watchdog_images_to_file "$file" "$images_json"; then
            ((updated_count++))
            log_success "Updated $(basename "$file") with images from version ${selected_version} (App ${selected_app_version})."
        else
            log_warning "Failed to inject image metadata into $(basename "$file")."
        fi
    done
    if [ $updated_count -gt 0 ]; then
        log_info "Watchdog synchronization complete for $updated_count file(s). Review the updated image tags before deploying."
    else
        log_warning "Watchdog synchronization did not update any files."
    fi
}

# Function to check dependencies
check_dependencies() {
    local deps=("aws" "jq" "openssl" "curl" "yq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Please install the missing tools before running this script."
        exit 1
    fi
}

# Main function
main() {
    log_info "Starting Dify Helm values generation..."
    
    # Check dependencies
    check_dependencies
    
    # Step 1: Find and select env file
    log_info "Searching for environment files..."
    env_files=($(find_env_files))
    
    echo
    selected_index=$(show_menu "${env_files[@]}")
    selected_env="${env_files[$selected_index]}"
    
    clear
    log_info "Selected environment file: $selected_env"
    
    # Step 2: Load environment variables
    load_env_file "$selected_env"
    CLUSTER_ARCHITECTURE=$(detect_cluster_architecture)
    local arch_lower
    arch_lower=$(echo "${CLUSTER_ARCHITECTURE:-}" | tr '[:upper:]' '[:lower:]')
    if [ "$arch_lower" = "arm64" ]; then
        WATCHDOG_FORCE_ARM64_TAGS=1
        log_info "Cluster architecture detected as arm64 - enforcing arm64 image tags for specific components."
    else
        WATCHDOG_FORCE_ARM64_TAGS=0
        log_info "Cluster architecture detected as ${CLUSTER_ARCHITECTURE:-$DEFAULT_CLUSTER_ARCH} - using default amd64 image tags."
    fi
    
    # Step 3: Get and select AWS certificate
    echo
    log_info "Fetching AWS certificates..."
    
    # Read certificates into array, handling multi-line output properly
    cert_options=()
    while IFS= read -r cert; do
        [ -n "$cert" ] && cert_options+=("$cert")
    done < <(get_aws_certificates)
    
    if [ ${#cert_options[@]} -eq 0 ]; then
        log_warning "No AWS ACM certificates found in region ${AWS_REGION}"
        log_warning "Helm values will be generated without certificate configuration"
        selected_cert=""
        IS_USE_TLS="false"
    else
        # Add "No certificate" option
        cert_options=("No certificate - Skip certificate configuration and use 'dify.local', you can change it later" "${cert_options[@]}")
        
        echo
        selected_index=$(show_menu "${cert_options[@]}")
        
        if [ $selected_index -eq 0 ]; then
            selected_cert=""
            clear
            log_info "No certificate selected"
            
            # Ask user if they want to enable TLS when no certificate is selected
            echo
            log_info "Do you want to enable TLS for your deployment?"
            tls_options=("Yes - Enable TLS (recommended for production)" "No - Disable TLS (only for testing)")
            tls_index=$(show_menu "${tls_options[@]}")
            
            clear
            if [ $tls_index -eq 0 ]; then
                IS_USE_TLS="true"
                log_info "TLS enabled - You will need to configure certificates later"
            else
                IS_USE_TLS="false"
                log_info "TLS disabled - HTTP will be used (not recommended for production)"
            fi
        else
            selected_cert="${cert_options[$selected_index]}"
            IS_USE_TLS="true"
            clear
            log_info "Selected certificate: $(echo "$selected_cert" | cut -d'|' -f1)"
            log_info "TLS automatically enabled with AWS certificate"
        fi
    fi
    
    # Step 4: Generate output directory
    timestamp=$(date +"%Y%m%d_%H%M%S")
    output_dir="${SECRET_DIR}/helm_values_${timestamp}"
    mkdir -p "$output_dir"
    
    log_info "Output directory: $output_dir"
    
    # Step 5: Process all template files
    echo
    local processed=0
    for template in "${HELM_TEMPLATES_DIR}"/*.yaml; do
        if [ -f "$template" ]; then
            template_name=$(basename "$template" .yaml)
            # Remove "example." prefix from filename
            template_name=${template_name#values.example.}
            output_file="${output_dir}/values.${template_name}_${timestamp}.yaml"
            if replace_template "$template" "$output_file" "$selected_cert" "$IS_USE_TLS"; then
                ((processed++))
            else
                log_error "Failed to process template: $template"
            fi
        fi
    done
    
    if [ $processed -eq 0 ]; then
        log_error "No templates were processed successfully"
        exit 1
    fi
    
    echo
    log_success "Helm values generation completed!"
    log_info "Generated files are stored in: $output_dir"
    
    # List generated files
    echo
    log_info "Generated files:"
    ls -la "$output_dir"/*.yaml | awk '{print "  - " $NF}'
    
    # Add explanation of different YAML configurations
    echo
    echo -e "${BOLD}${BLUE}📋 Configuration Files Overview:${NC}"
    echo -e "${GREEN}┌─ quick-poc:${NC} Minimal setup with single replica pods and no CPU limits - ideal for quick validation"
    echo -e "${YELLOW}├─ test:${NC}      Balanced configuration optimized for testing environments"  
    echo -e "${RED}└─ prod:${NC}      Production-ready configuration with high availability and resource limits"
    echo
    echo -e "${BOLD}💡 Next Steps:${NC}"
    echo -e "   Choose the appropriate configuration file based on your deployment environment"
    echo -e "   and apply it using: ${BLUE}helm upgrade -i dify -f <selected-values-file> dify/dify -n dify ${NC}"
    echo
    
    run_watchdog_stage "$output_dir"
}

# Run main function
main "$@"
