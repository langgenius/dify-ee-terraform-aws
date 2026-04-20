locals {
  s3_storage_gb = var.environment == "test" ? 100 : 512
}

# S3 Bucket for Dify storage
resource "aws_s3_bucket" "dify_storage" {
  bucket = "dify-${var.deployment_id}-storage"

  tags = {
    Name        = "dify-${var.deployment_id}-storage"
    Environment = var.environment
  }
}



resource "aws_s3_bucket_versioning" "dify_storage" {
  bucket = aws_s3_bucket.dify_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dify_storage" {
  bucket = aws_s3_bucket.dify_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "dify_storage" {
  bucket = aws_s3_bucket.dify_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}