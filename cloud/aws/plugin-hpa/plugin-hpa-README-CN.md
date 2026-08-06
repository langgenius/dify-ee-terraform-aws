# Dify 企业版插件 Pod 自动伸缩 —— 原生 HPA（`setup-plugin-hpa.sh`）

## 适用版本

| Dify EE Helm Chart | DifyPlugin CRD 子资源 | 自动伸缩方案 |
|---|---|---|
| < 3.10.0（含 3.9.2、3.9.9） | 仅 `status` | CronJob 暂行方案 —— [`setup-plugin-autoscaler.sh`](./plugin-autoscaler-README-CN.md) |
| **>= 3.10.0**（对应 Community appVersion 1.14.1，发布于 2026-05-27） | `status` + **`scale`** | **本脚本** —— 原生 Kubernetes HPA |

3.10.0 是第一个正式交付 `scale` 子资源的企业版 Chart。该变更曾进入 3.9 发布分支但**在发布前被回退** —— 这正是本脚本启动时校验**集群实际 CRD** 而非 Chart 版本号的原因。集群不支持时直接报错退出并给出指引，不会应用任何资源。

## Why（为什么是这套方案）

完整因果链，帮助判断该用哪个工具、以及它为什么存在：

1. **插件 Pod 不是普通 Deployment。** 每个已安装插件对应一个 `DifyPlugin` 自定义资源（`enterprise.dify.ai/v1`）；`dify-crd-controller` 持续按 `spec.runner.k8sPod.replica` 调和底层 Deployment 的副本数。
2. **因此指向 Deployment 的 HPA 无效。** HPA 对 Deployment 写入的任何副本数变更都会被 controller 立即改回。这也是当初给 Dify 核心组件加 HPA/CA（`tf/autoscaling.tf`）时插件组件被排除在外的原因。
3. **Kubernetes HPA 可以伸缩任何暴露 `/scale` 子资源的对象**，不限于 Deployment。3.10.0 之前 `DifyPlugin` CRD 没有暴露它，合法修改副本数的唯一途径是企业版 Scale API（`POST /v1/plugin-manager/plugin-instances/{id}/scale`）—— 这就是 CronJob 暂行方案（轮询 Metrics Server 并调用该 API）的由来。
4. **从 3.10.0 起 CRD 内置 `/scale`：**

   ```yaml
   scale:
     specReplicasPath: .spec.runner.k8sPod.replica
     statusReplicasPath: .status.replicas
     labelSelectorPath: .status.selector
   ```

   标准 `autoscaling/v2` HPA 可以直接指向 `DifyPlugin` 资源，副本数变更由 CRD controller 自己下发：

   ```yaml
   scaleTargetRef:
     apiVersion: enterprise.dify.ai/v1
     kind: DifyPlugin
     name: <plugin-name>
   ```

   不再需要轮询循环、API Token、JWT 伪造 —— 原生 HPA 控制回路（带真正的稳定窗口语义）完成全部工作。
5. **为什么是脚本而不是 Terraform？** 插件是运行时通过企业版控制台安装的，`DifyPlugin` 资源在基础设施创建阶段并不存在。Terraform 实现曾被原型验证后放弃：它要求在 Chart 与插件安装完成后额外执行一次 `terraform apply`，之后每装一个新插件还要再 apply 一次。本脚本无状态、幂等 —— 任何时候重跑即可。

## 前提条件

| 要求 | 说明 |
|---|---|
| Dify EE Helm Chart >= 3.10.0 | 脚本会校验 CRD 的 `/scale` 能力，不满足则报错退出并给出指引 |
| kubectl | 已配置且可访问集群 |
| Metrics Server | `kubectl top pods` 可用（与核心组件 HPA 要求一致） |
| 插件 Pod 的 CPU requests | 基于利用率的 HPA 没有 `resources.requests.cpu` 无法计算百分比 |

## 快速开始

```bash
chmod +x setup-plugin-hpa.sh
./setup-plugin-hpa.sh                 # 发现全部插件，确认后应用
./setup-plugin-hpa.sh --auto-cover    # 同上 + 部署 syncer（见下节）
```

