################################################################################
# Current account - configured natively, one bucket per listed region
################################################################################

data "aws_iam_role" "bedrock_logs_reader" {
  count = length(local.local_bedrock_logs_regions) > 0 && !local.create_local_role ? 1 : 0

  name = local.role_name
}

data "aws_iam_policy_document" "bedrock_logs_kms" {
  for_each = local.local_bedrock_logs_regions

  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowBedrockEncryption"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${each.key}:${local.account_id}:*"]
    }
  }

  statement {
    sid       = "AllowSpikeDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type = "AWS"
      identifiers = [
        local.create_local_role ? aws_iam_role.spike[0].arn : data.aws_iam_role.bedrock_logs_reader[0].arn,
      ]
    }
  }
}

resource "aws_kms_key" "bedrock_logs" {
  for_each = local.local_bedrock_logs_regions

  region                  = each.key
  description             = "Encrypts Directeam Bedrock invocation logs in ${each.key}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.bedrock_logs_kms[each.key].json
  tags                    = local.tags

  depends_on = [aws_iam_role.spike]
}

resource "aws_kms_alias" "bedrock_logs" {
  for_each = aws_kms_key.bedrock_logs

  region        = each.key
  name          = "alias/directeam-finops-bedrock-logs-${each.key}"
  target_key_id = each.value.key_id
}

