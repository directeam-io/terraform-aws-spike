locals {
  member_policy_logical_ids = { for name in keys(local.member_role_policies) : name => "${name}Policy" }

  # The role is global, so it is only created by the home-region stack of each account. Other regions only exist for
  # optional regional features such as Bedrock invocation logs.
  member_home_region_resources = merge(
    {
      SpikeRole = {
        Type      = "AWS::IAM::Role"
        Condition = "IsHomeRegion"
        Properties = {
          RoleName           = local.role_name
          Description        = "Directeam Spike read-only access role"
          MaxSessionDuration = 3600
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Sid       = "AllowSpikeAssumeRole"
              Effect    = "Allow"
              Principal = { AWS = local.spike_trusted_principal_arns }
              Action    = "sts:AssumeRole"
              Condition = { StringEquals = { "sts:ExternalId" = { Ref = "ExternalId" } } }
            }]
          }
          Tags = [for key in sort(keys(local.tags)) : { Key = key, Value = local.tags[key] }]
        }
      }
    },
    {
      for name, policy in local.member_role_policies : local.member_policy_logical_ids[name] => {
        Type      = "AWS::IAM::ManagedPolicy"
        Condition = "IsHomeRegion"
        Properties = {
          ManagedPolicyName = "${local.role_name}-${name}"
          Description       = local.policy_descriptions[name]
          Roles             = [{ Ref = "SpikeRole" }]
          PolicyDocument    = jsondecode(policy)
        }
      }
    },
    var.notify_spike ? {
      SpikeRegistration = {
        Type      = "AWS::CloudFormation::CustomResource"
        Condition = "IsHomeRegion"
        DependsOn = concat(["SpikeRole"], values(local.member_policy_logical_ids))
        Properties = {
          ServiceToken   = var.notification_topic_arn
          ServiceTimeout = var.notification_timeout
          stackArn       = { Ref = "AWS::StackId" }
          directeamId    = { Ref = "DirecteamId" }
          state          = "finish"
          stackName      = local.role_name
          stackVersion   = "v${local.module_version}"
        }
      }
    } : {},
  )

  member_template = merge(
    {
      AWSTemplateFormatVersion = "2010-09-09"
      Description              = "Directeam Spike (terraform-aws-spike v${local.module_version})"

      Parameters = {
        ExternalId = {
          Type        = "String"
          Description = "External ID Spike presents when assuming the role"
          MinLength   = 2
          MaxLength   = 1224
        }
        DirecteamId = {
          Type        = "String"
          Description = "Directeam customer ID"
          MinLength   = 2
          MaxLength   = 1224
        }
      }

      Conditions = {
        IsHomeRegion = { "Fn::Equals" = [{ Ref = "AWS::Region" }, local.home_region] }
      }

      Resources = local.member_home_region_resources

      Outputs = {
        RoleArn = {
          Condition   = "IsHomeRegion"
          Description = "ARN of the Spike read-only access role"
          Value       = { "Fn::GetAtt" = ["SpikeRole", "Arn"] }
        }
      }
    },
  )

  member_template_body = jsonencode(local.member_template)

  # CloudFormation accepts inline templates up to 51,200 bytes. Both StackSet templates are sent inline so nothing
  # has to be hosted in the customer's account.
  member_template_limit = 51200
}

resource "aws_cloudformation_stack_set" "spike" {
  count = local.deploy_stack_set ? 1 : 0

  name             = local.stack_set_name
  description      = "Deploys Spike to member accounts (terraform-aws-spike)"
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  call_as          = var.stackset_call_as
  template_body    = local.member_template_body

  parameters = {
    ExternalId  = local.external_id
    DirecteamId = local.directeam_id
  }

  auto_deployment {
    enabled                          = local.auto_deployment_active
    retain_stacks_on_account_removal = local.auto_deployment_active ? var.retain_stacks_on_account_removal : null
  }

  # Queues overlapping operations (the home region and the optional extra regions) instead of rejecting them.
  managed_execution {
    active = true
  }

  operation_preferences {
    max_concurrent_percentage    = var.stackset_max_concurrent_percentage
    failure_tolerance_percentage = var.stackset_failure_tolerance_percentage
    region_concurrency_type      = "PARALLEL"
  }

  tags = local.tags

  timeouts {
    update = "60m"
  }

  lifecycle {
    # AWS populates this for SERVICE_MANAGED StackSets, which would otherwise show a permanent diff.
    ignore_changes = [administration_role_arn]

    precondition {
      condition     = var.stackset_call_as == "DELEGATED_ADMIN" || local.management_account_id == local.account_id
      error_message = "deployment_mode = \"organization\" must run from the AWS Organizations management account (${coalesce(local.management_account_id, "unknown")}); current account is ${local.account_id}. Use stackset_call_as = \"DELEGATED_ADMIN\" from a StackSets delegated administrator, or deployment_mode = \"account\"."
    }

    precondition {
      condition     = length(local.target_ou_ids) > 0
      error_message = "Could not discover the organization root ID. Set organizational_unit_ids explicitly (e.g. [\"r-xxxx\"])."
    }

    precondition {
      condition     = length(local.member_template_body) <= local.member_template_limit
      error_message = "The generated member account template is ${length(local.member_template_body)} bytes, above the ${local.member_template_limit}-byte CloudFormation limit."
    }
  }
}

resource "aws_cloudformation_stack_set_instance" "spike" {
  count = local.deploy_stack_set ? 1 : 0

  stack_set_name            = aws_cloudformation_stack_set.spike[0].name
  stack_set_instance_region = local.home_region
  call_as                   = var.stackset_call_as
  retain_stack              = false

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
