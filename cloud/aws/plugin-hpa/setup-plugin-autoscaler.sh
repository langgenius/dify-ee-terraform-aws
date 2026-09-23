#!/bin/bash
# ============================================================================
# Dify Enterprise - Plugin Autoscaler 安装脚本
# ============================================================================
# 交互式引导用户配置并部署插件自动伸缩 CronJob。
# 自动检测集群环境，智能跳过已确定的配置项。
#
# 使用方法:
#   chmod +x setup-plugin-autoscaler.sh
#   ./setup-plugin-autoscaler.sh
#
# 前提条件:
#   - kubectl 已配置且可访问集群
#   - 集群中已安装 Metrics Server (kubectl top pods 可用)
#   - Dify Enterprise 已通过 Helm 部署
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$SCRIPT_DIR/plugin-autoscaler-states.yaml"
USE_STATE_FILE=false
DEFAULT_CPU_TARGET=70
DEFAULT_SCALEUP_MAX_PERCENT=50
DEFAULT_SCALEUP_MAX_PODS=4
DEFAULT_SCALEDOWN_MAX_PERCENT=10
DEFAULT_SCALEDOWN_MAX_PODS=2
DEFAULT_SCALEDOWN_STABILIZATION_SECONDS=300
STATE_NAMESPACE=""
STATE_RELEASE=""
STATE_CPU_TARGET=""
STATE_SCALEUP_MAX_PERCENT="$DEFAULT_SCALEUP_MAX_PERCENT"
STATE_SCALEUP_MAX_PODS="$DEFAULT_SCALEUP_MAX_PODS"
STATE_SCALEDOWN_MAX_PERCENT="$DEFAULT_SCALEDOWN_MAX_PERCENT"
STATE_SCALEDOWN_MAX_PODS="$DEFAULT_SCALEDOWN_MAX_PODS"
STATE_SCALEDOWN_STABILIZATION_SECONDS="$DEFAULT_SCALEDOWN_STABILIZATION_SECONDS"
STATE_PLUGINS=""
DEPLOYED_NAMESPACE=""
DEPLOYED_RELEASE=""
DEPLOYED_CPU_TARGET=""
DEPLOYED_SCALEUP_MAX_PERCENT=""
DEPLOYED_SCALEUP_MAX_PODS=""
DEPLOYED_SCALEDOWN_MAX_PERCENT=""
DEPLOYED_SCALEDOWN_MAX_PODS=""
DEPLOYED_SCALEDOWN_STABILIZATION_SECONDS=""
DEPLOYED_PLUGINS=""
CPU_TARGET="$DEFAULT_CPU_TARGET"
SCALEUP_MAX_PERCENT="$DEFAULT_SCALEUP_MAX_PERCENT"
SCALEUP_MAX_PODS="$DEFAULT_SCALEUP_MAX_PODS"
SCALEDOWN_MAX_PERCENT="$DEFAULT_SCALEDOWN_MAX_PERCENT"
SCALEDOWN_MAX_PODS="$DEFAULT_SCALEDOWN_MAX_PODS"
SCALEDOWN_STABILIZATION_SECONDS="$DEFAULT_SCALEDOWN_STABILIZATION_SECONDS"
ENTRY_ID=""
ENTRY_MIN=""
ENTRY_MAX=""
ENTRY_CPU_TARGET=""

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_cluster_connectivity() {
  local attempts=3
  local delay_seconds=2
  local try

  if ! kubectl config current-context >/dev/null 2>&1; then
    err "No active kubectl context found. Check your kubeconfig."
    return 1
  fi

  for try in $(seq 1 "$attempts"); do
    if kubectl get ns --request-timeout=10s >/dev/null 2>&1; then
      return 0
    fi

    if [ "$try" -lt "$attempts" ]; then
      warn "Kubernetes API check failed (attempt ${try}/${attempts}), retrying in ${delay_seconds}s..."
      sleep "$delay_seconds"
    fi
  done

  err "Cannot connect to Kubernetes cluster. Current context: $(kubectl config current-context 2>/dev/null || echo unknown)"
  warn "Try: kubectl get ns --request-timeout=10s"
  return 1
}

parse_plugin_entry() {
  local entry="$1"
  IFS=':' read -r ENTRY_ID ENTRY_MIN ENTRY_MAX ENTRY_CPU_TARGET <<< "$entry"
  ENTRY_MIN="${ENTRY_MIN:-1}"
  ENTRY_MAX="${ENTRY_MAX:-4}"
}

plugin_effective_cpu_target() {
  local plugin_cpu_target="$1"
  local default_cpu_target="$2"
  echo "${plugin_cpu_target:-$default_cpu_target}"
}

plugin_list_contains_id() {
  local target_id="$1"
  local list="$2"
  local entry

  IFS=',' read -ra entries <<< "$list"
  for entry in "${entries[@]}"; do
    parse_plugin_entry "$entry"
    [ "$ENTRY_ID" = "$target_id" ] && return 0
  done
  return 1
}

plugin_config_for_id() {
  local target_id="$1"
  local list="$2"
  local entry

  IFS=',' read -ra entries <<< "$list"
  for entry in "${entries[@]}"; do
    parse_plugin_entry "$entry"
    if [ "$ENTRY_ID" = "$target_id" ]; then
      echo "${ENTRY_MIN}:${ENTRY_MAX}:${ENTRY_CPU_TARGET}"
      return 0
    fi
  done
  return 1
}

print_config_entries() {
  local list="$1"
  local default_cpu_target="$2"
  local entry effective_cpu

  IFS=',' read -ra entries <<< "$list"
  for entry in "${entries[@]}"; do
    [ -z "$entry" ] && continue
    parse_plugin_entry "$entry"
    effective_cpu=$(plugin_effective_cpu_target "$ENTRY_CPU_TARGET" "$default_cpu_target")
    echo "    - $ENTRY_ID  (${ENTRY_MIN}~${ENTRY_MAX}, cpu=${effective_cpu}%)"
  done
}

