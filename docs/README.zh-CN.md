# Dify 企业版 AWS 部署

> **工作目录** — 本文档中所有 shell 命令和相对路径，除非明确以 `cloud/aws/` 开头，否则都假定你已经先 `cd cloud/aws/`。

## ⚠️ 安全提示

**生产环境部署前请务必：**
- 仔细审查所有配置参数
- 使用 `terraform plan` 检查部署计划
- 避免使用 `-auto-approve` 标志
- 确保密码和密钥的安全性
- 定期备份 Terraform 状态文件

## 📜 许可与适用范围

本仓库的脚本与 Terraform 代码用于在 AWS 上配置运行 **Dify Enterprise** 所需的基础设施。基础设施代码本身基于 **Apache License 2.0** 开源（见 `LICENSE`），可自由使用、修改、分发。

**但 Dify Enterprise 软件本身并非 Apache 2.0 协议授权**，其使用受单独的商业许可协议约束。请通过 Dify Enterprise 官方渠道获取许可与镜像访问权限，并自行确认你的使用方式符合该协议。本仓库仅提供基础设施编排脚本，不授予 Dify Enterprise 软件的任何许可。

## 🧩 部署前需要替换的变量

在执行 `terraform apply` 之前，请将 `cloud/aws/tf/terraform.tfvars`（从 `terraform.tfvars.example` 复制而来）中的以下占位符替换为你的真实值。完整变量清单请见 `cloud/aws/tf/terraform.tfvars.example`。

| 变量 | 示例 | 说明 |
|---|---|---|
| `aws_account_id` | `"123456789012"` | 你的 AWS 账户 ID |
| `aws_region` | `"us-east-1"` / `"cn-northwest-1"` | 部署区域；中国区使用 `cn-north-1` 或 `cn-northwest-1` |
| `deployment_id` | `"dev1"` | 本次部署的唯一标识，3–15 字符，仅小写字母、数字、连字符 |
| `environment` | `"test"` 或 `"prod"` | 影响节点规模与 Redis 高可用配置 |
| `eks_arch` | `"amd64"` 或 `"arm64"` | 节点 CPU 架构 |
| `vpc_cidr` | `"10.0.0.0/16"` | 仅在 `use_existing_vpc = false` 时使用 |
| `vpc_id` + `existing_vpc_subnets` | `"vpc-xxxxxxxx"` + 子网 ID 列表 | 仅在 `use_existing_vpc = true` 时使用，需要至少 2 个不同 AZ 的私有子网 |
| `elb_mode` | `"internet-facing"` 或 `"internal"` | 负载均衡暴露模式 |
| `db_master_password` | **请改为强密码** | Aurora 主密码，请勿保留示例值 |
| `opensearch_master_user_password` | **请改为强密码** | OpenSearch 主用户密码，请勿保留示例值 |

> 提示：所有密码类字段在示例文件中给出的都是占位字符串，请务必替换；生成的 `secret/` 目录下的派生配置会沿用这些值。

## 🔧 完整部署流程

### 阶段一：部署 AWS 基础设施

```bash
# 1. 克隆仓库
git clone <repository-url>
cd cloud/aws

# 2. 确认权限
bash scripts/1_check_aws_permissions.sh

# 3. 配置变量
cp tf/terraform.tfvars.example tf/terraform.tfvars

# 编辑 terraform.tfvars 文件，设置：
# - environment = "test" 或 "prod"
# - aws_region = "your-region"
# - aws_account_id = "your-account-id"

# 4. 部署基础设施
cd tf

# 初始化 Terraform
terraform init

# 生成并审查部署计划
terraform plan -out=tfplan

# 应用配置（推荐方式）
terraform apply tfplan

# 或者直接应用（跳过确认）
# terraform apply -auto-approve
```

### 阶段二：验证部署并生成配置

```bash
# 1. 验证基础设施状态

bash scripts/2_verify_tf_deployment.sh

# 2. 生成 Dify 部署配置
bash scripts/3_post_tf_apply.sh

bash scripts/4_generate_dify_helm.sh

# 编辑你自己的 value.yaml 文件，可以参考提供的 values.*.yaml 示例。

# 3. 获取 Dify Helm
helm repo add dify https://langgenius.github.io/dify-helm
 
helm repo update
helm search repo dify/dify

# 4. 安装 Dify
helm upgrade -i dify -f values.yaml dify/dify -n dify


# 更多信息详见：https://langgenius.github.io/dify-helm/#/

```
**中国区域安装请注意**

