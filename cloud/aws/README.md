# Dify 企业版 AWS 部署
# Dify Enterprise AWS Deployment

## ⚠️ 安全提示 | Security Notice

**生产环境部署前请务必：**
- 仔细审查所有配置参数
- 使用 `terraform plan` 检查部署计划
- 避免使用 `-auto-approve` 标志
- 确保密码和密钥的安全性
- 定期备份 Terraform 状态文件

**Before deploying to production, please:**
- Carefully review all configuration parameters
- Use `terraform plan` to check deployment plan
- Avoid using `-auto-approve` flag
- Ensure security of passwords and keys
- Regularly backup Terraform state files

## 🔧 完整部署流程
## 🔧 Complete Deployment Process

### 阶段一：部署AWS基础设施
### Stage 1: Deploy AWS Infrastructure

```bash
# 1. 克隆仓库 | Clone repository
git clone <repository-url>
cd cloud/aws

# 2. 确认权限 | Check permissions
bash scripts/1_check_aws_permissions.sh

# 3. 配置变量 | Configure variables
cp tf/terraform.tfvars.example tf/terraform.tfvars

# 编辑 terraform.tfvars 文件，设置：| Edit terraform.tfvars file and set:
# - environment = "test" 或 "prod" | "test" or "prod"
# - aws_region = "your-region"
# - aws_account_id = "your-account-id"

# 4. 部署基础设施 | Deploy infrastructure
cd tf

# 初始化 Terraform | Initialize Terraform
terraform init

# 生成并审查部署计划 | Generate and review deployment plan
terraform plan -out=tfplan

# 应用配置（推荐方式）| Apply configuration (recommended way)
terraform apply tfplan

# 或者直接应用（跳过确认）| Or apply directly (skip confirmation)
# terraform apply -auto-approve
```

### 阶段二：验证部署并生成配置
### Stage 2: Verify Deployment and Generate Configuration

```bash
# 1. 验证基础设施状态 | Verify infrastructure status

bash bash scripts/2_verify_tf_deployment.sh

# 2. 生成 Dify 部署配置 | Generate Dify deployment configuration
bash bash scripts/3_post_tf_apply.sh

bash bash scripts/4_generate_dify_helm.sh

# 编辑你自己的 value.yaml 文件，可以参考提供的 values.*.yaml 示例。
# Edit your own value.yaml file, you can refer to existed values.*yaml examples.

# 3. 获取 Dify Helm ｜ Obtain Dify Helm
helm repo add dify https://langgenius.github.io/dify-helm
 
helm repo update
helm search repo dify/dify

# 4. 安装 Dify ｜ Install Dify
helm upgrade -i dify -f values.yaml dify/dify -n dify


# 更多信息详见：https://langgenius.github.io/dify-helm/#/
# For more information, please visit https://langgenius.github.io/dify-helm/#/

```
**中国区域安装请注意**  
**Note for China Region Deployment**

因中国区不支持 DATA API 执行 RDS 数据库操作，请使用 cloud/aws/scripts/5_create_databases.sh 脚本，该脚本将通过建立集群中的临时 Pod 执行数据库创建命令。  
Since the China region does not support RDS database operations via the DATA API, please use the `cloud/aws/scripts/5_create_databases.sh` script. This script will create the databases by running commands inside a temporary Pod in your cluster.

