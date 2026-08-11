---
name: dify-ee-aws-rebuild
description: Use when the user asks to (a) deploy Dify Enterprise Edition on AWS from a clean account or (b) tear down an existing deployment cleanly — phrases like "从 0 部署"、"全套 tf 跑通"、"测试一下 3.x.x"、"看看新 chart 跟 tf 兼不兼容"、"helm uninstall 然后 tf destroy"、"清理干净"、"deploy from scratch"、"tear it all down". The skill defines two scenarios end-to-end: SCENARIO A boots an empty AWS account through `terraform apply` → script 2/3/4 → `helm install` and ends with every Dify pod 1/1 Running; SCENARIO B walks helm uninstall → S3 drain → plugin-ECR cleanup → `terraform destroy` → orphan scan and ends with no `dify-{deployment_id}-*` resource left in the account. Includes the catalog of past chart-vs-tf mismatches to look for during deploy and the order-sensitive cleanup steps that prevent destroy from hanging.
---

# Dify EE on AWS — deploy from zero / tear down completely

This skill covers two scenarios for the `dify-ee-terraform-aws` repo. Pick the one the user asked for; don't run both unless they explicitly want a full cycle (teardown → redeploy).

| | Scenario A: **Deploy from zero** | Scenario B: **Tear down completely** |
|---|---|---|
| **Starting state** | Empty AWS account, or one where no `dify-{deployment_id}-*` resources exist | Running Dify deployment (helm release `dify`, full tf state) |
| **Ending state** | All Dify pods `1/1 Running`, ALB ingress (or noted-as-skipped) | Zero `dify-{deployment_id}-*` resources in the AWS account |
| **Typical trigger** | "测试一下 3.10"、"从 0 跑一遍"、"validate the new chart"、PR review | "彻底清理"、"helm uninstall 然后 tf destroy"、end-of-test cleanup |
| **Failure mode** | Pod CrashLoopBackOff with NoCredentialsError; HPA `deployments.apps "..." not found`; chart values schema regression | Versioned S3 blocks destroy; orphan plugin ECR repos / orphan VPC ENI cascade leaves stuck NAT GW / EIP |

The two scenarios share zero commands. Don't conflate them.

## Pre-flight (both scenarios)

```bash
# Working directory: cloud/aws/ — relative paths in this skill assume this.
# Verify creds + region match tfvars.
aws sts get-caller-identity
grep -E "^(deployment_id|aws_region|aws_account_id|environment)" tf/terraform.tfvars

# Scenario A: also confirm the TF-owned control-plane log group isn't lingering
# from an old teardown (EKS can flush final logs post-destroy and re-create it).
# Any hit here → delete it (or terraform import it) BEFORE apply, or apply dies
# with ResourceAlreadyExistsException on aws_cloudwatch_log_group.eks_cluster.
# Pin --region to tfvars — a differing default CLI region would false-pass this check.
aws logs describe-log-groups \
  --region "$(awk -F'"' '/^aws_region/{print $2}' tf/terraform.tfvars)" \
  --log-group-name-prefix "/aws/eks/dify-$(awk -F'"' '/^deployment_id/{print $2}' tf/terraform.tfvars)-" \
  --query 'logGroups[].logGroupName'
```

If `aws sts` returns the wrong account or `aws_region` in tfvars doesn't match the user's intent, **stop** and surface that to the user before running anything destructive.

---

# SCENARIO A — Deploy from zero

**Goal:** empty AWS account → `kubectl get pods -n dify` shows every pod `1/1 Running` (or `2/2`).

**Time budget:** ~25 minutes for the test profile (single arm64 m7g.xlarge node), dominated by OpenSearch domain creation (~13-14 min) and image pulls.

## A.1 — Terraform apply

```bash
cd tf/
terraform init -upgrade
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
```

Expect ~94 resources created on first apply. **Two transient errors are normal and self-heal on a second `terraform apply`:**
- `Error: could not download chart: Get "https://github.com/.../metrics-server-3.12.0.tgz": EOF` — GitHub TLS / rate limit on the helm provider's chart download.
- `Error: Post "https://....eks.amazonaws.com/api/v1/namespaces": EOF` — EKS API not yet responsive when terraform tries to create the `dify` namespace.

If you see those: just `terraform apply -auto-approve` again with no flags. The remaining ~12 K8s/Helm resources finish cleanly.

