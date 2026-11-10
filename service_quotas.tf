################################################################################
# Service Quotas Automatic Management
#
# Current account: configured natively per region through
# aws_servicequotas_auto_management (provider >= 6.40.0). Covers
# deployment_mode = "account" and the management account in organization
# mode; a delegated administrator is itself a member account and receives
# the feature through the StackSet below.
#
# Member accounts (organization mode): CloudFormation has no native resource
# for auto management, so a service-managed StackSet deploys a member
# template with a Lambda-backed custom resource that calls the
# servicequotas Start/Update/Stop AutoManagement APIs. StackSets never deploy
# to the management account, which is handled directly by this module.
#
# Regions: by default every region enabled in the current account, and every
# region that needs no opt-in in member accounts (a StackSet cannot see which
# opt-in regions each member enabled). A list in
# service_quotas_auto_management_regions overrides both. A member region that
# is already on is left untouched; a current-account region that is already on
# must be imported (the native resource cannot start it twice).
################################################################################

locals {
  service_quotas_function_name   = "DirecteamFinOpsServiceQuotasAutoManagement"
  service_quotas_function_source = file("${path.module}/functions/service_quotas_auto_management.py")
  service_quotas_template_tags   = [for key in sort(keys(local.tags)) : { Key = key, Value = local.tags[key] }]

  configure_local_service_quotas = var.enable_service_quotas_auto_management && !local.is_delegated_admin
  # Independent of deploy_stack_set (existing CloudFormation onboarding):
  # like the Bedrock member StackSet, the feature deploys to linked accounts
  # even when the base onboarding is CloudFormation-owned. The management
  # account itself is always configured directly by this module.
  deploy_service_quotas_stackset = var.enable_service_quotas_auto_management && local.is_organization

  local_service_quotas_regions = local.configure_local_service_quotas ? sort(
    var.service_quotas_auto_management_regions != null ? var.service_quotas_auto_management_regions : tolist(data.aws_regions.service_quotas_current[0].names)
  ) : []
  member_service_quotas_regions = local.deploy_service_quotas_stackset ? sort(
    var.service_quotas_auto_management_regions != null ? var.service_quotas_auto_management_regions : tolist(data.aws_regions.service_quotas_members[0].names)
  ) : []
}

# Regions enabled in the current account.
data "aws_regions" "service_quotas_current" {
  count = local.configure_local_service_quotas && var.service_quotas_auto_management_regions == null ? 1 : 0
}

# Regions that member accounts have without opting in.
data "aws_regions" "service_quotas_members" {
  count = local.deploy_service_quotas_stackset && var.service_quotas_auto_management_regions == null ? 1 : 0

  all_regions = true

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_servicequotas_auto_management" "spike" {
  for_each = local.configure_local_service_quotas ? toset(local.local_service_quotas_regions) : toset([])

  region         = each.key
  opt_in_level   = "ACCOUNT"
  opt_in_type    = var.service_quotas_auto_management_opt_in_type
  exclusion_list = length(var.service_quotas_auto_management_exclusion_list) > 0 ? var.service_quotas_auto_management_exclusion_list : null

  depends_on = [terraform_data.spike_stack_update]
}

