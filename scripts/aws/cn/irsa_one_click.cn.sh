#!/bin/bash
set -euo pipefail

error_handler() {
  local lineno=$1
  local msg=$2
  echo "❌ Error on or near line ${lineno}: ${msg}"
  exit 1
}

trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR

# AWS China partition identifier
AWS_PARTITION="aws-cn"

# ──────────────── Input Section ────────────────
# Prompt for AWS China region (must be valid, default: cn-north-1)
echo "📍 AWS 中国区可用区域: cn-north-1 (北京), cn-northwest-1 (宁夏)"
while true; do
  read -rp "AWS 中国区 region [默认: cn-north-1]: " region
  region=${region:-cn-north-1}

  # Validate China regions
  if [[ "$region" == "cn-north-1" || "$region" == "cn-northwest-1" ]]; then
    if AWS_PAGER="" aws ec2 describe-regions --region "$region" --query "Regions[].RegionName" --output text 2>/dev/null | grep -wq "$region"; then
      echo "✅ 已选择 AWS 中国区: $region"
      break
    else
      echo "❌ 无法访问区域 '$region'。请检查您的 AWS 中国区凭证配置。"
    fi
  else
    echo "❌ 无效的中国区 region。请输入 'cn-north-1' 或 'cn-northwest-1'。"
  fi
done


# Prompt for EKS cluster name (must exist, not empty)
while true; do
  read -rp "EKS 集群名称 (必须已存在): " cluster_name
  if [[ -z "$cluster_name" ]]; then
    echo "❌ 集群名称不能为空。"
    continue
  fi

  if aws eks describe-cluster --name "$cluster_name" --region "$region" >/dev/null 2>&1; then
    # 获取集群 ARN (中国区使用 aws-cn 分区)
    cluster_arn=$(aws eks describe-cluster \
      --name "$cluster_name" \
      --region "$region" \
      --query "cluster.arn" \
      --output text)

    echo "✅ 找到集群 '$cluster_name'。"
    echo "🔗 集群 ARN: $cluster_arn"
    break
  else
    echo "❌ 集群 '$cluster_name' 在区域 '$region' 中不存在。请重新输入。"
  fi
done


# Prompt for S3 bucket name (must exist, not empty)
while true; do
  read -rp "S3 存储桶名称 (必须已存在): " bucket_name
  if [[ -z "$bucket_name" ]]; then
    echo "❌ 存储桶名称不能为空。"
    continue
  fi
  if AWS_PAGER="" aws s3api head-bucket --bucket "$bucket_name" >/dev/null 2>&1; then
    echo "✅ 找到 S3 存储桶 '$bucket_name'。"
    break
  else
    echo "❌ 存储桶 '$bucket_name' 不存在或您没有访问权限。请重新输入。"
  fi
done

# IAM roles name 
# Set fixed IAM role names based on cluster name
s3_role_name="DifyEE-Role-${cluster_name}-s3"
s3_ecr_role_name="DifyEE-Role-${cluster_name}-s3-ecr"
ecr_pull_role_name="DifyEE-Role-${cluster_name}-ecr-image-pull"

# Default ECR repo name based on cluster name
default_repo_name="dify-ee-plugin-repo-$(echo "$cluster_name" | tr '[:upper:]' '[:lower:]')"

