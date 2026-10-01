mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_data "aws_organizations_organization" {
    defaults = {
      master_account_id = "111111111111"
      roots = [{
        arn          = "arn:aws:organizations::111111111111:root/o-abcdefghij/r-ab12"
        id           = "r-ab12"
        name         = "Root"
        policy_types = []
      }]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/DirecteamFinOpsReadOnlyAccess"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::111111111111:policy/DirecteamFinOpsReadOnlyAccess-mock"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::dt-bedrock-invocation-logs-mock"
    }
  }
}

mock_provider "external" {}

variables {
  external_id          = "spike-test-external-id"
  directeam_id         = "directeam-test-id"
  base_onboarding_mode = "create"
}

run "disabled_by_default" {
  command = plan

  variables {
    deployment_mode = "organization"
  }

  assert {
    condition     = length(aws_s3_bucket.bedrock_logs) == 0 && length(aws_iam_role_policy.bedrock_logs_read) == 0 && length(aws_cloudformation_stack_instances.bedrock_logs) == 0
    error_message = "Bedrock invocation logging must be opt-in."
  }

  assert {
    condition     = !strcontains(local.member_template_body, "Bedrock") && !contains(keys(local.member_template), "Mappings")
    error_message = "The Spike template must not contain Bedrock resources unless the feature is enabled."
  }
}

run "accounts_listed_but_feature_off" {
  command = plan

  variables {
    deployment_mode                  = "organization"
    enable_bedrock_invocation_logs   = false
    bedrock_invocation_logs_accounts = { "111111111111" = ["us-east-1"], "222222222222" = ["us-west-2"] }
  }

  assert {
    condition     = length(aws_s3_bucket.bedrock_logs) == 0 && length(aws_cloudformation_stack_instances.bedrock_logs) == 0 && !strcontains(local.member_template_body, "Bedrock")
    error_message = "enable_bedrock_invocation_logs = false must disable the feature even when accounts are listed."
  }
}

run "single_account" {
  command = plan

  variables {
    deployment_mode                = "account"
    enable_bedrock_invocation_logs = true
    bedrock_invocation_logs_accounts = {
      "111111111111" = ["us-east-1", "eu-west-1"]
      "999999999999" = ["us-west-2"]
    }
    bedrock_invocation_logs_retention_days = 14
  }

  assert {
    condition     = toset(keys(aws_s3_bucket.bedrock_logs)) == toset(["us-east-1", "eu-west-1"])
    error_message = "Only the current account's regions must get a log bucket; other accounts' entries are ignored."
  }

  assert {
    condition     = aws_s3_bucket.bedrock_logs["eu-west-1"].bucket == "dt-bedrock-invocation-logs-111111111111-eu-west-1" && aws_s3_bucket.bedrock_logs["eu-west-1"].region == "eu-west-1"
    error_message = "Each bucket must be named after and created in its region."
  }

  assert {
    condition     = aws_bedrock_model_invocation_logging_configuration.spike["eu-west-1"].region == "eu-west-1"
    error_message = "Invocation logging must be configured in each listed region."
  }

  assert {
    condition = alltrue([
      for config in aws_bedrock_model_invocation_logging_configuration.spike : (
        !config.logging_config[0].text_data_delivery_enabled &&
        !config.logging_config[0].image_data_delivery_enabled &&
        !config.logging_config[0].embedding_data_delivery_enabled &&
        !config.logging_config[0].video_data_delivery_enabled
      )
    ])
    error_message = "Only invocation metadata may be delivered; prompts, responses and embeddings must stay off."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.bedrock_logs["us-east-1"].rule[0].expiration[0].days == 14
    error_message = "Log retention must follow bedrock_invocation_logs_retention_days."
  }

  assert {
    condition     = aws_kms_key.bedrock_logs["us-east-1"].enable_key_rotation && aws_s3_bucket_versioning.bedrock_logs["us-east-1"].versioning_configuration[0].status == "Enabled" && one(one(aws_s3_bucket_server_side_encryption_configuration.bedrock_logs["us-east-1"].rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "Bedrock log buckets must use rotating customer-managed KMS keys and versioning."
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy.bedrock_logs_read)) == toset(["us-east-1", "eu-west-1"]) && aws_iam_role_policy.bedrock_logs_read["eu-west-1"].name == "BedrockInvocationLogsRead-eu-west-1"
    error_message = "The Spike role must get one read policy per log bucket."
  }

  assert {
    condition     = length(aws_cloudformation_stack_set.spike) == 0 && length(aws_cloudformation_stack_instances.bedrock_logs) == 0
    error_message = "Account mode must not use a StackSet."
  }

  assert {
    condition     = jsonencode(output.bedrock_invocation_logs_accounts) == jsonencode({ "111111111111" = ["eu-west-1", "us-east-1"] })
    error_message = "Only the current account must be reported as deployed."
  }
}

