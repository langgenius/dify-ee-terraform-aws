# Dify Enterprise AWS Deployment

[🇨🇳 中文文档 / Chinese Documentation](docs/README.zh-CN.md)

> **Working directory** — All shell commands and relative paths in this guide assume you have `cd cloud/aws/` first, unless prefixed with `cloud/aws/` explicitly.

## ⚠️ Security Notice

**Before deploying to production, please:**
- Carefully review all configuration parameters
- Use `terraform plan` to check the deployment plan
- Avoid using the `-auto-approve` flag
- Ensure security of passwords and keys
- Regularly back up Terraform state files

## 📜 License & Scope

The scripts and Terraform code in this repository are used to provision the AWS infrastructure required to run **Dify Enterprise**. The infrastructure code itself is open-sourced under the **Apache License 2.0** (see `LICENSE`) — you are free to use, modify, and distribute it.

**However, the Dify Enterprise software itself is NOT licensed under Apache 2.0.** Its use is governed by a separate commercial license. Please obtain the license and image access through official Dify Enterprise channels and ensure your usage complies with that agreement. This repository only provides infrastructure orchestration scripts; it does NOT grant any license to the Dify Enterprise software.

## 🧩 Required Placeholders Before Deployment

Before running `terraform apply`, replace the following placeholders in `cloud/aws/tf/terraform.tfvars` (copied from `terraform.tfvars.example`) with your actual values. For the full list of available variables, see `cloud/aws/tf/terraform.tfvars.example`.

| Variable | Example | Description |
|---|---|---|
| `aws_account_id` | `"123456789012"` | Your AWS account ID |
| `aws_region` | `"us-east-1"` / `"cn-northwest-1"` | Target region; for China use `cn-north-1` or `cn-northwest-1` |
| `deployment_id` | `"dev1"` | Unique deployment identifier (3–15 chars, lowercase alphanumeric + hyphens) |
| `environment` | `"test"` or `"prod"` | Drives node sizing and Redis HA |
| `eks_arch` | `"amd64"` or `"arm64"` | Node CPU architecture |
| `vpc_cidr` | `"10.0.0.0/16"` | Only used when `use_existing_vpc = false` |
| `vpc_id` + `existing_vpc_subnets` | `"vpc-xxxxxxxx"` + subnet ID list | Only used when `use_existing_vpc = true`; requires at least 2 private subnets in different AZs |
| `elb_mode` | `"internet-facing"` or `"internal"` | Load balancer exposure mode |
| `nat_availability_mode` | `"zonal"` (default) or `"regional"` | Only used when `use_existing_vpc = false`. `"regional"` provisions a multi-AZ Regional NAT Gateway, removing the single-AZ egress SPOF — recommended for `environment = "prod"`. Forced to `"zonal"` in China regions |
| `db_master_password` | **replace with strong password** | Aurora master password — do NOT keep the sample value |
| `opensearch_master_user_password` | **replace with strong password** | OpenSearch master password — do NOT keep the sample value |

> **Tip:** All password fields in the example file are placeholder strings — make sure to replace them. Derived configs under `secret/` will inherit these values.

## 🔧 Complete Deployment Process

### Stage 1: Deploy AWS Infrastructure

```bash
# 1. Clone repository
git clone <repository-url>
cd cloud/aws

# 2. Check permissions
bash scripts/1_check_aws_permissions.sh

# 3. Configure variables
cp tf/terraform.tfvars.example tf/terraform.tfvars

# Edit terraform.tfvars and set:
# - environment = "test" or "prod"
# - aws_region = "your-region"
# - aws_account_id = "your-account-id"

# 4. Deploy infrastructure
cd tf

# Initialize Terraform
terraform init

# Generate and review deployment plan
terraform plan -out=tfplan

# Apply configuration (recommended)
terraform apply tfplan

# Or apply directly (skip confirmation)
# terraform apply -auto-approve
```

### Stage 2: Verify Deployment and Generate Configuration

```bash
# 1. Verify infrastructure status
bash scripts/2_verify_tf_deployment.sh

# 2. Generate Dify deployment configuration
bash scripts/3_post_tf_apply.sh
bash scripts/4_generate_dify_helm.sh

# Edit your own value.yaml file; refer to the provided values.*.yaml examples.

# 3. Add the Dify Helm repo
helm repo add dify https://langgenius.github.io/dify-helm

helm repo update
helm search repo dify/dify

# 4. Install Dify
helm upgrade -i dify -f values.yaml dify/dify -n dify

# For more information, visit https://langgenius.github.io/dify-helm/#/
```

**Note for China Region Deployment**

Since the China region does not support RDS database operations via the DATA API, please use the `cloud/aws/scripts/5_create_databases.sh` script. This script will create the databases by running commands inside a temporary Pod in your cluster.