# Prompt for ECR repo name (non-empty, format check, default supported)
while true; do
  read -rp "ECR 仓库名称 (将在不存在时创建) [默认: ${default_repo_name}]: " repo_name
  repo_name=${repo_name:-$default_repo_name}

  if [[ -z "$repo_name" ]]; then
    echo "❌ 仓库名称不能为空。"
    continue
  fi

  if [[ ! "$repo_name" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
    echo "❌ 无效的 ECR 仓库名称。只允许使用字母、数字、'.'、'_'、'/' 和 '-'。"
    continue
  fi

  if aws ecr describe-repositories --repository-names "$repo_name" --region "$region" >/dev/null 2>&1; then
    echo "ℹ️  ECR 仓库 '$repo_name' 已存在，将复用该仓库。"
  else
    echo "✅ ECR 仓库 '$repo_name' 将被创建。"
  fi
  break
done

account_id=$(aws sts get-caller-identity --query Account --output text)

# ──────────────── Preview all input variables ────────────────
echo ""
echo "=========== 配置预览 ==========="
echo "AWS 区域           : $region"
echo "AWS 分区           : $AWS_PARTITION"
echo "AWS 账户 ID        : $account_id"
echo "EKS 集群名称       : $cluster_name"
echo "S3 存储桶名称      : $bucket_name"
echo "ECR 仓库名称       : $repo_name"
echo "================================"
echo "以下 IAM 角色将被使用或创建："
echo "1. S3 角色:                $s3_role_name"
echo "2. S3 + ECR 角色:          $s3_ecr_role_name"
echo "3. ECR 镜像拉取角色:        $ecr_pull_role_name"
echo "================================"

read -rp "是否继续执行上述配置? [Y/n]: " config_confirm
config_confirm=$(echo "$config_confirm" | tr '[:upper:]' '[:lower:]')

if [[ -n "$config_confirm" && "$config_confirm" != "y" ]]; then
  echo "❌ 用户取消操作。"
  exit 1
fi

# ──────────────── Create ECR ────────────────
if aws ecr describe-repositories --repository-names "${repo_name}" --region "${region}" >/dev/null 2>&1; then
  echo "ℹ️  ECR 仓库 '${repo_name}' 已存在。复用现有仓库。"
else
  echo "📦 ECR 仓库 '${repo_name}' 未找到。正在创建..."
  aws ecr create-repository --repository-name "${repo_name}" --region "${region}"
  echo "✅ ECR 仓库 '${repo_name}' 已创建。"
fi

# ──────────────── OIDC Setup ────────────────
echo "正在解析集群 '${cluster_name}' 的 OIDC 提供商..."
oidc_issuer=$(aws eks describe-cluster \
  --name "${cluster_name}" \
  --region "${region}" \
  --query "cluster.identity.oidc.issuer" \
  --output text)

oidc_provider="${oidc_issuer/https:\/\//}"
echo "OIDC 提供商: ${oidc_provider}"
oidc_id=$(echo "${oidc_issuer}" | cut -d'/' -f5)
oidc_provider_arn=$(aws iam list-open-id-connect-providers \
  | grep "${oidc_id}" \
  | awk -F'"' '{print $4}')

if [[ -z "${oidc_provider_arn}" ]]; then
  echo "❌ 未找到 OIDC 提供商。请确保已为此集群启用 IAM OIDC 提供商。"
  exit 1
fi
echo "OIDC 提供商 ARN: ${oidc_provider_arn}"
echo "OIDC ID: ${oidc_id}"

# ──────────────── Create Role ────────────────

# Function to create or reuse IAM role
create_or_refresh_iam_role() {
  local role_name="$1"
  trust_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { 
          "Federated": "${oidc_provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity"
    }
  ]
}
EOF
)
  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    echo "🔄 IAM 角色 '$role_name' 已存在。将复用该角色..."
    role_arn=$(aws iam get-role \
    --role-name "${role_name}" \
    --query 'Role.Arn' \
    --output text)
  else
    echo "🚀 正在创建 IAM 角色 '$role_name'..."
    role_arn=$(aws iam create-role \
    --role-name "${role_name}" \
    --assume-role-policy-document "${trust_policy}" \
    --description "irsa role for Dify EE (AWS China)" \
    --query 'Role.Arn' \
    --output text)
    echo "✅ IAM 角色已创建: $role_arn"
  fi
}

# Create or update each role
for role in "$s3_role_name" "$s3_ecr_role_name" "$ecr_pull_role_name"; do
  create_or_refresh_iam_role "$role"
done


