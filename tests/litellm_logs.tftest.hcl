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
    condition     = length(aws_iam_role_policy.litellm_logs_read) == 0 && length(aws_cloudformation_stack.litellm_registration) == 0
    error_message = "LiteLLM log registration must be opt-in."
  }
}

run "buckets_listed" {
  command = plan

  variables {
    deployment_mode = "account"
    litellm_logs_bucket_arns = [
      "arn:aws:s3:::acme-litellm-logs",
      "arn:aws:s3:::acme-litellm-logs-eu",
    ]
  }

  assert {
    condition     = length(aws_iam_role_policy.litellm_logs_read) == 1 && aws_iam_role_policy.litellm_logs_read[0].name == "LiteLLMLogsRead"
    error_message = "The Spike role must get one read policy covering all listed buckets."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.litellm_logs_read.statement) == 2 && toset(data.aws_iam_policy_document.litellm_logs_read.statement[0].resources) == toset(["arn:aws:s3:::acme-litellm-logs", "arn:aws:s3:::acme-litellm-logs-eu"]) && toset(data.aws_iam_policy_document.litellm_logs_read.statement[1].resources) == toset(["arn:aws:s3:::acme-litellm-logs/*", "arn:aws:s3:::acme-litellm-logs-eu/*"])
    error_message = "The read policy must list and read exactly the configured buckets."
  }

  assert {
    condition     = length(aws_cloudformation_stack.litellm_registration) == 1 && local.litellm_registration_resources.LiteLLMLogs.Properties.feature == "litellm_logs" && toset(local.litellm_registration_resources.LiteLLMLogs.Properties.bucketArns) == toset(["arn:aws:s3:::acme-litellm-logs", "arn:aws:s3:::acme-litellm-logs-eu"])
    error_message = "All listed buckets must be registered with Spike in one custom resource."
  }

  assert {
    condition     = local.litellm_registration_resources.LiteLLMLogs.Properties.accountId == "111111111111" && local.litellm_registration_resources.LiteLLMLogs.Properties.ServiceToken == "arn:aws:sns:us-east-1:250260913666:directeam-onboarding-topic-f7a69a4b"
    error_message = "Registration must be attributed to the current account and target the onboarding topic."
  }
}