**If the chart EOF does NOT self-heal** (repeated failures AND `curl -sI https://github.com` also dies — e.g. a fake-ip VPN whose github.com route is down; `dig github.com` returning `198.18.x.x` confirms DNS interception): build a local chart mirror and override the repo vars — both are already variables (`metrics_server_chart_repo` / `cluster_autoscaler_chart_repo`, originally for AWS China). Validated on the 2026-08-10 rebuild:

```bash
# 1. api.github.com is often reachable when github.com isn't (redirects to codeload):
curl -sL -o /tmp/ms.tar.gz https://api.github.com/repos/kubernetes-sigs/metrics-server/tarball/metrics-server-helm-chart-<ver>
curl -sL -o /tmp/as.tar.gz https://api.github.com/repos/kubernetes/autoscaler/tarball/cluster-autoscaler-chart-<ver>
# Chart dirs inside the tarballs: charts/metrics-server and
# cluster-autoscaler/charts/cluster-autoscaler (NOT top-level charts/).
# Verify Chart.yaml `version:` matches the tf-pinned chart version.

# 2. helm package both dirs into /tmp/dify-charts, then serve as a repo:
helm repo index /tmp/dify-charts --url http://127.0.0.1:8879
python3 -m http.server 8879 --directory /tmp/dify-charts --bind 127.0.0.1 &

# 3. Repository MUST be an HTTP URL — a bare local path fails with
# "could not find protocol handler":
terraform apply -auto-approve \
  -var metrics_server_chart_repo=http://127.0.0.1:8879 \
  -var cluster_autoscaler_chart_repo=http://127.0.0.1:8879
```

Residue: state then records `repository = localhost` for those two releases; once GitHub is reachable, a plain `terraform apply` points them back at the defaults.

A third error through flaky tunnels: `failed to download openapi ... Client.Timeout` from the helm provider **while kubectl itself is fast** (`time kubectl get --raw /openapi/v2 | wc -c` jitters 2s–22s). Pure throughput lottery — loop `terraform apply` until it lands.

For background runs, monitor with:
```bash
terraform apply -auto-approve tfplan > /tmp/tf_apply.log 2>&1
# Then in a Monitor: tail -F /tmp/tf_apply.log | grep --line-buffered -E "Creation complete after.*(eks_cluster|node_group|aurora|opensearch|s3_bucket|helm_release)|Error:|Apply complete!"
```

The big-rock resources to watch: `aws_rds_cluster.main`, `aws_rds_cluster_instance.main`, `aws_eks_cluster.main`, `aws_eks_node_group.main`, `aws_opensearch_domain.main`. OpenSearch is the long pole.

## A.2 — Project scripts (2 → 3 → 4)

```bash
cd ..                                     # back to cloud/aws/ — A.1 left the shell in tf/
bash scripts/2_verify_tf_deployment.sh    # generates secret/deployment_verification_*.txt
bash scripts/3_post_tf_apply.sh           # generates secret/config_*.env, dify_deployment_config_*.txt, out_*.log
bash scripts/4_generate_dify_helm.sh      # generates secret/helm_values_<ts>/values.{quick-poc,test,prod}_*.yaml
```

**(CN region only)** Run `bash scripts/5_create_databases.sh` between scripts 2 and 3 — Aurora RDS Data API isn't available in `cn-north-1` / `cn-northwest-1` so the in-tf SQL provisioner is replaced by this script.

**Pitfalls in script 4:**
- Watchdog stage fetches image tags from `helm-watchdog.dify.ai`. Sometimes returns SSL/EOF errors. The values files are written **before** the watchdog stage, so a watchdog failure doesn't prevent install — image tags just fall back to chart defaults. Re-run if you need exact pinning.
- The version-pick menu and cert-selection step are interactive. With no TTY (`</dev/null`), the version menu auto-picks the highlighted top option (latest, usually correct) — but the cert step won't run. **`{{cert_uuid}}` then stays literal in the ingress annotation, ALB rejects with `no certificate found for host: ...`**. If you need HTTPS, run script 4 with a real TTY and pick a cert; if not, post-edit the values to drop the `alb.ingress.kubernetes.io/certificate-arn` annotation and set `useTLS: false`.
- All three interactive prompts (env file → cert → watchdog version) are arrow-key menus; driving them through a PTY works fine: newest env file is the top option, watchdog's top option is the latest chart version. Validated on the 2026-08-10 3.12.0 test-profile deploy.

## A.3 — Helm install

