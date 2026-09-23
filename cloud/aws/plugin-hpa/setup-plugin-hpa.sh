#!/bin/bash
# ============================================================================
# Dify Enterprise - Plugin HPA 安装脚本 (chart >= 3.10.0)
# ============================================================================
# 为集群中的 DifyPlugin 资源生成并应用标准 Kubernetes HPA。
#
# 从 Dify EE Helm chart 3.10.0 (appVersion 1.14.1) 开始, DifyPlugin CRD 内置
# /scale 子资源, 标准 HPA 可直接指向 DifyPlugin 资源, 由 dify-crd-controller
# 同步副本数。3.10.0 之前的版本请使用同目录的 setup-plugin-autoscaler.sh
# (CronJob 方案)。
#
# 使用方法:
#   chmod +x setup-plugin-hpa.sh
#   ./setup-plugin-hpa.sh                      # 交互式: 发现全部插件并创建 HPA
#   ./setup-plugin-hpa.sh --min 1 --max 8      # 自定义副本范围
#   ./setup-plugin-hpa.sh --plugins a,b        # 只为指定插件创建 (可分批调参)
#   ./setup-plugin-hpa.sh --uninstall          # 删除本脚本管理的全部 HPA
#
# 安装新插件后重跑一次本脚本即可覆盖新插件。
#
# 前提条件:
#   - kubectl 已配置且可访问集群
#   - Dify EE Helm chart >= 3.10.0 已部署 (CRD 带 scale 子资源, 脚本会校验)
#   - Metrics Server 已安装 (kubectl top pods 可用)
#   - 插件 Pod 配置了 CPU requests (基于利用率的 HPA 必需)
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/secret"
OUTPUT_FILE="$SECRET_DIR/plugin-hpa-generated.yaml"
CRD_NAME="difyplugins.enterprise.dify.ai"
MANAGED_BY_LABEL="app.kubernetes.io/managed-by=dify-plugin-hpa"

NAMESPACE=""
PLUGIN_FILTER=""
MIN_REPLICAS=1
MAX_REPLICAS=4
CPU_TARGET=70
MEMORY_TARGET=""
SCALEUP_WINDOW=0
SCALEDOWN_WINDOW=300
DRY_RUN=false
UNINSTALL=false
ASSUME_YES=false
FORCE=false
AUTO_COVER=false

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
  cat <<'EOF'
Usage: setup-plugin-hpa.sh [options]

Creates standard Kubernetes HPAs targeting DifyPlugin resources via the
/scale subresource (requires Dify EE Helm chart >= 3.10.0).

Options:
  -n, --namespace NS        Dify namespace (default: auto-detect)
      --plugins a,b,c       Only manage these DifyPlugin names (default: all)
      --min N               minReplicas          (default: 1)
      --max N               maxReplicas          (default: 4)
      --cpu-target N        Target CPU utilization %      (default: 70)
      --memory-target N     Target memory utilization %   (default: unset)
      --scale-up-window S   scaleUp stabilization seconds   (default: 0)
      --scale-down-window S scaleDown stabilization seconds (default: 300)
      --auto-cover          Also deploy the plugin-hpa-syncer CronJob: every 5
                            minutes it creates HPAs (with this run's defaults)
                            for newly installed plugins and prunes HPAs whose
                            plugin was uninstalled. Existing HPAs are never
                            modified, so per-plugin tuning survives.
      --dry-run             Generate YAML only, do not apply
      --force               Proceed even if the CronJob autoscaler is deployed
      --uninstall           Delete all HPAs managed by this script (and the
                            plugin-hpa-syncer CronJob if deployed)
  -y, --yes                 Non-interactive; accept defaults, skip prompts
  -h, --help                Show this help

Without --auto-cover, re-run the script after installing new plugins to cover
them. To tune a subset of plugins differently, re-run with --plugins and new
values; existing HPAs for other plugins are left untouched.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)       NAMESPACE="$2"; shift 2 ;;
    --plugins)            PLUGIN_FILTER="$2"; shift 2 ;;
    --min)                MIN_REPLICAS="$2"; shift 2 ;;
    --max)                MAX_REPLICAS="$2"; shift 2 ;;
    --cpu-target)         CPU_TARGET="$2"; shift 2 ;;
    --memory-target)      MEMORY_TARGET="$2"; shift 2 ;;
    --scale-up-window)    SCALEUP_WINDOW="$2"; shift 2 ;;
    --scale-down-window)  SCALEDOWN_WINDOW="$2"; shift 2 ;;
    --auto-cover)         AUTO_COVER=true; shift ;;
    --dry-run)            DRY_RUN=true; shift ;;
    --force)              FORCE=true; shift ;;
    --uninstall)          UNINSTALL=true; shift ;;
    -y|--yes)             ASSUME_YES=true; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# --- Validate numeric options ---
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_uint "$MIN_REPLICAS" && is_uint "$MAX_REPLICAS" && is_uint "$CPU_TARGET" \
  && is_uint "$SCALEUP_WINDOW" && is_uint "$SCALEDOWN_WINDOW" \
  || { err "--min/--max/--cpu-target/--scale-*-window must be non-negative integers"; exit 1; }
