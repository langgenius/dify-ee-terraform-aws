# HPA + Cluster Autoscaler + Metrics Server Deployment Guide for Existing Dify Clusters

**Use Case**: You have already deployed Dify EE on AWS EKS via Terraform, and need to enable autoscaling capabilities afterward

**Prerequisites**:
- An EKS cluster with Dify EE already deployed
- EKS version 1.28+
- Node Group `max_size > min_size` (required by CA)
- kubeconfig access configured

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        Autoscaling Flow                          │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  User Traffic ↑  →  HPA detects CPU/Memory utilization above     │
│       ↓              threshold                                   │
│  HPA increases Pod replica count                                 │
│       ↓                                                          │
│  Pods enter Pending state (insufficient node resources)          │
│       ↓                                                          │
│  Cluster Autoscaler detects Pending Pods                         │
│       ↓                                                          │
│  CA adds EC2 instances to ASG                                    │
│       ↓                                                          │
│  New nodes join the EKS cluster                                  │
│       ↓                                                          │
│  Pending Pods are scheduled onto new nodes ✓                     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Component Dependencies**:
```
Metrics Server  →  HPA (requires metrics data)
       ↓
Cluster Autoscaler  →  Node Group (discovered via ASG tags)
```

---

## 2. Cluster Autoscaler Only (Minimal Setup)

If you only need automatic Node scaling without Pod autoscaling (HPA), follow these 3 steps:

### Step 1: Add CA Tags to the Node Group

```bash
# Set variables
CLUSTER_NAME="dify-<deployment_id>-eks-cluster"  # Replace <deployment_id>
AWS_REGION="us-east-1"  # Replace with your actual region

# Get ASG name
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '${CLUSTER_NAME}')].AutoScalingGroupName" \
  --output text)
echo "ASG: $ASG_NAME"

# Add CA discovery tags
aws autoscaling create-or-update-tags --tags \
  "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/${CLUSTER_NAME},Value=owned,PropagateAtLaunch=true" \
  "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=true"
```

### Step 2: Create the CA IRSA Role

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

# Create trust policy
cat > ca-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:cluster-autoscaler",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

# Create permissions policy
cat > ca-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"],
      "Resource": "*",
      "Condition": {"StringEquals": {"aws:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}": "owned"}}
    }
  ]
}
EOF

# Create IAM Role
aws iam create-role --role-name "${CLUSTER_NAME}-ca" --assume-role-policy-document file://ca-trust-policy.json
aws iam put-role-policy --role-name "${CLUSTER_NAME}-ca" --policy-name ca-policy --policy-document file://ca-policy.json
CA_ROLE_ARN=$(aws iam get-role --role-name "${CLUSTER_NAME}-ca" --query "Role.Arn" --output text)
echo "CA Role ARN: $CA_ROLE_ARN"
```

### Step 3: Deploy Cluster Autoscaler

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

# ⚠️ image.tag must match EKS version: EKS 1.28→v1.28.5, EKS 1.29→v1.29.3, EKS 1.30→v1.30.1
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version 9.35.0 \
  --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
  --set awsRegion="${AWS_REGION}" \
  --set image.tag="v1.28.5" \
  --set rbac.serviceAccount.create=true \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${CA_ROLE_ARN}" \
  --set extraArgs.scale-down-delay-after-add=10m \
  --set extraArgs.scale-down-unneeded-time=10m

# For AWS China regions, add: --set image.repository="registry.aliyuncs.com/google_containers/autoscaling/cluster-autoscaler"
```

### Verify & Test

```bash
# Verify CA is running
kubectl get deployment cluster-autoscaler -n kube-system
kubectl logs -n kube-system deployment/cluster-autoscaler | tail -10

# Test scaling: manually increase Pod replicas to trigger CA
kubectl scale deployment dify-api --replicas=10 -n dify

# Watch Pending Pods and node scaling
kubectl get pods -n dify -w
kubectl get nodes -w
```

**Workflow**:
```
Manually increase replicas → Pods Pending (insufficient resources) → CA detects → Adds EC2 nodes → Pods scheduled successfully
```

---

## 3. Full Deployment (HPA + CA + Metrics Server)

### Step 1: Deploy Metrics Server

Metrics Server provides CPU/Memory metrics data for HPA.

```bash
# Add metrics-server Helm repo
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

# Deploy metrics-server (standard AWS regions)
helm install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --version 3.12.0 \
  --set replicas=2 \
  --set args[0]="--kubelet-preferred-address-types=InternalIP" \
  --set args[1]="--kubelet-insecure-tls"

# AWS China regions (using Alibaba Cloud mirror)
helm install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --version 3.12.0 \
  --set replicas=2 \
  --set args[0]="--kubelet-preferred-address-types=InternalIP" \
  --set args[1]="--kubelet-insecure-tls" \
  --set image.repository="registry.aliyuncs.com/google_containers/metrics-server"
```