locals {
  service_quotas_member_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Directeam Service Quotas Automatic Management (terraform-aws-spike v${local.module_version})"

    Parameters = {
      DirecteamId = {
        Type      = "String"
        MinLength = 2
        MaxLength = 1224
      }
      OptInType = {
        Type          = "String"
        AllowedValues = ["NotifyOnly", "NotifyAndAdjust"]
      }
      ExclusionList = {
        Type    = "String"
        Default = "{}"
      }
    }

    Resources = {
      ServiceQuotasLogGroup = {
        Type = "AWS::Logs::LogGroup"
        Properties = {
          LogGroupName    = "/aws/lambda/${local.service_quotas_function_name}"
          RetentionInDays = 30
        }
      }

      ServiceQuotasFunctionRole = {
        Type = "AWS::IAM::Role"
        Properties = {
          Description = "Configures Service Quotas Automatic Management for Spike"
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { Service = "lambda.amazonaws.com" }
              Action    = "sts:AssumeRole"
            }]
          }
          Policies = [{
            PolicyName = "ServiceQuotasAutoManagementConfigurator"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [
                {
                  Sid    = "ManageAutoManagement"
                  Effect = "Allow"
                  Action = [
                    "servicequotas:GetAutoManagementConfiguration",
                    "servicequotas:StartAutoManagement",
                    "servicequotas:UpdateAutoManagement",
                    "servicequotas:StopAutoManagement",
                  ]
                  Resource = "*"
                },
                {
                  Sid      = "PublishOnboardingEvent"
                  Effect   = "Allow"
                  Action   = "sns:Publish"
                  Resource = var.notification_topic_arn
                },
                {
                  Sid      = "WriteFunctionLogs"
                  Effect   = "Allow"
                  Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
                  Resource = { "Fn::GetAtt" = ["ServiceQuotasLogGroup", "Arn"] }
                },
              ]
            }
          }]
          Tags = local.service_quotas_template_tags
        }
      }

      ServiceQuotasFunction = {
        Type = "AWS::Lambda::Function"
        Properties = {
          FunctionName  = local.service_quotas_function_name
          Description   = "Configures Service Quotas Automatic Management for Spike"
          Runtime       = "python3.13"
          Handler       = "index.handler"
          Role          = { "Fn::GetAtt" = ["ServiceQuotasFunctionRole", "Arn"] }
          Timeout       = 300
          MemorySize    = 128
          Code          = { ZipFile = local.service_quotas_function_source }
          LoggingConfig = { LogGroup = { Ref = "ServiceQuotasLogGroup" } }
          Tags          = local.service_quotas_template_tags
        }
      }

      ServiceQuotasAutoManagement = {
        Type = "Custom::ServiceQuotasAutoManagement"
        Properties = {
          ServiceToken         = { "Fn::GetAtt" = ["ServiceQuotasFunction", "Arn"] }
          NotificationTopicArn = var.notification_topic_arn
          DirecteamId          = { Ref = "DirecteamId" }
          OptInType            = { Ref = "OptInType" }
          ExclusionList        = { Ref = "ExclusionList" }
          AccountId            = { Ref = "AWS::AccountId" }
          Region               = { Ref = "AWS::Region" }
          StackVersion         = "v${local.module_version}"
        }
      }
    }
  }

  service_quotas_member_template_body = jsonencode(local.service_quotas_member_template)
}

resource "aws_cloudformation_stack_set" "service_quotas" {
  count = local.deploy_service_quotas_stackset ? 1 : 0

  name             = local.service_quotas_stack_set_name
  description      = "Deploys Service Quotas Automatic Management to member accounts (terraform-aws-spike)"
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  call_as          = var.stackset_call_as
  template_body    = local.service_quotas_member_template_body

  parameters = {
    DirecteamId   = local.directeam_id
    OptInType     = var.service_quotas_auto_management_opt_in_type
    ExclusionList = jsonencode(var.service_quotas_auto_management_exclusion_list)
  }

  auto_deployment {
    enabled                          = local.auto_deployment_active
    retain_stacks_on_account_removal = local.auto_deployment_active ? var.retain_stacks_on_account_removal : null
  }

  # Queues overlapping operations (per-region stack instances) instead of rejecting them.
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
    # AWS populates this for SERVICE_MANAGED StackSets, which would otherwise show a permanent diff.
    ignore_changes = [administration_role_arn]

    precondition {
      condition     = var.stackset_call_as == "DELEGATED_ADMIN" || local.management_account_id == local.account_id
      error_message = "Organization mode must run from the AWS Organizations management account (${coalesce(local.management_account_id, "unknown")}); current account is ${local.account_id}. Use stackset_call_as = \"DELEGATED_ADMIN\" from a StackSets delegated administrator, or deployment_mode = \"account\"."
    }

    precondition {
      condition     = length(local.service_quotas_member_template_body) <= 51200
      error_message = "The generated Service Quotas member template is ${length(local.service_quotas_member_template_body)} bytes, above the 51,200-byte CloudFormation limit."
    }

    precondition {
      condition     = length(local.service_quotas_function_source) <= 4096
      error_message = "The Service Quotas function is ${length(local.service_quotas_function_source)} characters, above the 4,096-character inline Lambda limit."
    }
  }

  depends_on = [aws_cloudformation_stack_set_instance.spike]
}

resource "aws_cloudformation_stack_instances" "service_quotas" {
  # One resource for all regions: the provider reads every instance of the
  # StackSet into each resource, so one resource per region drifts and the
  # next apply deletes the member instances.
  count = local.deploy_service_quotas_stackset ? 1 : 0

  stack_set_name = aws_cloudformation_stack_set.service_quotas[0].name
  regions        = local.member_service_quotas_regions
  call_as        = var.stackset_call_as
  retain_stacks  = false

  deployment_targets {
    organizational_unit_ids = local.target_ou_ids
    accounts                = local.has_account_filter ? var.member_account_ids : null
    account_filter_type     = local.has_account_filter ? "INTERSECTION" : null
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
