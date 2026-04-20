# HPA + Cluster Autoscaler + Metrics Server Implementation Plan

**Implementation Date**: 2026-01-28
**Status**: ✅ Completed
**Version**: 1.0

## Overview

This document describes the implementation of a complete autoscaling solution for Dify Enterprise Edition on AWS EKS, including:
- **Metrics Server**: Provides CPU/memory metrics (required by HPA)
- **Cluster Autoscaler (CA)**: Automatically scales EKS node groups
- **Horizontal Pod Autoscaler (HPA)**: Automatically scales Dify pod replicas

## Architecture

### Component Dependencies

```
EKS Cluster → Node Group (with CA tags) → Metrics Server → Cluster Autoscaler
                                                        ↘
                                                          HPA Resources
```

### Autoscaling Flow

```
User Request → HPA detects high CPU/memory utilization
  ↓
HPA increases Pod replicas to meet demand
  ↓
Pods enter Pending state (insufficient node resources)
  ↓
Cluster Autoscaler detects Pending pods
  ↓
CA adds EC2 instances to the node group (ASG)
  ↓
New nodes join the EKS cluster
  ↓
Pending pods are scheduled on new nodes
  ↓
Scaling complete ✓
```

## Files Modified/Created

### 1. NEW: `tf/autoscaling.tf`

Complete autoscaling infrastructure containing:

#### Metrics Server
- Helm release with EKS-specific kubelet configuration
- Production configuration: 2 replicas with PodDisruptionBudget
- Test configuration: 1 replica
- EKS-specific args: `--kubelet-preferred-address-types=InternalIP`, `--kubelet-insecure-tls`
- Configurable chart repo and image registry for AWS China support

#### Cluster Autoscaler IRSA (IAM Roles for Service Accounts)
- IAM role with proper OIDC trust policy
- Conditions match: `system:serviceaccount:kube-system:cluster-autoscaler`
- IAM policy with required permissions:
  - Read: `autoscaling:Describe*`, `ec2:Describe*`, `eks:DescribeNodegroup`
  - **Critical**: `ec2:DescribeLaunchTemplateVersions` (required for Launch Template support)
  - Write (conditional on tags): `autoscaling:SetDesiredCapacity`, `autoscaling:TerminateInstanceInAutoScalingGroup`

#### Cluster Autoscaler Helm Release
- Pinned image version (must match EKS cluster version)
- Explicit IRSA role annotation
- Auto-discovery configuration
- Configurable scale-down delays
- Configurable chart repo and image registry for AWS China

#### HPA Resources
- Dynamic creation for each enabled Dify deployment
- CPU metric (always present)
- Memory metric (conditional, only if `target_memory_utilization` is set)
- Configurable scaling behavior with stabilization windows
- Scale-up policies: max 50% or 4 pods per minute
- Scale-down policies: max 10% or 2 pods per minute

### 2. MODIFIED: `tf/variables.tf`

Added autoscaling variables organized in three sections:

#### Metrics Server Variables
```hcl
install_metrics_server       = bool    # Enable/disable
metrics_server_version       = string  # Helm chart version
metrics_server_chart_repo    = string  # Chart repository URL
metrics_server_image_registry = string # Image registry (override for China)
metrics_server_replicas      = number  # Replica count (1-10)
```

#### Cluster Autoscaler Variables
```hcl
install_cluster_autoscaler              = bool   # Enable/disable
cluster_autoscaler_version              = string # Helm chart version
cluster_autoscaler_image_tag            = string # Image tag (must match EKS version)
cluster_autoscaler_chart_repo           = string # Chart repository URL
cluster_autoscaler_image_registry       = string # Image registry (override for China)
cluster_autoscaler_scale_down_delay     = string # e.g., "10m"
cluster_autoscaler_scale_down_unneeded_time = string # e.g., "10m"
```

