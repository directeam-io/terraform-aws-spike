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
      arn = "arn:aws:iam::111111111111:role/DirecteamSpikeReadOnlyAccess"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::111111111111:policy/DirecteamSpikeReadOnlyAccess-mock"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::dt-cur-111111111111"
    }
  }
}

variables {
  external_id  = "spike-test-external-id"
  directeam_id = "directeam-test-id"
}

run "organization_whole_org" {
  command = plan

  variables {
    deployment_mode = "organization"
  }

  assert {
    condition     = aws_iam_role.spike[0].name == "DirecteamSpikeReadOnlyAccess"
    error_message = "The Spike role must be created in the management account."
  }

  assert {
    condition     = toset(keys(aws_iam_policy.spike)) == toset(["ReadOnly1", "ReadOnly2", "ReadOnly3", "ReadOnly4", "ReadOnly5", "ReadOnly6", "ReadOnly7", "CloudWatchLogsReadOnly"])
    error_message = "The management role must get the full read-only policy set plus CloudWatch Logs read access by default."
  }

  assert {
    condition     = aws_cloudformation_stack_set_instance.spike[0].deployment_targets[0].organizational_unit_ids == toset(["r-ab12"])
    error_message = "The StackSet must target the discovered organization root."
  }

  assert {
    condition     = aws_cloudformation_stack_set_instance.spike[0].deployment_targets[0].account_filter_type == null
    error_message = "No account filter must be applied when member_account_ids is empty."
  }

  assert {
    condition     = aws_cloudformation_stack_set_instance.spike[0].stack_set_instance_region == "us-east-1"
    error_message = "Member stacks must be deployed to us-east-1."
  }

  assert {
    condition     = aws_cloudformation_stack_set.spike[0].auto_deployment[0].enabled == true
    error_message = "Auto-deployment must be enabled by default when deploying to whole OUs."
  }

  assert {
    condition     = length(aws_bcmdataexports_export.cur) == 1 && aws_s3_bucket.cur[0].bucket == "dt-cur-111111111111"
    error_message = "The CUR 2.0 export must be created in organization mode."
  }

  assert {
    condition     = length(aws_cloudformation_stack.registration) == 1
    error_message = "Spike must be notified by default."
  }

  assert {
    condition     = length(local.member_template_body) <= 51200
    error_message = "The member account template must fit the CloudFormation inline template limit."
  }

  assert {
    condition = alltrue([
      for resource in values(local.member_template.Resources) :
      startswith(resource.Properties.ManagedPolicyName, "DirecteamSpikeReadOnlyAccess-")
      if resource.Type == "AWS::IAM::ManagedPolicy"
    ])
    error_message = "Every member account policy must be named after the Spike role."
  }
}

run "organization_selected_accounts" {
  command = plan

  variables {
    deployment_mode    = "organization"
    member_account_ids = ["222222222222", "333333333333"]
  }

  assert {
    condition     = aws_cloudformation_stack_set_instance.spike[0].deployment_targets[0].account_filter_type == "INTERSECTION"
    error_message = "Selected accounts must be deployed with an INTERSECTION filter."
  }

  assert {
    condition     = aws_cloudformation_stack_set_instance.spike[0].deployment_targets[0].accounts == toset(["222222222222", "333333333333"])
    error_message = "Only the selected accounts must be targeted."
  }

  assert {
    condition     = aws_cloudformation_stack_set.spike[0].auto_deployment[0].enabled == false
    error_message = "Auto-deployment must be off when specific accounts are selected, otherwise new accounts would receive the role."
  }
}

run "organization_specific_ous" {
  command = plan

  variables {
    deployment_mode         = "organization"
    organizational_unit_ids = ["ou-ab12-11111111", "ou-ab12-22222222"]
    auto_deployment         = false
  }

  assert {
    condition     = aws_cloudformation_stack_set_instance.spike[0].deployment_targets[0].organizational_unit_ids == toset(["ou-ab12-11111111", "ou-ab12-22222222"])
    error_message = "The StackSet must target the given OUs."
  }

  assert {
    condition     = aws_cloudformation_stack_set.spike[0].auto_deployment[0].enabled == false
    error_message = "auto_deployment = false must be honored."
  }
}

