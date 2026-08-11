# Dify Enterprise Plugin Pod Autoscaling

## Background

Dify Enterprise plugins run as independent Pods, with replica counts managed by `dify-crd-controller` via the `DifyPlugin` CRD. Standard Kubernetes HPA cannot be used directly — any replica changes HPA makes to the Deployment are immediately overridden by the CRD Controller.

This solution uses a CronJob that periodically reads CPU metrics and calls the Enterprise internal Scale API to modify CRD replica counts, achieving autoscaling in coordination with the CRD Controller.

> **Applicability — interim workaround for charts earlier than 3.10.0 only.**
> Starting with Dify EE Helm chart **3.10.0** (community appVersion 1.14.1, released 2026-05-27), the `DifyPlugin` CRD ships the Kubernetes `/scale` subresource:
>
> ```yaml
> scale:
>   specReplicasPath: .spec.runner.k8sPod.replica
>   statusReplicasPath: .status.replicas
>   labelSelectorPath: .status.selector
> ```
>
> so standard Kubernetes HPA can target the `DifyPlugin` resource directly:
>
> ```yaml
> scaleTargetRef:
>   apiVersion: enterprise.dify.ai/v1
>   kind: DifyPlugin
>   name: <plugin-name>
> ```
>
> On chart >= 3.10.0, **do not use this CronJob** — use the sibling script instead (full docs: [`plugin-hpa-README.md`](./plugin-hpa-README.md)):
>
> ```bash
> ./setup-plugin-hpa.sh               # discovers all DifyPlugin resources, creates native HPAs
> ./setup-plugin-hpa.sh --auto-cover  # + in-cluster syncer: new plugins get HPAs automatically
> ./setup-plugin-hpa.sh --help        # min/max replicas, CPU/memory targets, per-plugin selection
> ./setup-plugin-hpa.sh --uninstall   # removes the HPAs (and syncer) it manages
> ```
>
> It verifies the CRD `/scale` capability up front (failing with guidance on older charts) and refuses to run alongside this CronJob to avoid the two mechanisms fighting over replica counts.
>
> Verified: the 3.9.2 and 3.9.9 CRDs only have the `status` subresource (the scale change was reverted on the 3.9 release branch); 3.10.0 is the first enterprise chart to deliver it. This CronJob remains the only autoscaling path for those older versions.

## How It Works

```
CronJob (every minute)
  │
  ├── kubectl top pods        ← Read CPU metrics from Metrics Server
  ├── Calculate target replicas  ← Based on CPU utilization vs target threshold
  ├── Apply scaleUp/scaleDown policy ← Limit scaling magnitude, stabilization window for scale-down
  └── curl Scale API          ← POST /v1/plugin-manager/plugin-instances/{id}/scale
        │
        ├── Update DifyPlugin CRD spec.runner.k8sPod.replica
        └── CRD Controller syncs to Deployment → Pod count changes
```

## Prerequisites

| Requirement | Description |
|-------------|-------------|
| Kubernetes cluster | Dify Enterprise deployed (via Helm) |
| Metrics Server | Installed in the cluster; `kubectl top pods` must work |
| kubectl | Configured locally with cluster access |

### Installing Metrics Server

The script automatically detects whether Metrics Server is available and provides platform-specific installation guidance (EKS/GKE/AKS/self-managed).

Manual installation example:

```bash
# EKS (recommended)
aws eks create-addon --cluster-name <cluster> --addon-name metrics-server

# Or via Helm
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args[0]=--kubelet-preferred-address-types=InternalIP'

# Verify
kubectl top pods -n <dify-namespace>
```

> For production environments, do not use `--kubelet-insecure-tls`. Configure proper kubelet certificates instead.

## Quick Start (Recommended)

Use the interactive setup script, which auto-detects the environment and guides configuration:

```bash
chmod +x setup-plugin-autoscaler.sh
./setup-plugin-autoscaler.sh
```

The script automatically performs the following steps:

1. Detects kubectl connectivity and Dify installation location
2. Auto-discovers namespace and Helm release name
3. Checks Metrics Server availability (with platform-specific installation advice)
4. Lists all installed plugins for selection (numbered menu, supports `a` for select-all)
5. Deploys with default settings (CPU target 70%, replicas 1–4)
6. Generates `plugin-autoscaler-generated.yaml` and deploys to the cluster
7. Writes `plugin-autoscaler-states.yaml` state file