**Verify**:
```bash
kubectl get deployment metrics-server -n kube-system
kubectl top nodes  # Should display node CPU/Memory usage
kubectl top pods -n dify  # Should display Pod resource usage
```

---

### Step 2: Add Cluster Autoscaler Tags to the Node Group

CA discovers manageable Node Groups via ASG tags.

```bash
# Get ASG name (replace <your-cluster-name>)
CLUSTER_NAME="dify-<deployment_id>-eks-cluster"
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '${CLUSTER_NAME}')].AutoScalingGroupName" \
  --output text)

echo "ASG Name: $ASG_NAME"

# Add CA discovery tags
aws autoscaling create-or-update-tags --tags \
  "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/${CLUSTER_NAME},Value=owned,PropagateAtLaunch=true" \
  "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=true"
```

**Verify**:
```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].Tags" --output table
```

Expected output:
| Key | Value |
|-----|-------|
| `k8s.io/cluster-autoscaler/<cluster-name>` | `owned` |
| `k8s.io/cluster-autoscaler/enabled` | `true` |

---

### Step 3: Create Cluster Autoscaler IAM Role (IRSA)

```bash
# Set variables
CLUSTER_NAME="dify-<deployment_id>-eks-cluster"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"  # Replace with your actual region

# Get OIDC Provider ID
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

echo "OIDC Provider: $OIDC_PROVIDER"

# Create trust policy
cat > ca-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:cluster-autoscaler",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create IAM Role
aws iam create-role \
  --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --assume-role-policy-document file://ca-trust-policy.json

# Create permissions policy (⚠️ Critical: includes ec2:DescribeLaunchTemplateVersions)
cat > ca-permissions-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}": "owned"
        }
      }
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --policy-name "cluster-autoscaler-policy" \
  --policy-document file://ca-permissions-policy.json

# Get Role ARN
CA_ROLE_ARN=$(aws iam get-role --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --query "Role.Arn" --output text)
echo "CA Role ARN: $CA_ROLE_ARN"
```

---

### Step 4: Deploy Cluster Autoscaler

```bash
# Add autoscaler Helm repo
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

# Deploy (⚠️ image.tag must match EKS version)
# EKS 1.28 → v1.28.5
# EKS 1.29 → v1.29.3
# EKS 1.30 → v1.30.1

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version 9.35.0 \
  --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
  --set awsRegion="${AWS_REGION}" \
  --set image.tag="v1.28.5" \
  --set rbac.serviceAccount.create=true \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${CA_ROLE_ARN}" \
  --set extraArgs.scale-down-delay-after-add=10m \
  --set extraArgs.scale-down-unneeded-time=10m \
  --set extraArgs.skip-nodes-with-system-pods=false \
  --set extraArgs.balance-similar-node-groups=true

# AWS China regions (using Alibaba Cloud mirror)
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version 9.35.0 \
  --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
  --set awsRegion="${AWS_REGION}" \
  --set image.repository="registry.aliyuncs.com/google_containers/autoscaling/cluster-autoscaler" \
  --set image.tag="v1.28.5" \
  --set rbac.serviceAccount.create=true \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${CA_ROLE_ARN}" \
  --set extraArgs.scale-down-delay-after-add=10m \
  --set extraArgs.scale-down-unneeded-time=10m
```

**Verify**:
```bash
kubectl get deployment cluster-autoscaler -n kube-system
kubectl logs -n kube-system deployment/cluster-autoscaler | tail -20
```

---

### Step 5: Update Dify Helm Values (Add Resource Requests)

**⚠️ Critical**: HPA requires Pods to have `resources.requests` defined in order to calculate utilization

Create or modify `values-hpa.yaml`:

```yaml
# Resource requests configuration required by HPA
api:
  replicas: 1  # Set static replica count to 1 once HPA takes over
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

worker:
  replicas: 1
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

# ⚠️ CRITICAL: workerBeat must NEVER be scaled!
workerBeat:
  replicas: 1  # Must always be 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

web:
  replicas: 1
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1Gi

sandbox:
  replicas: 1
  resources:
    requests:
      cpu: 500m
      memory: 256Mi
    limits:
      cpu: 2000m
      memory: 1Gi
```

Apply the update:
```bash
helm upgrade dify <chart> -f values.yaml -f values-hpa.yaml -n dify
```

---

### Step 6: Create HPA Resources

```bash
# API HPA (CPU + Memory)
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dify-api-hpa
  namespace: dify
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dify-api
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
      - type: Pods
        value: 2
        periodSeconds: 60
      selectPolicy: Min
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
      - type: Pods
        value: 4
        periodSeconds: 60
      selectPolicy: Max
EOF

# Worker HPA (CPU only)
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dify-worker-hpa
  namespace: dify
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dify-worker
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 0
EOF

# Web HPA
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dify-web-hpa
  namespace: dify
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dify-web
  minReplicas: 2
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
EOF

# Sandbox HPA
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dify-sandbox-hpa
  namespace: dify
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dify-sandbox
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
EOF
```