#### HPA Variables
```hcl
enable_hpa = bool # Enable/disable HPA

hpa_config = map(object({
  enabled                         = bool
  deployment_name                 = optional(string, "")
  min_replicas                    = number
  max_replicas                    = number
  target_cpu_utilization          = number
  target_memory_utilization       = optional(number)
  scale_down_stabilization_window = optional(number, 300)
  scale_up_stabilization_window   = optional(number, 0)
}))
```

#### Default HPA Configuration

| Component | Enabled | Min | Max | CPU Target | Memory Target | Notes |
|-----------|---------|-----|-----|------------|---------------|-------|
| api | true | 2 | 10 | 70% | 80% | Main API service |
| worker | true | 2 | 20 | 70% | - | Background workers |
| **workerBeat** | **false** | **1** | **1** | **70%** | **-** | **⚠️ SINGLETON - NEVER SCALE** |
| web | true | 2 | 8 | 70% | - | Frontend service |
| sandbox | true | 1 | 10 | 80% | - | Code execution sandbox |
| enterprise | false | 1 | 4 | 70% | - | Enterprise features |
| gateway | false | 1 | 4 | 70% | - | API gateway |
| plugin_daemon | false | 1 | 4 | 70% | - | Plugin daemon |
| plugin_connector | false | 1 | 4 | 70% | - | Plugin connector |

#### Validations
- `min_replicas >= 1 && min_replicas <= max_replicas`
- `target_cpu_utilization` between 1-100
- `target_memory_utilization` between 1-100 (if set)
- `cluster_autoscaler_image_tag` matches semantic version format `v1.28.5`
- Scale-down delays match format `10m` or `1h`

### 3. MODIFIED: `tf/eks.tf`

Added Cluster Autoscaler discovery tags at **two levels**:

#### Node Group Tags (ASG Level) - REQUIRED ✅
```hcl
tags = merge({
  Name        = "dify-${var.deployment_id}-nodes"
  Environment = var.environment
}, var.install_cluster_autoscaler ? {
  "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  "k8s.io/cluster-autoscaler/enabled"               = "true"
} : {})
```

**Critical**: These tags on the ASG itself allow Cluster Autoscaler to discover and manage the node group.

#### Launch Template Tags (EC2 Instance Level) - OPTIONAL
```hcl
tag_specifications {
  resource_type = "instance"
  tags = merge({
    Name        = "dify-${var.deployment_id}-node"
    Environment = var.environment
  }, var.install_cluster_autoscaler ? {
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
  } : {})
}
```

These tags are propagated to EC2 instances for visibility, but not required for CA discovery.

### 4. MODIFIED: `tf/outputs.tf`

Added `autoscaling_status` output:

```hcl
output "autoscaling_status" {
  value = {
    metrics_server = var.install_metrics_server ? {
      status   = "deployed"
      replicas = var.environment == "prod" ? var.metrics_server_replicas : 1
    } : null

    cluster_autoscaler = var.install_cluster_autoscaler ? {
      status              = "deployed"
      role_arn            = aws_iam_role.cluster_autoscaler[0].arn
      image_tag           = var.cluster_autoscaler_image_tag
      scale_down_delay    = var.cluster_autoscaler_scale_down_delay
      scale_down_unneeded = var.cluster_autoscaler_scale_down_unneeded_time
    } : null

    hpa = var.enable_hpa ? {
      enabled_deployments = [for k, v in var.hpa_config : k if v.enabled]
      total_hpa_resources = length([for k, v in var.hpa_config : k if v.enabled])
    } : null
  }
}
```

### 5. MODIFIED: `tf/terraform.tfvars.example`

Added comprehensive autoscaling configuration section with:
- Detailed variable documentation
- Standard AWS region configuration
- AWS China region override examples (commented)
- Complete HPA config for all components
- Critical warnings about workerBeat singleton constraint

## Critical Design Decisions

### 1. ⚠️ workerBeat Singleton Constraint

