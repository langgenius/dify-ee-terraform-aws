# Dify Enterprise 插件 Pod 自动伸缩方案

## 背景

Dify Enterprise 的插件以独立 Pod 形式运行，由 `dify-crd-controller` 通过 `DifyPlugin` CRD 管理副本数。标准 Kubernetes HPA 无法直接用于插件 Pod——HPA 修改 Deployment 副本数后会被 CRD Controller 立即重置。

本方案通过 CronJob 定期读取 CPU 指标，调用 Enterprise 内部 Scale API 修改 CRD 副本数，实现与 CRD Controller 协同的自动伸缩。

> **适用范围 —— 仅作为 3.10.0 之前版本的暂行方案。**
> 从 Dify 企业版 Helm Chart **3.10.0**（对应 Community appVersion 1.14.1，发布于 2026-05-27）开始，`DifyPlugin` CRD 已内置 Kubernetes `/scale` 子资源：
>
> ```yaml
> scale:
>   specReplicasPath: .spec.runner.k8sPod.replica
>   statusReplicasPath: .status.replicas
>   labelSelectorPath: .status.selector
> ```
>
> 因此标准 Kubernetes HPA 可以直接指向 `DifyPlugin` 资源：
>
> ```yaml
> scaleTargetRef:
>   apiVersion: enterprise.dify.ai/v1
>   kind: DifyPlugin
>   name: <plugin-name>
> ```
>
> Chart >= 3.10.0 时**请勿使用本 CronJob 方案** —— 改为在 `cloud/aws/tf` 中设置 `enable_plugin_hpa = true`（参见 `terraform.tfvars.example`）：Terraform 会自动发现集群中的 `DifyPlugin` 资源并创建对应 HPA，且在 plan 阶段校验 CRD 是否具备 scale 能力。注意这是 **day-2 开关**：首次部署必须保持 `false`，待 Dify Chart 装好、控制台安装插件之后再置 `true` 并重新 `terraform apply`（Chart 未安装时 `enterprise.dify.ai` API 尚未注册，发现逻辑会导致 apply 失败；且没有插件时也无可伸缩对象）。
>
> 核实结果：3.9.2、3.9.9 的 CRD 都只有 `status` 子资源（该变更曾在 3.9 发布分支被回退）；3.10.0 是第一个正式交付该能力的企业版 Chart。对这些旧版本，本 CronJob 方案仍是唯一的自动伸缩途径。

## 工作原理

```
CronJob (每分钟)
  │
  ├── kubectl top pods        ← 读取 Metrics Server 的 CPU 指标
  ├── 计算目标副本数            ← 基于 CPU 利用率 vs 目标阈值
  ├── 应用 scaleUp/scaleDown 策略 ← 限制每次伸缩幅度，缩容有 stabilization window
  └── curl Scale API          ← POST /v1/plugin-manager/plugin-instances/{id}/scale
        │
        ├── 修改 DifyPlugin CRD 的 spec.runner.k8sPod.replica
        └── CRD Controller 自动同步到 Deployment → Pod 数量变化
```

## 前提条件

| 条件 | 说明 |
|------|------|
| Kubernetes 集群 | 已部署 Dify Enterprise（Helm 方式） |
| Metrics Server | 集群中已安装，`kubectl top pods` 命令可用 |
| kubectl | 本地已配置并可访问集群 |

### 安装 Metrics Server

脚本会自动检测 Metrics Server 是否可用，并根据集群平台（EKS/GKE/AKS/自建）给出安装建议。

手动安装示例：

```bash
# EKS（推荐方式）
aws eks create-addon --cluster-name <cluster> --addon-name metrics-server

# 或通过 Helm
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args[0]=--kubelet-preferred-address-types=InternalIP'

# 验证
kubectl top pods -n <dify-namespace>
```

> 生产环境不建议使用 `--kubelet-insecure-tls`，应配置正确的 kubelet 证书。

## 快速开始（推荐）

使用交互式安装脚本，自动检测环境并引导配置：

```bash
chmod +x setup-plugin-autoscaler.sh
./setup-plugin-autoscaler.sh
```

脚本会自动完成以下步骤：

1. 检测 kubectl 连接和 Dify 安装位置
2. 自动发现 namespace 和 Helm release name
3. 检查 Metrics Server 是否可用（按平台给出安装建议）
4. 列出所有已安装的插件供选择（编号菜单，支持 `a` 全选）
5. 使用默认配置直接部署（CPU 目标 70%，副本 1~4）
6. 生成 `plugin-autoscaler-generated.yaml` 并部署到集群
7. 写入 `plugin-autoscaler-states.yaml` 状态文件