print_behavior_config() {
  local prefix="$1"
  local cpu_target="$2"
  local scaleup_max_percent="$3"
  local scaleup_max_pods="$4"
  local scaledown_max_percent="$5"
  local scaledown_max_pods="$6"
  local scaledown_stabilization_seconds="$7"

  echo "${prefix}CPU target default: ${cpu_target}%"
  echo "${prefix}scaleUp limit: +max(${scaleup_max_percent}%, ${scaleup_max_pods} pods) / 60s"
  echo "${prefix}scaleDown limit: -min(${scaledown_max_percent}%, ${scaledown_max_pods} pods) / 60s"
  echo "${prefix}scaleDown stabilization: ${scaledown_stabilization_seconds}s"
}

parse_state_file() {
  local file="$1"
  local line current_id="" current_min="" current_max="" current_cpu_target=""

  STATE_NAMESPACE=$(awk -F': *' '/^namespace:/{print $2; exit}' "$file" | xargs)
  STATE_RELEASE=$(awk -F': *' '/^release:/{print $2; exit}' "$file" | xargs)
  STATE_CPU_TARGET=$(awk -F': *' '/^cpu_target:/{print $2; exit}' "$file" | xargs)
  STATE_CPU_TARGET="${STATE_CPU_TARGET:-$DEFAULT_CPU_TARGET}"
  STATE_SCALEUP_MAX_PERCENT=$(awk -F': *' '/^scaleup_max_percent:/{print $2; exit}' "$file" | xargs)
  STATE_SCALEUP_MAX_PODS=$(awk -F': *' '/^scaleup_max_pods:/{print $2; exit}' "$file" | xargs)
  STATE_SCALEDOWN_MAX_PERCENT=$(awk -F': *' '/^scaledown_max_percent:/{print $2; exit}' "$file" | xargs)
  STATE_SCALEDOWN_MAX_PODS=$(awk -F': *' '/^scaledown_max_pods:/{print $2; exit}' "$file" | xargs)
  STATE_SCALEDOWN_STABILIZATION_SECONDS=$(awk -F': *' '/^scaledown_stabilization_seconds:/{print $2; exit}' "$file" | xargs)
  STATE_SCALEUP_MAX_PERCENT="${STATE_SCALEUP_MAX_PERCENT:-$DEFAULT_SCALEUP_MAX_PERCENT}"
  STATE_SCALEUP_MAX_PODS="${STATE_SCALEUP_MAX_PODS:-$DEFAULT_SCALEUP_MAX_PODS}"
  STATE_SCALEDOWN_MAX_PERCENT="${STATE_SCALEDOWN_MAX_PERCENT:-$DEFAULT_SCALEDOWN_MAX_PERCENT}"
  STATE_SCALEDOWN_MAX_PODS="${STATE_SCALEDOWN_MAX_PODS:-$DEFAULT_SCALEDOWN_MAX_PODS}"
  STATE_SCALEDOWN_STABILIZATION_SECONDS="${STATE_SCALEDOWN_STABILIZATION_SECONDS:-$DEFAULT_SCALEDOWN_STABILIZATION_SECONDS}"
  STATE_PLUGINS=""

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]id:[[:space:]]*(.+)$ ]]; then
      if [ -n "$current_id" ]; then
        current_min="${current_min:-1}"
        current_max="${current_max:-4}"
        current_cpu_target="${current_cpu_target:-$STATE_CPU_TARGET}"
        [ -n "$STATE_PLUGINS" ] && STATE_PLUGINS="${STATE_PLUGINS},"
        STATE_PLUGINS="${STATE_PLUGINS}${current_id}:${current_min}:${current_max}:${current_cpu_target}"
      fi
      current_id="${BASH_REMATCH[1]}"
      current_min=""
      current_max=""
      current_cpu_target=""
    elif [[ "$line" =~ ^[[:space:]]*min:[[:space:]]*([^[:space:]]+) ]]; then
      current_min="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*max:[[:space:]]*([^[:space:]]+) ]]; then
      current_max="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*cpu_target:[[:space:]]*([^[:space:]]+) ]]; then
      current_cpu_target="${BASH_REMATCH[1]}"
    fi
  done < "$file"

  if [ -n "$current_id" ]; then
    current_min="${current_min:-1}"
    current_max="${current_max:-4}"
    current_cpu_target="${current_cpu_target:-$STATE_CPU_TARGET}"
    [ -n "$STATE_PLUGINS" ] && STATE_PLUGINS="${STATE_PLUGINS},"
    STATE_PLUGINS="${STATE_PLUGINS}${current_id}:${current_min}:${current_max}:${current_cpu_target}"
  fi

  [ -n "$STATE_NAMESPACE" ] && [ -n "$STATE_RELEASE" ] && [ -n "$STATE_CPU_TARGET" ] && [ -n "$STATE_PLUGINS" ]
}

write_state_file() {
  local file="$1"
  local entry effective_cpu

  cat > "$file" <<EOF
# Plugin Autoscaler State
# Generated: $(date -Iseconds)
# Edit this file and re-run the script to apply changes.
namespace: $NAMESPACE
release: $RELEASE
cpu_target: $CPU_TARGET
scaleup_max_percent: $SCALEUP_MAX_PERCENT
scaleup_max_pods: $SCALEUP_MAX_PODS
scaledown_max_percent: $SCALEDOWN_MAX_PERCENT
scaledown_max_pods: $SCALEDOWN_MAX_PODS
scaledown_stabilization_seconds: $SCALEDOWN_STABILIZATION_SECONDS
plugins:
EOF

  IFS=',' read -ra entries <<< "$PLUGINS"
  for entry in "${entries[@]}"; do
    [ -z "$entry" ] && continue
    parse_plugin_entry "$entry"
    effective_cpu=$(plugin_effective_cpu_target "$ENTRY_CPU_TARGET" "$CPU_TARGET")
    local pname pver label
    pname=$(plugin_lookup "$ENTRY_ID" name)
    pver=$(plugin_lookup "$ENTRY_ID" version)
    label=""
    [ -n "$pname" ] && label=" # ${pname} - ${pver}"
    cat >> "$file" <<EOF
  - id: $ENTRY_ID${label}
    min: $ENTRY_MIN
    max: $ENTRY_MAX
EOF
    if [ "$effective_cpu" != "$CPU_TARGET" ]; then
      cat >> "$file" <<EOF
    cpu_target: $effective_cpu
EOF
    fi
  done
}