run "organization_limited_management_access" {
  command = plan

  variables {
    deployment_mode   = "organization"
    role_access_level = "limited"
  }

  assert {
    condition     = keys(aws_iam_policy.spike) == ["ManagementReadOnly"]
    error_message = "The limited role must only get the management read-only policy."
  }

  assert {
    condition     = strcontains(local.member_template_body, "DirecteamSpikeReadOnlyAccess-ReadOnly1")
    error_message = "Member accounts must still receive the full read-only policy set."
  }
}

run "organization_optional_policies" {
  command = plan

  variables {
    deployment_mode                    = "organization"
    enable_cloudwatch_logs_read_access = false
    enable_eks_read_access             = true
    enable_log_management              = true
  }

  assert {
    condition     = toset(keys(aws_iam_policy.spike)) == toset(["ReadOnly1", "ReadOnly2", "ReadOnly3", "ReadOnly4", "ReadOnly5", "ReadOnly6", "ReadOnly7", "EksReadOnly", "LogManagement"])
    error_message = "Optional policies must follow the enable_* flags."
  }

  assert {
    condition     = strcontains(aws_iam_policy.spike["LogManagement"].policy, "arn:aws:s3:::dt-logs-111111111111")
    error_message = "The local log management policy must be scoped to this account's log bucket."
  }

  assert {
    condition     = strcontains(local.member_template_body, "arn:aws:s3:::dt-logs-$${AWS::AccountId}")
    error_message = "The member log management policy must resolve the account ID in each member account."
  }

  assert {
    condition     = length(local.member_template_body) <= 51200
    error_message = "The member account template with every optional policy must fit the CloudFormation inline template limit."
  }
}

run "organization_delegated_admin" {
  command = plan

  variables {
    deployment_mode         = "organization"
    stackset_call_as        = "DELEGATED_ADMIN"
    organizational_unit_ids = ["r-ab12"]
  }

  assert {
    condition     = length(aws_iam_role.spike) == 0 && length(aws_bcmdataexports_export.cur) == 0
    error_message = "A delegated administrator must only deploy the StackSet: the management account owns the CUR export."
  }

  assert {
    condition     = aws_cloudformation_stack_set.spike[0].call_as == "DELEGATED_ADMIN"
    error_message = "The StackSet must be created as a delegated administrator."
  }
}

run "organization_ignores_disabling_cur_export" {
  command = plan

  variables {
    deployment_mode   = "organization"
    enable_cur_export = false
  }

  assert {
    condition     = length(aws_bcmdataexports_export.cur) == 1
    error_message = "The management account must always create the CUR export in organization mode."
  }

  expect_failures = [check.cur_export_setting_ignored_in_organization_mode]
}

run "organization_from_member_account_fails" {
  command = plan

  variables {
    deployment_mode = "organization"
  }

  override_data {
    target = data.aws_organizations_organization.current[0]
    values = {
      master_account_id = "999999999999"
      roots             = []
    }
  }

  expect_failures = [aws_cloudformation_stack_set.spike]
}

run "single_account" {
  command = plan

  variables {
    deployment_mode = "account"
  }

  assert {
    condition     = length(aws_iam_role.spike) == 1
    error_message = "The Spike role must be created in the current account."
  }

  assert {
    condition     = length(aws_cloudformation_stack_set.spike) == 0 && length(aws_cloudformation_stack_set_instance.spike) == 0
    error_message = "No StackSet must be deployed in account mode."
  }

  assert {
    condition     = length(aws_bcmdataexports_export.cur) == 0
    error_message = "A linked account must not create a CUR export by default; the management account's export covers every account."
  }
}

run "single_account_with_cur_and_no_notification" {
  command = plan

  variables {
    deployment_mode   = "account"
    enable_cur_export = true
    notify_spike      = false
  }

  assert {
    condition     = length(aws_bcmdataexports_export.cur) == 1
    error_message = "enable_cur_export = true must create the export in account mode (management account or standalone account)."
  }

  assert {
    condition     = length(aws_cloudformation_stack.registration) == 0
    error_message = "notify_spike = false must skip the registration stack."
  }
}

run "invalid_deployment_mode" {
  command = plan

  variables {
    deployment_mode = "org"
  }

  expect_failures = [var.deployment_mode]
}

run "invalid_member_account_id" {
  command = plan

  variables {
    deployment_mode    = "organization"
    member_account_ids = ["1234"]
  }

  expect_failures = [var.member_account_ids]
}