```bash
helm repo add dify https://langgenius.github.io/dify-helm 2>/dev/null
helm repo update dify

CANDIDATE=3.12.0                                                   # pin explicitly (3.9.1 and 3.12.0 validated end-to-end)
PROFILE=quick-poc                                                  # or test / prod
VALUES=$(ls -t secret/helm_values_*/values.${PROFILE}_*.yaml | head -1)
helm upgrade -i dify -f "$VALUES" dify/dify --version "$CANDIDATE" -n dify
```

First chart download sometimes hits `EOF` from `langgenius.github.io` — retry. Always pin `--version` so an upstream chart bump doesn't change behavior under your feet.

## A.4 — Verify pods

The success criterion is binary:

```bash
kubectl get pods -n dify
```

A clean quick-poc deploy on chart 3.9.1 settles at **16 pods × 1/1 Running** in ~2-3 min. The slow ones:
- `dify-unstructured` — ~800MB image, ~30-60s to pull
- `dify-api` — flips through `0/1 Running` for ~1 min while in-pod DB migration runs (probe `initialDelaySeconds=120/300` is **intentional** in 3.9.x; do not panic)

A test-profile deploy on chart 3.12.0 settles at ~33 pods `1/1` in ~3 min (HPA replica counts make the total vary). Two benign first-boot artifacts (2026-08-10 run):
- `dify-enterprise-collector` may restart once before stabilizing.
- `dify-sandbox` HPA can burst toward maxReplicas right after install: sandbox pods report Ready before their python-dependency init finishes, then each new pod burns ~1 CPU against a 100m request, so utilization stays above target until init completes; replicas then drain back through the 300s scale-down window. `terraform.tfvars.example` now ships `hpa_config.sandbox.scale_up_stabilization_window = 300` to suppress this (early pods go idle inside the window, vetoing further scale-up — at the cost of real bursts also waiting up to 300s). A tfvars written before that change (window 0) will still show the burst; it self-heals in ~5-10 min. Root cause is chart-side readiness timing.

For autonomous monitoring, an until-loop works well:
```bash
# Monitor: emits one event per state-change tick + one final ALL READY line
prev=""; for i in $(seq 1 80); do
  snap=$(kubectl get pods -n dify --no-headers 2>/dev/null | awk '{print $1,$2,$3}' | sort)
  if [ "$snap" != "$prev" ]; then
    bad=$(echo "$snap" | grep -E "Error|CrashLoopBackOff|ImagePull|Init:Err|OOMKilled" || true)
    [ -n "$bad" ] && echo "BAD: $bad"
    ready=$(echo "$snap" | awk '$2=="1/1" || $2=="2/2"' | wc -l | tr -d ' ')
    total=$(echo "$snap" | wc -l | tr -d ' ')
    echo "tick $i: $ready/$total ready"
    prev="$snap"
    [ "$ready" = "$total" ] && [ "$total" -gt 0 ] && echo "ALL READY" && break
  fi
  sleep 15
done
```

## A.5 — Validate the chart-vs-tf contract

Once pods are stable, sanity-check the things most likely to silently regress between chart releases:

```bash
# (1) Every Deployment's actual SA — catches "chart added a new deployment we didn't know about"
kubectl get deploy -n dify -o custom-columns=NAME:.metadata.name,SA:.spec.template.spec.serviceAccountName

# (2) IRSA wired on every SA the chart consumes
for sa in $(kubectl get sa -n dify -o jsonpath='{.items[*].metadata.name}'); do
  arn=$(kubectl get sa "$sa" -n dify -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
  echo "$sa: ${arn:-<no IRSA>}"
done

# (3) Any pod with restart count > 0 = something silently CrashLoopped before stabilizing
kubectl get pods -n dify --no-headers | awk '$4!="0" {print}'

# (4) Worker celery queue overlap — if two ConfigMaps share queues, you have duplicate task execution
for cm in $(kubectl get cm -n dify -o name | grep -E 'worker|trigger'); do
  echo "=== $cm ==="
  kubectl get "$cm" -n dify -o jsonpath='{.data.CELERY_QUEUES}{"\n"}'
done

# (5) Ingress got an address (or surfaces a cert error to investigate)
kubectl get ingress -n dify
```