在执行 cloud/aws/scripts/4_generate_dify_helm.sh 后，请修改 secret 文件夹中 values.yaml 中 connector 的配置，以使用中国区域镜像, 示例如下：（各版本对应示例请访问 https://helm-watchdog.dify.ai/）  
After running `cloud/aws/scripts/4_generate_dify_helm.sh`, please modify the connector configuration in the values.yaml file inside the secret folder to use China region container images. For example (refer to the corresponding version examples at https://helm-watchdog.dify.ai/):


```
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


**重要提醒 / Important Notice**

若需重新安装 Dify，**请勿直接使用 `helm uninstall dify` 再通过 `helm upgrade` 命令安装。** 由于服务账号（SA）需要由 Terraform 和 Helm 共同创建，该操作将导致 SA 配置漂移（configuration shifting），导致插件无法安装。**请务必实施“先执行 Terraform，再执行 Helm”以确保重装完成。（请注意保存数据库）**

If you need to reinstall Dify, **do NOT use `helm uninstall dify` and then `helm upgrade` to reinstall unless absolutely necessary**. The Service Account (SA) in the cluster is created by both Terraform and Helm. This operation will cause configuration shifting of the SA, resulting in plugin installation failures. **Always perform "Terraform first, then Helm"** to ensure a successful reinstallation. (Please remember to back up your database.)



### 常见问题解决
### Common Issues and Solutions

#### 1. 权限问题 | Permission Issues
```bash
# 检查AWS凭证 | Check AWS credentials
aws sts get-caller-identity

# 检查EKS访问 | Check EKS access
aws eks describe-cluster --name <cluster-name>
```

#### 2. 网络连接问题 | Network Connection Issues
```bash
# 更新kubeconfig | Update kubeconfig
aws eks update-kubeconfig --region <region> --name <cluster-name>

# 测试连接 | Test connection
kubectl get nodes
```

#### 3. Terraform状态问题 | Terraform State Issues
```bash
# 检查状态 | Check state
terraform show

# 刷新状态 | Refresh state
terraform refresh
```



## 🔄 维护和更新
## 🔄 Maintenance and Updates

### 配置更新 | Configuration Updates
```bash
# 更新Helm部署 | Update Helm deployment
helm upgrade dify -f dify_values_*.yaml dify/dify -n dify
```

### 基础设施更新 | Infrastructure Updates
```bash
# 更新Terraform配置 | Update Terraform configuration

# 1. 生成更新计划 | Generate update plan
terraform plan -out=tfplan

# 2. 审查计划内容 | Review plan content
terraform show tfplan

# 3. 应用更新 | Apply updates
terraform apply tfplan

# 或者直接应用（生产环境不推荐）| Or apply directly (not recommended for production)
# terraform apply -auto-approve


## 🗑️ 资源清理
## 🗑️ Resource Cleanup

```bash
# 删除Dify应用 | Delete Dify application
helm uninstall dify -n dify

# 删除基础设施 | Delete infrastructure
cd tf

# 1. 生成销毁计划 | Generate destroy plan
terraform plan -destroy -out=destroy.tfplan

# 2. 审查销毁计划 | Review destroy plan
terraform show destroy.tfplan

# 3. 执行销毁 | Execute destruction
terraform apply destroy.tfplan

# 或者直接销毁（谨慎使用）| Or destroy directly (use with caution)
# terraform destroy -auto-approve

# 注意：可能需要手动清理 S3、RDS Secret 和 ELB
# Note: You may need to manually clean up S3, RDS secrets, and ELB
```

⚠️ **警告**: 此操作将永久删除所有数据，请先备份重要信息。
⚠️ **Warning**: This operation will permanently delete all data. Please backup important information first.

## 🔒 安全注意事项
## 🔒 Security Considerations

### 敏感文件管理 | Sensitive File Management
- 生成的配置文件包含密码和密钥 | Generated configuration files contain passwords and keys
- 文件权限自动设置为600 | File permissions are automatically set to 600
- 不要提交敏感文件到版本控制 | Do not commit sensitive files to version control

### 密钥轮换 | Key Rotation
```bash
# 定期更换数据库密码 | Regularly change database passwords
# 更新API密钥和应用密钥 | Update API keys and application keys
# 轮换IRSA角色权限 | Rotate IRSA role permissions
```

### 域名配置 | Domain Configuration
```bash
# 修改所有默认域名 | Modify all default domain names
consoleApiDomain: "console.your-company.com"
serviceApiDomain: "api.your-company.com"
appApiDomain: "app.your-company.com"
```

## 📋 TODO 和未来改进
## 📋 TODO and Future Improvements

### Terraform State 管理 | Terraform State Management
- [ ] **配置 S3 后端存储**: 将 Terraform state 持久化存储到 S3，支持团队协作和状态备份
- [ ] **配置 DynamoDB 锁**: 使用 DynamoDB 实现状态锁定，防止并发操作冲突
- [ ] **配置状态加密**: 启用 S3 服务器端加密保护敏感状态信息

**配置示例 | Configuration Example:**
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

### 其他改进项 | Other Improvements
- [ ] **多环境支持**: 支持 dev/staging/prod 环境分离
- [ ] **模块化重构**: 将基础设施代码拆分为可重用的 Terraform 模块
- [ ] **监控和告警**: 集成 CloudWatch 监控和 SNS 告警
- [ ] **成本优化**: 添加资源标签和成本分配策略

## 📖 参考文档
## 📖 Reference Documentation

- [Dify企业版官方文档 | Dify Enterprise Official Documentation](https://enterprise-docs.dify.ai/)
- [Helm Chart配置 | Helm Chart Configuration](https://langgenius.github.io/dify-helm/)
- [AWS EKS文档 | AWS EKS Documentation](https://docs.aws.amazon.com/eks/)
- [Kubernetes IRSA配置 | Kubernetes IRSA Configuration](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)



## 🆘 支持
## 🆘 Support

如遇到问题，请：| If you encounter issues, please:
1. 运行验证脚本检查资源状态 | Run verification scripts to check resource status
2. 查看生成的验证报告 | Review generated verification reports
3. 检查CloudWatch日志 | Check CloudWatch logs
4. 在GitHub上创建Issue并提供详细信息 | Create an Issue on GitHub with detailed information

## AWS 中国区部署

- 请手动在 values.yaml 设置镜像源
- 由于中国区不支持 RDS Data API， 请在创建 RDS 后手动创建所需的数据库。

