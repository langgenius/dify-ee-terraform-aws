locals {
  aws_is_cn_region = startswith(var.aws_region, "cn")
  aws_partition    = local.aws_is_cn_region ? "aws-cn" : "aws"
  dns_suffix       = local.aws_is_cn_region ? "amazonaws.com.cn" : "amazonaws.com"
}