parse_deployed_autoscaler() {
  local namespace="$1"
  local api_host secret_name

  DEPLOYED_NAMESPACE=""
  DEPLOYED_RELEASE=""
  DEPLOYED_CPU_TARGET=""
  DEPLOYED_SCALEUP_MAX_PERCENT=""
  DEPLOYED_SCALEUP_MAX_PODS=""
  DEPLOYED_SCALEDOWN_MAX_PERCENT=""
  DEPLOYED_SCALEDOWN_MAX_PODS=""
  DEPLOYED_SCALEDOWN_STABILIZATION_SECONDS=""
  DEPLOYED_PLUGINS=""

  kubectl get cronjob plugin-autoscaler -n "$namespace" &>/dev/null || return 1

  DEPLOYED_NAMESPACE="$namespace"
  DEPLOYED_PLUGINS=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="PLUGINS")].value}' 2>/dev/null)
  DEPLOYED_CPU_TARGET=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="CPU_TARGET_PERCENT")].value}' 2>/dev/null)
  DEPLOYED_SCALEUP_MAX_PERCENT=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SCALEUP_MAX_PERCENT")].value}' 2>/dev/null)
  DEPLOYED_SCALEUP_MAX_PODS=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SCALEUP_MAX_PODS")].value}' 2>/dev/null)
  DEPLOYED_SCALEDOWN_MAX_PERCENT=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SCALEDOWN_MAX_PERCENT")].value}' 2>/dev/null)
  DEPLOYED_SCALEDOWN_MAX_PODS=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SCALEDOWN_MAX_PODS")].value}' 2>/dev/null)
  DEPLOYED_SCALEDOWN_STABILIZATION_SECONDS=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SCALEDOWN_STABILIZATION")].value}' 2>/dev/null)
  api_host=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="API_HOST")].value}' 2>/dev/null)
  secret_name=$(kubectl get cronjob plugin-autoscaler -n "$namespace" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="JWT_SECRET")].valueFrom.secretKeyRef.name}' 2>/dev/null)

  DEPLOYED_SCALEUP_MAX_PERCENT="${DEPLOYED_SCALEUP_MAX_PERCENT:-$DEFAULT_SCALEUP_MAX_PERCENT}"
  DEPLOYED_SCALEUP_MAX_PODS="${DEPLOYED_SCALEUP_MAX_PODS:-$DEFAULT_SCALEUP_MAX_PODS}"
  DEPLOYED_SCALEDOWN_MAX_PERCENT="${DEPLOYED_SCALEDOWN_MAX_PERCENT:-$DEFAULT_SCALEDOWN_MAX_PERCENT}"
  DEPLOYED_SCALEDOWN_MAX_PODS="${DEPLOYED_SCALEDOWN_MAX_PODS:-$DEFAULT_SCALEDOWN_MAX_PODS}"
  DEPLOYED_SCALEDOWN_STABILIZATION_SECONDS="${DEPLOYED_SCALEDOWN_STABILIZATION_SECONDS:-$DEFAULT_SCALEDOWN_STABILIZATION_SECONDS}"

  if [[ "$api_host" =~ ^http://([^.]*)-plugin-manager-svc\. ]]; then
    DEPLOYED_RELEASE="${BASH_REMATCH[1]}"
  elif [[ "$secret_name" =~ ^(.*)-plugin-manager-secret$ ]]; then
    DEPLOYED_RELEASE="${BASH_REMATCH[1]}"
  fi

  [ -n "$DEPLOYED_PLUGINS" ] && [ -n "$DEPLOYED_CPU_TARGET" ]
}

print_deployed_vs_yaml_diff() {
  local yaml_list="$1"
  local deployed_list="$2"
  local yaml_cpu_target="$3"
  local deployed_cpu_target="$4"
  local yaml_scaleup_max_percent="$5"
  local yaml_scaleup_max_pods="$6"
  local yaml_scaledown_max_percent="$7"
  local yaml_scaledown_max_pods="$8"
  local yaml_scaledown_stabilization_seconds="$9"
  local deployed_scaleup_max_percent="${10}"
  local deployed_scaleup_max_pods="${11}"
  local deployed_scaledown_max_percent="${12}"
  local deployed_scaledown_max_pods="${13}"
  local deployed_scaledown_stabilization_seconds="${14}"
  local entry id yaml_config deployed_config
  local yaml_min yaml_max yaml_plugin_cpu deployed_min deployed_max deployed_plugin_cpu
  local has_diff=false

  echo ""
  echo "  Diff: deployed autoscaler vs YAML"

  if [ "$deployed_cpu_target" != "$yaml_cpu_target" ]; then
    echo "    - CPU target default differs: deployed=${deployed_cpu_target}% yaml=${yaml_cpu_target}%"
    has_diff=true
  fi
  if [ "$deployed_scaleup_max_percent" != "$yaml_scaleup_max_percent" ]; then
    echo "    - scaleUp max percent differs: deployed=${deployed_scaleup_max_percent}% yaml=${yaml_scaleup_max_percent}%"
    has_diff=true
  fi
  if [ "$deployed_scaleup_max_pods" != "$yaml_scaleup_max_pods" ]; then
    echo "    - scaleUp max pods differs: deployed=${deployed_scaleup_max_pods} yaml=${yaml_scaleup_max_pods}"
    has_diff=true
  fi
  if [ "$deployed_scaledown_max_percent" != "$yaml_scaledown_max_percent" ]; then
    echo "    - scaleDown max percent differs: deployed=${deployed_scaledown_max_percent}% yaml=${yaml_scaledown_max_percent}%"
    has_diff=true
  fi
  if [ "$deployed_scaledown_max_pods" != "$yaml_scaledown_max_pods" ]; then
    echo "    - scaleDown max pods differs: deployed=${deployed_scaledown_max_pods} yaml=${yaml_scaledown_max_pods}"
    has_diff=true
  fi
  if [ "$deployed_scaledown_stabilization_seconds" != "$yaml_scaledown_stabilization_seconds" ]; then
    echo "    - scaleDown stabilization differs: deployed=${deployed_scaledown_stabilization_seconds}s yaml=${yaml_scaledown_stabilization_seconds}s"
    has_diff=true
  fi

  IFS=',' read -ra yaml_entries <<< "$yaml_list"
  for entry in "${yaml_entries[@]}"; do
    [ -z "$entry" ] && continue
    parse_plugin_entry "$entry"
    id="$ENTRY_ID"
    yaml_min="$ENTRY_MIN"
    yaml_max="$ENTRY_MAX"
    yaml_plugin_cpu=$(plugin_effective_cpu_target "$ENTRY_CPU_TARGET" "$yaml_cpu_target")
    if deployed_config=$(plugin_config_for_id "$id" "$deployed_list"); then
      IFS=':' read -r deployed_min deployed_max deployed_plugin_cpu <<< "$deployed_config"
      deployed_plugin_cpu=$(plugin_effective_cpu_target "$deployed_plugin_cpu" "$deployed_cpu_target")
      if [ "$yaml_min" != "$deployed_min" ] || [ "$yaml_max" != "$deployed_max" ] || [ "$yaml_plugin_cpu" != "$deployed_plugin_cpu" ]; then
        echo "    - Plugin $id differs: deployed=${deployed_min}~${deployed_max},cpu=${deployed_plugin_cpu}% yaml=${yaml_min}~${yaml_max},cpu=${yaml_plugin_cpu}%"
        has_diff=true
      fi
    else
      echo "    - Plugin $id exists only in YAML: ${yaml_min}~${yaml_max},cpu=${yaml_plugin_cpu}%"
      has_diff=true
    fi
  done

  IFS=',' read -ra deployed_entries <<< "$deployed_list"
  for entry in "${deployed_entries[@]}"; do
    [ -z "$entry" ] && continue
    parse_plugin_entry "$entry"
    id="$ENTRY_ID"
    if ! plugin_list_contains_id "$id" "$yaml_list"; then
      deployed_plugin_cpu=$(plugin_effective_cpu_target "$ENTRY_CPU_TARGET" "$deployed_cpu_target")
      echo "    - Plugin $id exists only in deployed config: ${ENTRY_MIN}~${ENTRY_MAX},cpu=${deployed_plugin_cpu}%"
      has_diff=true
    fi
  done

  if [ "$has_diff" = false ]; then
    echo "    - No differences"
  fi
}

# ============================================================
# Step 0: Pre-flight checks
# ============================================================
echo ""
echo "=========================================="
echo "  Dify Plugin Autoscaler Setup"
echo "=========================================="
echo ""

if ! command -v kubectl &>/dev/null; then
  err "kubectl not found. Please install kubectl first."
  exit 1
fi

if ! check_cluster_connectivity; then
  exit 1
fi
ok "kubectl connected"

if [ -f "$STATE_FILE" ]; then
  info "Found existing config: $(basename "$STATE_FILE")"
  if parse_state_file "$STATE_FILE"; then
    IFS=',' read -ra STATE_ENTRIES <<< "$STATE_PLUGINS"
    echo ""
    echo "  Current config: ${#STATE_ENTRIES[@]} plugins"
    print_behavior_config "    - " "$STATE_CPU_TARGET" "$STATE_SCALEUP_MAX_PERCENT" "$STATE_SCALEUP_MAX_PODS" "$STATE_SCALEDOWN_MAX_PERCENT" "$STATE_SCALEDOWN_MAX_PODS" "$STATE_SCALEDOWN_STABILIZATION_SECONDS"
    print_config_entries "$STATE_PLUGINS" "$STATE_CPU_TARGET"

    if parse_deployed_autoscaler "$STATE_NAMESPACE"; then
      echo ""
      echo "  Actual deployed autoscaler:"
      echo "    - namespace: $DEPLOYED_NAMESPACE"
      [ -n "$DEPLOYED_RELEASE" ] && echo "    - release: $DEPLOYED_RELEASE"
      print_behavior_config "    - " "$DEPLOYED_CPU_TARGET" "$DEPLOYED_SCALEUP_MAX_PERCENT" "$DEPLOYED_SCALEUP_MAX_PODS" "$DEPLOYED_SCALEDOWN_MAX_PERCENT" "$DEPLOYED_SCALEDOWN_MAX_PODS" "$DEPLOYED_SCALEDOWN_STABILIZATION_SECONDS"
      print_config_entries "$DEPLOYED_PLUGINS" "$DEPLOYED_CPU_TARGET"
      print_deployed_vs_yaml_diff \
        "$STATE_PLUGINS" "$DEPLOYED_PLUGINS" \
        "$STATE_CPU_TARGET" "$DEPLOYED_CPU_TARGET" \
        "$STATE_SCALEUP_MAX_PERCENT" "$STATE_SCALEUP_MAX_PODS" \
        "$STATE_SCALEDOWN_MAX_PERCENT" "$STATE_SCALEDOWN_MAX_PODS" "$STATE_SCALEDOWN_STABILIZATION_SECONDS" \
        "$DEPLOYED_SCALEUP_MAX_PERCENT" "$DEPLOYED_SCALEUP_MAX_PODS" \
        "$DEPLOYED_SCALEDOWN_MAX_PERCENT" "$DEPLOYED_SCALEDOWN_MAX_PODS" "$DEPLOYED_SCALEDOWN_STABILIZATION_SECONDS"
    else
      echo ""
      echo "  Actual deployed autoscaler:"
      echo "    - Not found in namespace $STATE_NAMESPACE"
    fi

    if kubectl get namespace "$STATE_NAMESPACE" &>/dev/null; then
      NEW_PLUGIN_LINES=()
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        id=$(echo "$line" | awk '{print $1}')
        if ! plugin_list_contains_id "$id" "$STATE_PLUGINS"; then
          NEW_PLUGIN_LINES+=("$line")
        fi
      done < <(kubectl get difyplugins.enterprise.dify.ai -n "$STATE_NAMESPACE" \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.state,REPLICA:.spec.runner.k8sPod.replica,READY:.status.ready' \
        --no-headers 2>/dev/null)

      if [ ${#NEW_PLUGIN_LINES[@]} -gt 0 ]; then
        echo ""
        echo "  New plugins in cluster (not in config):"
        for line in "${NEW_PLUGIN_LINES[@]}"; do
          echo "    - $line"
        done
      fi
    else
      warn "Namespace from state file not found: $STATE_NAMESPACE"
    fi

    echo ""
    echo "  1) Update deployment from YAML config"
    echo "  2) Skip YAML and re-select plugins (will overwrite YAML)"
    echo ""
    while true; do
      read -rp "> " STATE_CHOICE
      case "$STATE_CHOICE" in
        ""|1)
          USE_STATE_FILE=true
          NAMESPACE="$STATE_NAMESPACE"
          RELEASE="$STATE_RELEASE"
          CPU_TARGET="$STATE_CPU_TARGET"
          SCALEUP_MAX_PERCENT="$STATE_SCALEUP_MAX_PERCENT"
          SCALEUP_MAX_PODS="$STATE_SCALEUP_MAX_PODS"
          SCALEDOWN_MAX_PERCENT="$STATE_SCALEDOWN_MAX_PERCENT"
          SCALEDOWN_MAX_PODS="$STATE_SCALEDOWN_MAX_PODS"
          SCALEDOWN_STABILIZATION_SECONDS="$STATE_SCALEDOWN_STABILIZATION_SECONDS"
          PLUGINS="$STATE_PLUGINS"
          ok "Using configuration from $(basename "$STATE_FILE")"
          break
          ;;
        2)
          info "Skipping YAML config and continuing with interactive setup"
          break
          ;;
        *)
          warn "Please enter 1 or 2"
          ;;
      esac
    done
  else
    warn "State file could not be parsed. Continuing with interactive setup."
  fi
fi

# ============================================================
# Step 1: Detect namespace (auto-use if found)
# ============================================================
if [ "$USE_STATE_FILE" != true ]; then
  info "Detecting Dify installation..."
  DETECTED_NS=$(kubectl get deployments --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep 'plugin-manager' | head -1 | awk '{print $1}')

  if [ -n "$DETECTED_NS" ]; then
    NAMESPACE="$DETECTED_NS"
    ok "Found Dify in namespace: $NAMESPACE"
  else
    warn "Could not auto-detect Dify namespace"
    read -rp "Enter Dify namespace: " NAMESPACE
  fi

  if [ -z "$NAMESPACE" ]; then
    err "Namespace is required"
    exit 1
  fi
else
  ok "Using namespace from state file: $NAMESPACE"
fi

# ============================================================
# Step 2: Detect Helm release name (auto-use if found)
# ============================================================
if [ "$USE_STATE_FILE" != true ]; then
  DETECTED_RELEASE=$(kubectl get deployments -n "$NAMESPACE" -o name 2>/dev/null \
    | grep plugin-manager | sed 's|deployment.apps/||' | sed 's|-plugin-manager||')

  if [ -n "$DETECTED_RELEASE" ]; then
    RELEASE="$DETECTED_RELEASE"
    ok "Helm release name: $RELEASE"
  else
    read -rp "Enter Helm release name [dify]: " RELEASE
    RELEASE="${RELEASE:-dify}"
  fi
else
  ok "Using Helm release name from state file: $RELEASE"
fi

SVC_NAME="${RELEASE}-plugin-manager-svc"
SECRET_NAME="${RELEASE}-plugin-manager-secret"

if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  err "Secret $SECRET_NAME not found in namespace $NAMESPACE"
  exit 1
fi
ok "Secret $SECRET_NAME found"

# ============================================================
# Step 3: Check Metrics Server
# ============================================================
detect_k8s_platform() {
  if kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -qi 'aws'; then
    echo "eks"
  elif kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -qi 'gce'; then
    echo "gke"
  elif kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -qi 'azure'; then
    echo "aks"
  else
    echo "unknown"
  fi
}

if kubectl top pods -n "$NAMESPACE" --no-headers &>/dev/null; then
  ok "Metrics Server is available"
else
  warn "Metrics Server not detected. kubectl top pods failed."
  echo ""
  echo "   Plugin autoscaler requires Metrics Server to function."
  echo ""

  PLATFORM=$(detect_k8s_platform)
  case "$PLATFORM" in
    eks)
      info "Detected platform: AWS EKS"
      echo ""
      echo "   Option A (recommended): Enable EKS Metrics Server addon"
      echo "     aws eks create-addon --cluster-name <cluster> --addon-name eks-pod-identity-agent"
      echo "     aws eks create-addon --cluster-name <cluster> --addon-name metrics-server"
      echo ""
      echo "   Option B: Install via Helm"
      echo "     helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/"
      echo "     helm install metrics-server metrics-server/metrics-server -n kube-system"
      ;;
    gke)
      info "Detected platform: GKE (Metrics Server should be built-in)"
      echo ""
      echo "   GKE includes Metrics Server by default. If kubectl top pods fails,"
      echo "   it may be temporarily unavailable or disabled."
      echo "   Check: gcloud container clusters describe <cluster> --zone <zone>"
      ;;
    aks)
      info "Detected platform: AKS (Metrics Server should be built-in)"
      echo ""
      echo "   AKS includes Metrics Server by default. If kubectl top pods fails,"
      echo "   it may be temporarily unavailable. Check cluster health in Azure Portal."
      ;;
    *)
      info "Detected platform: Unknown / self-managed cluster"
      echo ""
      echo "   Install Metrics Server via Helm:"
      echo "     helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/"
      echo "     helm repo update"
      echo "     helm install metrics-server metrics-server/metrics-server -n kube-system \\"
      echo "       --set 'args[0]=--kubelet-preferred-address-types=InternalIP'"
      echo ""
      echo "   Note: Only add '--set args[1]=--kubelet-insecure-tls' if your kubelet"
      echo "   does not have valid TLS certificates (not recommended for production)."
      ;;
  esac

  echo ""
  echo "   You can continue now and install Metrics Server later."
  echo "   The CronJob will be deployed but won't function until Metrics Server is available."
  echo ""
  read -rp "Continue without Metrics Server? [y/N]: " CONTINUE
  [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ] && exit 1
