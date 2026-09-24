# NAT Gateway Availability Modes — Operator Guide

**Audience**: operators choosing an egress topology for a Dify EE deployment on AWS, and reviewers checking the change from `PLAN:REGIONAL_NAT_GATEWAY.md`.
**Applies to**: deployments that create their own VPC (`use_existing_vpc = false`).
**Baseline date**: 2026-08-08.

---

## 1. What the variable does

```hcl
nat_availability_mode = "zonal"     # default — unchanged from before this PR
nat_availability_mode = "regional"  # multi-AZ, recommended for environment = "prod"
```

| | `zonal` | `regional` |
|---|---|---|
| Terraform resource | `aws_nat_gateway.main` + `aws_eip.nat` | `aws_nat_gateway.regional` |
| AZ coverage | one AZ (first public subnet) | AWS spreads across AZs, following workload ENIs |
| Public subnet required | yes | no |
| Elastic IPs | one, Terraform-managed, **stable** | up to 32 per AZ, **AWS-managed and changing** (§5) |
| Egress survives one AZ failing | **no** | yes |
| Private route table | single `0.0.0.0/0` route | identical — same single route |
| Hourly billing | 1 × rate | **AZ count × rate** (§7) |
| Available in China / GovCloud | yes | no — forced to `zonal` (§4) |

Both modes produce exactly one NAT Gateway ID, so nothing downstream of the route table changes.

**Provider requirement**: `>= 6.24.0` (enforced in `providers.tf`). The regional arguments are parsed even when `nat_availability_mode = "zonal"` leaves the resource at `count = 0`, so an older provider fails `terraform validate` in *either* mode. Existing deployments carrying a lock below 6.24.0 must run `terraform init -upgrade` once; `terraform plan` is empty afterwards for `zonal`.

## 2. Choosing a mode

- **`environment = "prod"` → use `"regional"`**, unless something upstream allowlists your egress IPs (§5). The prod profile already runs EKS nodes, Aurora, and Redis multi-AZ. Leaving egress zonal means one AZ outage still stops every chat and workflow response, because all LLM provider calls leave through that gateway.
- **Anything upstream pins your egress IPs → stay on `"zonal"`.** Regional mode's address set changes as AWS expands across AZs; a fixed allowlist and automatic expansion cannot both hold. Read §5 before deciding.
- **`environment = "test"` → `"zonal"` is fine.** It is the cheaper option and a test environment does not warrant the redundancy.
- **China / GovCloud regions** → the setting is inert; see §4.

> Removing the NAT SPOF does **not** make this stack fully HA. OpenSearch is single-node even in the prod profile: `aws_opensearch_domain.main.cluster_config` reads `var.opensearch_instance_count` (default `1`), while the `instance_count = 3` in `local.opensearch_config` is dead code no resource consumes, and no `zone_awareness_config` is set. Unrelated to NAT, but do not read this PR as closing out availability work.

## 3. Behaviour verification

The mode-selection logic was evaluated directly with `terraform console` across the full input matrix:

| `aws_region` | `nat_availability_mode` | `use_existing_vpc` | effective mode | zonal NAT | regional NAT |
|---|---|---|---|---|---|
| `us-west-2` | `zonal` | `false` | `zonal` | 1 | 0 |
| `us-west-2` | `regional` | `false` | `regional` | 0 | 1 |
| `cn-north-1` | `regional` | `false` | **`zonal`** | 1 | 0 |
| `cn-northwest-1` | `zonal` | `false` | `zonal` | 1 | 0 |
| `us-gov-west-1` | `regional` | `false` | **`zonal`** | 1 | 0 |
| `us-west-2` | `regional` | `true` | `regional` | 0 | 0 |
| `us-west-2` | `zonal` | `true` | `zonal` | 0 | 0 |

Exactly one NAT Gateway is created when the stack owns the VPC, and none when it does not.

### Provider boundary

`aws_nat_gateway`'s schema was measured per provider version, and the `count = 0` case was verified to still fail below the floor:

| provider | `availability_mode` | `vpc_id` | `regional_nat_gateway_address` | `validate` with `count = 0` |
|---|---|---|---|---|
| 6.3.0 | absent | absent | absent | fails |
| 6.23.0 | absent | absent | absent | fails — `Unsupported argument`, `Missing required argument "subnet_id"` |
| 6.24.0 | present | present | present | passes |

This is why `providers.tf` declares `>= 6.24.0, < 7.0.0` rather than the previous `~> 6.3`.

Formatting and schema checks:

```
$ terraform fmt -recursive     # clean
$ terraform validate
Success! The configuration is valid.
```

> **Note for the reviewer**: `terraform plan` against a live AWS account was **not** run — this contribution was prepared without a sandbox account that can create EKS/RDS/OpenSearch. The verification above is limited to `fmt`, `validate`, provider-schema confirmation of `availability_mode` / `vpc_id` / `regional_nat_gateway_address`, and console evaluation of the branch logic. An `apply` in `regional` mode has not been exercised end to end, so please confirm on your side before merging.

## 4. Unsupported regions (China, GovCloud)

AWS states the feature "is available in all commercial AWS Regions, except for AWS GovCloud (US) Regions and China Regions." Rather than rejecting the input and failing at apply, `local.nat_availability_mode` overrides it:

```hcl
nat_regional_supported = !local.aws_is_cn_region && !local.aws_is_gov_region
nat_availability_mode  = local.nat_regional_supported ? var.nat_availability_mode : "zonal"
```

Setting `"regional"` in a `cn-*` or `us-gov-*` region is therefore safe but has no effect — you get the zonal gateway. The `nat_availability_mode` **output** reports the effective value, so `terraform output` shows `zonal`, not the requested `regional`. Check it after apply rather than assuming your tfvars took effect. If AWS later ships the feature to these partitions, narrowing `nat_regional_supported` is the only change needed.