**Problem**: workerBeat is a Celery beat scheduler that manages periodic tasks. Running multiple replicas causes:
- Duplicate task execution
- Race conditions in task scheduling
- Potential data corruption

**Solution**:
- Added `workerBeat` to HPA config with `enabled = false` by default
- Set `min_replicas = 1` and `max_replicas = 1` (enforced limit)
- Added clear warnings in variables.tf and terraform.tfvars.example
- Documentation emphasizes this must NEVER be changed

**User Action Required**: Ensure Helm values.yaml sets `workerBeat.replicas: 1` and never enables HPA for this component.

### 2. AWS China Region Compatibility

All Helm charts and container images use configurable registries:

**Standard AWS Regions** (default):
```hcl
metrics_server_chart_repo       = "https://kubernetes-sigs.github.io/metrics-server/"
metrics_server_image_registry   = "registry.k8s.io"
cluster_autoscaler_chart_repo   = "https://kubernetes.github.io/autoscaler"
cluster_autoscaler_image_registry = "registry.k8s.io"
```

**AWS China Regions** (override in terraform.tfvars):
```hcl
metrics_server_chart_repo       = "https://kubernetes-sigs.github.io/metrics-server/"  # or China mirror
metrics_server_image_registry   = "registry.aliyuncs.com/google_containers"
cluster_autoscaler_chart_repo   = "https://kubernetes.github.io/autoscaler"  # or China mirror
cluster_autoscaler_image_registry = "registry.aliyuncs.com/google_containers"
```

### 3. Cluster Autoscaler Version Matching

**Requirement**: CA image version MUST match EKS cluster version

| EKS Version | CA Image Tag | Chart Version |
|-------------|--------------|---------------|
| 1.28.x | v1.28.5 | 9.35.0 |
| 1.29.x | v1.29.x | 9.35.0+ |
| 1.30.x | v1.30.x | 9.35.0+ |

**Why**: Version mismatch causes CA to make incorrect scaling decisions or fail to scale entirely.

**Implementation**: Added semantic version validation for `cluster_autoscaler_image_tag` variable.

### 4. IAM Policy Completeness

**Critical Permission**: `ec2:DescribeLaunchTemplateVersions`

**Why**: EKS Node Groups use Launch Templates (not Launch Configurations). Without this permission, CA cannot query node configuration and fails to scale.

**Other Required Permissions**:
- Read-only: `autoscaling:Describe*`, `ec2:DescribeImages`, `ec2:DescribeInstanceTypes`, `eks:DescribeNodegroup`
- Conditional write (based on tags): `autoscaling:SetDesiredCapacity`, `autoscaling:TerminateInstanceInAutoScalingGroup`

### 5. HPA Metric Conditional Rendering

**Problem**: Terraform/Kubernetes API rejects HPA specs with null memory metric values.

**Solution**: Use dynamic blocks to conditionally render memory metric only when `target_memory_utilization != null`:

```hcl
# CPU metric (always present)
metric {
  type = "Resource"
  resource {
    name = "cpu"
    target {
      type                = "Utilization"
      average_utilization = each.value.target_cpu_utilization
    }
  }
}

# Memory metric (conditional)
dynamic "metric" {
  for_each = each.value.target_memory_utilization != null ? [1] : []
  content {
    type = "Resource"
    resource {
      name = "memory"
      target {
        type                = "Utilization"
        average_utilization = each.value.target_memory_utilization
      }
    }
  }
}
```

### 6. Metrics Server Production Configuration

**Test Environment**:
- Replicas: 1
- No PodDisruptionBudget
- Minimal resource requests

**Production Environment**:
- Replicas: 2 (configurable via `metrics_server_replicas`)
- PodDisruptionBudget enabled with `minAvailable: 1`
- Higher resource requests
- Ensures HA during node maintenance or failures

### 7. Variable Validation Limitations

**Attempted**: Cross-variable validation (e.g., `enable_hpa` requires `install_metrics_server`)

**Limitation**: Terraform variable validation blocks can only reference `var.<self>`, not other variables.

