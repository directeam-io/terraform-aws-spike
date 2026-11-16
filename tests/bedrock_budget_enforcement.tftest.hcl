mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
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
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "external" {}
mock_provider "archive" {}

variables {
  external_id          = "spike-test-external-id"
  directeam_id         = "directeam-test-id"
  base_onboarding_mode = "create"
}

run "disabled_by_default" {
  command = plan
  variables {
    deployment_mode                  = "account"
    enable_bedrock_invocation_logs   = true
    bedrock_invocation_logs_accounts = { "111111111111" = ["eu-west-1"] }
  }
  assert {
    condition     = length(aws_lambda_function.bedrock_budget_blocker) == 0 && length(aws_cloudformation_stack_set.bedrock_budget) == 0
    error_message = "Budget enforcement must be opt-in."
  }
  assert {
    condition     = length(aws_iam_role_policy.bedrock_budget_delegator) == 0
    error_message = "Shared delegator access must be opt-in."
  }
}

run "account_mode" {
  command = plan
  variables {
    deployment_mode                   = "account"
    enable_bedrock_invocation_logs    = true
    enable_bedrock_budget_enforcement = true
    bedrock_invocation_logs_accounts = {
      "111111111111" = ["eu-west-1"]
      "222222222222" = ["us-west-2"]
    }
  }
  assert {
    condition     = length(aws_lambda_function.bedrock_budget_blocker) == 1 && aws_lambda_function.bedrock_budget_blocker[0].region == "us-east-1" && length(aws_cloudformation_stack_set.bedrock_budget) == 0
    error_message = "Account mode must deploy only in the current account's home region."
  }
  assert {
    condition     = length(aws_iam_role_policy.bedrock_budget_delegator) == 0
    error_message = "Customer enforcement must not manage the platform delegator."
  }
}

run "organization_mode" {
  command = plan
  variables {
    deployment_mode                   = "organization"
    enable_bedrock_invocation_logs    = true
    enable_bedrock_budget_enforcement = true
    bedrock_invocation_logs_accounts = {
      "111111111111" = ["us-east-1"]
      "222222222222" = ["us-west-2"]
      "333333333333" = ["eu-west-1"]
    }
  }
  assert {
    condition     = toset(aws_cloudformation_stack_instances.bedrock_budget[0].deployment_targets[0].accounts) == toset(["222222222222", "333333333333"]) && toset(aws_cloudformation_stack_instances.bedrock_budget[0].regions) == toset(["us-east-1"])
    error_message = "Member enforcement must target exactly the logs accounts in the home region."
  }
  assert {
    condition     = length(jsonencode(local.budget_member_template)) <= local.member_template_limit && local.budget_member_template.Resources.BudgetManager.Properties.Policies[0].PolicyDocument.Statement[0].Action == "lambda:InvokeFunction"
    error_message = "The blocker must fit CloudFormation and the manager must only invoke it."
  }
}

run "directeam_delegator_access_without_customer_enforcement" {
  command = plan
  variables {
    deployment_mode                        = "account"
    enable_bedrock_invocation_logs         = false
    enable_bedrock_budget_delegator_access = true
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "250260913666" }
  }
  assert {
    condition = (
      aws_iam_role_policy.bedrock_budget_delegator[0].role == "DirecteamAccessDelegator" &&
      jsondecode(aws_iam_role_policy.bedrock_budget_delegator[0].policy).Statement == [{
        Sid      = "AssumeCustomerBedrockBudgetManager"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::*:role/DirecteamBedrockBudgetManager"
      }]
    )
    error_message = "The Directeam delegator must only gain permission to assume budget manager roles."
  }
  assert {
    condition     = length(aws_lambda_function.bedrock_budget_blocker) == 0
    error_message = "Shared delegator access must not depend on enabling customer enforcement."
  }
}

run "reject_delegator_access_in_customer_account" {
  command = plan
  variables {
    deployment_mode                        = "account"
    enable_bedrock_invocation_logs         = false
    enable_bedrock_budget_delegator_access = true
  }
  expect_failures = [aws_iam_role_policy.bedrock_budget_delegator]
}