因中国区不支持 DATA API 执行 RDS 数据库操作，请使用 `cloud/aws/scripts/5_create_databases.sh` 脚本，该脚本将通过建立集群中的临时 Pod 执行数据库创建命令。

在执行 `cloud/aws/scripts/4_generate_dify_helm.sh` 后，请修改 `secret` 文件夹中 `values.yaml` 中 connector 的配置，以使用中国区域镜像，示例如下：（各版本对应示例请访问 https://helm-watchdog.dify.ai/）

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


**重要提醒**

若需重新安装 Dify，**请勿直接使用 `helm uninstall dify` 再通过 `helm upgrade` 命令安装。** 由于服务账号（SA）需要由 Terraform 和 Helm 共同创建，该操作将导致 SA 配置漂移（configuration shifting），导致插件无法安装。**请务必实施 "先执行 Terraform，再执行 Helm" 以确保重装完成。（请注意保存数据库）**



### 常见问题解决

#### 1. 权限问题
```bash
# 检查 AWS 凭证
aws sts get-caller-identity

# 检查 EKS 访问
aws eks describe-cluster --name <cluster-name>
```

#### 2. 网络连接问题
```bash
# 更新 kubeconfig
aws eks update-kubeconfig --region <region> --name <cluster-name>

# 测试连接
kubectl get nodes
```

#### 3. Terraform 状态问题
```bash
# 检查状态
terraform show

# 刷新状态
terraform refresh
```



## 🔄 维护和更新

### 配置更新
```bash
# 更新 Helm 部署
helm upgrade dify -f dify_values_*.yaml dify/dify -n dify
```

### 基础设施更新
```bash
# 更新 Terraform 配置

# 1. 生成更新计划
terraform plan -out=tfplan

# 2. 审查计划内容
terraform show tfplan

# 3. 应用更新
terraform apply tfplan

# 或者直接应用（生产环境不推荐）
# terraform apply -auto-approve


## 🗑️ 资源清理

```bash
# 删除 Dify 应用
helm uninstall dify -n dify

# 删除基础设施
cd tf

# 1. 生成销毁计划
terraform plan -destroy -out=destroy.tfplan

# 2. 审查销毁计划
terraform show destroy.tfplan

# 3. 执行销毁
terraform apply destroy.tfplan

# 或者直接销毁（谨慎使用）
# terraform destroy -auto-approve

# 注意：可能需要手动清理 S3、RDS Secret 和 ELB
```

⚠️ **警告**: 此操作将永久删除所有数据，请先备份重要信息。

## 🔒 安全注意事项

### 敏感文件管理
- 生成的配置文件包含密码和密钥
- 文件权限自动设置为 600
- 不要提交敏感文件到版本控制

### 密钥轮换
```bash
# 定期更换数据库密码
# 更新 API 密钥和应用密钥
# 轮换 IRSA 角色权限
```

### 域名配置
```bash
# 修改所有默认域名
consoleApiDomain: "console.your-company.com"
serviceApiDomain: "api.your-company.com"
appApiDomain: "app.your-company.com"
```

## 📋 TODO 与未来改进

### Terraform State 管理
- [ ] **配置 S3 后端存储**: 将 Terraform state 持久化存储到 S3，支持团队协作和状态备份
- [ ] **配置 DynamoDB 锁**: 使用 DynamoDB 实现状态锁定，防止并发操作冲突
- [ ] **配置状态加密**: 启用 S3 服务器端加密保护敏感状态信息

**配置示例：**
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

### 其他改进项
- [ ] **多环境支持**: 支持 dev/staging/prod 环境分离
- [ ] **模块化重构**: 将基础设施代码拆分为可重用的 Terraform 模块
- [ ] **监控和告警**: 集成 CloudWatch 监控和 SNS 告警
- [ ] **成本优化**: 添加资源标签和成本分配策略

## 📖 参考文档

- [Dify 企业版官方文档](https://enterprise-docs.dify.ai/)
- [Helm Chart 配置](https://langgenius.github.io/dify-helm/)
- [AWS EKS 文档](https://docs.aws.amazon.com/eks/)
- [Kubernetes IRSA 配置](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)



## 🆘 支持

如遇到问题，请：
1. 运行验证脚本检查资源状态
2. 查看生成的验证报告
3. 检查 CloudWatch 日志
4. 在 GitHub 上创建 Issue 并提供详细信息

## AWS 中国区部署

- 请手动在 values.yaml 设置镜像源
- 由于中国区不支持 RDS Data API， 请在创建 RDS 后手动创建所需的数据库。