**Solution**: Removed cross-variable validation, added clear documentation in variable descriptions and terraform.tfvars.example.

## Codex Review Issues - All Resolved ✅

| Issue | Priority | Resolution |
|-------|----------|------------|
| Missing `ec2:DescribeLaunchTemplateVersions` in CA IAM policy | 🔴 High | ✅ Added to Statement[0].Action in autoscaling.tf:157 |
| IRSA conditions for CA not explicit | 🔴 High | ✅ Explicitly set `sub` and `aud` conditions in autoscaling.tf:95-106 |
| CA image tag not pinned to EKS version | 🟡 Medium | ✅ Added `cluster_autoscaler_image_tag` variable with semantic version validation |
| CA discovery tags only on Launch Template | 🟡 Medium | ✅ Added tags to both Node Group (ASG - required) and Launch Template (EC2 - optional) |
| HPA memory metric not conditional | 🟡 Medium | ✅ Used `dynamic "metric"` block with null check in autoscaling.tf:346-358 |
| No AWS China region support | 🟡 Medium | ✅ Added configurable chart repos and image registries for all components |
| No variable validation | ✅ Improvement | ✅ Added validations for replica bounds, CPU/memory ranges, semantic versions |
| Metrics Server not production-ready | ✅ Improvement | ✅ Added replicas=2, PDB, EKS-specific args for production |
| CA Helm values not explicit | ✅ Improvement | ✅ Explicitly set all critical values (clusterName, region, IRSA, image) |

## Usage Guide

### Standard Deployment (AWS Commercial Regions)

**Step 1**: Copy example configuration
```bash
cd tf/
cp terraform.tfvars.example terraform.tfvars
```

**Step 2**: Enable autoscaling in `terraform.tfvars`
```hcl
# Enable Metrics Server
install_metrics_server = true
metrics_server_version = "3.12.0"
metrics_server_replicas = 2  # Production: 2, Test: 1

# Enable Cluster Autoscaler
install_cluster_autoscaler = true
cluster_autoscaler_version = "9.35.0"
cluster_autoscaler_image_tag = "v1.28.5"  # ⚠️ MUST match your EKS version
cluster_autoscaler_scale_down_delay = "10m"
cluster_autoscaler_scale_down_unneeded_time = "10m"

# Enable HPA
enable_hpa = true

# Customize HPA config (optional)
hpa_config = {
  api = {
    enabled                   = true
    min_replicas              = 2
    max_replicas              = 10
    target_cpu_utilization    = 70
    target_memory_utilization = 80
  }
  worker = {
    enabled                = true
    min_replicas           = 2
    max_replicas           = 20
    target_cpu_utilization = 70
  }
  # workerBeat must ALWAYS have enabled = false
  workerBeat = {
    enabled                = false  # ⚠️ CRITICAL: NEVER change this
    deployment_name        = "dify-worker-beat"
    min_replicas           = 1
    max_replicas           = 1
    target_cpu_utilization = 70
  }
  # ... other components
}
```

**Step 3**: Deploy
```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**Step 4**: Update Dify Helm values

In your `values.yaml` for Dify Helm chart:
```yaml
# For HPA-enabled components, set replicas to 1
api:
  replicas: 1  # HPA will manage this
  resources:
    requests:
      cpu: 500m     # ⚠️ Required for HPA
      memory: 512Mi # ⚠️ Required for HPA
    limits:
      cpu: 2000m
      memory: 2Gi

worker:
  replicas: 1  # HPA will manage this
  resources:
    requests:
      cpu: 500m
      memory: 512Mi

# workerBeat MUST stay at exactly 1 replica
workerBeat:
  replicas: 1  # ⚠️ CRITICAL: Never change this, no HPA
  resources:
    requests:
      cpu: 100m
      memory: 128Mi

web:
  replicas: 1  # HPA will manage this
  resources:
    requests:
      cpu: 200m
      memory: 256Mi