首次部署使用默认值快速上线，后续通过编辑 `plugin-autoscaler-states.yaml` 调整 per-plugin 配置后重跑脚本即可。

### 重复运行

脚本支持幂等运行。再次执行时会：

- 读取 `plugin-autoscaler-states.yaml` 中的已有配置
- 对比集群中实际部署的 CronJob 配置，显示 diff
- 检测集群中新增的未纳管插件
- 提供两个选项：
  1. 直接用 YAML 配置更新部署
  2. 跳过 YAML，重新交互式选择

编辑 `plugin-autoscaler-states.yaml` 后重跑脚本即可更新配置，无需重新交互。

### 交互过程示例

```
==========================================
  Dify Plugin Autoscaler Setup
==========================================

[OK] kubectl connected
[INFO] Found existing config: plugin-autoscaler-states.yaml

  #   PLUGIN NAME              VERSION    STATUS     REPLICA  READY
  --- ------                   -------    ------     -------  -----
  1   b0d9.. my-plugin-a       0.1.0      Running    1        true
  2   d44f.. my-plugin-b       0.2.0      Running    1        true

  a   Select all plugins

Enter selection (numbers separated by spaces, or 'a' for all):
> a
[OK] Selected all 2 plugins
[INFO] Using defaults: CPU target=70%, replicas=1~4 per plugin
[INFO] To customize per-plugin settings, edit plugin-autoscaler-states.yaml and re-run this script.

  ...

Deploy autoscaler with these settings? [Y/n]: ↵

[OK] Plugin Autoscaler deployed successfully!
[OK] State file written: plugin-autoscaler-states.yaml
```

## 伸缩算法

### 基本公式

```
目标副本数 = ceil(当前副本数 × 当前CPU利用率 / 目标CPU利用率)
```

然后限制在 `[MIN_REPLICAS, MAX_REPLICAS]` 范围内。

### 伸缩策略（Scaling Behavior）

类似 Kubernetes HPA 的 behavior 机制，防止伸缩抖动：

**扩容（scaleUp）**：
- 每 60 秒最多扩容 `max(scaleup_max_percent%, scaleup_max_pods)` 个 Pod
- 默认值：`max(50%, 4 pods)`
- 取较大值，确保小规模时也能快速扩容

**缩容（scaleDown）**：
- 每 60 秒最多缩容 `min(scaledown_max_percent%, scaledown_max_pods)` 个 Pod
- 默认值：`min(10%, 2 pods)`
- 取较小值，确保缩容更保守
- **Stabilization Window**：缩容后有冷却期（默认 300 秒），期间不再缩容
- 冷却状态通过 ConfigMap 持久化，跨 CronJob 执行保持

**Per-plugin CPU 目标**：
- 每个插件可单独设置 CPU 目标，覆盖全局默认值
- 格式：`ID:MIN:MAX:CPU_TARGET`（第四个字段可选）

### 示例

| 当前副本 | CPU 用量 | CPU Request | 利用率 | 目标(70%) | 结果 |
|---------|---------|-------------|--------|----------|------|
| 1 | 500m | 100m | 500% | 8 | 扩到 MAX |
| 4 | 200m | 100m×4 | 50% | 3 | 缩容（受 policy 限制） |
| 2 | 130m | 100m×2 | 65% | 2 | 不变 |
| 1 | 10m | 100m | 10% | 1 | 不变 |

## 日常运维

### 查看最近一次执行日志

```bash
kubectl logs -n <namespace> job/$(kubectl get jobs -n <namespace> \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

输出示例：

```
[2026-04-02T15:52:01+00:00] Plugin Autoscaler run
  [b0d91fffa5be74075995378d70201b97] cpu=1m util=1% target=70% replicas=1 OK
  [d44f6db0acf0e8c506b328b8fa98a9fc] cpu=0m util=0% target=70% replicas=1 OK
Done (2 plugins checked)
```

### 暂停自动伸缩

```bash
kubectl patch cronjob plugin-autoscaler -n <namespace> \
  -p '{"spec":{"suspend":true}}'
```

### 恢复自动伸缩

```bash
kubectl patch cronjob plugin-autoscaler -n <namespace> \
  -p '{"spec":{"suspend":false}}'
```

### 修改配置

推荐方式：编辑 `plugin-autoscaler-states.yaml` 后重跑脚本：

```bash
# 编辑状态文件
vim plugin-autoscaler-states.yaml

