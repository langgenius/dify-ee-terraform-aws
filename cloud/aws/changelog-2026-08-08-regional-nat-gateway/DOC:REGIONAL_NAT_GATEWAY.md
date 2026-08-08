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
| Elastic IPs | one, Terraform-managed | one per active AZ, **AWS-managed** |
| Egress survives one AZ failing | **no** | yes |
| Private route table | single `0.0.0.0/0` route | identical — same single route |
| Available in `aws-cn` | yes | no (forced to `zonal`) |

Both modes produce exactly one NAT Gateway ID, so nothing downstream of the route table changes.

## 2. Choosing a mode

- **`environment = "prod"` → use `"regional"`.** The prod profile already runs EKS nodes, Aurora, and Redis multi-AZ. Leaving egress zonal means one AZ outage still stops every chat and workflow response, because all LLM provider calls leave through that gateway.
- **`environment = "test"` → `"zonal"` is fine.** It is the cheaper option and a test environment does not warrant the redundancy.
- **China regions** → the setting is inert; see §4.

## 3. Behaviour verification

The mode-selection logic was evaluated directly with `terraform console` across the full input matrix:

| `aws_region` | `nat_availability_mode` | `use_existing_vpc` | effective mode | zonal NAT | regional NAT |
|---|---|---|---|---|---|
| `us-west-2` | `zonal` | `false` | `zonal` | 1 | 0 |
| `us-west-2` | `regional` | `false` | `regional` | 0 | 1 |
| `cn-north-1` | `regional` | `false` | **`zonal`** | 1 | 0 |
| `cn-northwest-1` | `zonal` | `false` | `zonal` | 1 | 0 |
| `us-west-2` | `regional` | `true` | `regional` | 0 | 0 |
| `us-west-2` | `zonal` | `true` | `zonal` | 0 | 0 |

Exactly one NAT Gateway is created when the stack owns the VPC, and none when it does not. Formatting and schema checks:

```
$ terraform fmt -recursive     # clean
$ terraform validate
Success! The configuration is valid.
```

> **Note for the reviewer**: `terraform plan` against a live AWS account was **not** run — this contribution was prepared without a sandbox account that can create EKS/RDS/OpenSearch. The verification above is limited to `fmt`, `validate`, provider-schema confirmation of `availability_mode` / `vpc_id` / `regional_nat_gateway_address`, and console evaluation of the branch logic. An `apply` in `regional` mode has not been exercised end to end, so please confirm on your side before merging.

## 4. AWS China regions

Regional NAT Gateway is not offered in the `aws-cn` partition. Rather than rejecting the input, `local.nat_availability_mode` overrides it:

```hcl
nat_availability_mode = local.aws_is_cn_region ? "zonal" : var.nat_availability_mode
```

Setting `"regional"` in a `cn-*` region is therefore safe but has no effect — you get the zonal gateway. The `nat_availability_mode` **output** reports the effective value, so `terraform output` shows `zonal`, not the requested `regional`. If AWS later ships the feature in China, deleting the ternary is the only change needed.

## 5. Egress IP allowlisting

Zonal mode has one stable egress IP; regional mode has one per active AZ, and **the set changes as AWS expands or contracts the gateway across AZs**. Any upstream firewall or vendor allowlist (a self-hosted LLM endpoint, a corporate proxy, a partner API) must accept all of them.

```bash
terraform output -json nat_gateway_public_ips
# zonal:    ["52.10.0.1"]
# regional: ["52.10.0.1", "52.10.0.2", "52.10.0.3"]
```

The output is a **list in both modes** — scripts should iterate, never index `[0]`.

If you depend on a fixed, permanently-known egress IP set for a third party's allowlist, stay on `zonal` (accepting the SPOF) or manage the addresses out of band; automatic AZ expansion and pinned IPs are mutually exclusive.

## 6. Switching modes on a live deployment

Changing `nat_availability_mode` destroys one NAT Gateway and creates another. In-flight connections are reset — Dify pods mid-LLM-call will see them drop.

1. Schedule a maintenance window.
2. `terraform plan -out=tfplan` and confirm the plan touches only the NAT Gateway, the EIP, and the private route table's default route.
3. `terraform apply tfplan`.
4. Re-read `terraform output -json nat_gateway_public_ips` and update any upstream allowlists (§5) — going `zonal` → `regional` adds addresses, and the old EIP is released.

Going `zonal` → `regional` leaves the public subnets in place. They are still used by the internet-facing ALB when `elb_mode = "internet-facing"`, so they are not removed and no subnet CIDR changes.

## 7. Cost

Regional mode bills per NAT Gateway hour plus data processed, the same dimensions as zonal. The practical difference is that regional mode can run capacity in several AZs at once, and it removes the cross-AZ data-transfer charge that zonal mode incurs when a pod in AZ-b egresses through a gateway pinned to AZ-a. Model your own traffic before assuming a direction; for the prod profile the availability argument is the primary one, not cost.

## 8. References

- [AWS: NAT gateway regional availability (announcement, Nov 2025)](https://aws.amazon.com/about-aws/whats-new/2025/11/aws-nat-gateway-regional-availability/)
- [AWS VPC User Guide: Regional NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html)
- [terraform-provider-aws#45151 — regional NAT gateway support](https://github.com/hashicorp/terraform-provider-aws/pull/45151)