# ──────────────── S3 Policy (China) ────────────────
s3_policy_json=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": "arn:${AWS_PARTITION}:s3:::${bucket_name}/*"
    }
  ]
}
EOF
)

# ──────────────── ECR Policy (China) ────────────────
ecr_policy_json=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:*",
                "cloudtrail:LookupEvents"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

# ──────────────── ECR Pull Only Policy ────────────────
ecr_pull_only_policy_json=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)


s3_policy_name="dify-ee-irsa-${cluster_name}-s3-policy"
ecr_policy_name="dify-ee-irsa-${cluster_name}-ecr-policy"
ecr_pull_only_policy_name="dify-ee-irsa-${cluster_name}-ecr-pull-only-policy"

# ──────────────── Preview ────────────────
echo ""
echo "──── IAM 策略预览 ────"
echo "[S3 策略: ${s3_policy_name}]"
echo "${s3_policy_json}" | jq .
echo
echo "[ECR 策略: ${ecr_policy_name}]"
echo "${ecr_policy_json}" | jq .
echo
echo "[ECR 拉取策略: ${ecr_pull_only_policy_name}]"
echo "${ecr_pull_only_policy_json}" | jq .
echo "─────────────────────────────"

read -rp "是否继续创建策略? (y/N): " preview_confirm
preview_confirm=$(echo "$preview_confirm" | tr '[:upper:]' '[:lower:]')

if [[ "$preview_confirm" != "y" ]]; then
  echo "❌ 用户取消操作。"
  exit 1
fi

# ──────────────── Create S3 Policy ────────────────
# Check if S3 policy already exists (China ARN format)
if aws iam get-policy --policy-arn "arn:${AWS_PARTITION}:iam::${account_id}:policy/${s3_policy_name}" >/dev/null 2>&1; then
  echo "ℹ️  策略 '${s3_policy_name}' 已存在。将复用该策略。"
  s3_policy_arn="arn:${AWS_PARTITION}:iam::${account_id}:policy/${s3_policy_name}"
else
  echo "📜 正在创建 IAM 策略 '${s3_policy_name}'..."
  s3_policy_arn=$(aws iam create-policy \
    --policy-name "${s3_policy_name}" \
    --policy-document "${s3_policy_json}" \
    --query 'Policy.Arn' \
    --output text)
  echo "✅ 已创建策略: ${s3_policy_arn}"
fi

# ──────────────── Create ECR Policy ────────────────
# Check if ECR policy already exists (China ARN format)
if aws iam get-policy --policy-arn "arn:${AWS_PARTITION}:iam::${account_id}:policy/${ecr_policy_name}" >/dev/null 2>&1; then
  echo "ℹ️  策略 '${ecr_policy_name}' 已存在。将复用该策略。"
  ecr_policy_arn="arn:${AWS_PARTITION}:iam::${account_id}:policy/${ecr_policy_name}"
else
  echo "📜 正在创建 IAM 策略 '${ecr_policy_name}'..."
  ecr_policy_arn=$(aws iam create-policy \
    --policy-name "${ecr_policy_name}" \
    --policy-document "${ecr_policy_json}" \
    --query 'Policy.Arn' \
    --output text)
  echo "✅ 已创建策略: ${ecr_policy_arn}"
fi

# ──────────────── Create ECR Pull Only Policy ────────────────
# Check if ECR pull only policy already exists (China ARN format)
if aws iam get-policy --policy-arn "arn:${AWS_PARTITION}:iam::${account_id}:policy/${ecr_pull_only_policy_name}" >/dev/null 2>&1; then
  echo "ℹ️  策略 '${ecr_pull_only_policy_name}' 已存在。将复用该策略。"
  ecr_pull_only_policy_arn="arn:${AWS_PARTITION}:iam::${account_id}:policy/${ecr_pull_only_policy_name}"
else
  echo "📜 正在创建 IAM 策略 '${ecr_pull_only_policy_name}'..."
  ecr_pull_only_policy_arn=$(aws iam create-policy \
    --policy-name "${ecr_pull_only_policy_name}" \
    --policy-document "${ecr_pull_only_policy_json}" \
    --query 'Policy.Arn' \
    --output text)
  echo "✅ 已创建策略: ${ecr_pull_only_policy_arn}"
fi


attach_policy_to_role() {
  local role_name="$1"
  shift
  local policy_names=("$@")

  for policy_name in "${policy_names[@]}"; do
    echo "🔗 正在将策略 '${policy_name}' 附加到角色 '${role_name}'..."
    aws iam attach-role-policy \
      --role-name "${role_name}" \
      --policy-arn "arn:${AWS_PARTITION}:iam::${account_id}:policy/${policy_name}"
  done
}

# Attach policies to roles
attach_policy_to_role "$s3_role_name" "$s3_policy_name"
attach_policy_to_role "$s3_ecr_role_name" "$ecr_policy_name" "$s3_policy_name"
attach_policy_to_role "$ecr_pull_role_name" "$ecr_pull_only_policy_name"

# ──────────────── Output ECR repo (China domain) ────────────────
repo_uri="${account_id}.dkr.ecr.${region}.amazonaws.com.cn/${repo_name}"

cat <<EOM

✅ 完成！
──────────────────────────────────────────────
AWS 区域           : ${region}
AWS 分区           : ${AWS_PARTITION}
EKS 集群名称       : ${cluster_name}
ECR 仓库名称       : ${repo_name}
S3 存储桶          : ${bucket_name}
──────────────────────────────────────────────
ECR 仓库地址       : ${repo_uri}
──────────────────────────────────────────────
EOM

echo "🎯 最终 IAM 角色 ARN："
echo "──────────────────────────────────────────────"
for role_name in "$s3_role_name" "$s3_ecr_role_name" "$ecr_pull_role_name"; do
  role_arn=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)
  echo "  - $role_name: $role_arn"
done
echo "──────────────────────────────────────────────"

# Prompt for namespace (default to 'default')
read -rp "ServiceAccount 的命名空间 [默认: default]: " sa_namespace
sa_namespace=${sa_namespace:-default}

echo ""
echo "📦 已确认命名空间: $sa_namespace"

echo ""
echo "🔧 请确认或自定义命名空间 '$sa_namespace' 中的 ServiceAccount 名称："

read -rp "dify-api 的 ServiceAccount [默认: dify-api-sa]: " sa_api
sa_api=${sa_api:-dify-api-sa}

read -rp "dify-plugin-crd 的 ServiceAccount [默认: dify-plugin-crd-sa]: " sa_crd
sa_crd=${sa_crd:-dify-plugin-crd-sa}

read -rp "dify-plugin-runner 的 ServiceAccount [默认: dify-plugin-runner-sa]: " sa_runner
sa_runner=${sa_runner:-dify-plugin-runner-sa}

# ─── Get current cluster name from kubectl context ───
current_context=$(kubectl config current-context)
echo "🔎 kubectl 当前指向集群 '$current_context'"

# ─── Compare current with target ───
if [[ "$current_context" != "$cluster_arn" ]]; then
  echo "⚠️  您当前的 kubectl context 指向集群: $current_context"
  echo "🔁 但您指定的目标集群是: $cluster_name"

  while true; do
    read -rp "❓ 是否要将 kubectl 切换到 '$cluster_name'? [Y/n]: " switch
    switch=${switch:-Y}
    if [[ "$switch" =~ ^[Yy]$ ]]; then
      echo "🔄 正在切换 context..."
      aws eks update-kubeconfig --name "$cluster_name" --region "$region"
      echo "✅ kubectl context 已切换到 '$cluster_name'"
      break
    elif [[ "$switch" =~ ^[Nn]$ ]]; then
      echo "❌ 已取消。请手动切换集群或使用正确的集群重新运行。"
      exit 1
    else
      echo "❗ 请输入 Y 或 N。"
    fi
  done
else
  echo "✅ kubectl 已经指向 EKS 集群 '$cluster_name'"
fi

assign_role_to_sa() {
  local role_name="$1"
  local sa_name="$2"
  local namespace="$3"
  local role_arn="arn:${AWS_PARTITION}:iam::${account_id}:role/${role_name}"

  echo ""
  echo "🔍 检查 ServiceAccount '$sa_name' 是否存在于命名空间 '$namespace'..."
  if kubectl get sa "$sa_name" -n "$namespace" >/dev/null 2>&1; then
    echo "✅ ServiceAccount '$sa_name' 已存在于 '$namespace'。"
  else
    echo "🚀 正在创建 ServiceAccount '$sa_name' 于 '$namespace'..."
    kubectl create sa "$sa_name" -n "$namespace"
    echo "✅ ServiceAccount '$sa_name' 已创建。"
  fi
  echo "🔗 正在为 '$sa_name' 添加 IRSA 角色注解..."
  kubectl annotate serviceaccount "$sa_name" \
    -n "$namespace" \
    eks.amazonaws.com/role-arn="$role_arn" \
    --overwrite
  echo "✅ ServiceAccount '$sa_name' 已配置 IRSA 角色"
}

assign_role_to_sa "$s3_role_name" "$sa_api" "$sa_namespace"
assign_role_to_sa "$s3_ecr_role_name" "$sa_crd" "$sa_namespace"
assign_role_to_sa "$ecr_pull_role_name" "$sa_runner" "$sa_namespace"

echo ""
echo "🎉 所有操作已完成！"
echo ""
echo "📝 重要提示（AWS 中国区）："
echo "  1. ECR 域名后缀为: .amazonaws.com.cn"
echo "  2. 所有 ARN 使用 arn:aws-cn 前缀"
echo "  3. 请确保 Helm values 中配置正确的中国区域和 ECR 地址"
echo "  4. 登录 ECR 命令示例："
echo "     aws ecr get-login-password --region ${region} | docker login --username AWS --password-stdin ${account_id}.dkr.ecr.${region}.amazonaws.com.cn"
echo ""