A pod running as `default` SA where the chart docs say a named SA should be → file the gap (most likely the chart added a new deployment whose `serviceAccountName` we haven't wired up in `values.yaml`). See **Past mismatches catalog** below for the recurring ones.

## A.6 — Point DNS at the new ALB

Every rebuild creates a **new** ALB hostname — external DNS records still alias the destroyed one. `kubectl get ingress -n dify` gives the new address. If the domain's zone is NOT in this account's Route53 (`aws route53 list-hosted-zones`), the CNAMEs must be updated at the external DNS provider — nothing in tf or the scripts does this. Until DNS propagates, smoke test the ALB directly:

```bash
ALB=$(kubectl get ingress dify-ingress -n dify -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: console.<domain>" "http://$ALB/"   # expect 301 (ssl-redirect)
curl -s -o /dev/null -w "%{http_code}\n" --resolve "api.<domain>:443:$(dig +short "$ALB" | head -1)" "https://api.<domain>/"  # expect 200 with valid TLS
```

---

# SCENARIO B — Tear down completely

**Goal:** zero `dify-{deployment_id}-*` resources left in the AWS account.

**Time budget:** ~20-25 minutes, dominated by OpenSearch (~13 min) and EKS node group drain (~3-5 min).

## Order is mandatory

```
1. helm uninstall              ← stops new writes to S3 / RDS / ECR
2. drain S3 bucket             ← versioned, must be empty before tf can destroy
3. delete plugin ECR repos     ← orphans not in tf state
4. terraform destroy
5. orphan scan + cleanup       ← VPC ENI cascade, leaked EIPs
```

Skipping or reordering is what makes destroy hang. The S3 drain must happen before destroy or the bucket resource refuses to delete. The ECR plugin cleanup must happen before destroy or the orphan repos survive forever.

## B.1 — Helm uninstall

```bash
helm uninstall dify -n dify
```

**Don't `helm uninstall` then immediately `helm install`** as a "reset." The chart re-creates the SAs without the IRSA `eks.amazonaws.com/role-arn` annotation that terraform put on them, and SA configuration drifts. If only redeploying the app: `terraform apply` first to recreate the SAs, **then** helm install.

## B.2 — Drain the S3 bucket

`aws_s3_bucket.dify_storage` has versioning enabled (per `tf/s3.tf`) and **no `force_destroy`**. Versioned buckets need every object version + every delete marker removed before terraform can destroy them — otherwise `terraform destroy` fails with `BucketNotEmpty`.

```bash
BUCKET=dify-<deployment_id>-storage

# CHECK EMPTINESS FIRST. On an empty bucket the JMESPath below yields null,
# the python parse fails, count never becomes "0", and the loop spins forever
# (burned us on 2026-08-07: a fresh deploy's bucket had zero objects).
aws s3api list-object-versions --bucket "$BUCKET" \
  --query '[length(Versions||`[]`), length(DeleteMarkers||`[]`)]' --output json
# [0, 0] -> bucket already empty, skip the loop entirely.

# NOTE: merge Versions + DeleteMarkers in Python — JMESPath has no `+` array
# concatenation, and a silently failing --query would end this loop with the
# bucket still full.
while :; do
  payload=$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 1000 \
    --output json | python3 -c 'import json,sys
raw = sys.stdin.read()
d = json.loads(raw) if raw.strip() else {}
objs = [{"Key": o["Key"], "VersionId": o["VersionId"]}
        for k in ("Versions", "DeleteMarkers") for o in d.get(k) or []]
print(json.dumps({"Objects": objs}) if objs else "")')
  [ -z "$payload" ] && break
  aws s3api delete-objects --bucket "$BUCKET" --delete "$payload" >/dev/null
  echo "deleted $(printf %s "$payload" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["Objects"]))')"
done
```

`aws s3 rm "s3://$BUCKET" --recursive` is **not enough** — it only removes current objects, not noncurrent versions / delete markers.

## B.3 — Delete plugin-created ECR repos (NOT in tf state)

The plugin daemon creates ECR repos at runtime, named `dify-{deployment_id}/{provider}-{sha}`. Terraform only manages two repos (`dify-{deployment_id}` and `dify-{deployment_id}-ee-plugin-repo`). Plugin repos accumulate during normal use and **are not in tf state** — `terraform destroy` leaves them, and they keep costing money.

```bash
DEP_ID=<deployment_id>; REGION=us-east-2

aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName, 'dify-${DEP_ID}/')].repositoryName" \
  --output text | tr '\t' '\n' > /tmp/ecr_repos.txt

cat /tmp/ecr_repos.txt   # SHOW the user the list before bulk-deleting

while IFS= read -r r; do
  [ -z "$r" ] && continue
  aws ecr delete-repository --region "$REGION" --repository-name "$r" --force
done < /tmp/ecr_repos.txt
```

**Use `while read`, not `for r in $repos`** — repo names from `--output text` are tab-separated, and `for` will glue them into one ~10kB argument that fails with `must have length less than or equal to 256`.

## B.4 — Terraform destroy

```bash
cd tf/
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

For autonomous runs, monitor key destroy events + errors:
```bash
terraform apply destroy.tfplan > /tmp/tf_destroy.log 2>&1
# Monitor: tail -F /tmp/tf_destroy.log | grep --line-buffered -E "Destruction complete after.*(eks_cluster|node_group|aurora|opensearch|s3_bucket|nat_gateway|vpc)|Error:|Destroy complete!|Still destroying.*\[(15|30|45)m"
```

Test envs have `skip_final_snapshot = true` (per the `environment == "test"` guard in `tf/rds.tf`) so Aurora drops without needing a snapshot identifier. Prod env requires a `final_snapshot_identifier`.

OpenSearch is the slowest single resource (~13 min). EKS node group drain is ~3-5 min. If destroy is still going past 25 min, look at OpenSearch and the VPC ENI cascade — those are almost always the holdup.

## B.5 — Orphan scan

After `Destroy complete!`, scan for resources that share the deployment's name prefix but weren't in tf state:

```bash
DEP_ID=<deployment_id>; REGION=us-east-2

# (a) Surviving ECR repos (older deployments / out-of-band creation)
aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?contains(repositoryName, '${DEP_ID}')].repositoryName" --output text