Use defaults for initial deployment to get started quickly, then edit `plugin-autoscaler-states.yaml` to adjust per-plugin settings and re-run the script.

### Re-running the Script

The script is idempotent. On subsequent runs it will:

- Read existing configuration from `plugin-autoscaler-states.yaml`
- Compare against the CronJob configuration currently deployed in the cluster, showing a diff
- Detect newly installed plugins not yet managed
- Offer two options:
  1. Update the deployment using the YAML configuration
  2. Skip the YAML and re-enter interactive selection

Edit `plugin-autoscaler-states.yaml` and re-run the script to update configuration without re-entering interactive mode.

### Interactive Session Example

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

## Scaling Algorithm

### Basic Formula

```
target replicas = ceil(current replicas × current CPU utilization / target CPU utilization)
```

The result is clamped to `[MIN_REPLICAS, MAX_REPLICAS]`.

### Scaling Behavior

Similar to the Kubernetes HPA behavior mechanism, designed to prevent scaling oscillation:

**Scale Up**:
- Every 60 seconds, scale up by at most `max(scaleup_max_percent%, scaleup_max_pods)` Pods
- Defaults: `max(50%, 4 pods)`
- Uses the larger value to ensure fast scale-up even at small scale

**Scale Down**:
- Every 60 seconds, scale down by at most `min(scaledown_max_percent%, scaledown_max_pods)` Pods
- Defaults: `min(10%, 2 pods)`
- Uses the smaller value for more conservative scale-down
- **Stabilization Window**: After a scale-down, a cooldown period (default 300 seconds) prevents further scale-downs
- Cooldown state is persisted via ConfigMap across CronJob executions

**Per-plugin CPU Target**:
- Each plugin can have its own CPU target, overriding the global default
- Format: `ID:MIN:MAX:CPU_TARGET` (fourth field is optional)

### Examples

| Current Replicas | CPU Usage | CPU Request | Utilization | Target (70%) | Result |
|-----------------|-----------|-------------|-------------|-------------|--------|
| 1 | 500m | 100m | 500% | 8 | Scale to MAX |
| 4 | 200m | 100m×4 | 50% | 3 | Scale down (subject to policy limits) |
| 2 | 130m | 100m×2 | 65% | 2 | No change |
| 1 | 10m | 100m | 10% | 1 | No change |

## Day-to-Day Operations

### View the Latest Execution Log

```bash
kubectl logs -n <namespace> job/$(kubectl get jobs -n <namespace> \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

Sample output:

```
[2026-04-02T15:52:01+00:00] Plugin Autoscaler run
  [b0d91fffa5be74075995378d70201b97] cpu=1m util=1% target=70% replicas=1 OK
  [d44f6db0acf0e8c506b328b8fa98a9fc] cpu=0m util=0% target=70% replicas=1 OK
Done (2 plugins checked)
```

### Suspend Autoscaling

```bash
kubectl patch cronjob plugin-autoscaler -n <namespace> \
  -p '{"spec":{"suspend":true}}'
```

### Resume Autoscaling

```bash
kubectl patch cronjob plugin-autoscaler -n <namespace> \
  -p '{"spec":{"suspend":false}}'
```

### Modify Configuration

Recommended approach — edit `plugin-autoscaler-states.yaml` and re-run the script:

```bash
# Edit the state file
vim plugin-autoscaler-states.yaml

# Re-deploy
./setup-plugin-autoscaler.sh
```

You can also edit the CronJob directly:

```bash
kubectl edit cronjob plugin-autoscaler -n <namespace>
```

### Uninstall

```bash
kubectl delete -f plugin-autoscaler-generated.yaml
```

## Configuration Reference

### plugin-autoscaler-states.yaml

```yaml
namespace: dify
release: dify
cpu_target: 70                        # Global CPU target (%)
scaleup_max_percent: 50               # Max scale-up percentage per 60s
scaleup_max_pods: 4                   # Max scale-up pods per 60s
scaledown_max_percent: 10             # Max scale-down percentage per 60s
scaledown_max_pods: 2                 # Max scale-down pods per 60s
scaledown_stabilization_seconds: 300  # Scale-down cooldown period (seconds)
plugins:
  - id: <plugin-instance-id>
    min: 1
    max: 4
  - id: <plugin-instance-id>
    min: 2
    max: 8
    cpu_target: 60                    # Optional: override global CPU target
