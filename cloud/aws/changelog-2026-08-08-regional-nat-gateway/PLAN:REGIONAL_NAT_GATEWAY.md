# Regional NAT Gateway — Eliminate the Single-AZ Outbound SPOF

**Implementation Date**: 2026-08-08
**Status**: ✅ Completed
**Version**: 1.0
**Branch**: `feat/regional-nat-gateway`
**Issue**: #8 — *feat: support Regional NAT Gateway to eliminate single-AZ outbound SPOF*

## Overview

`vpc.tf` created exactly one zonal NAT Gateway (`aws_nat_gateway.main`, `count = 1`, pinned to the *first* public subnet) for every deployment, including `environment = "prod"`. All Dify outbound traffic — LLM provider APIs (OpenAI, Bedrock), the plugin marketplace, and the license server — egresses through it. An outage in that one AZ therefore takes down chat and workflow responses for the whole deployment, even though EKS node groups, Aurora (writer + reader), and Redis (primary + replica) are all multi-AZ in the prod profile.

This PR removes that egress SPOF. It does **not** make the stack fully HA: `aws_opensearch_domain.main.cluster_config` reads `var.opensearch_instance_count` (default `1`), not the `instance_count = 3` in `local.opensearch_config`, which no resource consumes — so OpenSearch is single-node even in the prod profile, and has no `zone_awareness_config`. That is a separate defect, out of scope here and worth its own issue.

AWS released **Regional NAT Gateway** (GA, Nov 2025). It auto-expands and contracts across AZs following workload ENIs, provides zonal redundancy by default, requires no public subnet, and manages its own Elastic IPs — while still exposing a single NAT Gateway ID that all route tables can reference.

This change adds an **opt-in** `nat_availability_mode` variable. The default preserves the existing zonal behaviour exactly, so current deployments see a no-op plan.

### Design constraints

