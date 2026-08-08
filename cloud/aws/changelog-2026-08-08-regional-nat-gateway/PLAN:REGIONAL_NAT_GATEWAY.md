# Regional NAT Gateway — Eliminate the Single-AZ Outbound SPOF

**Implementation Date**: 2026-08-08
**Status**: ✅ Completed
**Version**: 1.0
**Branch**: `feat/regional-nat-gateway`
**Issue**: #8 — *feat: support Regional NAT Gateway to eliminate single-AZ outbound SPOF*

## Overview

`vpc.tf` created exactly one zonal NAT Gateway (`aws_nat_gateway.main`, `count = 1`, pinned to the *first* public subnet) for every deployment, including `environment = "prod"`. All Dify outbound traffic — LLM provider APIs (OpenAI, Bedrock), the plugin marketplace, and the license server — egresses through it. An outage in that one AZ therefore takes down chat and workflow responses for the whole deployment, even though EKS node groups, Aurora (writer + reader), and Redis (primary + replica) are all multi-AZ in the prod profile. The NAT was the last remaining single point of failure in an otherwise HA architecture.

AWS released **Regional NAT Gateway** (GA, Nov 2025). It auto-expands and contracts across AZs following workload ENIs, provides zonal redundancy by default, requires no public subnet, and manages its own Elastic IPs — while still exposing a single NAT Gateway ID that all route tables can reference.

This change adds an **opt-in** `nat_availability_mode` variable. The default preserves the existing zonal behaviour exactly, so current deployments see a no-op plan.

### Design constraints

1. **Zero change for existing deployments.** Default stays `"zonal"`; the `aws_nat_gateway.main` / `aws_eip.nat` addresses and their arguments are untouched in that mode.
2. **Route wiring must not fork.** Both modes resolve to one NAT Gateway ID, so `aws_route_table.private` keeps a single `route` block.
3. **China partition must not break.** Regional NAT Gateway is not offered in `aws-cn`. Rather than failing validation, the effective mode is forced to `"zonal"` for `cn-*` regions, consistent with this repo's existing China-region policy (`local.aws_is_cn_region`).
4. **Egress IPs must stay discoverable.** Regional mode allocates one address per active AZ, so the output must be a list, not a scalar.

---

## Files Modified

### 1. MODIFIED: `tf/variables.tf`

New variable, placed after `elb_mode` (network configuration group):

```hcl
variable "nat_availability_mode" {
  description = "NAT Gateway availability mode: 'zonal' (single-AZ, current behavior) or 'regional' (multi-AZ HA, recommended for prod). Only applies when use_existing_vpc = false. Forced to 'zonal' in AWS China regions, where Regional NAT Gateway is not available."
  type        = string
  default     = "zonal"
  validation {
    condition     = contains(["zonal", "regional"], var.nat_availability_mode)
    error_message = "nat_availability_mode must be either 'zonal' or 'regional'."
  }
}
```

### 2. MODIFIED: `tf/vpc.tf`

**a. New locals** (top-level `locals` block):

```hcl
nat_availability_mode = local.aws_is_cn_region ? "zonal" : var.nat_availability_mode
create_zonal_nat      = local.create_vpc && local.nat_availability_mode == "zonal"
create_regional_nat   = local.create_vpc && local.nat_availability_mode == "regional"
```

`local.aws_is_cn_region` already exists in `locals.global.tf`, so the China guard adds no new detection logic.

**b. `aws_eip.nat` and `aws_nat_gateway.main`** — `count` narrowed from `local.create_vpc` to `local.create_zonal_nat`. Arguments unchanged.

**c. NEW `aws_nat_gateway.regional`** — automatic mode; AWS picks the AZs and manages the EIPs:

```hcl
resource "aws_nat_gateway" "regional" {
  count             = local.create_regional_nat ? 1 : 0
  vpc_id            = aws_vpc.main[0].id
  availability_mode = "regional"
  # no subnet_id, no allocation_id — prohibited in regional mode
  depends_on = [aws_internet_gateway.main]
}
```

**d. New local `nat_gateway_id`** — collapses both modes to one ID (`null` when using an existing VPC):

```hcl
nat_gateway_id = (
  local.create_regional_nat ? aws_nat_gateway.regional[0].id :
  local.create_zonal_nat ? aws_nat_gateway.main[0].id :
  null
)
```

**e. `aws_route_table.private`** — default route now points at `local.nat_gateway_id` instead of `aws_nat_gateway.main[0].id`. Single `route` block retained.

### 3. MODIFIED: `tf/outputs.tf`

Three outputs added after `public_subnet_ids`, satisfying the CONTRIBUTING rule that new resources ship with outputs:

| Output | Purpose |
|---|---|
| `nat_availability_mode` | Effective mode after the China override — tells operators what they actually got, not what they asked for |
| `nat_gateway_id` | The ID wired into the private route table |
| `nat_gateway_public_ips` | **List.** Zonal → one EIP; regional → one `public_ip` per entry in `regional_nat_gateway_address`. Needed for upstream egress allowlists |

### 4. MODIFIED: `tf/terraform.tfvars.example`, `README.md`, `CLAUDE.md`

Documented the variable, the prod recommendation, the China override, the list-shaped egress IP output, and the maintenance-window caveat for switching modes on a live deployment.

---

## Provider Support

`availability_mode` and the regional-mode `vpc_id` landed in the AWS provider in Dec 2025 (hashicorp/terraform-provider-aws#45151). Verified against the resource schema resolved under this repo's existing `~> 6.3` constraint — **no provider version bump required**:

```
$ terraform providers schema -json | jq '...resource_schemas.aws_nat_gateway.block.attributes'
availability_mode            | string | optional=true computed=true
vpc_id                       | string | optional=true computed=true
regional_nat_gateway_address | set(object({... public_ip, availability_zone, status ...})) | computed=true
```

Per the provider docs: `subnet_id` and `allocation_id` are zonal-only and **must not be set** when `availability_mode = "regional"`; `vpc_id` is required in regional mode.

---

## Verification

- `terraform fmt -recursive` — clean
- `terraform validate` — `Success! The configuration is valid.`
- Branch-logic truth table evaluated via `terraform console` — see `DOC:REGIONAL_NAT_GATEWAY.md` §3

## Out of Scope

- **Existing-VPC deployments** (`use_existing_vpc = true`): this stack does not create their NAT, so the variable does not apply. Both `create_*_nat` locals evaluate false and `nat_gateway_id` is `null`.
- **Private NAT** (`connectivity_type = "private"`): not used by this stack, so the regional-mode restriction against it is not a concern.
- **Per-AZ private route tables**: unnecessary here. Regional mode solves the availability problem without splitting the route table, and zonal mode's cross-AZ data-transfer cost profile is unchanged from before this PR.