# (b) Surviving VPCs tagged with this deployment id (= an older tf run that didn't fully clean)
aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=*${DEP_ID}*" \
  --query 'Vpcs[].{VpcId:VpcId,Name:Tags[?Key==`Name`].Value|[0]}'

# (c) Unattached EIPs (NAT gateway leaks)
aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[?AssociationId==null].{AllocationId:AllocationId,Tag:Tags[?Key==`Name`].Value|[0]}'

# (d) CloudWatch log groups — EKS creates /aws/eks/<cluster>/cluster OUTSIDE tf
# (never-expiring by default; the audit stream alone is >1 GB/day). tf now
# pre-creates it with retention, but EKS can flush final logs after destroy
# and re-create a small orphan — always check.
aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "/aws/eks/dify-${DEP_ID}" \
  --query 'logGroups[].{n:logGroupName,bytes:storedBytes}'

# (e) Orphan EBS volumes/snapshots from dynamically-provisioned PVs
aws ec2 describe-volumes --region "$REGION" \
  --query "Volumes[?State=='available'].{id:VolumeId,size:Size,tags:Tags}"
aws ec2 describe-snapshots --region "$REGION" --owner-ids "$(aws sts get-caller-identity --query Account --output text)" \
  --query "Snapshots[?contains(to_string(Tags||\`[]\`),'${DEP_ID}')].SnapshotId"