sandbox:
  replicas: 1  # HPA will manage this
  resources:
    requests:
      cpu: 1000m
      memory: 1Gi
```

**Step 5**: Verify deployment
```bash
# Check Metrics Server
kubectl get deployment metrics-server -n kube-system
kubectl top nodes  # Should show CPU/memory usage

# Check Cluster Autoscaler
kubectl get deployment cluster-autoscaler -n kube-system
kubectl logs -n kube-system deployment/cluster-autoscaler | tail -20

# Check HPA resources
kubectl get hpa -n dify
kubectl describe hpa dify-api-hpa -n dify
```

### AWS China Region Deployment

**Additional configuration** in `terraform.tfvars`:

```hcl
# Override image registries for China region
metrics_server_image_registry = "registry.aliyuncs.com/google_containers"
cluster_autoscaler_image_registry = "registry.aliyuncs.com/google_containers"

# Optional: Use China chart repo mirrors (if available)
# metrics_server_chart_repo = "https://your-china-mirror.com/metrics-server"
# cluster_autoscaler_chart_repo = "https://your-china-mirror.com/autoscaler"
```

All other steps remain the same.

### Disabling Autoscaling

To disable autoscaling components:

```hcl
install_metrics_server = false
install_cluster_autoscaler = false
enable_hpa = false
```

Then run `terraform apply`. Terraform will destroy the autoscaling resources.

## Testing and Validation

### Test Autoscaling Behavior

**1. Load Test API**
```bash
# Generate load on API pods
kubectl run -n dify load-generator --image=busybox --rm -it -- sh -c \
  "while true; do wget -q -O- http://dify-api:5001/health; done"
```

**2. Watch HPA Scale Up**
```bash
kubectl get hpa -n dify -w
```

Expected output:
```
NAME            REFERENCE        TARGETS   MINPODS   MAXPODS   REPLICAS
dify-api-hpa    Deployment/api   45%/70%   2         10        2
dify-api-hpa    Deployment/api   85%/70%   2         10        2
dify-api-hpa    Deployment/api   85%/70%   2         10        3  # Scaled up
```

**3. Watch Cluster Autoscaler Add Nodes**
```bash
# Check for pending pods
kubectl get pods -n dify -o wide | grep Pending

# Watch CA logs
kubectl logs -n kube-system deployment/cluster-autoscaler -f

# Watch nodes
kubectl get nodes -w
```

**4. Verify Scale Down**
```bash
# Stop load generator (Ctrl+C)

# After scale_down_unneeded_time (default 10m), HPA will reduce replicas
kubectl get hpa -n dify -w

# After node is empty for scale_down_delay (default 10m), CA will remove node
kubectl get nodes -w
```

### Troubleshooting

#### HPA Not Scaling

**Symptom**: HPA shows `<unknown>/70%` for CPU/memory targets

**Cause**: Pods don't have resource requests defined

**Fix**: Add resource requests to Deployment spec:
```yaml
resources:
  requests:
    cpu: 500m
    memory: 512Mi
