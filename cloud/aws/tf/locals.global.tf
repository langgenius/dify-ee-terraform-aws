locals {
  aws_is_cn_region = startswith(var.aws_region, "cn")
  aws_partition    = local.aws_is_cn_region ? "aws-cn" : "aws"
  dns_suffix       = local.aws_is_cn_region ? "amazonaws.com.cn" : "amazonaws.com"

  # Used to gate features that AWS ships to commercial regions only. This stack is not
  # otherwise validated against GovCloud; the flag exists so such features degrade
  # gracefully rather than failing at apply time.
  aws_is_gov_region = startswith(var.aws_region, "us-gov-")
}