## 新装插件的覆盖

HPA 对象是按插件一一创建的，安装于配置**之后**的插件没有 HPA。两种选择：

- **重跑脚本**（默认）：幂等 —— 已有 HPA 原地更新，新插件自动补上。这与 CronJob 暂行方案行为一致：其插件清单同样是部署时烤入 `PLUGINS` 环境变量的固定列表，新插件也需要重跑 setup 脚本。
- **`--auto-cover`**（推荐给免维护集群）：额外部署 `plugin-hpa-syncer` CronJob，**在集群内每 5 分钟**执行：
  - 为没有 HPA 的 `DifyPlugin` 按本次运行的默认参数（ConfigMap 模板）补建 HPA；
  - 清理插件已卸载的残留 HPA；
  - **绝不修改已存在的 HPA** —— 单插件手工调参不会被覆盖。

  注意：syncer 生效期间手动删除某插件的 HPA 没有意义（5 分钟内会被重建）。要停止某插件的自动伸缩，先 `--uninstall` 再不带 `--auto-cover` 重跑。

## 参数

```
-n, --namespace NS        Dify 命名空间（默认自动探测）
    --plugins a,b,c       只管理指定的 DifyPlugin（默认全部）
    --min N               minReplicas                  （默认 1）
    --max N               maxReplicas                  （默认 4）
    --cpu-target N        目标 CPU 利用率 %             （默认 70）
    --memory-target N     目标内存利用率 %              （默认不设）
    --scale-up-window S   scaleUp 稳定窗口秒数           （默认 0）
    --scale-down-window S scaleDown 稳定窗口秒数         （默认 300）
    --auto-cover          同时部署 plugin-hpa-syncer CronJob
    --dry-run             只生成 plugin-hpa-generated.yaml，不应用
    --force               即使 CronJob autoscaler 已部署也继续
    --uninstall           删除全部受管 HPA（以及 syncer，若已部署）
-y, --yes                 非交互模式
```

伸缩策略固定，与 CronJob 方案默认值一致：扩容每分钟最多 50% / 4 个 Pod（取更快者），缩容每分钟最多 10% / 2 个 Pod（取更慢者）。

单插件调参 —— 用子集重跑，其余插件的 HPA 不受影响：

```bash
./setup-plugin-hpa.sh --plugins hot-plugin --min 2 --max 12 --cpu-target 60
```

## 从 CronJob 方案迁移

两套机制**绝不能同时运行** —— 会互相争抢副本数。检测到 `plugin-autoscaler` CronJob 存在时脚本会拒绝执行（`--force` 可强行越过，风险自负）。

```bash
kubectl delete -f plugin-autoscaler-generated.yaml   # 或: kubectl delete cronjob plugin-autoscaler -n dify
./setup-plugin-hpa.sh
```

## 验证与故障排查

```bash
kubectl get hpa -n dify -l app.kubernetes.io/managed-by=dify-plugin-hpa
kubectl describe hpa dify-plugin-<name>-hpa -n dify
kubectl get cronjob plugin-hpa-syncer -n dify        # 若使用了 --auto-cover
```

| 现象 | 原因 |
|---|---|
| `TARGETS` 显示 `<unknown>/70%` | Metrics Server 缺失/启动中，或插件 Pod 没有 CPU requests，或插件仍在安装中（无害，Pod 上报指标后自动恢复） |
| `FailedGetScale` 事件 | CRD 没有 `/scale` 子资源 —— Chart < 3.10.0，请用 CronJob 方案 |
| 副本数被改回 | CronJob autoscaler（或其他机制）也在写副本数 —— 移除它 |
| 删掉的 HPA 又出现 | `plugin-hpa-syncer` 的设计行为；见「新装插件的覆盖」 |

## 文件说明

| 文件 | 用途 |
|---|---|
| `setup-plugin-hpa.sh` | 本安装脚本 |
| `plugin-hpa-generated.yaml` | 生成的 HPA（+ syncer）YAML —— 自动生成、已 gitignore，勿手动编辑 |
| `plugin-autoscaler-README-CN.md` | CronJob 暂行方案文档（Chart < 3.10.0） |