run "account_not_listed" {
  command = plan

  variables {
    deployment_mode                  = "account"
    enable_bedrock_invocation_logs   = true
    bedrock_invocation_logs_accounts = { "999999999999" = ["us-east-1"] }
  }

  assert {
    condition     = length(aws_s3_bucket.bedrock_logs) == 0 && length(aws_iam_role_policy.bedrock_logs_read) == 0
    error_message = "Accounts that aren't listed must not get Bedrock invocation logging."
  }
}

run "organization" {
  command = plan

  variables {
    deployment_mode                = "organization"
    enable_bedrock_invocation_logs = true
    bedrock_invocation_logs_accounts = {
      "111111111111" = ["us-east-1"]
      "222222222222" = ["us-east-1", "us-west-2"]
      "333333333333" = ["eu-west-1"]
    }
  }

  assert {
    condition     = keys(aws_s3_bucket.bedrock_logs) == ["us-east-1"]
    error_message = "The management account must only get buckets for its own listed regions."
  }

  assert {
    condition     = length(aws_cloudformation_stack_set.spike) == 1 && length(aws_cloudformation_stack_set.bedrock_logs) == 1 && !strcontains(local.member_template_body, "BedrockInvocationLogging") && strcontains(local.bedrock_member_template_body, "BedrockInvocationLogging")
    error_message = "Bedrock invocation logs must use a separate StackSet from the read-only role."
  }

  assert {
    condition     = local.bedrock_member_template.Resources.BedrockLogKey.Type == "AWS::KMS::Key" && local.bedrock_member_template.Resources.BedrockLogBucket.Properties.VersioningConfiguration.Status == "Enabled" && local.bedrock_member_template.Resources.BedrockLogBucket.Properties.BucketEncryption.ServerSideEncryptionConfiguration[0].ServerSideEncryptionByDefault.SSEAlgorithm == "aws:kms"
    error_message = "Member-account Bedrock buckets must use customer-managed KMS encryption and versioning."
  }

  assert {
    condition = jsonencode(local.bedrock_member_template.Mappings.BedrockInvocationLogs) == jsonencode({
      "eu-west-1" = { "333333333333" = "1" }
      "us-east-1" = { "222222222222" = "1" }
      "us-west-2" = { "222222222222" = "1" }
    })
    error_message = "The template mapping must list exactly the member account/region pairs, without the management account."
  }

  assert {
    condition     = toset(keys(aws_cloudformation_stack_instances.bedrock_logs)) == toset(["us-east-1", "us-west-2", "eu-west-1"])
    error_message = "The Bedrock-only StackSet must target every enabled member-account region."
  }

  assert {
    condition     = aws_cloudformation_stack_instances.bedrock_logs["eu-west-1"].deployment_targets[0].accounts == toset(["333333333333"]) && aws_cloudformation_stack_instances.bedrock_logs["eu-west-1"].deployment_targets[0].account_filter_type == "INTERSECTION"
    error_message = "Extra regions must only target the accounts that use them."
  }

  assert {
    condition     = aws_cloudformation_stack_instances.bedrock_logs["us-west-2"].stack_set_name == aws_cloudformation_stack_set.bedrock_logs[0].name
    error_message = "Enabled regions must be instances of the Bedrock-only StackSet."
  }

  assert {
    condition = alltrue([
      for name in concat(["SpikeRole"], [for policy in keys(local.member_role_policies) : "${policy}Policy"]) :
      local.member_template.Resources[name].Condition == "IsHomeRegion"
    ])
    error_message = "The global role and its policies must only be created by the home-region stacks."
  }

  assert {
    condition = alltrue([
      for name, resource in local.bedrock_member_template.Resources :
      resource.Condition == "CreateBedrockInvocationLogs" if startswith(name, "Bedrock")
    ])
    error_message = "Every Bedrock resource must be conditional on the account/region mapping."
  }

  assert {
    condition     = aws_cloudformation_stack_set.bedrock_logs[0].template_body == local.bedrock_member_template_body && length(local.bedrock_member_template_body) <= 51200
    error_message = "The Bedrock template must be sent inline and fit the CloudFormation limit."
  }

  assert {
    condition     = length(local.bedrock_logs_function_source) <= 4096
    error_message = "The Bedrock logging function must fit CloudFormation's inline code limit."
  }

  assert {
    condition = jsonencode(output.bedrock_invocation_logs_accounts) == jsonencode({
      "111111111111" = ["us-east-1"]
      "222222222222" = ["us-east-1", "us-west-2"]
      "333333333333" = ["eu-west-1"]
    })
    error_message = "Every deployed account/region pair must be reported to Spike."
  }
}

