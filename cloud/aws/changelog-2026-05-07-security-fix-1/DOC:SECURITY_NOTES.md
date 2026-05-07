# Security Notes — Dify EE on AWS (post-PR7 Baseline)

**Audience**: operators standing up a new Dify EE deployment on AWS, plus security/compliance reviewers who need to map this stack to common controls.
**Scope**: greenfield deploys only. This stack is not designed for in-place upgrades; this document does **not** describe an upgrade path.
**Baseline date**: 2026-05-07 (corresponds to PR #7 / branch `chore/security-ci`).

This document is a *snapshot* of the security posture established by `cloud/aws/`. The accompanying `PLAN:SECURITY_FIX_1.md` records the diff that produced this baseline.

---

## 1. Encryption Posture

### 1.1 At rest

| Layer | Default in this repo | Key | Notes |
|-------|----------------------|-----|-------|
| Aurora PostgreSQL storage | encrypted | AWS-managed KMS | CMK migration tracked separately. Suppression: `tfsec:ignore:aws-rds-encrypt-cluster-storage-data` in `tf/rds.tf`. |
| Aurora Performance Insights | encrypted | AWS-managed KMS | Suppression: `tfsec:ignore:aws-rds-enable-performance-insights-encryption` in `tf/rds.tf`. |
| RDS credentials (Secrets Manager) | encrypted | AWS-managed KMS | Suppression: `tfsec:ignore:aws-ssm-secret-use-customer-key` in `tf/rds.tf`. |
| ElastiCache Redis | encrypted (PR7) | AWS-managed | `at_rest_encryption_enabled = true`. |
| OpenSearch storage | encrypted | AWS-managed | OpenSearch domain default. |
| S3 (`dify-storage`) | encrypted | SSE-S3 (AES256) | CMK migration tracked separately. Suppression: `tfsec:ignore:aws-s3-encryption-customer-key` in `tf/s3.tf`. |
| ECR repositories | encrypted | AES256 (AWS-managed) | Suppression: `tfsec:ignore:aws-ecr-repository-customer-key` in `tf/ecr.tf`. |
| EKS Kubernetes secrets | **envelope-encrypted (PR7)** | **dedicated CMK** with rotation, 7-day deletion window | New `aws_kms_key.eks_secrets` + `aws_kms_alias.eks_secrets` in `tf/eks.tf`. |

### 1.2 In transit

| Channel | TLS? | Notes |
|---------|------|-------|
| End user → ALB | yes | ACM certificate supplied by the operator (`acm_certificate_arn` tfvar). |
| ALB → pods | optional | Cluster-internal traffic; not TLS by default (mitigation: private subnets, SG allowlists). |
| pods → Aurora PostgreSQL | yes | Aurora forces SSL. |
| pods → Redis | **yes (PR7)** | `transit_encryption_enabled = true`; client URL must be `rediss://`. Helm values set `externalRedis.useSSL: true`. |
| pods → OpenSearch | yes | OpenSearch is HTTPS-only. |
| pods → S3 / ECR / STS / Secrets Manager | yes | AWS API endpoints are HTTPS. |

---

## 2. Network Posture

### 2.1 VPC layout

- 3 AZs (auto-detected from the deploy region).
- Public + private subnets per AZ.
- ALB lives in **public** subnets.
- All data-plane resources (EKS worker nodes, Aurora, ElastiCache, OpenSearch) live in **private** subnets and reach the internet only via NAT.

### 2.2 Public subnet hardening (PR7)

- `aws_subnet.public.map_public_ip_on_launch = false` (was `true` before PR7). Nothing in a public subnet auto-receives a public IP at launch. The internet-facing ALB and NAT gateway both manage their own routing without relying on this attribute.

### 2.3 Security groups

Each `aws_security_group` and each `ingress` / `egress` rule has a `description` (PR7). Minimal ingress per data-plane resource:

| SG | Ingress | Source |
|----|---------|--------|
| `eks_nodes` | TCP 0–65535 (intra-cluster, self) | self |
| `eks_nodes` | TCP 1025–65535 | EKS control-plane SG |
| `eks_nodes` | TCP 443 | EKS control-plane SG |
| `redis` | TCP 6379 | `eks_nodes` |
| `rds` | TCP 5432 | `eks_nodes` |
| `opensearch` | TCP 443, 9200 | `eks_nodes` |

Wide-open egress (`0.0.0.0/0`) is **intentional** on every SG and carries a `tfsec:ignore:aws-ec2-no-public-egress-sgr` annotation with rationale (NAT-routed AWS API calls — image pulls, snapshots, KMS, CloudWatch).

### 2.4 EKS endpoint exposure

- Public is **gated on** `elb_mode == "internet-facing"`. With `elb_mode == "internal"`, the cluster endpoint is private only.
- When public is enabled, `public_access_cidrs` defaults to `0.0.0.0/0`. Tightening is tracked separately. Suppression: `tfsec:ignore:aws-eks-no-public-cluster-access(-to-cidr)` in `tf/eks.tf`.

---

## 3. Compute / Control Plane

### 3.1 EKS control-plane logging (PR7)

```hcl
enabled_cluster_log_types = [
  "api", "audit", "authenticator", "controllerManager", "scheduler"
]
```

All five log types stream to CloudWatch Logs.

### 3.2 IMDSv2 enforcement on worker nodes (PR7)

```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"   # IMDSv2 mandatory
  http_put_response_hop_limit = 2            # one extra hop for pod-to-IMDS
}
```

Token-less IMDSv1 requests are rejected. The hop limit is intentionally 2 so pods (one extra network hop from the host ENI) can still reach IMDS for kubelet credential discovery.

### 3.3 Kubernetes secrets envelope encryption (PR7)

```hcl
encryption_config {
  provider { key_arn = aws_kms_key.eks_secrets.arn }
  resources = ["secrets"]
}
```

Dedicated CMK (`alias/dify-<deployment_id>-eks-cluster-secrets`), rotation enabled, 7-day deletion window.

---

## 4. Identity / IRSA

Three IRSA roles, each scoped per-deployment via `deployment_id`:

| Role | Bound ServiceAccounts | Permissions |
|------|------------------------|-------------|
| `dify-<id>-s3-role` | `dify-api-sa`, `dify-plugin-connector`, **`plugin_daemon` (PR7)** | S3 access scoped to `dify-<id>-storage` bucket prefix |
| `dify-<id>-s3-ecr-role` | `dify-plugin-crd`, `dify-plugin-build` | S3 + ECR push/pull |
| `dify-<id>-ecr-pull-role` | `dify-plugin-runner`, `dify-plugin-build-run` | ECR pull-only |

Wildcard policy actions (`s3:*Object*`, `s3:List*`, multipart, etc.) are required for app uploads and lifecycle ops; resource scope is restricted to the Dify-owned bucket. Suppressions in `tf/irsa.tf`:
- `trivy:ignore:AVD-AWS-0345` on `aws_iam_policy.dify_ee_s3_policy`.
- `tfsec:ignore:aws-iam-no-policy-wildcards` on `aws_iam_policy.s3_access`.

**PR7 change**: the `plugin_daemon` ServiceAccount is now bound to `dify-api-sa` (which carries the `dify-<id>-s3-role`) so plugin-daemon pods can write plugin artifacts to S3.

---

## 5. Secrets Management

### 5.1 RDS credentials

Stored in AWS Secrets Manager (`aws_secretsmanager_secret.rds_credentials`), encrypted with AWS-managed KMS, retrieved at runtime by Dify components via IAM-authorized API calls.

### 5.2 `enterprise.passwordEncryptionKey` (PR7)

- AES-256, base64-encoded.
- Generated by Terraform: `random_bytes "password_encryption_key" { length = 32 }` in `tf/secrets.tf`.
- Persisted in TF state. **Operators must protect TF state accordingly** (S3 backend + DynamoDB locking with bucket-level encryption is the recommended path; see repo-level TODO).
- Surfaced as a sensitive Terraform output (`password_encryption_key`) and consumed by `scripts/3_post_tf_apply.sh` → `scripts/4_generate_dify_helm.sh`.
- **Rotating this key invalidates any password-policy ciphertext already stored in the database** (`enterprise.sys_settings.PASSWORD_POLICY`). Treat as an opaque, stable secret bound to the lifetime of the deployment.
- Pre-PR7 deployments generated this key with `openssl rand` inside `scripts/4_generate_dify_helm.sh`, which produced a *new* key on every helm regen — this is now only a fallback path that warns loudly.

### 5.3 `APP_SECRET_KEY`

Generated at helm-values render time by `scripts/4_generate_dify_helm.sh` if not already set in the sourced `config_*.env`. Once written into a `config_*.env` it is reused on subsequent runs.

---

## 6. Supply-chain / CI (PR7)

`.github/workflows/security.yml` runs on every push and PR:

- **`gitleaks 8.30.1`** — scans the working tree and history for credentials. Allowlist: `.gitleaksignore` (covers redacted `innerApiKey` samples in templates and pre-existing remediated matches).
- **`trivy`** — IaC + config scanning across `cloud/aws/tf/`. Replaces the earlier tfsec workflow.

All remaining findings are suppressed inline at the resource (not at the workflow level) with one-line rationale:

| Suppression source | File(s) | Rationale class |
|--------------------|---------|-----------------|
| `tfsec:ignore:aws-ec2-no-public-egress-sgr` | `tf/eks.tf`, `tf/elasticache.tf`, `tf/rds.tf`, `tf/opensearch.tf` | NAT-routed AWS API egress required |
| `tfsec:ignore:aws-eks-no-public-cluster-access(-to-cidr)` | `tf/eks.tf` | gated on `elb_mode`; `public_access_cidrs` tightening tracked separately |
| `tfsec:ignore:aws-rds-encrypt-cluster-storage-data` | `tf/rds.tf` | CMK migration tracked separately |
| `tfsec:ignore:aws-rds-enable-performance-insights-encryption` | `tf/rds.tf` | CMK migration tracked separately |
| `tfsec:ignore:aws-ssm-secret-use-customer-key` | `tf/rds.tf` | CMK migration tracked separately |
| `tfsec:ignore:aws-s3-enable-bucket-logging` | `tf/s3.tf` | central log bucket; opt-in via overrides |
| `tfsec:ignore:aws-s3-encryption-customer-key` | `tf/s3.tf` | CMK migration tracked separately |
| `tfsec:ignore:aws-ecr-enforce-immutable-repository` | `tf/ecr.tf` | application/plugin image flows reuse tags |
| `tfsec:ignore:aws-ecr-repository-customer-key` | `tf/ecr.tf` | CMK migration tracked separately |
| `tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs` | `tf/vpc.tf` | central logging stack handles flow logs |
| `tfsec:ignore:aws-iam-no-policy-wildcards` | `tf/irsa.tf` | wildcard scoped to bucket prefix only |
| `trivy:ignore:AVD-AWS-0345` | `tf/irsa.tf` | bucket-scoped object actions required for app/plugin flows |

---

## 7. Open Items / Future Work

- **CMK rollout** — Aurora storage, RDS Performance Insights, Secrets Manager, S3, ECR.
- **VPC Flow Logs** — currently expected to come from a central logging stack; consider an in-stack option for self-contained deploys.
- **EKS `public_access_cidrs` tightening** — currently `0.0.0.0/0` when `elb_mode == "internet-facing"`.
- **S3 server-access logging** — currently opt-in via env-specific overrides.
- **Remote TF state backend** — README notes a TODO for S3 + DynamoDB. Critical given that the password encryption key now lives in state.
- **Helm pod-level enhancements** — NetworkPolicies, PSA labels, mTLS between services. Not in scope for `cloud/aws/` Terraform.

---

## 8. Mapping to Common Controls (informational)

| Concern | Where it's addressed |
|---------|----------------------|
| Data-at-rest encryption | §1.1 |
| Data-in-transit encryption | §1.2 |
| Network segmentation / least privilege | §2.3 |
| Public exposure of internal endpoints | §2.2, §2.4 |
| Privileged-host metadata access | §3.2 (IMDSv2) |
| Secret-store encryption | §1.1 (EKS secrets), §5 |
| Audit logging | §3.1 (EKS control plane) |
| IAM least privilege | §4 |
| Supply-chain scanning | §6 |
| Key management & rotation | §1.1, §5.2 |

This is a self-mapping by the maintainers; it is not a substitute for an independent audit.