# 重新部署
./setup-plugin-autoscaler.sh
```

也可以直接编辑 CronJob：

```bash
kubectl edit cronjob plugin-autoscaler -n <namespace>
```

### 卸载

```bash
kubectl delete -f plugin-autoscaler-generated.yaml
```

## 配置参考

### plugin-autoscaler-states.yaml

```yaml
namespace: dify
release: dify
cpu_target: 70                        # 全局 CPU 目标（%）
scaleup_max_percent: 50               # 扩容每 60s 最大百分比
scaleup_max_pods: 4                   # 扩容每 60s 最大 Pod 数
scaledown_max_percent: 10             # 缩容每 60s 最大百分比
scaledown_max_pods: 2                 # 缩容每 60s 最大 Pod 数
scaledown_stabilization_seconds: 300  # 缩容冷却期（秒）
plugins:
  - id: <plugin-instance-id>
    min: 1
    max: 4
  - id: <plugin-instance-id>
    min: 2
    max: 8
    cpu_target: 60                    # 可选：覆盖全局 CPU 目标
```

## 验证测试

### 1. 确认 CronJob 正常运行

```bash
kubectl get cronjob plugin-autoscaler -n <namespace>

# 等待 1-2 分钟后查看最近一次日志
kubectl logs -n <namespace> job/$(kubectl get jobs -n <namespace> \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

### 2. 压测验证扩容

```bash
# 获取插件 Pod 名称
kubectl get pods -n <namespace> | grep <plugin-id>

# 在插件容器中启动 CPU 压测
kubectl exec -n <namespace> <pod-name> -c dify-plugin -- \
  sh -c 'nohup sh -c "while true; do :; done" &'
```

等待 1-2 分钟后查看日志，预期输出：

```
[...] Plugin Autoscaler run
  [<plugin-id>] cpu=999m util=999% target=70% up 1->4 (raw=15) HTTP=200
Done (1 plugins checked)
```

### 3. 停止压测，验证缩容

```bash
kubectl exec -n <namespace> <pod-name> -c dify-plugin -- \
  sh -c 'for f in /proc/[0-9]*/cmdline; do
    pid=$(echo $f | tr -dc 0-9)
    cmd=$(cat $f 2>/dev/null | tr "\0" " ")
    if echo "$cmd" | grep -q "while true"; then
      kill -9 $pid && echo "killed $pid"
    fi
  done 2>/dev/null'
```

等待 stabilization window（默认 300 秒）后自动缩容。

## 注意事项

| 项目 | 说明 |
|------|------|
| 检查间隔 | 每分钟一次（CronJob 最小粒度） |
| 扩容策略 | 受 `scaleup_max_percent` 和 `scaleup_max_pods` 限制，取较大值 |
| 缩容策略 | 受 `scaledown_max_percent` 和 `scaledown_max_pods` 限制，取较小值 |
| 缩容冷却 | 默认 300 秒 stabilization window，通过 ConfigMap 持久化状态 |
| Metrics Server | 必须正常运行，否则 CronJob 会跳过（不会报错退出） |
| 认证 | JWT token 从 Kubernetes Secret 自动注入，无需手动管理 |
| 多集群 / DR | 如果启用了 Plugin DR（灾备），Scale API 会自动处理 DR 同步 |
| 镜像 | 使用 `bitnami/kubectl:latest`，生产环境建议锁定版本（如 `bitnami/kubectl:1.28`） |

## 文件说明

| 文件 | 用途 |
|------|------|
| `setup-plugin-autoscaler.sh` | 交互式安装脚本（推荐） |
| `plugin-autoscaler-states.yaml` | 声明式配置文件（编辑后重跑脚本即可更新） |
| `plugin-autoscaler-generated.yaml` | 脚本生成的实际部署 YAML（自动生成，勿手动编辑） |

## 故障排查

### CronJob 未执行

```bash
kubectl get cronjob plugin-autoscaler -n <namespace>
# 检查 SUSPEND 是否为 True、LAST SCHEDULE 时间
```

### 日志显示 "no pod metrics, skip"

插件 Pod 不在运行状态，或 Metrics Server 尚未采集到数据。确认：

```bash
kubectl get difyplugins.enterprise.dify.ai -n <namespace>
kubectl top pods -n <namespace> | grep <plugin-id-prefix>
```

### Scale API 返回 401

JWT Secret 不匹配。确认 Secret 名称正确：

```bash
kubectl get secret -n <namespace> | grep plugin-manager-secret
```

### Scale API 返回 404

插件 ID 错误或插件已被卸载。重新获取插件列表：

```bash
kubectl get difyplugins.enterprise.dify.ai -n <namespace>
```

### 缩容未生效

检查是否在 stabilization window 内：

```bash
kubectl get configmap plugin-autoscaler-state -n <namespace> -o yaml
```

查看对应插件的最后缩容时间戳，等待冷却期过后再观察。

### Metrics 显示 0m 但实际有负载

Metrics Server 可能还在采集中（刚启动），等待 1-2 分钟后重试。