run "organization_many_accounts_fit_inline" {
  command = plan

  variables {
    deployment_mode                = "organization"
    enable_eks_read_access         = true
    enable_log_management          = true
    enable_bedrock_invocation_logs = true
    bedrock_invocation_logs_accounts = {
      for i in range(40) : format("2%011d", i) => ["us-east-1", "us-west-2", "eu-west-1"]
    }
  }

  assert {
    condition     = length(local.bedrock_member_template_body) <= 51200 && aws_cloudformation_stack_set.bedrock_logs[0].template_body == local.bedrock_member_template_body
    error_message = "120 Bedrock account/region pairs must fit the inline template limit."
  }
}

run "organization_too_many_bedrock_pairs_fails" {
  command = plan

  variables {
    deployment_mode                = "organization"
    enable_eks_read_access         = true
    enable_log_management          = true
    enable_bedrock_invocation_logs = true
    bedrock_invocation_logs_accounts = {
      for i in range(1000) : format("2%011d", i) => ["us-east-1", "us-west-2", "eu-west-1"]
    }
  }

  expect_failures = [aws_cloudformation_stack_set.bedrock_logs]
}

run "account_outside_selected_members" {
  command = plan

  variables {
    deployment_mode                = "organization"
    member_account_ids             = ["222222222222"]
    enable_bedrock_invocation_logs = true
    bedrock_invocation_logs_accounts = {
      "222222222222" = ["us-east-1"]
      "333333333333" = ["us-east-1"]
    }
  }

  expect_failures = [aws_cloudformation_stack_set.bedrock_logs]
}

run "delegated_admin" {
  command = plan

  variables {
    deployment_mode                  = "organization"
    stackset_call_as                 = "DELEGATED_ADMIN"
    organizational_unit_ids          = ["r-ab12"]
    enable_bedrock_invocation_logs   = true
    bedrock_invocation_logs_accounts = { "111111111111" = ["us-east-1", "us-west-2"] }
  }

  override_data {
    target = data.aws_organizations_organization.current[0]
    values = {
      master_account_id = "999999999999"
    }
  }

  assert {
    condition     = length(aws_s3_bucket.bedrock_logs) == 0
    error_message = "A delegated administrator must not create Bedrock logging directly."
  }

  assert {
    condition     = jsonencode(local.bedrock_member_template.Mappings.BedrockInvocationLogs) == jsonencode({ "us-east-1" = { "111111111111" = "1" }, "us-west-2" = { "111111111111" = "1" } })
    error_message = "The delegated administrator account must get Bedrock logging through the StackSet."
  }

  assert {
    condition     = aws_cloudformation_stack_instances.bedrock_logs["us-west-2"].call_as == "DELEGATED_ADMIN"
    error_message = "Extra-region instances must be created as a delegated administrator."
  }
}

run "invalid_account_id" {
  command = plan

  variables {
    deployment_mode                  = "account"
    bedrock_invocation_logs_accounts = { "1234" = ["us-east-1"] }
  }

  expect_failures = [var.bedrock_invocation_logs_accounts]
}

run "invalid_region" {
  command = plan

  variables {
    deployment_mode                  = "account"
    bedrock_invocation_logs_accounts = { "111111111111" = ["useast1"] }
  }

  expect_failures = [var.bedrock_invocation_logs_accounts]
}

run "empty_region_list" {
  command = plan

  variables {
    deployment_mode                  = "account"
    bedrock_invocation_logs_accounts = { "111111111111" = [] }
  }

  expect_failures = [var.bedrock_invocation_logs_accounts]
}