```

**Always show the user the orphan list and ask before deleting.** Substring grep across multiple deployments has burned us — `dify-severn-vpc-eip-us-east-2a` once nearly got deleted because it matched a `*riino*` substring fluke. Filter by full deployment_id token, not substring.

If you find an orphan VPC, the cascade order is mandatory:
```
ENIs / load balancers → NAT GW (delete) → wait for state=deleted → release EIP → IGW (detach + delete) → subnets → route tables → VPC
```
Skipping a step (e.g. trying to delete the VPC before the NAT GW) returns `DependencyViolation`.

Done state: zero matches in (a), (b), (c) for the deployment_id token.

---

# Past mismatches catalog (chart 3.9.x)

When deploying a new chart version (Scenario A.5), explicitly check whether each of these is still a thing or has been fixed upstream.

| Mismatch | Surface | Status as of 3.9.1 |
|---|---|---|
| Chart's `additionalWorkers[trigger-worker]` defaults to `enabled: true` with **no IRSA SA** → `dify-trigger-worker` runs as `default` SA → `botocore.exceptions.NoCredentialsError` CrashLoopBackOff | Pod restart count climbs on `dify-trigger-worker` after deploy | Fixed in `dify-ee-terraform-aws` `feat/support-dify-3.9.1` `db2011d` — all 3 templates now set `additionalWorkers: [{name: trigger-worker, enabled: false}]`. Main `worker` consumes trigger queues (its default `celeryQueues` = all queues), so disabling doesn't lose function. |
| If `trigger-worker` IS kept enabled with a SA, main `worker` and `trigger-worker` both consume the trigger queues → duplicate task execution | Same scheduled task fires twice; `kubectl get cm dify-worker-config dify-trigger-worker-config -o jsonpath='{.data.CELERY_QUEUES}'` shows overlap | Either disable trigger-worker (above), OR override `worker.celeryQueues` to exclude trigger queues. Docs PR `mincodify/Dify-Enterprise-Docs#76` flagged the same issue. |
| `enterprise.passwordEncryptionKey` is new in 3.9.x | Chart ships a public default key; missing override = security risk | Script 4 generates `PASSWORD_ENCRYPTION_KEY` and substitutes `{{password_encryption_key}}` — verify the placeholder is present in **all** 3 templates (was missed in quick-poc, fixed in `db2011d`). |
| `externalPostgres` → `externalDatabase` schema rename in 3.9.0+; multi-engine, single top-level `user`/`password`; 3.9.1 adds `databaseCredentials` for per-DB overrides | Chart silently uses sub-chart Postgres if old schema is provided | All 3 values templates already migrated as part of `feat/support-dify-3.9.1`. |
| Bundled MinIO sub-chart removed in 3.9.0+ | External S3 is now mandatory | Not an issue for AWS deploys (always external S3). |
| New SAs auto-created by chart, RBAC-only, **must NOT have IRSA**: `dify-plugin-controller-sa` (`dify-crd-controller` Deployment), `dify-plugin-manager-sa` (`dify-plugin-manager` Deployment) | Annotating these with `eks.amazonaws.com/role-arn` doesn't break anything but is misleading | Old `dify-plugin-crd-sa` is **not renamed** — it stays for Kaniko build pods spawned by the connector. |
| New `dify-enterprise-collector` Deployment (in-cluster OTLP collector), gated by `global.otel.enabled` (default `true`) AND `enterpriseCollector.enabled` (default `true`) | New deployment showing up in `kubectl get deploy` | No IRSA needed. To disable in cost-sensitive envs, set both to `false`. |
| API probe timing: `readinessProbe.initialDelaySeconds` 30→120, `livenessProbe.initialDelaySeconds` 60→300 | First-deploy `dify-api` looks "stuck" at 0/1 Running for ~1 min | Intentional — covers the in-pod DB migration. Do not kill the pod. |
| Script 4 cert flow has a hole: when watchdog fails (`helm-watchdog.dify.ai` SSL/EOF), cert-selection doesn't run, `{{cert_uuid}}` stays literal | ALB ingress: `Failed build model due to ingress: ... no certificate found for host: api.dify.local` | Workaround: rerun script 4 with TTY + working network, OR post-edit values to drop the cert annotation and set `useTLS: false`. Script-side fix not yet in any merged PR. |

When scanning chart 3.10.x or later, walk the catalog and check whether each one still applies — these are sticky issues but the surface keeps shifting.

---

# Reference — tf knobs that affect lifecycle speed

| Knob | Default | Effect |
|---|---|---|
| `aws_rds_cluster.skip_final_snapshot` | `true` for test, `false` for prod | `false` blocks destroy unless `final_snapshot_identifier` is provided |
| `aws_s3_bucket.force_destroy` | unset (false) | versioned bucket must be drained manually first (Scenario B.2) |
| `s3_versioning_enabled` | `true` | every put creates a version + every delete creates a marker |
| `aws_opensearch_domain` | — | ~13 min create, ~13 min destroy — usually the slowest single resource |
| `aws_eks_node_group` | — | drain ~3-5 min; depends on PDBs |
| `eks_arch` | `arm64` | switches between m7g (arm) and m7a (amd) instance families; check chart images support arm64 if testing arm |

# Reference — repo file map

```
cloud/aws/
├── tf/
│   ├── terraform.tfvars              # deployment_id, region, env, sizing
│   ├── eks.tf, vpc.tf, rds.tf, ...   # the 94 resources
│   ├── irsa.tf                       # IAM roles + SA annotations
│   └── kubernetes.tf                 # SAs created in `dify` namespace
├── scripts/
│   ├── 1_check_aws_permissions.sh
│   ├── 2_verify_tf_deployment.sh    # writes secret/deployment_verification_*.txt
│   ├── 3_post_tf_apply.sh           # writes secret/config_*.env, .txt, .log
│   ├── 4_generate_dify_helm.sh      # writes secret/helm_values_<ts>/values.{quick-poc,test,prod}_*.yaml
│   ├── 5_create_databases.sh        # cn-region only — RDS Data API workaround
│   └── helm_templates/
│       ├── values.example.quick-poc.yaml
│       ├── values.example.test.yaml
│       └── values.example.prod.yaml
└── secret/                          # generated, gitignored, chmod 600
```
