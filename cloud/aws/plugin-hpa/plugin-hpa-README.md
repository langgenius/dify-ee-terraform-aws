# Dify Enterprise Plugin Pod Autoscaling — Native HPA (`setup-plugin-hpa.sh`)

## Applicable Versions

| Dify EE Helm chart | DifyPlugin CRD subresources | Autoscaling approach |
|---|---|---|
| < 3.10.0 (incl. 3.9.2, 3.9.9) | `status` only | CronJob workaround — [`setup-plugin-autoscaler.sh`](./plugin-autoscaler-README.md) |
| **>= 3.10.0** (community appVersion 1.14.1, released 2026-05-27) | `status` + **`scale`** | **This script** — native Kubernetes HPA |

Chart 3.10.0 is the first enterprise chart to deliver the `scale` subresource. The change once landed on the 3.9 release branch but was **reverted before release** — which is exactly why this script verifies the capability against the **live CRD** at startup instead of trusting a chart version number. On an unsupported cluster it aborts with guidance; nothing is applied.

## Why

The full causal chain, so you know which tool to reach for and why it exists:

1. **Plugin pods are not ordinary Deployments.** Every installed plugin is represented by a `DifyPlugin` custom resource (`enterprise.dify.ai/v1`); `dify-crd-controller` continuously reconciles the backing Deployment's replica count from `spec.runner.k8sPod.replica`.
2. **Therefore Deployment-targeted HPA cannot work.** Any replica change HPA writes to the Deployment is immediately overwritten by the controller. This is why plugin components were excluded when HPA/CA was added for the core Dify components (`tf/autoscaling.tf`).
3. **Kubernetes HPA can scale any resource that exposes the `/scale` subresource** — not just Deployments. Before chart 3.10.0 the `DifyPlugin` CRD did not expose it, so the only legitimate way to change replicas was the Enterprise Scale API (`POST /v1/plugin-manager/plugin-instances/{id}/scale`) — hence the CronJob workaround that polls Metrics Server and calls that API.
4. **From chart 3.10.0 the CRD ships `/scale`:**

   ```yaml
   scale:
     specReplicasPath: .spec.runner.k8sPod.replica
     statusReplicasPath: .status.replicas
     labelSelectorPath: .status.selector
   ```

   so a standard `autoscaling/v2` HPA can target the `DifyPlugin` resource directly, and the CRD controller itself propagates the replica change:

   ```yaml
   scaleTargetRef:
     apiVersion: enterprise.dify.ai/v1
     kind: DifyPlugin
     name: <plugin-name>
   ```

   No polling loop, no API tokens, no JWT forging — the native HPA control loop (with real stabilization-window semantics) does the work.
5. **Why a script and not Terraform?** Plugins are installed at runtime through the Enterprise console, so `DifyPlugin` resources don't exist at infrastructure-provisioning time. A Terraform implementation was prototyped and dropped: it required a second `terraform apply` after chart + plugin installation, plus one more apply for every plugin installed later. This script is stateless and idempotent — re-run it anytime.

## Prerequisites

| Requirement | Notes |
|---|---|
| Dify EE Helm chart >= 3.10.0 | Script verifies the CRD `/scale` capability and aborts with guidance otherwise |
| kubectl | Configured with cluster access |
| Metrics Server | `kubectl top pods` must work (same requirement as core-component HPA) |
| CPU requests on plugin pods | Utilization-based HPA cannot compute a percentage without `resources.requests.cpu` |

## Quick Start

```bash
chmod +x setup-plugin-hpa.sh
./setup-plugin-hpa.sh                 # discover all plugins, confirm, apply
./setup-plugin-hpa.sh --auto-cover    # same + deploy the syncer (see below)
```

## Covering Newly Installed Plugins

HPA objects are per-plugin, so a plugin installed *after* setup has no HPA yet. Two options:

- **Re-run the script** (default): idempotent — existing HPAs are updated in place, new plugins get covered. This matches the CronJob workaround's behavior, whose plugin list is also baked in at deploy time and needs a re-run for new plugins.
- **`--auto-cover`** (recommended for hands-off clusters): additionally deploys a `plugin-hpa-syncer` CronJob that runs **in-cluster every 5 minutes**:
  - creates an HPA (from a ConfigMap template baked with this run's defaults) for every `DifyPlugin` that doesn't have one;
  - prunes managed HPAs whose plugin was uninstalled;
  - **never modifies an existing HPA** — per-plugin tuning survives.

  Note: with the syncer active, deleting a plugin's HPA by hand is pointless (it will be recreated within 5 minutes). To stop autoscaling a specific plugin, remove the syncer (`--uninstall`, then re-run without `--auto-cover`).

## Options

```
-n, --namespace NS        Dify namespace (default: auto-detect)
    --plugins a,b,c       Only manage these DifyPlugin names (default: all)
    --min N               minReplicas                     (default: 1)
    --max N               maxReplicas                     (default: 4)
    --cpu-target N        Target CPU utilization %        (default: 70)
    --memory-target N     Target memory utilization %     (default: unset)
    --scale-up-window S   scaleUp stabilization seconds   (default: 0)
    --scale-down-window S scaleDown stabilization seconds (default: 300)
    --auto-cover          Also deploy the plugin-hpa-syncer CronJob
    --dry-run             Generate plugin-hpa-generated.yaml only, don't apply
    --force               Proceed even if the CronJob autoscaler is deployed
    --uninstall           Delete managed HPAs (and the syncer, if deployed)
-y, --yes                 Non-interactive
```

Scaling policies are fixed and match the CronJob workaround's defaults: scale up by at most 50% / 4 pods per minute (whichever allows more), scale down by at most 10% / 2 pods per minute (whichever allows less).

Per-plugin tuning — re-run with a subset; other plugins' HPAs are left untouched:

```bash
./setup-plugin-hpa.sh --plugins hot-plugin --min 2 --max 12 --cpu-target 60
```

## Migrating from the CronJob Workaround

The two mechanisms MUST NOT run together — they will fight over replica counts. The script refuses to proceed while the `plugin-autoscaler` CronJob exists (override with `--force` at your own risk).

```bash
kubectl delete -f plugin-autoscaler-generated.yaml   # or: kubectl delete cronjob plugin-autoscaler -n dify
./setup-plugin-hpa.sh
```

## Verification & Troubleshooting

```bash
kubectl get hpa -n dify -l app.kubernetes.io/managed-by=dify-plugin-hpa
kubectl describe hpa dify-plugin-<name>-hpa -n dify
kubectl get cronjob plugin-hpa-syncer -n dify        # if --auto-cover was used
```

| Symptom | Cause |
|---|---|
| `TARGETS` shows `<unknown>/70%` | Metrics Server missing/starting, or plugin pods lack CPU requests, or the plugin is still installing (harmless — resolves once pods report metrics) |
| `FailedGetScale` events | CRD has no `/scale` subresource — chart < 3.10.0, use the CronJob workaround |
| Replicas snap back after scaling | The CronJob autoscaler (or something else) is also writing replica counts — remove it |
| Deleted HPA reappears | `plugin-hpa-syncer` is active by design; see "Covering Newly Installed Plugins" |

## Files

| File | Purpose |
|---|---|
| `setup-plugin-hpa.sh` | This installer |
| `plugin-hpa-generated.yaml` | Generated HPA (+ syncer) YAML — auto-generated, gitignored, do not edit |
| `plugin-autoscaler-README.md` | CronJob workaround docs (chart < 3.10.0) |
