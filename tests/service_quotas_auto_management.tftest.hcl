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

  mock_data "aws_regions" {
    defaults = {
      names = ["us-east-1", "eu-west-1", "ap-southeast-3"]
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
    condition     = length(aws_servicequotas_auto_management.spike) == 0 && length(aws_cloudformation_stack_set.service_quotas) == 0 && length(aws_cloudformation_stack_instances.service_quotas) == 0 && length(aws_cloudformation_stack.service_quotas_registration) == 0
    error_message = "Service Quotas Automatic Management must be opt-in."
  }
}

run "single_account" {
  command = plan

  variables {
    deployment_mode                               = "account"
    enable_service_quotas_auto_management         = true
    service_quotas_auto_management_regions        = ["us-east-1", "eu-west-2"]
    service_quotas_auto_management_opt_in_type    = "NotifyAndAdjust"
    service_quotas_auto_management_exclusion_list = { dynamodb = ["L-F98FE922"] }
  }

  assert {
    condition     = toset(keys(aws_servicequotas_auto_management.spike)) == toset(["us-east-1", "eu-west-2"])
    error_message = "One auto-management opt-in must be created per configured region."
  }

  assert {
    condition     = aws_servicequotas_auto_management.spike["eu-west-2"].opt_in_type == "NotifyAndAdjust" && aws_servicequotas_auto_management.spike["eu-west-2"].opt_in_level == "ACCOUNT" && aws_servicequotas_auto_management.spike["eu-west-2"].region == "eu-west-2"
    error_message = "Each opt-in must be an ACCOUNT-level opt-in of the configured type in its region."
  }

  assert {
    condition     = length(aws_cloudformation_stack_set.service_quotas) == 0 && length(aws_cloudformation_stack_instances.service_quotas) == 0
    error_message = "Account mode must not use a StackSet."
  }

  assert {
    condition     = length(aws_cloudformation_stack.service_quotas_registration) == 1 && toset(keys(local.service_quotas_registration_resources)) == toset(["ServiceQuotasUsEast1", "ServiceQuotasEuWest2"])
    error_message = "Each local region must be registered with Spike."
  }
}

run "organization" {
  command = plan

  variables {
    deployment_mode                        = "organization"
    enable_service_quotas_auto_management  = true
    service_quotas_auto_management_regions = ["us-east-1", "us-west-2"]
  }

  assert {
    condition     = length(aws_servicequotas_auto_management.spike) == 2 && length(aws_cloudformation_stack_set.service_quotas) == 1 && toset(keys(aws_cloudformation_stack_instances.service_quotas)) == toset(["us-east-1", "us-west-2"])
    error_message = "The management account must be configured directly and members must be deployed per region."
  }

  assert {
    condition     = local.service_quotas_member_template.Resources.ServiceQuotasFunction.Properties.Runtime == "python3.13" && local.service_quotas_member_template.Resources.ServiceQuotasAutoManagement.Properties.ServiceToken == { "Fn::GetAtt" = ["ServiceQuotasFunction", "Arn"] }
    error_message = "Member accounts must configure auto management through the Lambda-backed custom resource."
  }

  assert {
    condition     = contains(local.service_quotas_member_template.Resources.ServiceQuotasFunctionRole.Properties.Policies[0].PolicyDocument.Statement[0].Action, "servicequotas:StartAutoManagement") && local.service_quotas_member_template.Resources.ServiceQuotasFunctionRole.Properties.Policies[0].PolicyDocument.Statement[1].Resource == "arn:aws:sns:us-east-1:250260913666:directeam-onboarding-topic-f7a69a4b"
    error_message = "The member function must manage auto management and publish registration events to the onboarding topic."
  }

  assert {
    condition     = length(local.service_quotas_member_template_body) <= 51200 && length(local.service_quotas_function_source) <= 4096
    error_message = "The member template and inline function source must stay within CloudFormation inline limits."
  }
}

run "existing_onboarding_organization" {
  command = plan

  variables {
    deployment_mode                        = "organization"
    base_onboarding_mode                   = "existing"
    member_account_ids                     = ["222222222222"]
    enable_service_quotas_auto_management  = true
    service_quotas_auto_management_regions = ["us-east-1"]
  }

  override_data {
    target = data.external.existing_onboarding[0]
    values = {
      result = {
        exists       = "true"
        stack_name   = "DirecteamFinOpsStackSet"
        stack_status = "CREATE_COMPLETE"
      }
    }
  }

  assert {
    condition     = length(aws_cloudformation_stack_set.spike) == 0 && length(aws_cloudformation_stack.registration) == 0
    error_message = "Existing organization onboarding and registration must remain CloudFormation-owned."
  }

  assert {
    condition     = length(aws_servicequotas_auto_management.spike) == 1 && length(aws_cloudformation_stack_set.service_quotas) == 1 && length(aws_cloudformation_stack_instances.service_quotas) == 1
    error_message = "The Service Quotas StackSet must still be deployed for existing organizations."
  }
}

run "default_regions" {
  command = plan

  variables {
    deployment_mode                       = "organization"
    enable_service_quotas_auto_management = true
  }

  # The current account has opted in to ap-southeast-3; members only get the
  # regions that need no opt-in.
  override_data {
    target = data.aws_regions.service_quotas_members[0]
    values = {
      names = ["us-east-1", "eu-west-1"]
    }
  }

  assert {
    condition     = toset(keys(aws_servicequotas_auto_management.spike)) == toset(["us-east-1", "eu-west-1", "ap-southeast-3"])
    error_message = "With no region list, the current account must use every enabled region."
  }

  assert {
    condition     = toset(keys(aws_cloudformation_stack_instances.service_quotas)) == toset(["us-east-1", "eu-west-1"])
    error_message = "With no region list, member accounts must use only the regions that need no opt-in."
  }

  assert {
    condition     = length(local.service_quotas_registration_resources) == length(local.local_service_quotas_regions) && length(jsonencode(local.service_quotas_registration_resources)) < 51200
    error_message = "The registration template must have one resource per local region and stay within the CloudFormation inline limit."
  }
}

run "explicit_regions_override_both" {
  command = plan

  variables {
    deployment_mode                        = "organization"
    enable_service_quotas_auto_management  = true
    service_quotas_auto_management_regions = ["us-west-2", "af-south-1"]
  }

  assert {
    condition     = toset(keys(aws_servicequotas_auto_management.spike)) == toset(["us-west-2", "af-south-1"]) && toset(keys(aws_cloudformation_stack_instances.service_quotas)) == toset(["us-west-2", "af-south-1"])
    error_message = "An explicit region list must apply to the current account and to member accounts."
  }

  assert {
    condition     = length(data.aws_regions.service_quotas_current) == 0 && length(data.aws_regions.service_quotas_members) == 0
    error_message = "No region lookup is needed when the regions are set."
  }
}

run "empty_regions_rejected" {
  command = plan

  variables {
    deployment_mode                        = "account"
    enable_service_quotas_auto_management  = true
    service_quotas_auto_management_regions = []
  }

  expect_failures = [var.service_quotas_auto_management_regions]
}

run "duplicate_regions_rejected" {
  command = plan

  variables {
    deployment_mode                        = "account"
    enable_service_quotas_auto_management  = true
    service_quotas_auto_management_regions = ["us-east-1", "us-east-1"]
  }

  expect_failures = [var.service_quotas_auto_management_regions]
}