After running `cloud/aws/scripts/4_generate_dify_helm.sh`, modify the connector configuration in the `values.yaml` file inside the `secret` folder to use China region container images. For example (refer to the corresponding version examples at https://helm-watchdog.dify.ai/):

```yaml
  gatewayImage: "g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/nginx:1.27.3"
  shaderImage: "g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/executor:latest"
  busyBoxImage: "g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/busybox:latest"
  awsCliImage: "g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/aws-cli:latest"
  generatorConf: |
      generator:
        repo: langgenius
        python:
          pipMirror: ""
          preCompile: true
          versions:
            python3.13:
              langgenius: g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/plugin-build-base-python:3.13
            python3.12:
              langgenius: g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/plugin-build-base-python:3.12
            python3.11:
              langgenius: g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/plugin-build-base-python:3.11
            python3.10:
              langgenius: g-hsod9681-docker.pkg.coding.net/dify-artifact/dify/plugin-build-base-python:3.10
```

**Important Notice**

If you need to reinstall Dify, **do NOT use `helm uninstall dify` and then `helm upgrade` to reinstall unless absolutely necessary**. The Service Account (SA) in the cluster is created by both Terraform and Helm. This operation will cause configuration shifting of the SA, resulting in plugin installation failures. **Always perform "Terraform first, then Helm"** to ensure a successful reinstallation. (Please remember to back up your database.)

### Common Issues and Solutions

#### 1. Permission Issues
```bash
# Check AWS credentials
aws sts get-caller-identity

# Check EKS access
aws eks describe-cluster --name <cluster-name>
```

#### 2. Network Connection Issues
```bash
# Update kubeconfig
aws eks update-kubeconfig --region <region> --name <cluster-name>

# Test connection
kubectl get nodes
```

#### 3. Terraform State Issues
```bash
# Check state
terraform show

# Refresh state
terraform refresh
```

## 🔄 Maintenance and Updates

### Configuration Updates
```bash
# Update Helm deployment
helm upgrade dify -f dify_values_*.yaml dify/dify -n dify
```

### Infrastructure Updates
```bash
# Update Terraform configuration

# 1. Generate update plan
terraform plan -out=tfplan

# 2. Review plan content
terraform show tfplan

# 3. Apply updates
terraform apply tfplan

# Or apply directly (not recommended for production)
# terraform apply -auto-approve
```

## 🗑️ Resource Cleanup

```bash
# Delete Dify application
helm uninstall dify -n dify

# Delete infrastructure
cd tf

# 1. Generate destroy plan
terraform plan -destroy -out=destroy.tfplan

# 2. Review destroy plan
terraform show destroy.tfplan

# 3. Execute destruction
terraform apply destroy.tfplan

# Or destroy directly (use with caution)
# terraform destroy -auto-approve

# Note: You may need to manually clean up S3, RDS secrets, and ELB
```

⚠️ **Warning**: This operation will permanently delete all data. Please back up important information first.

## 🔒 Security Considerations

### Sensitive File Management
- Generated configuration files contain passwords and keys
- File permissions are automatically set to 600
- Do not commit sensitive files to version control

### Key Rotation
```bash
# Regularly change database passwords
# Update API keys and application keys
# Rotate IRSA role permissions
```

### Domain Configuration
```bash
# Modify all default domain names
consoleApiDomain: "console.your-company.com"
serviceApiDomain: "api.your-company.com"
appApiDomain: "app.your-company.com"
```

## 📋 TODO and Future Improvements

### Terraform State Management
- [ ] **Configure S3 backend storage**: Persist Terraform state to S3 for team collaboration and state backup
- [ ] **Configure DynamoDB locking**: Use DynamoDB for state locking to prevent concurrent operation conflicts
- [ ] **Configure state encryption**: Enable S3 server-side encryption to protect sensitive state information

**Configuration Example:**
```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "dify-ee/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

### Other Improvements
- [ ] **Multi-environment support**: Separate dev/staging/prod environments
- [ ] **Modular refactoring**: Split infrastructure code into reusable Terraform modules
- [ ] **Monitoring and alerting**: Integrate CloudWatch monitoring and SNS alerts
- [ ] **Cost optimization**: Add resource tags and cost allocation strategies

## 📖 Reference Documentation

- [Dify Enterprise Official Documentation](https://enterprise-docs.dify.ai/)
- [Helm Chart Configuration](https://langgenius.github.io/dify-helm/)
- [AWS EKS Documentation](https://docs.aws.amazon.com/eks/)
- [Kubernetes IRSA Configuration](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

## 🆘 Support

If you encounter issues, please:
1. Run verification scripts to check resource status
2. Review generated verification reports
3. Check CloudWatch logs
4. Create an Issue on GitHub with detailed information

## AWS China Region Deployment

- Manually set container image sources in `values.yaml`
- Since the China region does not support the RDS Data API, manually create the required databases after provisioning RDS.