fi

# ============================================================
# Step 4: Select plugins to autoscale (numbered menu)
# ============================================================
echo ""
plugin_lookup() {
  local target="$1" field="$2"
  for idx in "${!PLUGIN_IDS[@]}"; do
    if [ "${PLUGIN_IDS[$idx]}" = "$target" ]; then
      case "$field" in
        name)    echo "${PLUGIN_NAMES[$idx]}" ;;
        version) echo "${PLUGIN_VERSIONS[$idx]}" ;;
      esac
      return
    fi
  done
}

PLUGIN_IDS=()
PLUGIN_NAMES=()
PLUGIN_VERSIONS=()
PLUGIN_STATUSES=()
PLUGIN_REPLICAS=()
PLUGIN_READYS=()
while IFS=$'\t' read -r id identifier status replica ready; do
  [ -z "$id" ] && continue
  pname=$(echo "$identifier" | sed 's/:.*//')
  pver=$(echo "$identifier" | sed 's/[^:]*://;s/@.*//')
  PLUGIN_IDS+=("$id")
  PLUGIN_NAMES+=("$pname")
  PLUGIN_VERSIONS+=("$pver")
  PLUGIN_STATUSES+=("$status")
  PLUGIN_REPLICAS+=("$replica")
  PLUGIN_READYS+=("$ready")