```

## Verification & Testing

### 1. Confirm the CronJob Is Running

```bash
kubectl get cronjob plugin-autoscaler -n <namespace>

# Wait 1-2 minutes, then check the latest log
kubectl logs -n <namespace> job/$(kubectl get jobs -n <namespace> \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

### 2. Stress Test to Verify Scale-Up

```bash
# Get plugin Pod name
kubectl get pods -n <namespace> | grep <plugin-id>

# Start a CPU stress test inside the plugin container
kubectl exec -n <namespace> <pod-name> -c dify-plugin -- \
  sh -c 'nohup sh -c "while true; do :; done" &'
```

Wait 1–2 minutes and check the log. Expected output:

```
[...] Plugin Autoscaler run
  [<plugin-id>] cpu=999m util=999% target=70% up 1->4 (raw=15) HTTP=200
Done (1 plugins checked)
```

### 3. Stop the Stress Test and Verify Scale-Down

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

After the stabilization window expires (default 300 seconds), scale-down will occur automatically.

## Notes

| Item | Description |
|------|-------------|
| Check interval | Once per minute (CronJob minimum granularity) |
| Scale-up policy | Limited by `scaleup_max_percent` and `scaleup_max_pods`, using the larger value |
| Scale-down policy | Limited by `scaledown_max_percent` and `scaledown_max_pods`, using the smaller value |
| Scale-down cooldown | Default 300-second stabilization window, state persisted via ConfigMap |
| Metrics Server | Must be running; CronJob skips gracefully if unavailable (does not exit with error) |
| Authentication | JWT token is automatically injected from a Kubernetes Secret — no manual management needed |
| Multi-cluster / DR | If Plugin DR (disaster recovery) is enabled, the Scale API handles DR synchronization automatically |
| Image | Uses `bitnami/kubectl:latest`; for production, pin a specific version (e.g. `bitnami/kubectl:1.28`) |

## File Descriptions

| File | Purpose |
|------|---------|
| `setup-plugin-autoscaler.sh` | Interactive setup script (recommended) |
| `plugin-autoscaler-states.yaml` | Declarative config file (edit and re-run script to update) |
| `plugin-autoscaler-generated.yaml` | Generated deployment YAML (auto-generated, do not edit manually) |
| `setup-plugin-hpa.sh` | Native HPA setup script for chart >= 3.10.0 (use instead of the CronJob) — see [`plugin-hpa-README.md`](./plugin-hpa-README.md) |
| `../secret/plugin-hpa-generated.yaml` | Generated HPA YAML from `setup-plugin-hpa.sh` (auto-generated, do not edit manually) |

## Troubleshooting

### CronJob Not Executing

```bash
kubectl get cronjob plugin-autoscaler -n <namespace>
# Check if SUSPEND is True and the LAST SCHEDULE time
```

### Log Shows "no pod metrics, skip"

The plugin Pod is not running, or Metrics Server has not yet collected data. Verify:

```bash
kubectl get difyplugins.enterprise.dify.ai -n <namespace>
kubectl top pods -n <namespace> | grep <plugin-id-prefix>
```

### Scale API Returns 401

JWT Secret mismatch. Confirm the Secret name is correct:

```bash
kubectl get secret -n <namespace> | grep plugin-manager-secret
```

### Scale API Returns 404

The plugin ID is incorrect or the plugin has been uninstalled. Re-fetch the plugin list:

```bash
kubectl get difyplugins.enterprise.dify.ai -n <namespace>
```

### Scale-Down Not Taking Effect

Check whether the stabilization window is still active:

```bash
kubectl get configmap plugin-autoscaler-state -n <namespace> -o yaml
```

Look at the last scale-down timestamp for the plugin and wait for the cooldown period to pass.

### Metrics Show 0m Despite Actual Load

Metrics Server may still be collecting data (just started). Wait 1–2 minutes and retry.