1. **No infrastructure change for existing deployments.** Default stays `"zonal"`; the `aws_nat_gateway.main` / `aws_eip.nat` addresses and their arguments are untouched in that mode, so the plan is empty. This is *not* a zero-effort upgrade: the provider floor moves (see below) and operators must run `terraform init -upgrade` once.
2. **Route wiring must not fork.** Both modes resolve to one NAT Gateway ID, so `aws_route_table.private` keeps a single `route` block.
3. **Unsupported partitions must not break.** Regional NAT Gateway is commercial-regions-only. Rather than failing at apply, the effective mode is forced to `"zonal"` for `cn-*` and `us-gov-*`, extending this repo's existing China-region policy (`local.aws_is_cn_region`) with a new `local.aws_is_gov_region`.
4. **Egress IPs must stay discoverable — and honestly described.** Regional mode allocates up to 32 addresses per AZ and changes the set as it expands, so the output must be a list, and the docs must warn that a state-backed output is a snapshot rather than a live allowlist source.

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
nat_regional_supported = !local.aws_is_cn_region && !local.aws_is_gov_region
nat_availability_mode  = local.nat_regional_supported ? var.nat_availability_mode : "zonal"
create_zonal_nat       = local.create_vpc && local.nat_availability_mode == "zonal"
create_regional_nat    = local.create_vpc && local.nat_availability_mode == "regional"
```

`local.aws_is_cn_region` already exists in `locals.global.tf`; `local.aws_is_gov_region` is added there alongside it (see below).

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
| `nat_gateway_public_ips` | **List.** Zonal → one EIP; regional → every `public_ip` in `regional_nat_gateway_address` as of the last state refresh. The description warns that this is a snapshot, not a live allowlist source |

### 4. MODIFIED: `tf/providers.tf`

AWS provider constraint `~> 6.3` → `>= 6.24.0, < 7.0.0`, with a comment recording why the floor exists.

### 5. MODIFIED: `tf/locals.global.tf`

Added `local.aws_is_gov_region = startswith(var.aws_region, "us-gov-")`, mirroring the existing `aws_is_cn_region`. Scoped as a general "commercial-regions-only feature" gate. The existing `aws_partition` / `dns_suffix` ternaries still return the commercial values for GovCloud (correct partition would be `aws-us-gov`) — pre-existing and out of scope for this PR, since the stack is not otherwise validated on GovCloud.

### 6. MODIFIED: `tf/terraform.tfvars.example`, `README.md`, `CLAUDE.md`

Documented the variable, the prod recommendation, the provider floor and `terraform init -upgrade` step, the China/GovCloud override, the unstable egress IP set, and the maintenance-window caveat for switching modes on a live deployment.

---

## Provider Support — floor raised to 6.24.0 (breaking for old locks)

`availability_mode`, the regional-mode `vpc_id`, and `regional_nat_gateway_address` landed in the AWS provider in Dec 2025 (hashicorp/terraform-provider-aws#45151). Measuring `aws_nat_gateway`'s schema per version:

| provider | `availability_mode` | `vpc_id` | `regional_nat_gateway_address` |
|---|---|---|---|
| 6.3.0 | absent | absent | absent |
| 6.23.0 | absent | absent | absent |
| **6.24.0** | present | present | present |

The old `~> 6.3` constraint admits 6.3–6.23, where these arguments do not exist. **Terraform validates resource schemas even when `count` evaluates to 0**, so a deployment left on the default `"zonal"` still fails — confirmed by pinning `= 6.23.0` and running `terraform validate` with `count = 0`:

```
Error: Unsupported argument — An argument named "availability_mode" is not expected here.
Error: Unsupported argument — An argument named "vpc_id" is not expected here.
Error: Missing required argument — The argument "subnet_id" is required, but no definition was found.
```

`providers.tf` therefore moves to `>= 6.24.0, < 7.0.0`.

**Operator impact**: `.terraform.lock.hcl` is gitignored in this repo, so each deployment holds its own lock. Anyone whose lock pins < 6.24.0 must run `terraform init -upgrade` once; a plain `terraform init` reuses the locked version and now fails the constraint. After upgrading, `terraform plan` should be empty for `zonal` deployments.

Per the provider docs: `subnet_id` and `allocation_id` are zonal-only and **must not be set** when `availability_mode = "regional"`; `vpc_id` is required in regional mode.

---

## Verification

- `terraform fmt -recursive` — clean
- `terraform validate` — `Success! The configuration is valid.`
- Branch-logic truth table (region × mode × `use_existing_vpc`) evaluated via `terraform console` — see `DOC:REGIONAL_NAT_GATEWAY.md` §3
- Provider boundary measured at 6.3.0 / 6.23.0 / 6.24.0 — see the Provider Support table above
- **Not run**: `terraform plan` / `apply` against a live AWS account (no sandbox available). A regional-mode apply has not been exercised end to end.

## Out of Scope

- **Existing-VPC deployments** (`use_existing_vpc = true`): this stack does not create their NAT, so the variable does not apply. Both `create_*_nat` locals evaluate false and `nat_gateway_id` is `null`.
- **Private NAT** (`connectivity_type = "private"`): not used by this stack, so the regional-mode restriction against it is not a concern.
- **Regional manual mode**: automatic mode is used. Manual mode (operator-managed EIPs per AZ, via `associate-nat-gateway-address`) would give a fixed egress IP set with multi-AZ redundancy, but requires the operator to expand/contract AZs by hand — the opposite of this PR's goal. Deployments that need pinned egress IPs should stay on `zonal`.
- **Per-AZ private route tables**: unnecessary here. Regional mode solves the availability problem without splitting the route table, and zonal mode's cross-AZ data-transfer cost profile is unchanged from before this PR.
- **OpenSearch single-node in prod** (`var.opensearch_instance_count` default `1`, dead `local.opensearch_config`, no `zone_awareness_config`): a real availability gap surfaced while checking the "last SPOF" claim, but unrelated to NAT. Should be filed separately.
