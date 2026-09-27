resource "aws_s3_bucket" "cur" {
  count = local.create_cur_export ? 1 : 0

  region        = local.home_region
  bucket        = local.cur_bucket_name
  force_destroy = var.cur_bucket_force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_ownership_controls" "cur" {
  count = local.create_cur_export ? 1 : 0

  region = local.home_region
  bucket = aws_s3_bucket.cur[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cur" {
  count = local.create_cur_export ? 1 : 0

  region                  = local.home_region
  bucket                  = aws_s3_bucket.cur[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur" {
  count = local.create_cur_export ? 1 : 0

  region = local.home_region
  bucket = aws_s3_bucket.cur[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "cur_bucket" {
  count = local.create_cur_export ? 1 : 0

  statement {
    sid       = "AllowSpikeListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.cur[0].arn]

    principals {
      type        = "AWS"
      identifiers = [local.spike_cur_reader_arn]
    }
  }

  statement {
    sid       = "AllowSpikeReadObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.cur[0].arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [local.spike_cur_reader_arn]
    }
  }

  statement {
    sid       = "DenyNonHTTPSAccess"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cur[0].arn, "${aws_s3_bucket.cur[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "AllowDataExportsDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetBucketPolicy"]
    resources = [aws_s3_bucket.cur[0].arn, "${aws_s3_bucket.cur[0].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["bcm-data-exports.amazonaws.com", "billingreports.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:cur:${local.home_region}:${local.account_id}:definition/*",
        "arn:aws:bcm-data-exports:${local.home_region}:${local.account_id}:export/*",
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "cur" {
  count = local.create_cur_export ? 1 : 0

  region = local.home_region
  bucket = aws_s3_bucket.cur[0].id
  policy = data.aws_iam_policy_document.cur_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.cur]
}

resource "aws_bcmdataexports_export" "cur" {
  count = local.create_cur_export ? 1 : 0

  export {
    name        = local.cur_export_name
    description = "CUR 2.0 (Parquet) export for Spike - ${local.account_id}"

    data_query {
      query_statement = replace(trimspace(file("${path.module}/queries/cur2.sql")), "/\\s+/", " ")
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                   = "HOURLY"
          INCLUDE_RESOURCES                  = "TRUE"
          INCLUDE_CAPACITY_RESERVATION_DATA  = "TRUE"
          INCLUDE_IAM_PRINCIPAL_DATA         = "TRUE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA = "TRUE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cur[0].id
        s3_prefix = local.cur_prefix
        s3_region = local.home_region

        s3_output_configurations {
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
          overwrite   = "OVERWRITE_REPORT"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  tags = local.tags

  depends_on = [aws_s3_bucket_policy.cur]
}