[ -n "$MEMORY_TARGET" ] && { is_uint "$MEMORY_TARGET" || { err "--memory-target must be an integer"; exit 1; }; }
[ "$MIN_REPLICAS" -ge 1 ] || { err "--min must be >= 1"; exit 1; }
[ "$MIN_REPLICAS" -le "$MAX_REPLICAS" ] || { err "--min must be <= --max"; exit 1; }
[ "$CPU_TARGET" -ge 1 ] && [ "$CPU_TARGET" -le 100 ] || { err "--cpu-target must be 1-100"; exit 1; }
if [ -n "$MEMORY_TARGET" ]; then
  [ "$MEMORY_TARGET" -ge 1 ] && [ "$MEMORY_TARGET" -le 100 ] || { err "--memory-target must be 1-100"; exit 1; }
fi

confirm() { # confirm "prompt" -> 0 yes / 1 no; --yes auto-accepts
  $ASSUME_YES && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ============================================================
# Preflight
# ============================================================
command -v kubectl >/dev/null 2>&1 || { err "kubectl not found in PATH."; exit 1; }
kubectl config current-context >/dev/null 2>&1 || { err "No active kubectl context found. Check your kubeconfig."; exit 1; }
kubectl get ns --request-timeout=10s >/dev/null 2>&1 || { err "Cannot reach the Kubernetes API."; exit 1; }
ok "Cluster reachable (context: $(kubectl config current-context))"

# --- Namespace auto-detection: namespaces that contain DifyPlugin resources ---
if [ -z "$NAMESPACE" ]; then
  ns_candidates=()
  while IFS= read -r ns; do
    [ -n "$ns" ] && ns_candidates+=("$ns")
  done < <(kubectl get "$CRD_NAME" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)
  if [ ${#ns_candidates[@]} -eq 1 ]; then
    NAMESPACE="${ns_candidates[0]}"
    info "Auto-detected namespace: $NAMESPACE"
  elif [ ${#ns_candidates[@]} -gt 1 ]; then
    if $ASSUME_YES; then
      err "Multiple namespaces contain DifyPlugin resources (${ns_candidates[*]}). Pass -n explicitly."
      exit 1
    fi
    echo "Namespaces with DifyPlugin resources:"
    printf '  - %s\n' "${ns_candidates[@]}"
    read -r -p "Namespace to use [${ns_candidates[0]}]: " NAMESPACE
    NAMESPACE="${NAMESPACE:-${ns_candidates[0]}}"
  else
    NAMESPACE="dify"
    warn "No DifyPlugin resources found in any namespace; defaulting to '$NAMESPACE'."
  fi
fi

# ============================================================
# Uninstall mode
# ============================================================
if $UNINSTALL; then
  count=$(kubectl get hpa -n "$NAMESPACE" -l "$MANAGED_BY_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  syncer_exists=false
  kubectl get cronjob plugin-hpa-syncer -n "$NAMESPACE" >/dev/null 2>&1 && syncer_exists=true
  if [ "$count" -eq 0 ] && ! $syncer_exists; then
    info "No managed plugin HPAs or plugin-hpa-syncer found in namespace '$NAMESPACE'. Nothing to do."
    exit 0
  fi
  [ "$count" -gt 0 ] && kubectl get hpa -n "$NAMESPACE" -l "$MANAGED_BY_LABEL"
  $syncer_exists && info "plugin-hpa-syncer CronJob is deployed and will be removed as well."
  confirm "Delete $count HPA(s)$($syncer_exists && echo ' and the plugin-hpa-syncer')?" || { info "Aborted."; exit 0; }
  [ "$count" -gt 0 ] && kubectl delete hpa -n "$NAMESPACE" -l "$MANAGED_BY_LABEL"
  if $syncer_exists; then
    kubectl delete -n "$NAMESPACE" cronjob/plugin-hpa-syncer serviceaccount/plugin-hpa-syncer \
      role/plugin-hpa-syncer rolebinding/plugin-hpa-syncer configmap/plugin-hpa-template --ignore-not-found
  fi
  ok "Removed $count plugin HPA(s) from '$NAMESPACE'."
  exit 0
fi

# --- CRD present? ---
if ! kubectl get crd "$CRD_NAME" >/dev/null 2>&1; then
  err "CRD $CRD_NAME not found. Is the Dify EE Helm chart installed in this cluster?"
  exit 1
fi

# --- CRD scale subresource (first shipped in chart 3.10.0 / appVersion 1.14.1) ---
scale_path=$(kubectl get crd "$CRD_NAME" -o jsonpath='{.spec.versions[*].subresources.scale.specReplicasPath}' 2>/dev/null)
if [ -z "$scale_path" ]; then
  err "The DifyPlugin CRD on this cluster has no /scale subresource, so standard HPA cannot scale plugin pods."
  err "This requires Dify EE Helm chart >= 3.10.0 (appVersion 1.14.1); 3.9.x and earlier only ship the status subresource."
  err "Either upgrade the chart, or use the CronJob-based workaround: ./setup-plugin-autoscaler.sh"
  exit 1
fi
ok "DifyPlugin CRD supports /scale (specReplicasPath: $scale_path)"

# --- Metrics Server ---
if kubectl top pods -n "$NAMESPACE" --no-headers >/dev/null 2>&1; then
  ok "Metrics Server is working (kubectl top pods)"
else
  warn "kubectl top pods failed - Metrics Server may be missing or still starting."
  warn "HPAs will stay at <unknown> utilization until pod metrics are available."
  confirm "Continue anyway?" || { info "Aborted."; exit 0; }
fi

# --- Conflict with the CronJob-based autoscaler ---
if kubectl get cronjob plugin-autoscaler -n "$NAMESPACE" >/dev/null 2>&1; then
  warn "The CronJob-based plugin-autoscaler is deployed in '$NAMESPACE'."
  warn "Running both mechanisms will fight over replica counts."
  if ! $FORCE; then
    err "Remove it first (kubectl delete -f plugin-autoscaler-generated.yaml, or"
    err "kubectl delete cronjob plugin-autoscaler -n $NAMESPACE), or re-run with --force."
    exit 1
  fi
  warn "--force given, proceeding anyway."
fi

# ============================================================
# Plugin discovery
# ============================================================
PLUGINS=()
while IFS=$'\t' read -r name state replica; do
  [ -n "$name" ] || continue
  if [ -n "$PLUGIN_FILTER" ]; then
    case ",$PLUGIN_FILTER," in
      *",$name,"*) ;;
      *) continue ;;
    esac
  fi
  PLUGINS+=("$name")
  printf '  - %s (state: %s, replicas: %s)\n' "$name" "${state:-?}" "${replica:-?}"
done < <(kubectl get "$CRD_NAME" -n "$NAMESPACE" \
  -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.status.state}}{{"\t"}}{{.spec.runner.k8sPod.replica}}{{"\n"}}{{end}}' \
  2>/dev/null)

if [ ${#PLUGINS[@]} -eq 0 ]; then
  if [ -n "$PLUGIN_FILTER" ]; then
    err "No DifyPlugin in '$NAMESPACE' matches --plugins $PLUGIN_FILTER."
  else
    err "No DifyPlugin resources found in '$NAMESPACE'. Install plugins via the Enterprise console first."
  fi
  exit 1
fi

echo ""
info "Will create/update HPAs for ${#PLUGINS[@]} plugin(s) in '$NAMESPACE':"
echo -e "  minReplicas=${BOLD}${MIN_REPLICAS}${NC} maxReplicas=${BOLD}${MAX_REPLICAS}${NC} cpuTarget=${BOLD}${CPU_TARGET}%${NC}${MEMORY_TARGET:+ memoryTarget=${BOLD}${MEMORY_TARGET}%${NC}}"
echo -e "  scaleUpWindow=${SCALEUP_WINDOW}s scaleDownWindow=${SCALEDOWN_WINDOW}s"
$AUTO_COVER && info "--auto-cover: the plugin-hpa-syncer CronJob will also be deployed (new plugins get HPAs automatically, every 5 min)."
confirm "Proceed?" || { info "Aborted."; exit 0; }

# ============================================================
# Generate YAML
# ============================================================
mkdir -p "$SECRET_DIR"
: > "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE"
for plugin in "${PLUGINS[@]}"; do
  cat >> "$OUTPUT_FILE" <<ENDOFYAML
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dify-plugin-${plugin}-hpa
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dify-plugin-hpa
    app.kubernetes.io/part-of: dify
spec:
  scaleTargetRef:
    apiVersion: enterprise.dify.ai/v1
    kind: DifyPlugin
    name: ${plugin}
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${CPU_TARGET}
ENDOFYAML
  if [ -n "$MEMORY_TARGET" ]; then
    cat >> "$OUTPUT_FILE" <<ENDOFYAML
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: ${MEMORY_TARGET}
ENDOFYAML
  fi
  cat >> "$OUTPUT_FILE" <<ENDOFYAML
  behavior:
    scaleUp:
      stabilizationWindowSeconds: ${SCALEUP_WINDOW}
      selectPolicy: Max
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
        - type: Pods
          value: 4
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: ${SCALEDOWN_WINDOW}
      selectPolicy: Min
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
        - type: Pods
          value: 2
          periodSeconds: 60
ENDOFYAML
done

# --- Optional: in-cluster syncer so newly installed plugins get HPAs automatically ---
if $AUTO_COVER; then
  mem_tpl=""
  if [ -n "$MEMORY_TARGET" ]; then
    mem_tpl="
        - type: Resource
          resource:
            name: memory
            target:
              type: Utilization
              averageUtilization: ${MEMORY_TARGET}"
  fi
  cat >> "$OUTPUT_FILE" <<ENDOFYAML
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: plugin-hpa-template
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dify-plugin-hpa
data:
  # Template applied by plugin-hpa-syncer for every DifyPlugin without an HPA.
  # __PLUGIN__ is replaced with the DifyPlugin name at sync time.
  hpa.yaml: |
    apiVersion: autoscaling/v2
    kind: HorizontalPodAutoscaler
    metadata:
      name: dify-plugin-__PLUGIN__-hpa
      namespace: ${NAMESPACE}
      labels:
        app.kubernetes.io/managed-by: dify-plugin-hpa
        app.kubernetes.io/part-of: dify
    spec:
      scaleTargetRef:
        apiVersion: enterprise.dify.ai/v1
        kind: DifyPlugin
        name: __PLUGIN__
      minReplicas: ${MIN_REPLICAS}
      maxReplicas: ${MAX_REPLICAS}
      metrics:
        - type: Resource
          resource:
            name: cpu
            target:
              type: Utilization
              averageUtilization: ${CPU_TARGET}${mem_tpl}
      behavior:
        scaleUp:
          stabilizationWindowSeconds: ${SCALEUP_WINDOW}
          selectPolicy: Max
          policies:
            - type: Percent
              value: 50
              periodSeconds: 60
            - type: Pods
              value: 4
              periodSeconds: 60
        scaleDown:
          stabilizationWindowSeconds: ${SCALEDOWN_WINDOW}
          selectPolicy: Min
          policies:
            - type: Percent
              value: 10
              periodSeconds: 60
            - type: Pods
              value: 2
              periodSeconds: 60
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: plugin-hpa-syncer
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dify-plugin-hpa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: plugin-hpa-syncer
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dify-plugin-hpa
rules:
  - apiGroups: ["enterprise.dify.ai"]
    resources: ["difyplugins"]
    verbs: ["get", "list"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "create", "delete", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: plugin-hpa-syncer
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dify-plugin-hpa
subjects:
  - kind: ServiceAccount
    name: plugin-hpa-syncer
    namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: plugin-hpa-syncer
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: plugin-hpa-syncer
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dify-plugin-hpa
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 120
      template:
        spec:
          serviceAccountName: plugin-hpa-syncer
          restartPolicy: Never
          volumes:
            - name: template
              configMap:
                name: plugin-hpa-template
          containers:
            - name: syncer
              image: bitnami/kubectl:latest
              volumeMounts:
                - name: template
                  mountPath: /template
              command:
                - /bin/bash
                - -c
                - |
                  set -e
                  NS="${NAMESPACE}"
                  echo "[\$(date -Iseconds)] plugin-hpa-syncer run"
                  created=0; pruned=0
                  # Create HPAs for plugins that do not have one yet.
                  # Existing HPAs are never modified, so per-plugin tuning survives.
                  for plugin in \$(kubectl get difyplugins.enterprise.dify.ai -n "\$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
                    if ! kubectl get hpa "dify-plugin-\${plugin}-hpa" -n "\$NS" >/dev/null 2>&1; then
                      sed "s/__PLUGIN__/\${plugin}/g" /template/hpa.yaml | kubectl apply -f -
                      created=\$((created+1))
                      echo "  created HPA for \${plugin}"
                    fi
                  done
                  # Prune managed HPAs whose DifyPlugin no longer exists.
                  for hpa in \$(kubectl get hpa -n "\$NS" -l app.kubernetes.io/managed-by=dify-plugin-hpa -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
                    target=\$(kubectl get hpa "\$hpa" -n "\$NS" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)
                    if [ -n "\$target" ] && ! kubectl get difyplugins.enterprise.dify.ai "\$target" -n "\$NS" >/dev/null 2>&1; then
                      kubectl delete hpa "\$hpa" -n "\$NS"
                      pruned=\$((pruned+1))
                      echo "  pruned stale HPA \$hpa (plugin \$target gone)"
                    fi
                  done
                  echo "Done (created=\$created pruned=\$pruned)"
ENDOFYAML
fi
ok "Generated manifest written to: $OUTPUT_FILE"

if $DRY_RUN; then
  info "--dry-run: not applying. Review the file and apply with: kubectl apply -f $OUTPUT_FILE"
  exit 0
fi

# ============================================================
# Apply + stale cleanup
# ============================================================
info "Applying to cluster..."
kubectl apply -f "$OUTPUT_FILE"

# Managed HPAs whose DifyPlugin no longer exists are safe to remove.
stale=()
while IFS= read -r hpa_name; do
  [ -n "$hpa_name" ] || continue
  target=$(kubectl get hpa "$hpa_name" -n "$NAMESPACE" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)
  if [ -n "$target" ] && ! kubectl get "$CRD_NAME" "$target" -n "$NAMESPACE" >/dev/null 2>&1; then
    stale+=("$hpa_name")
  fi
done < <(kubectl get hpa -n "$NAMESPACE" -l "$MANAGED_BY_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

if [ ${#stale[@]} -gt 0 ]; then
  warn "Found ${#stale[@]} managed HPA(s) whose DifyPlugin no longer exists:"
  printf '  - %s\n' "${stale[@]}"
  kubectl delete hpa -n "$NAMESPACE" "${stale[@]}"
  ok "Stale HPA(s) removed."
fi

echo ""
ok "Plugin HPA(s) deployed successfully!"
echo ""
echo "    Status:      kubectl get hpa -n $NAMESPACE -l $MANAGED_BY_LABEL"
echo "    Watch:       kubectl get hpa -n $NAMESPACE -w"
if $AUTO_COVER; then
  echo "    Auto-cover:  plugin-hpa-syncer runs every 5 min; new plugins get HPAs automatically"
  echo "    Syncer logs: kubectl logs -n $NAMESPACE job/\$(kubectl get jobs -n $NAMESPACE --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')"
else
  echo "    New plugins: re-run this script after installing plugins in the console (or use --auto-cover)"
fi
echo "    Uninstall:   ./setup-plugin-hpa.sh -n $NAMESPACE --uninstall"
echo ""