**Verify**:
```bash
kubectl get hpa -n dify
```

Expected output:
```
NAME              REFERENCE           TARGETS   MINPODS   MAXPODS   REPLICAS
dify-api-hpa      Deployment/dify-api    45%/70%   2         10        2
dify-worker-hpa   Deployment/dify-worker 30%/70%   2         20        2
dify-web-hpa      Deployment/dify-web    25%/70%   2         8         2
dify-sandbox-hpa  Deployment/dify-sandbox 10%/80%   1         10        1
```

---

---

## 4. Verification & Testing

### 4.1 Full Status Check

```bash
# 1. Metrics Server
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods -n dify

# 2. Cluster Autoscaler
kubectl get deployment cluster-autoscaler -n kube-system
kubectl logs -n kube-system deployment/cluster-autoscaler | grep -i "auto-scaling"

# 3. HPA
kubectl get hpa -n dify

# 4. Verify HPA can retrieve metrics
kubectl describe hpa dify-api-hpa -n dify
# Ensure TARGETS is not <unknown>
```

### 4.2 Load Testing

```bash
# Create a load generator
kubectl run -n dify load-test --image=busybox --rm -it -- sh -c \
  "while true; do wget -q -O- http://dify-api:5001/health; done"

# Watch HPA in another terminal
kubectl get hpa -n dify -w

# Watch Pod scaling
kubectl get pods -n dify -w

# Watch CA adding nodes (if Pods are Pending)
kubectl get nodes -w
kubectl logs -n kube-system deployment/cluster-autoscaler -f
```

---

## 5. Troubleshooting

### Issue 1: HPA shows `<unknown>/70%`

**Cause**: Pod does not have `resources.requests` defined

**Solution**:
```yaml
# Add to Helm values
api:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
```

### Issue 2: CA does not scale up nodes

**Check 1**: ASG Tags
```bash
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[*].{Name:AutoScalingGroupName,Tags:Tags[?contains(Key,'cluster-autoscaler')]}" \
  --output table
```

**Check 2**: CA Logs
```bash
kubectl logs -n kube-system deployment/cluster-autoscaler | grep -i error
```

**Check 3**: IAM Permissions
```bash
# Ensure ec2:DescribeLaunchTemplateVersions is included
aws iam get-role-policy \
  --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --policy-name cluster-autoscaler-policy
```

**Check 4**: Node Group min/max
```bash
# max_size must be > min_size
aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name <ng-name> \
  --query "nodegroup.scalingConfig"
```

### Issue 3: Metrics Server cannot retrieve kubelet metrics

**Symptom**: `kubectl top nodes` returns an error

**Solution**: Ensure EKS-compatible arguments are used:
```bash
--kubelet-preferred-address-types=InternalIP
--kubelet-insecure-tls
```

---

## 6. Rollback Steps

To disable autoscaling:

```bash
# 1. Delete HPA
kubectl delete hpa --all -n dify

# 2. Delete Cluster Autoscaler
helm uninstall cluster-autoscaler -n kube-system

# 3. Delete Metrics Server
helm uninstall metrics-server -n kube-system

# 4. Restore static replica counts
# Modify Helm values:
# api.replicas: 3
# worker.replicas: 5
# ...

helm upgrade dify <chart> -f values.yaml -n dify

# 5. (Optional) Delete IAM Role
aws iam delete-role-policy \
  --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --policy-name cluster-autoscaler-policy
aws iam delete-role --role-name "${CLUSTER_NAME}-cluster-autoscaler"
```

---

## 7. ⚠️ Important Notes

| Item | Details |
|------|---------|
| **workerBeat must not be scaled** | Celery Beat must run as a single replica; multiple replicas will cause duplicate task execution |
| **CA version matching** | `cluster_autoscaler_image_tag` must match the EKS version (v1.28.x for EKS 1.28) |
| **Resource Requests required** | HPA requires Pods to have `resources.requests` defined to calculate utilization |
| **Node Group configuration** | `max_size > min_size` is required for CA to scale up |
| **IAM permissions** | Must include `ec2:DescribeLaunchTemplateVersions` (EKS uses Launch Templates) |

---

## 8. References

- [Kubernetes HPA Documentation](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Cluster Autoscaler Documentation](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [EKS Best Practices - Autoscaling](https://aws.github.io/aws-eks-best-practices/cluster-autoscaling/)
- [Project Implementation Documentation](./AUTOSCALING_IMPLEMENTATION.md)

---

**Document Version**: 1.0
**Last Updated**: 2026-01-30