resource "aws_s3_bucket" "bedrock_logs" {
  for_each = local.local_bedrock_logs_regions

  region        = each.key
  bucket        = "${local.bedrock_logs_bucket_prefix}-${local.account_id}-${each.key}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "bedrock_logs" {
  for_each = aws_s3_bucket.bedrock_logs

  region = each.key
  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "bedrock_logs" {
  for_each = aws_s3_bucket.bedrock_logs

  region = each.key
  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "bedrock_logs" {
  for_each = aws_s3_bucket.bedrock_logs

  region                  = each.key
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bedrock_logs" {
  for_each = aws_s3_bucket.bedrock_logs

  region = each.key
  bucket = each.value.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.bedrock_logs[each.key].arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "bedrock_logs" {
  for_each = aws_s3_bucket.bedrock_logs

  region = each.key
  bucket = each.value.id

  rule {
    id     = "ExpireInvocationLogs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.bedrock_invocation_logs_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.bedrock_invocation_logs_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.bedrock_logs]
}

data "aws_iam_policy_document" "bedrock_logs_bucket" {
  for_each = aws_s3_bucket.bedrock_logs

  statement {
    sid       = "AllowBedrockInvocationLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${each.value.arn}/${local.bedrock_logs_key_prefix}/AWSLogs/${local.account_id}/BedrockModelInvocationLogs/*"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${each.key}:${local.account_id}:*"]
    }
  }

  statement {
    sid       = "DenyNonHTTPSAccess"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

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
}

resource "aws_s3_bucket_policy" "bedrock_logs" {
  for_each = aws_s3_bucket.bedrock_logs

  region = each.key
  bucket = each.value.id
  policy = data.aws_iam_policy_document.bedrock_logs_bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.bedrock_logs]
}

resource "aws_bedrock_model_invocation_logging_configuration" "spike" {
  for_each = aws_s3_bucket.bedrock_logs

  region = each.key

  logging_config {
    text_data_delivery_enabled      = false
    image_data_delivery_enabled     = false
    embedding_data_delivery_enabled = false
    video_data_delivery_enabled     = false

    s3_config {
      bucket_name = each.value.id
      key_prefix  = local.bedrock_logs_key_prefix
    }
  }

  depends_on = [
    aws_s3_bucket_ownership_controls.bedrock_logs,
    aws_s3_bucket_policy.bedrock_logs,
    aws_s3_bucket_server_side_encryption_configuration.bedrock_logs,
    aws_s3_bucket_versioning.bedrock_logs,
  ]
}

data "aws_iam_policy_document" "bedrock_logs_read" {
  for_each = aws_s3_bucket.bedrock_logs

  statement {
    sid       = "DiscoverInvocationLogging"
    effect    = "Allow"
    actions   = ["bedrock:GetModelInvocationLoggingConfiguration"]
    resources = ["*"]
  }

  statement {
    sid       = "ListInvocationLogs"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [each.value.arn]
  }

  statement {
    sid       = "ReadInvocationLogs"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${each.value.arn}/*"]
  }

  statement {
    sid       = "DecryptInvocationLogs"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.bedrock_logs[each.key].arn]
  }
}

resource "aws_iam_role_policy" "bedrock_logs_read" {
  for_each = aws_s3_bucket.bedrock_logs

  name   = "BedrockInvocationLogsRead-${each.key}"
  role   = local.create_local_role ? aws_iam_role.spike[0].name : data.aws_iam_role.bedrock_logs_reader[0].name
  policy = data.aws_iam_policy_document.bedrock_logs_read[each.key].json

  depends_on = [terraform_data.spike_stack_update]
}

################################################################################
# Member accounts - optional part of the Spike StackSet template
################################################################################

locals {
  bedrock_logs_function_name   = "DirecteamFinOpsBedrockInvocationLogging"
  bedrock_logs_function_source = file("${path.module}/functions/bedrock_invocation_logging.py")
  bedrock_logs_template_tags   = [for key in sort(keys(local.tags)) : { Key = key, Value = local.tags[key] }]

  # Region -> account ID -> "1". Each member stack looks up its own region and account to decide whether to
  # create the logging resources, so a single template serves every account/region pair.
  bedrock_logs_mapping = {
    for region, accounts in local.member_bedrock_logs_accounts_by_region :
    region => { for account_id in accounts : account_id => "1" }
  }

  bedrock_logs_member_conditions = {
    CreateBedrockInvocationLogs = {
      "Fn::Equals" = [
        {
          "Fn::FindInMap" = [
            "BedrockInvocationLogs",
            { Ref = "AWS::Region" },
            { Ref = "AWS::AccountId" },
          ]
        },
        "1",
      ]
    }
  }

  bedrock_logs_member_resource_definitions = {
    BedrockLogKey = {
      Type = "AWS::KMS::Key"
      Properties = {
        Description         = "Encrypts Directeam Bedrock invocation logs"
        EnableKeyRotation   = true
        PendingWindowInDays = 30
        KeyPolicy = {
          Version = "2012-10-17"
          Statement = [
            {
              Sid       = "EnableAccountAdministration"
              Effect    = "Allow"
              Principal = { AWS = { "Fn::Sub" = "arn:aws:iam::$${AWS::AccountId}:root" } }
              Action    = "kms:*"
              Resource  = "*"
            },
            {
              Sid       = "AllowBedrockEncryption"
              Effect    = "Allow"
              Principal = { Service = "bedrock.amazonaws.com" }
              Action    = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
              Resource  = "*"
              Condition = {
                StringEquals = { "aws:SourceAccount" = { Ref = "AWS::AccountId" } }
                ArnLike      = { "aws:SourceArn" = { "Fn::Sub" = "arn:aws:bedrock:$${AWS::Region}:$${AWS::AccountId}:*" } }
              }
            },
            {
              Sid       = "AllowSpikeDecrypt"
              Effect    = "Allow"
              Principal = { AWS = { "Fn::Sub" = "arn:aws:iam::$${AWS::AccountId}:role/${local.role_name}" } }
              Action    = ["kms:Decrypt", "kms:DescribeKey"]
              Resource  = "*"
            },
          ]
        }
        Tags = local.bedrock_logs_template_tags
      }
    }

    BedrockLogKeyAlias = {
      Type = "AWS::KMS::Alias"
      Properties = {
        AliasName   = { "Fn::Sub" = "alias/directeam-finops-bedrock-logs-$${AWS::Region}" }
        TargetKeyId = { Ref = "BedrockLogKey" }
      }
    }

    BedrockLogBucket = {
      Type = "AWS::S3::Bucket"
      Properties = {
        BucketName = { "Fn::Sub" = "${local.bedrock_logs_bucket_prefix}-$${AWS::AccountId}-$${AWS::Region}" }
        BucketEncryption = {
          ServerSideEncryptionConfiguration = [{
            BucketKeyEnabled = true
            ServerSideEncryptionByDefault = {
              KMSMasterKeyID = { "Fn::GetAtt" = ["BedrockLogKey", "Arn"] }
              SSEAlgorithm   = "aws:kms"
            }
          }]
        }
        VersioningConfiguration = { Status = "Enabled" }
        PublicAccessBlockConfiguration = {
          BlockPublicAcls       = true
          BlockPublicPolicy     = true
          IgnorePublicAcls      = true
          RestrictPublicBuckets = true
        }
        OwnershipControls = { Rules = [{ ObjectOwnership = "BucketOwnerEnforced" }] }
        LifecycleConfiguration = {
          Rules = [{
            Id                             = "ExpireInvocationLogs"
            Status                         = "Enabled"
            ExpirationInDays               = var.bedrock_invocation_logs_retention_days
            NoncurrentVersionExpiration    = { NoncurrentDays = var.bedrock_invocation_logs_retention_days }
            AbortIncompleteMultipartUpload = { DaysAfterInitiation = 7 }
          }]
        }
        Tags = local.bedrock_logs_template_tags
      }
    }

    BedrockLogBucketPolicy = {
      Type = "AWS::S3::BucketPolicy"
      Properties = {
        Bucket = { Ref = "BedrockLogBucket" }
        PolicyDocument = {
          Version = "2012-10-17"
          Statement = [
            {
              Sid       = "AllowBedrockInvocationLogDelivery"
              Effect    = "Allow"
              Principal = { Service = "bedrock.amazonaws.com" }
              Action    = "s3:PutObject"
              Resource  = { "Fn::Sub" = "arn:aws:s3:::$${BedrockLogBucket}/${local.bedrock_logs_key_prefix}/AWSLogs/$${AWS::AccountId}/BedrockModelInvocationLogs/*" }
              Condition = {
                StringEquals = { "aws:SourceAccount" = { Ref = "AWS::AccountId" } }
                ArnLike      = { "aws:SourceArn" = { "Fn::Sub" = "arn:aws:bedrock:$${AWS::Region}:$${AWS::AccountId}:*" } }
              }
            },
            {
              Sid       = "DenyNonHTTPSAccess"
              Effect    = "Deny"
              Principal = "*"
              Action    = "s3:*"
              Resource = [
                { "Fn::GetAtt" = ["BedrockLogBucket", "Arn"] },
                { "Fn::Sub" = "$${BedrockLogBucket.Arn}/*" },
              ]
              Condition = { Bool = { "aws:SecureTransport" = "false" } }
            },
          ]
        }
      }
    }

    BedrockLoggingFunctionLogGroup = {
      Type = "AWS::Logs::LogGroup"
      Properties = {
        LogGroupName    = "/aws/lambda/${local.bedrock_logs_function_name}"
        RetentionInDays = 30
      }
    }

    BedrockLoggingFunctionRole = {
      Type = "AWS::IAM::Role"
      Properties = {
        Description = "Configures Bedrock invocation logging for Spike"
        AssumeRolePolicyDocument = {
          Version = "2012-10-17"
          Statement = [{
            Effect    = "Allow"
            Principal = { Service = "lambda.amazonaws.com" }
            Action    = "sts:AssumeRole"
          }]
        }
        Policies = [{
          PolicyName = "BedrockInvocationLoggingConfigurator"
          PolicyDocument = {
            Version = "2012-10-17"
            Statement = [
              {
                Sid    = "ManageInvocationLogging"
                Effect = "Allow"
                Action = [
                  "bedrock:GetModelInvocationLoggingConfiguration",
                  "bedrock:PutModelInvocationLoggingConfiguration",
                  "bedrock:DeleteModelInvocationLoggingConfiguration",
                ]
                Resource = "*"
              },
              {
                Sid      = "InspectLogBucket"
                Effect   = "Allow"
                Action   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation", "s3:GetBucketPolicy"]
                Resource = { "Fn::GetAtt" = ["BedrockLogBucket", "Arn"] }
              },
              {
                Sid      = "EmptyLogBucketOnRemoval"
                Effect   = "Allow"
                Action   = ["s3:DeleteObject"]
                Resource = { "Fn::Sub" = "$${BedrockLogBucket.Arn}/*" }
              },
              {
                Sid      = "WriteFunctionLogs"
                Effect   = "Allow"
                Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
                Resource = { "Fn::GetAtt" = ["BedrockLoggingFunctionLogGroup", "Arn"] }
              },
              {
                Sid      = "PublishOnboardingEvent"
                Effect   = "Allow"
                Action   = "sns:Publish"
                Resource = var.notification_topic_arn
              },
            ]
          }
        }]
        Tags = local.bedrock_logs_template_tags
      }
    }

    BedrockLoggingFunction = {
      Type = "AWS::Lambda::Function"
      Properties = {
        FunctionName  = local.bedrock_logs_function_name
        Description   = "Configures Bedrock invocation logging for Spike"
        Runtime       = "python3.13"
        Handler       = "index.handler"
        Role          = { "Fn::GetAtt" = ["BedrockLoggingFunctionRole", "Arn"] }
        Timeout       = 900
        MemorySize    = 256
        Code          = { ZipFile = local.bedrock_logs_function_source }
        LoggingConfig = { LogGroup = { Ref = "BedrockLoggingFunctionLogGroup" } }
        Tags          = local.bedrock_logs_template_tags
      }
    }

    BedrockLogsReadPolicy = {
      Type = "AWS::IAM::RolePolicy"
      Properties = {
        RoleName   = local.role_name
        PolicyName = { "Fn::Sub" = "BedrockInvocationLogsRead-$${AWS::Region}" }
        PolicyDocument = {
          Version = "2012-10-17"
          Statement = [
            {
              Sid      = "DiscoverInvocationLogging"
              Effect   = "Allow"
              Action   = "bedrock:GetModelInvocationLoggingConfiguration"
              Resource = "*"
            },
            {
              Sid      = "ListInvocationLogs"
              Effect   = "Allow"
              Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
              Resource = { "Fn::GetAtt" = ["BedrockLogBucket", "Arn"] }
            },
            {
              Sid      = "ReadInvocationLogs"
              Effect   = "Allow"
              Action   = "s3:GetObject"
              Resource = { "Fn::Sub" = "$${BedrockLogBucket.Arn}/*" }
            },
            {
              Sid      = "DecryptInvocationLogs"
              Effect   = "Allow"
              Action   = ["kms:Decrypt", "kms:DescribeKey"]
              Resource = { "Fn::GetAtt" = ["BedrockLogKey", "Arn"] }
            },
          ]
        }
      }
    }

    BedrockInvocationLogging = {
      Type      = "Custom::BedrockInvocationLogging"
      DependsOn = ["BedrockLogBucketPolicy"]
      Properties = {
        ServiceToken         = { "Fn::GetAtt" = ["BedrockLoggingFunction", "Arn"] }
        BucketName           = { Ref = "BedrockLogBucket" }
        KeyPrefix            = local.bedrock_logs_key_prefix
        NotificationTopicArn = var.notification_topic_arn
        DirecteamId          = { Ref = "DirecteamId" }
        AccountId            = { Ref = "AWS::AccountId" }
        Region               = { Ref = "AWS::Region" }
        StackVersion         = "v${local.module_version}"
      }
    }
  }

  bedrock_logs_member_resources = merge(
    {
      for name, resource in local.bedrock_logs_member_resource_definitions :
      name => merge(resource, { Condition = "CreateBedrockInvocationLogs" })
    },
    {
      # Keeps stacks valid in regions where every other resource is skipped for that account.
      RegionPlaceholder = { Type = "AWS::CloudFormation::WaitConditionHandle" }
    },
  )

  bedrock_logs_member_outputs = {
    BedrockLogBucketName = {
      Condition   = "CreateBedrockInvocationLogs"
      Description = "Bucket receiving Bedrock invocation logs"
      Value       = { Ref = "BedrockLogBucket" }
    }
    BedrockLoggingStatus = {
      Condition   = "CreateBedrockInvocationLogs"
      Description = "enabled, or skipped-existing-configuration when the account already had invocation logging"
      Value       = { "Fn::GetAtt" = ["BedrockInvocationLogging", "Status"] }
    }
  }

  bedrock_member_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Directeam Bedrock invocation logging (terraform-aws-spike v${local.module_version})"
    Parameters = {
      DirecteamId = {
        Type      = "String"
        MinLength = 2
        MaxLength = 1224
      }
    }
    Mappings = {
      BedrockInvocationLogs = local.bedrock_logs_mapping
    }
    Conditions = local.bedrock_logs_member_conditions
    Resources  = local.bedrock_logs_member_resources
    Outputs    = local.bedrock_logs_member_outputs
  }
  bedrock_member_template_body = jsonencode(local.bedrock_member_template)
}

resource "aws_cloudformation_stack_set" "bedrock_logs" {
  count = local.member_bedrock_logs_enabled ? 1 : 0

  name             = local.bedrock_stack_set_name
  description      = "Deploys Directeam Bedrock invocation logging to selected member account regions"
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  call_as          = var.stackset_call_as
  template_body    = local.bedrock_member_template_body

  parameters = {
    DirecteamId = local.directeam_id
  }

  managed_execution {
    active = true
  }

  operation_preferences {
    max_concurrent_percentage    = var.stackset_max_concurrent_percentage
    failure_tolerance_percentage = var.stackset_failure_tolerance_percentage
    region_concurrency_type      = "PARALLEL"
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [administration_role_arn]

    precondition {
      condition     = length(local.bedrock_member_template_body) <= local.member_template_limit
      error_message = "The generated Bedrock member template is ${length(local.bedrock_member_template_body)} bytes, above the ${local.member_template_limit}-byte CloudFormation limit."
    }

    precondition {
      condition     = length(local.bedrock_logs_function_source) <= 4096
      error_message = "The Bedrock logging function is ${length(local.bedrock_logs_function_source)} characters, above the 4,096-character inline Lambda limit."
    }

    precondition {
      condition     = !local.has_account_filter || length(setsubtract(keys(local.member_bedrock_logs), var.member_account_ids)) == 0
      error_message = "bedrock_invocation_logs_accounts lists accounts that don't receive the Spike role: ${join(", ", setsubtract(keys(local.member_bedrock_logs), var.member_account_ids))}."
    }
  }

  depends_on = [aws_cloudformation_stack_set_instance.spike, terraform_data.spike_stack_update]
}

resource "aws_cloudformation_stack_instances" "bedrock_logs" {
  for_each = local.member_bedrock_logs_accounts_by_region

  stack_set_name = aws_cloudformation_stack_set.bedrock_logs[0].name
  regions        = [each.key]
  call_as        = var.stackset_call_as
  retain_stacks  = false

  deployment_targets {
    organizational_unit_ids = local.target_ou_ids
    accounts                = each.value
    account_filter_type     = "INTERSECTION"
  }

  operation_preferences {
    concurrency_mode             = "SOFT_FAILURE_TOLERANCE"
    max_concurrent_percentage    = var.stackset_max_concurrent_percentage
    failure_tolerance_percentage = var.stackset_failure_tolerance_percentage
    region_concurrency_type      = "PARALLEL"
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}
