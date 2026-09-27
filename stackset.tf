locals {
  member_policy_logical_ids = { for name in keys(local.member_role_policies) : name => "${name}Policy" }

  member_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Directeam Spike read-only access role (terraform-spike-aws-onboarding v${local.module_version})"

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

    Resources = merge(
      {
        SpikeRole = {
          Type = "AWS::IAM::Role"
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
          Type = "AWS::IAM::ManagedPolicy"
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
          DependsOn = concat(["SpikeRole"], values(local.member_policy_logical_ids))
          Properties = {
            ServiceToken   = var.notification_topic_arn
            ServiceTimeout = var.notification_timeout
            stackArn       = { Ref = "AWS::StackId" }
            directeamId    = { Ref = "DirecteamId" }
            state          = "finish"
            stackName      = local.role_name
            stackVersion   = "v${local.module_version}"
            deploymentTool = "terraform"
          }
        }
      } : {},
    )

    Outputs = {
      RoleArn = {
        Description = "ARN of the Spike read-only access role"
        Value       = { "Fn::GetAtt" = ["SpikeRole", "Arn"] }
      }
    }
  }

  member_template_body = jsonencode(local.member_template)
}

resource "aws_cloudformation_stack_set" "spike" {
  count = local.deploy_stack_set ? 1 : 0

  name             = local.stack_set_name
  description      = "Deploys the ${local.role_name} role to member accounts (terraform-spike-aws-onboarding)"
  permission_model = "SERVICE_MANAGED"
  call_as          = var.stackset_call_as
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  template_body    = local.member_template_body

  parameters = {
    ExternalId  = var.external_id
    DirecteamId = var.directeam_id
  }

  auto_deployment {
    enabled                          = local.auto_deployment_active
    retain_stacks_on_account_removal = local.auto_deployment_active ? var.retain_stacks_on_account_removal : null
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
      condition     = length(local.member_template_body) <= 51200
      error_message = "The generated member account template is ${length(local.member_template_body)} bytes, above the 51,200-byte CloudFormation inline template limit."
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