run "discovery_single_account" {
  command = plan

  variables {
    deployment_mode                = "account"
    enable_bedrock_invocation_logs = true
  }

  override_data {
    target = data.external.bedrock_usage[0]
    values = {
      result = {
        accounts = "{\"111111111111\":[\"eu-west-1\",\"us-east-1\"],\"222222222222\":[\"us-west-2\"]}"
        services = "Amazon Bedrock"
        period   = "2026-07-01/2026-09-29"
      }
    }
  }

  assert {
    condition     = toset(keys(aws_s3_bucket.bedrock_logs)) == toset(["us-east-1", "eu-west-1"])
    error_message = "Discovered regions of the current account must get a log bucket; other accounts are ignored in account mode."
  }

  assert {
    condition     = jsonencode(output.bedrock_invocation_logs_accounts) == jsonencode({ "111111111111" = ["eu-west-1", "us-east-1"] })
    error_message = "Only the current account's discovered regions must be registered."
  }
}

run "discovery_organization" {
  command = plan

  variables {
    deployment_mode                = "organization"
    enable_bedrock_invocation_logs = true
  }

  override_data {
    target = data.external.bedrock_usage[0]
    values = {
      result = {
        accounts = "{\"111111111111\":[\"us-east-1\"],\"222222222222\":[\"us-east-1\",\"us-west-2\"],\"333333333333\":[\"eu-west-1\"]}"
        services = "Amazon Bedrock"
        period   = "2026-07-01/2026-09-29"
      }
    }
  }

  assert {
    condition = jsonencode(output.bedrock_invocation_logs_accounts) == jsonencode({
      "111111111111" = ["us-east-1"]
      "222222222222" = ["us-east-1", "us-west-2"]
      "333333333333" = ["eu-west-1"]
    })
    error_message = "All discovered accounts must be registered in organization mode."
  }

  assert {
    condition     = toset(keys(aws_cloudformation_stack_instances.bedrock_logs)) == toset(["us-east-1", "us-west-2", "eu-west-1"])
    error_message = "Every discovered member-account region needs a Bedrock-only StackSet instance."
  }
}

run "discovery_organization_selected_accounts" {
  command = plan

  variables {
    deployment_mode                = "organization"
    member_account_ids             = ["222222222222"]
    enable_bedrock_invocation_logs = true
  }

  override_data {
    target = data.external.bedrock_usage[0]
    values = {
      result = {
        accounts = "{\"222222222222\":[\"us-east-1\"],\"333333333333\":[\"eu-west-1\"]}"
        services = "Amazon Bedrock"
        period   = "2026-07-01/2026-09-29"
      }
    }
  }

  assert {
    condition     = jsonencode(output.bedrock_invocation_logs_accounts) == jsonencode({ "222222222222" = ["us-east-1"] })
    error_message = "Discovered accounts outside member_account_ids must be ignored."
  }
}

run "discovery_nothing_found" {
  command = plan

  variables {
    deployment_mode                = "account"
    enable_bedrock_invocation_logs = true
  }

  override_data {
    target = data.external.bedrock_usage[0]
    values = {
      result = {
        accounts = "{}"
        services = ""
        period   = "2026-07-01/2026-09-29"
      }
    }
  }

  assert {
    condition     = length(aws_s3_bucket.bedrock_logs) == 0 && length(aws_bedrock_model_invocation_logging_configuration.spike) == 0
    error_message = "Nothing must be deployed when Bedrock isn't used."
  }

  # The module warns that nothing was found.
  expect_failures = [check.bedrock_invocation_logs_accounts_listed]
}

run "explicit_map_skips_discovery" {
  command = plan

  variables {
    deployment_mode                  = "account"
    enable_bedrock_invocation_logs   = true
    bedrock_invocation_logs_accounts = { "111111111111" = ["us-east-1"] }
  }

  assert {
    condition     = length(data.external.bedrock_usage) == 0
    error_message = "An explicit account map must skip Cost Explorer discovery."
  }
}

run "discovery_not_supported_for_delegated_admin" {
  command = plan

  variables {
    deployment_mode                = "organization"
    stackset_call_as               = "DELEGATED_ADMIN"
    enable_bedrock_invocation_logs = true
  }

  override_data {
    target = data.external.bedrock_usage[0]
    values = {
      result = {
        accounts = "{}"
        services = ""
        period   = "2026-07-01/2026-09-29"
      }
    }
  }

  expect_failures = [data.external.bedrock_usage]
}

run "invalid_lookback_days" {
  command = plan

  variables {
    deployment_mode                       = "account"
    bedrock_invocation_logs_lookback_days = 2
  }

  expect_failures = [var.bedrock_invocation_logs_lookback_days]
}
