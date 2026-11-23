# S3 log archive use case: the collector writes the processed (already redacted and sampled) logs to this bucket.
# It authenticates through the instance role, so there are no access keys anywhere.

locals {
  archive_bucket = "${var.lab_name}-logs-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket" "archive" {
  count         = var.enable_s3_archive ? 1 : 0
  bucket        = local.archive_bucket
  force_destroy = true # lab data only: terraform destroy must not get stuck on objects
}

resource "aws_s3_bucket_public_access_block" "archive" {
  count                   = var.enable_s3_archive ? 1 : 0
  bucket                  = aws_s3_bucket.archive[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  count  = var.enable_s3_archive ? 1 : 0
  bucket = aws_s3_bucket.archive[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Keep the lab cheap: archived objects expire after 7 days.
resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  count  = var.enable_s3_archive ? 1 : 0
  bucket = aws_s3_bucket.archive[0].id
  rule {
    id     = "expire-lab-archive"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

resource "aws_iam_role_policy" "archive_rw" {
  count = var.enable_s3_archive ? 1 : 0
  name  = "${var.lab_name}-logs-archive"
  role  = aws_iam_role.shop.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.archive[0].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.archive[0].arn
      }
    ]
  })
}