> **Scope note**: this stack is validated against commercial and China regions. `local.aws_is_gov_region` is a guard so this feature degrades gracefully, **not** a claim of GovCloud support — `local.aws_partition` still returns `aws` rather than `aws-us-gov` there, which is a pre-existing gap outside this PR.

AWS also documents that regional NAT gateways "are not supported in constrained Availability Zones." That is a per-AZ constraint rather than a region-wide one, so it cannot be gated on region prefix; if your VPC spans a constrained AZ, verify behaviour before relying on regional mode.

## 5. Egress IP allowlisting

**Read this before choosing `regional` if anything upstream allowlists your egress IPs.**

Zonal mode has one stable egress IP. Regional mode does not: AWS allocates **up to 32 IP addresses per Availability Zone** and adds or removes them as the gateway expands and contracts. Expansion into a new AZ can take **up to 60 minutes** after a resource is instantiated there. The egress IP set is therefore a moving target.

### Do not treat `terraform output` as the source of truth

`terraform output` extracts values from the **state file** — it does not contact AWS. If EKS scales into a new AZ after your last apply, AWS allocates new NAT addresses while state still holds the old set. `terraform output` will happily return the stale list, and traffic from the new AZ gets rejected by the upstream allowlist while every other AZ keeps working — a partial, hard-to-diagnose failure.

Refresh state first:

```bash
terraform apply -refresh-only    # reconcile state with AWS
terraform output -json nat_gateway_public_ips
```

Or bypass Terraform entirely for a live view, which also exposes each address's `Status` (an address still coming up is not yet usable):

```bash
aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$(terraform output -raw nat_gateway_id)" \
  --query 'NatGateways[0].NatGatewayAddresses[].[AvailabilityZone,PublicIp,Status]' \
  --output table
```

The Terraform output is a **list in both modes** — scripts must iterate, never index `[0]`.

### If you need a fixed egress IP set

Automatic AZ expansion and pinned IPs are mutually exclusive. Options, in order of preference:

1. **Stay on `zonal`** — one stable EIP, at the cost of the single-AZ SPOF this feature exists to remove.
2. **Regional manual mode** — you supply and manage EIPs per AZ (`aws ec2 associate-nat-gateway-address`), keeping the addresses fixed while still spanning AZs. **This stack does not implement manual mode**; it would need `availability_zone_address` blocks in `aws_nat_gateway.regional`. Open an issue if you need it.
3. **Re-poll on a schedule** — automate the `describe-nat-gateways` call above and push changes into the upstream allowlist. Only viable if you control that allowlist.

## 6. Switching modes on a live deployment

Changing `nat_availability_mode` destroys one NAT Gateway and creates another. In-flight connections are reset — Dify pods mid-LLM-call will see them drop.

1. Schedule a maintenance window.
2. `terraform init -upgrade` — required once if your lock predates provider 6.24.0, in either mode.
3. `terraform plan -out=tfplan` and confirm the plan touches only the NAT Gateway, the EIP, and the private route table's default route.
4. `terraform apply tfplan`.
5. Update any upstream allowlists (§5) — going `zonal` → `regional` releases the old EIP and introduces AWS-managed addresses. Confirm them with `describe-nat-gateways`, not a stale `terraform output`, and re-check after workloads have settled across AZs (expansion can lag by up to 60 minutes).

Going `zonal` → `regional` leaves the public subnets in place. They are still used by the internet-facing ALB when `elb_mode = "internet-facing"`, so they are not removed and no subnet CIDR changes.

## 7. Cost

**Regional mode is billed per Availability Zone, not per gateway ID.** One NAT Gateway ID does not mean one hourly charge. AWS bills the hourly rate for each AZ the regional gateway is configured in, plus data processed — the same dimensions as zonal, but multiplied by AZ count.

Rough shape for a 3-AZ prod deployment, using the `us-west-2` list rate of $0.045/NAT gateway-hour (check [Amazon VPC Pricing](https://aws.amazon.com/vpc/pricing/) for your region — rates differ and change):

| | hourly component | ~monthly (730 h) |
|---|---|---|
| `zonal` (1 AZ) | 1 × $0.045 | ~$33 |
| `regional`, expanded to 3 AZs | 3 × $0.045 | ~$99 |

Data processing is charged per GB at the same rate in both modes and is unaffected by this choice.

Two offsets to weigh against the ~$66/month delta:

- Zonal mode incurs **cross-AZ data transfer** whenever a pod in AZ-b egresses through a gateway pinned to AZ-a. In a 3-AZ EKS deployment that is roughly two-thirds of egress traffic. At high volume this can exceed the extra hourly charge.
- Regional mode contracts out of AZs with no active workload, so you are not billed for 3 AZs unless workloads actually span 3 AZs.

Model your own traffic before assuming a direction. For the prod profile the availability argument is the primary one; cost is secondary.

## 8. References

- [AWS: NAT gateway regional availability (announcement, Nov 2025)](https://aws.amazon.com/about-aws/whats-new/2025/11/aws-nat-gateway-regional-availability/)
- [AWS VPC User Guide: Regional NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html)
- [terraform-provider-aws#45151 — regional NAT gateway support](https://github.com/hashicorp/terraform-provider-aws/pull/45151)
- [Amazon VPC Pricing](https://aws.amazon.com/vpc/pricing/) — NAT gateway hourly rate is per AZ for regional mode
- [Terraform: `terraform output`](https://developer.hashicorp.com/terraform/cli/commands/output) — reads the state file; does not refresh
- [Terraform: dependency lock file](https://developer.hashicorp.com/terraform/language/files/dependency-lock) — why `-upgrade` is needed after the floor moved