```

#### Cluster Autoscaler Not Adding Nodes

**Symptom**: Pods stuck in Pending, CA not scaling up

**Check 1**: Verify CA is running
```bash
kubectl get deployment -n kube-system cluster-autoscaler
```

**Check 2**: Check CA logs for errors
```bash
kubectl logs -n kube-system deployment/cluster-autoscaler | grep -i error
```

**Common Issues**:
- IAM permissions missing (check IRSA role annotation)
- ASG tags missing (`k8s.io/cluster-autoscaler/*`)
- CA image version mismatch with EKS version
- Node group min_size = max_size (CA requires max > min)

**Check 3**: Verify ASG tags
```bash
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[?Key=='Name'].Value, 'dify')].Tags" \
  --output table
```

Should show:
```
k8s.io/cluster-autoscaler/dify-{deployment_id}-eks-cluster = owned
k8s.io/cluster-autoscaler/enabled = true
```

#### Metrics Server Not Working

**Symptom**: `kubectl top nodes` returns error

**Check 1**: Verify Metrics Server is running
```bash
kubectl get deployment -n kube-system metrics-server
```

**Check 2**: Check Metrics Server logs
```bash
kubectl logs -n kube-system deployment/metrics-server
```

**Common Issues**:
- kubelet TLS certificate issues → Use `--kubelet-insecure-tls`
- kubelet unreachable → Use `--kubelet-preferred-address-types=InternalIP`
- Image pull issues in China → Override `metrics_server_image_registry`

## Important Notes and Warnings

### ⚠️ Critical Constraints

1. **workerBeat Must Never Scale**
   - Always keep `workerBeat.enabled = false` in HPA config
   - Always keep `workerBeat.replicas = 1` in Helm values
   - Multiple replicas cause duplicate Celery beat tasks and data corruption

2. **Resource Requests Required**
   - All Deployments managed by HPA must define resource requests
   - Without requests, HPA cannot calculate utilization and shows `<unknown>`
   - HPA will not scale Deployments without resource requests

3. **HPA Conflicts with Static Replicas**
   - When HPA is enabled for a Deployment, set `replicas: 1` in Helm values
   - HPA will override the replica count based on metrics
   - Running both causes fights between HPA and ReplicaSet controller

4. **Version Matching Critical**
   - Cluster Autoscaler image version MUST match EKS cluster version
   - Example: EKS 1.28.x → CA v1.28.5
   - Version mismatch causes incorrect scaling decisions or failures

5. **Node Group Configuration**
   - Cluster Autoscaler requires `max_size > min_size` in node group
   - If `min_size = 0`, CA cannot scale from zero without additional setup
   - Recommended: `min_size >= 1` for system pods

### 📋 Prerequisites

- EKS cluster version 1.28 or higher
- OIDC provider configured for EKS cluster (created by this Terraform)
- Node group with `max_size > min_size`
- Helm provider configured in Terraform
- Kubernetes provider configured in Terraform

### 🔒 Security Considerations

1. **IRSA (IAM Roles for Service Accounts)**
   - Cluster Autoscaler uses IRSA for AWS API access
   - No AWS credentials stored in pods
   - IAM role scoped to specific ASG tags (`k8s.io/cluster-autoscaler/*`)

2. **Least Privilege Permissions**
   - CA can only modify ASGs tagged with cluster name
   - CA cannot modify other ASGs in the account
   - Read-only access to EC2/EKS APIs

3. **Network Access**
   - Metrics Server uses InternalIP for kubelet communication
   - All components run in kube-system namespace
   - No external network access required (except Helm chart pulls)

### 💰 Cost Implications

1. **Cluster Autoscaler**: Free (runs on existing nodes)
2. **Metrics Server**: Free (runs on existing nodes)
3. **HPA**: Free (Kubernetes built-in)
4. **EC2 Instances**: Pay for nodes added by CA
   - Production: up to 10 nodes (configurable via `max_size`)
   - Test: up to 2 nodes (configurable via `max_size`)

**Cost Optimization Tips**:
- Tune `scale_down_delay` and `scale_down_unneeded_time` to balance responsiveness vs cost
- Use spot instances for worker nodes (configure in `eks_*_node_config`)
- Set appropriate HPA min/max replicas based on actual traffic patterns

## Rollback Procedure

If autoscaling causes issues:

**Step 1**: Disable autoscaling in `terraform.tfvars`
```hcl
install_metrics_server = false
install_cluster_autoscaler = false
enable_hpa = false
```

**Step 2**: Restore static replicas in Helm values
```yaml
api:
  replicas: 3  # Restore to desired count
worker:
  replicas: 5  # Restore to desired count
# etc.
```

**Step 3**: Apply Terraform changes
```bash
terraform plan -out=tfplan
terraform apply tfplan
```

**Step 4**: Reinstall Dify Helm chart
```bash
helm upgrade dify -f values.yaml dify/dify -n dify
```

This will:
- Remove HPA resources
- Remove Cluster Autoscaler
- Remove Metrics Server
- Restore manual control over replica counts and node scaling

## Maintenance

### Upgrading EKS Cluster Version

When upgrading EKS from 1.28 → 1.29:

1. Update `cluster_version` in terraform.tfvars
2. Update `cluster_autoscaler_image_tag` to match (e.g., `v1.29.3`)
3. Run `terraform plan` to verify changes
4. Run `terraform apply`

Terraform will:
- Upgrade EKS control plane
- Update CA deployment with new image version
- No changes to Metrics Server or HPA (version-agnostic)

### Upgrading Helm Charts

To update Metrics Server or Cluster Autoscaler chart versions:

1. Update `metrics_server_version` or `cluster_autoscaler_version` in terraform.tfvars
2. Run `terraform plan`
3. Run `terraform apply`

Terraform will update the Helm releases in-place.

### Monitoring

**Key Metrics to Monitor**:

1. **HPA Scaling Events**
   ```bash
   kubectl get events -n dify --field-selector reason=ScalingReplicaSet
   ```

2. **CA Scaling Events**
   ```bash
   kubectl get events -n kube-system --field-selector reason=TriggeredScaleUp
   kubectl get events -n kube-system --field-selector reason=ScaleDown
   ```

3. **Pod Resource Usage**
   ```bash
   kubectl top pods -n dify
   ```

4. **Node Resource Usage**
   ```bash
   kubectl top nodes
   ```

**CloudWatch Metrics** (if using CloudWatch Container Insights):
- `pod_cpu_utilization`
- `pod_memory_utilization`
- `node_cpu_utilization`
- `node_memory_utilization`
- `cluster_failed_node_count`

## FAQ

**Q: Can I enable HPA for only some components?**
A: Yes, set `enabled = false` for components you don't want to autoscale in `hpa_config`.

**Q: What happens if I manually scale a Deployment that has HPA enabled?**
A: HPA will override your manual scaling within a few seconds based on current metrics.

**Q: Can I use custom metrics (e.g., queue length) for HPA?**
A: Not with this implementation. Current HPA only supports CPU/memory. For custom metrics, you need to deploy Prometheus Adapter or similar and modify HPA resources.

**Q: Why is workerBeat excluded from HPA?**
A: workerBeat runs Celery beat, which schedules periodic tasks. Multiple instances would duplicate tasks, causing race conditions and data corruption. It must always be exactly 1 replica.

**Q: Can CA scale to zero nodes?**
A: Not with this configuration. `min_size >= 1` ensures at least one node for system pods. Scaling to zero requires additional karpenter or special CA configuration.

**Q: What if I'm using an existing VPC?**
A: CA works with existing VPCs. Ensure ASG tags are applied to the node group (Terraform handles this automatically when `install_cluster_autoscaler = true`).

**Q: How do I customize CA scale-down behavior?**
A: Adjust `cluster_autoscaler_scale_down_delay` and `cluster_autoscaler_scale_down_unneeded_time` in terraform.tfvars. Increase for more conservative scale-down, decrease for aggressive cost optimization.

**Q: Can I use different HPA settings for test vs production?**
A: Yes, use Terraform workspaces or separate tfvars files. HPA config is fully customizable per environment.

## References

- [Kubernetes HPA Documentation](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Cluster Autoscaler Documentation](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [Metrics Server Documentation](https://github.com/kubernetes-sigs/metrics-server)
- [EKS Best Practices - Autoscaling](https://aws.github.io/aws-eks-best-practices/cluster-autoscaling/)
- [IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-28 | Initial implementation with Metrics Server, CA, HPA |

## Contributors

- Implementation based on Codex review feedback
- All Codex high/medium priority issues resolved
- Production-ready with AWS China support

---

**End of Implementation Plan**