done < <(kubectl get difyplugins.enterprise.dify.ai -n "$NAMESPACE" \
  -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{index .metadata.annotations "enterprise.dify.ai/plugin-unique-identifier"}}{{"\t"}}{{.status.state}}{{"\t"}}{{.spec.runner.k8sPod.replica}}{{"\t"}}{{.status.ready}}{{"\n"}}{{end}}' \
  2>/dev/null)

if [ ${#PLUGIN_IDS[@]} -eq 0 ]; then
  err "No plugins found in namespace $NAMESPACE"
  exit 1
fi

if [ "$USE_STATE_FILE" != true ]; then
  info "Fetching installed plugins..."
  echo ""
  printf "  %-3s %-6s %-24s %-10s %-10s %-8s %s\n" "#" "ID" "PLUGIN NAME" "VERSION" "STATUS" "REPLICA" "READY"
  printf "  %-3s %-6s %-24s %-10s %-10s %-8s %s\n" "---" "------" "-----------" "-------" "------" "-------" "-----"
  for i in "${!PLUGIN_IDS[@]}"; do
    short_id="${PLUGIN_IDS[$i]:0:4}"
    printf "  %-3s %-6s %-24s %-10s %-10s %-8s %s\n" "$((i+1))" "${short_id}.." "${PLUGIN_NAMES[$i]}" "${PLUGIN_VERSIONS[$i]}" "${PLUGIN_STATUSES[$i]}" "${PLUGIN_REPLICAS[$i]}" "${PLUGIN_READYS[$i]}"
  done
  echo ""
  echo -e "  ${BOLD}a${NC}   Select all plugins"
  echo ""

  echo "Enter selection (numbers separated by spaces, or 'a' for all):"
  read -rp "> " SELECTION

  SELECTED_IDS=()
  if [ "$SELECTION" = "a" ] || [ "$SELECTION" = "A" ]; then
    SELECTED_IDS=("${PLUGIN_IDS[@]}")
    ok "Selected all ${#PLUGIN_IDS[@]} plugins"
  else
    for num in $SELECTION; do
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#PLUGIN_IDS[@]} ]; then
        SELECTED_IDS+=("${PLUGIN_IDS[$((num-1))]}")
      else
        warn "Invalid selection: $num, skipping"
      fi
    done
  fi

  if [ ${#SELECTED_IDS[@]} -eq 0 ]; then
    err "No plugins selected"
    exit 1
  fi
else
  ok "Using plugin configuration from state file"
fi

# ============================================================
# Step 5: Scaling behavior and per-plugin CPU target
# ============================================================
echo ""
if [ "$USE_STATE_FILE" != true ]; then
  CPU_TARGET="$DEFAULT_CPU_TARGET"
  SCALEUP_MAX_PERCENT="$DEFAULT_SCALEUP_MAX_PERCENT"
  SCALEUP_MAX_PODS="$DEFAULT_SCALEUP_MAX_PODS"
  SCALEDOWN_MAX_PERCENT="$DEFAULT_SCALEDOWN_MAX_PERCENT"
  SCALEDOWN_MAX_PODS="$DEFAULT_SCALEDOWN_MAX_PODS"
  SCALEDOWN_STABILIZATION_SECONDS="$DEFAULT_SCALEDOWN_STABILIZATION_SECONDS"

  PLUGINS=""
  for id in "${SELECTED_IDS[@]}"; do
    [ -n "$PLUGINS" ] && PLUGINS="${PLUGINS},"
    PLUGINS="${PLUGINS}${id}:1:4:${CPU_TARGET}"
  done

  info "Using defaults: CPU target=${CPU_TARGET}%, replicas=1~4 per plugin"
  info "To customize per-plugin settings, edit $(basename "$STATE_FILE") and re-run this script."
else
  ok "Using scaling behavior from state file"
fi

# ============================================================
# Step 6: Summary & Confirm
# ============================================================
API_HOST="http://${SVC_NAME}.${NAMESPACE}.svc.cluster.local:8084"

echo ""
echo "=========================================="
echo "  Configuration Summary"
echo "=========================================="
echo "  Namespace:    $NAMESPACE"
echo "  Release:      $RELEASE"
echo "  API Host:     $API_HOST"
echo "  Secret:       $SECRET_NAME"
echo "  CPU Target:   ${CPU_TARGET}% (global default)"
echo "  scaleUp:      +max(${SCALEUP_MAX_PERCENT}%, ${SCALEUP_MAX_PODS} pods) / 60s"
echo "  scaleDown:    -min(${SCALEDOWN_MAX_PERCENT}%, ${SCALEDOWN_MAX_PODS} pods) / 60s"
echo "  Cooldown:     ${SCALEDOWN_STABILIZATION_SECONDS}s"
echo "  Plugins:"
IFS=',' read -ra DISPLAY_ENTRIES <<< "$PLUGINS"
for entry in "${DISPLAY_ENTRIES[@]}"; do
  parse_plugin_entry "$entry"
  effective_cpu=$(plugin_effective_cpu_target "$ENTRY_CPU_TARGET" "$CPU_TARGET")
  echo "    - ${ENTRY_ID:0:4}.. $(plugin_lookup "$ENTRY_ID" name) v$(plugin_lookup "$ENTRY_ID" version)  replicas: ${ENTRY_MIN}~${ENTRY_MAX}  cpu: ${effective_cpu}%"
done
echo "=========================================="
echo ""
read -rp "Deploy autoscaler with these settings? [Y/n]: " CONFIRM
[ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ] && { echo "Cancelled."; exit 0; }

# ============================================================
# Step 7: Generate & Apply YAML
# ============================================================
OUTPUT_FILE="plugin-autoscaler-generated.yaml"

cat > "$OUTPUT_FILE" << ENDOFYAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: plugin-autoscaler
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: plugin-autoscaler
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: plugin-autoscaler
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: plugin-autoscaler
  namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: plugin-autoscaler
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: plugin-autoscaler
  namespace: ${NAMESPACE}
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 55
      template:
        spec:
          serviceAccountName: plugin-autoscaler
          restartPolicy: Never
          containers:
          - name: autoscaler
            image: bitnami/kubectl:latest
            env:
            - name: PLUGINS
              value: "${PLUGINS}"
            - name: NAMESPACE
              value: "${NAMESPACE}"
            - name: CPU_TARGET_PERCENT
              value: "${CPU_TARGET}"
            - name: SCALEUP_MAX_PERCENT
              value: "${SCALEUP_MAX_PERCENT}"
            - name: SCALEUP_MAX_PODS
              value: "${SCALEUP_MAX_PODS}"
            - name: SCALEDOWN_MAX_PERCENT
              value: "${SCALEDOWN_MAX_PERCENT}"
            - name: SCALEDOWN_MAX_PODS
              value: "${SCALEDOWN_MAX_PODS}"
            - name: SCALEDOWN_STABILIZATION
              value: "${SCALEDOWN_STABILIZATION_SECONDS}"
            - name: API_HOST
              value: "${API_HOST}"
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: DASHBOARD_JWT_SECRET_KEY
            command:
            - /bin/bash
            - -c
            - |
              set -e
              STATE_CONFIGMAP_NAME="plugin-autoscaler-state"

              b64url() {
                openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
              }
              make_jwt() {
                local payload="\$1" secret="\$2"
                local header=\$(echo -n '{"alg":"HS256","typ":"JWT"}' | b64url)
                local body=\$(echo -n "\$payload" | b64url)
                local sig=\$(echo -n "\${header}.\${body}" | openssl dgst -sha256 -hmac "\$secret" -binary | b64url)
                echo "\${header}.\${body}.\${sig}"
              }
              ceil_div() {
                local numerator="\$1" denominator="\$2"
                echo \$(( (numerator + denominator - 1) / denominator ))
              }
              max_int() {
                [ "\$1" -ge "\$2" ] && echo "\$1" || echo "\$2"
              }
              min_int() {
                [ "\$1" -le "\$2" ] && echo "\$1" || echo "\$2"
              }
              cpu_to_millicores() {
                local cpu="\$1"
                case "\$cpu" in
                  *m) echo "\${cpu%m}" ;;
                  ""|0) echo "100" ;;
                  *) awk "BEGIN { printf \"%d\", \$cpu * 1000 }" ;;
                esac
              }
              ensure_state_configmap() {
                kubectl get configmap "\$STATE_CONFIGMAP_NAME" -n "\$NS" >/dev/null 2>&1 || \
                  kubectl create configmap "\$STATE_CONFIGMAP_NAME" -n "\$NS" >/dev/null
              }
              get_last_scaledown_timestamp() {
                local plugin="\$1"
                kubectl get configmap "\$STATE_CONFIGMAP_NAME" -n "\$NS" -o jsonpath="{.data.\$plugin}" 2>/dev/null || true
              }
              set_last_scaledown_timestamp() {
                local plugin="\$1" timestamp="\$2"
                kubectl patch configmap "\$STATE_CONFIGMAP_NAME" -n "\$NS" --type merge \
                  -p "{\"data\":{\"\${plugin}\":\"\${timestamp}\"}}" >/dev/null
              }
              scale_plugin_api() {
                local plugin="\$1" replicas="\$2"
                local url="\${API_HOST}/v1/plugin-manager/plugin-instances/\${plugin}/scale"
                curl -s -o /dev/null -w "%{http_code}" -X POST "\$url" \
                  -H "Content-Type: application/json" \
                  -H "Authorization: Bearer \$ACCESS" \
                  -H "X-CSRF-Token: \$CSRF" \
                  -d "{\"replicas\": \$replicas}"
              }

              EXP=\$(( \$(date +%s) + 300 ))
              ACCESS=\$(make_jwt "{\"user_id\":\"autoscaler\",\"exp\":\$EXP}" "\$JWT_SECRET")
              CSRF=\$(make_jwt "{\"sub\":\"autoscaler\",\"exp\":\$EXP}" "\$JWT_SECRET")
              NS="\$NAMESPACE"
              ALL_METRICS=\$(kubectl top pods -n "\$NS" --no-headers 2>/dev/null || true)

              scale_plugin() {
                local plugin="\$1" min_replicas="\$2" max_replicas="\$3" cpu_target_percent="\$4"
                local current_replicas cpu_req cpu_req_m total_cpu pod_count total_req avg_util raw_desired desired
                local allowed_percent allowed_delta capped_desired http_code now last_scaledown age effective_cpu_target

                current_replicas=\$(kubectl get deployment "\$plugin" -n "\$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null) || return
                cpu_req=\$(kubectl get deployment "\$plugin" -n "\$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
                cpu_req_m=\$(cpu_to_millicores "\$cpu_req")
                effective_cpu_target="\${cpu_target_percent:-\$CPU_TARGET_PERCENT}"

                total_cpu=0
                pod_count=0
                while IFS= read -r line; do
                  [ -z "\$line" ] && continue
                  cpu_val=\$(echo "\$line" | awk '{print \$2}' | sed 's/m//')
                  total_cpu=\$((total_cpu + cpu_val))
                  pod_count=\$((pod_count + 1))
                done <<< "\$(echo "\$ALL_METRICS" | grep "^\${plugin}")"

                if [ "\$pod_count" -eq 0 ]; then
                  echo "  [\$plugin] no pod metrics, skip"
                  return
                fi

                total_req=\$((cpu_req_m * pod_count))
                avg_util=\$((total_cpu * 100 / total_req))
                raw_desired=\$(( (current_replicas * avg_util + effective_cpu_target - 1) / effective_cpu_target ))
                desired="\$raw_desired"
                [ "\$desired" -lt "\$min_replicas" ] && desired="\$min_replicas"
                [ "\$desired" -gt "\$max_replicas" ] && desired="\$max_replicas"

                if [ "\$desired" -gt "\$current_replicas" ]; then
                  allowed_percent=\$(ceil_div \$((current_replicas * SCALEUP_MAX_PERCENT)) 100)
                  [ "\$allowed_percent" -lt 1 ] && allowed_percent=1
                  allowed_delta=\$(max_int "\$allowed_percent" "\$SCALEUP_MAX_PODS")
                  capped_desired=\$((current_replicas + allowed_delta))
                  [ "\$desired" -gt "\$capped_desired" ] && desired="\$capped_desired"
                  [ "\$desired" -gt "\$max_replicas" ] && desired="\$max_replicas"

                  if [ "\$desired" -ne "\$current_replicas" ]; then
                    http_code=\$(scale_plugin_api "\$plugin" "\$desired")
                    echo "  [\$plugin] cpu=\${total_cpu}m util=\${avg_util}% target=\${effective_cpu_target}% up \$current_replicas->\$desired (raw=\$raw_desired) HTTP=\$http_code"
                  else
                    echo "  [\$plugin] cpu=\${total_cpu}m util=\${avg_util}% target=\${effective_cpu_target}% replicas=\$current_replicas capped by scaleUp policy"
                  fi
                  return
                fi

                if [ "\$desired" -lt "\$current_replicas" ]; then
                  ensure_state_configmap
                  now=\$(date +%s)
                  last_scaledown=\$(get_last_scaledown_timestamp "\$plugin")
                  if [ -n "\$last_scaledown" ] && [[ "\$last_scaledown" =~ ^[0-9]+$ ]]; then
                    age=\$((now - last_scaledown))
                    if [ "\$age" -lt "\$SCALEDOWN_STABILIZATION" ]; then
                      echo "  [\$plugin] cpu=\${total_cpu}m util=\${avg_util}% target=\${effective_cpu_target}% scaleDown blocked by stabilization (\${age}s<\${SCALEDOWN_STABILIZATION}s)"
                      return
                    fi
                  fi

                  allowed_percent=\$(ceil_div \$((current_replicas * SCALEDOWN_MAX_PERCENT)) 100)
                  [ "\$allowed_percent" -lt 1 ] && allowed_percent=1
                  allowed_delta=\$(min_int "\$allowed_percent" "\$SCALEDOWN_MAX_PODS")
                  capped_desired=\$((current_replicas - allowed_delta))
                  [ "\$desired" -lt "\$capped_desired" ] && desired="\$capped_desired"
                  [ "\$desired" -lt "\$min_replicas" ] && desired="\$min_replicas"

                  if [ "\$desired" -ne "\$current_replicas" ]; then
                    http_code=\$(scale_plugin_api "\$plugin" "\$desired")
                    if [[ "\$http_code" =~ ^20[0-9]$ ]]; then
                      set_last_scaledown_timestamp "\$plugin" "\$now"
                    fi
                    echo "  [\$plugin] cpu=\${total_cpu}m util=\${avg_util}% target=\${effective_cpu_target}% down \$current_replicas->\$desired (raw=\$raw_desired) HTTP=\$http_code"
                  else
                    echo "  [\$plugin] cpu=\${total_cpu}m util=\${avg_util}% target=\${effective_cpu_target}% replicas=\$current_replicas capped by scaleDown policy"
                  fi
                  return
                fi

                echo "  [\$plugin] cpu=\${total_cpu}m util=\${avg_util}% target=\${effective_cpu_target}% replicas=\$current_replicas OK"
              }

              echo "[\$(date -Iseconds)] Plugin Autoscaler run"
              IFS=',' read -ra PLUGIN_LIST <<< "\$PLUGINS"
              for entry in "\${PLUGIN_LIST[@]}"; do
                IFS=':' read -r id min max plugin_cpu_target <<< "\$entry"
                scale_plugin "\$id" "\${min:-1}" "\${max:-4}" "\${plugin_cpu_target:-\$CPU_TARGET_PERCENT}"
              done
              echo "Done (\${#PLUGIN_LIST[@]} plugins checked)"
ENDOFYAML

ok "Generated $OUTPUT_FILE"

# Apply
info "Applying to cluster..."
kubectl apply -f "$OUTPUT_FILE"

echo ""
ok "Plugin Autoscaler deployed successfully!"
write_state_file "$STATE_FILE"
ok "State file written: $STATE_FILE"
echo ""
echo "  Useful commands:"
echo "    View logs:   kubectl logs -n $NAMESPACE job/\$(kubectl get jobs -n $NAMESPACE --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')"
echo "    Pause:       kubectl patch cronjob plugin-autoscaler -n $NAMESPACE -p '{\"spec\":{\"suspend\":true}}'"
echo "    Resume:      kubectl patch cronjob plugin-autoscaler -n $NAMESPACE -p '{\"spec\":{\"suspend\":false}}'"
echo "    Uninstall:   kubectl delete -f $OUTPUT_FILE"
echo ""
