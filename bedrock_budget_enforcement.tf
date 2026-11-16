locals {
  budget_blocker_name    = "DirecteamBedrockBudgetBlocker"
  budget_cleanup_name    = "DirecteamBedrockBudgetCleanup"
  budget_manager_name    = "DirecteamBedrockBudgetManager"
  budget_execution_name  = "DirecteamBedrockBudgetBlockerExecution"
  budget_source          = file("${path.module}/functions/bedrock_budget_blocker.py")
  budget_cleanup_source  = file("${path.module}/functions/bedrock_budget_cleanup.py")
  budget_local_enabled   = var.enable_bedrock_budget_enforcement && length(local.local_bedrock_logs_regions) > 0
  budget_member_accounts = var.enable_bedrock_budget_enforcement ? sort(keys(local.member_bedrock_logs)) : []
  budget_iam_actions = [
    "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
    "iam:GetUserPolicy", "iam:PutUserPolicy", "iam:DeleteUserPolicy",
  ]
  budget_protected_paths = [
    "role/aws-service-role/*", "role/aws-reserved/*",
    "role/*DirecteamFinOps*", "role/*DirecteamBedrockBudget*",
    "role/*OrganizationAccountAccessRole",
    "user/*DirecteamFinOps*", "user/*DirecteamBedrockBudget*",
    "user/*OrganizationAccountAccessRole",
  ]
  budget_member_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Directeam Bedrock budget enforcement"
    Parameters = {
      ExternalId  = { Type = "String", MinLength = 2, MaxLength = 1224 }
      DirecteamId = { Type = "String", MinLength = 2, MaxLength = 1224 }
    }
    Resources = merge({
      BudgetExecutionRole = {
        Type = "AWS::IAM::Role"
        Properties = {
          RoleName = local.budget_execution_name
          AssumeRolePolicyDocument = {
            Version   = "2012-10-17"
            Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
          }
          ManagedPolicyArns = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
          Policies = [{
            PolicyName = "BedrockBudgetPrincipalPolicies"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [
                {
                  Effect = "Allow"
                  Action = local.budget_iam_actions
                  Resource = [
                    { "Fn::Sub" = "arn:$${AWS::Partition}:iam::$${AWS::AccountId}:role/*" },
                    { "Fn::Sub" = "arn:$${AWS::Partition}:iam::$${AWS::AccountId}:user/*" },
                  ]
                },
                {
                  Effect   = "Allow"
                  Action   = ["iam:ListRoles", "iam:ListUsers"]
                  Resource = "*"
                },
                {
                  Effect   = "Allow"
                  Action   = ["lambda:GetFunctionConfiguration", "lambda:PutFunctionConcurrency"]
                  Resource = { "Fn::Sub" = "arn:$${AWS::Partition}:lambda:$${AWS::Region}:$${AWS::AccountId}:function:${local.budget_blocker_name}" }
                },
                {
                  Effect   = "Deny"
                  Action   = local.budget_iam_actions
                  Resource = [for path in local.budget_protected_paths : { "Fn::Sub" = "arn:$${AWS::Partition}:iam::$${AWS::AccountId}:${path}" }]
                },
              ]
            }
          }]
        }
      }
      BudgetBlocker = {
        Type = "AWS::Lambda::Function"
        Properties = {
          FunctionName = local.budget_blocker_name
          Runtime      = "python3.13"
          Handler      = "index.handler"
          Role         = { "Fn::GetAtt" = ["BudgetExecutionRole", "Arn"] }
          Timeout      = 30
          MemorySize   = 256
          Code         = { ZipFile = local.budget_source }
        }
      }
      BudgetCleanup = {
        Type = "AWS::Lambda::Function"
        Properties = {
          FunctionName = local.budget_cleanup_name
          Runtime      = "python3.13"
          Handler      = "index.handler"
          Role         = { "Fn::GetAtt" = ["BudgetExecutionRole", "Arn"] }
          Timeout      = 900
          MemorySize   = 256
          Code         = { ZipFile = local.budget_cleanup_source }
        }
      }
      BudgetCleanupHook = {
        Type      = "Custom::BedrockBudgetCleanup"
        DependsOn = ["BudgetBlocker", "BudgetManager"]
        Properties = {
          ServiceToken   = { "Fn::GetAtt" = ["BudgetCleanup", "Arn"] }
          ServiceTimeout = 3600
        }
      }
      BudgetManager = {
        Type = "AWS::IAM::Role"
        Properties = {
          RoleName           = local.budget_manager_name
          MaxSessionDuration = 3600
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { AWS = local.spike_trusted_principal_arns }
              Action    = "sts:AssumeRole"
              Condition = { StringEquals = { "sts:ExternalId" = { Ref = "ExternalId" } } }
            }]
          }
          Policies = [{
            PolicyName = "InvokeBedrockBudgetBlocker"
            PolicyDocument = {
              Version   = "2012-10-17"
              Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = { "Fn::GetAtt" = ["BudgetBlocker", "Arn"] } }]
            }
          }]
        }
      }
      }, var.notify_spike ? {
      BudgetRegistration = {
        Type      = "AWS::CloudFormation::CustomResource"
        DependsOn = ["BudgetManager", "BudgetCleanupHook"]
        Properties = {
          ServiceToken   = var.notification_topic_arn
          ServiceTimeout = var.notification_timeout
          feature        = "bedrock_budget_enforcement"
          eventStatus    = "enabled"
          directeamId    = { Ref = "DirecteamId" }
          accountId      = { Ref = "AWS::AccountId" }
          region         = { Ref = "AWS::Region" }
          stackVersion   = "v${local.module_version}"
        }
      }
    } : {})
  }
}

data "archive_file" "bedrock_budget_blocker" {
  count       = local.budget_local_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/functions/bedrock_budget_blocker.py"
  output_path = "${path.root}/.terraform/bedrock-budget-${sha256(path.module)}.zip"
}

data "archive_file" "bedrock_budget_cleanup" {
  count       = local.budget_local_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/functions/bedrock_budget_cleanup.py"
  output_path = "${path.root}/.terraform/bedrock-budget-cleanup-${sha256(path.module)}.zip"
}

data "aws_iam_policy_document" "budget_lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "budget_execution" {
  count              = local.budget_local_enabled ? 1 : 0
  name               = local.budget_execution_name
  assume_role_policy = data.aws_iam_policy_document.budget_lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "budget_lambda_logging" {
  count      = local.budget_local_enabled ? 1 : 0
  role       = aws_iam_role.budget_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "budget_execution" {
  count = local.budget_local_enabled ? 1 : 0
  name  = "BedrockBudgetPrincipalPolicies"
  role  = aws_iam_role.budget_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = local.budget_iam_actions
        Resource = ["arn:aws:iam::${local.account_id}:role/*", "arn:aws:iam::${local.account_id}:user/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:ListRoles", "iam:ListUsers"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:GetFunctionConfiguration", "lambda:PutFunctionConcurrency"]
        Resource = "arn:aws:lambda:${local.home_region}:${local.account_id}:function:${local.budget_blocker_name}"
      },
      {
        Effect   = "Deny"
        Action   = local.budget_iam_actions
        Resource = [for path in local.budget_protected_paths : "arn:aws:iam::${local.account_id}:${path}"]
      },
    ]
  })
}

resource "aws_lambda_function" "bedrock_budget_blocker" {
  #checkov:skip=CKV_AWS_50:X-Ray would require additional customer-account tracing permissions.
  #checkov:skip=CKV_AWS_117:The blocker calls public AWS APIs and does not need customer VPC access.
  #checkov:skip=CKV_AWS_115:A fixed concurrency limit could throttle budget reconciliation; teardown stops invocations explicitly.
  #checkov:skip=CKV_AWS_116:The platform invokes synchronously and handles per-principal failures and retries.
  #checkov:skip=CKV_AWS_272:Customer-managed signing profiles are not required for the module's packaged source.
  count            = local.budget_local_enabled ? 1 : 0
  region           = local.home_region
  function_name    = local.budget_blocker_name
  role             = aws_iam_role.budget_execution[0].arn
  handler          = "bedrock_budget_blocker.handler"
  runtime          = "python3.13"
  filename         = data.archive_file.bedrock_budget_blocker[0].output_path
  source_code_hash = data.archive_file.bedrock_budget_blocker[0].output_base64sha256
  timeout          = 30
  memory_size      = 256
  tags             = local.tags
  lifecycle {
    precondition {
      condition     = length(local.budget_source) <= local.member_template_limit && length(local.budget_cleanup_source) <= local.member_template_limit
      error_message = "The Bedrock budget Lambda source exceeds the CloudFormation template size limit."
    }
  }
}

resource "aws_lambda_function" "bedrock_budget_cleanup" {
  #checkov:skip=CKV_AWS_50:X-Ray would require additional customer-account tracing permissions.
  #checkov:skip=CKV_AWS_117:Cleanup calls public AWS APIs and CloudFormation's response URL, not customer VPC resources.
  #checkov:skip=CKV_AWS_115:A fixed concurrency limit could prevent the CloudFormation teardown hook from running.
  #checkov:skip=CKV_AWS_116:The custom resource reports failures directly to CloudFormation, which prevents unsafe teardown.
  #checkov:skip=CKV_AWS_272:Customer-managed signing profiles are not required for the module's packaged source.
  count            = local.budget_local_enabled ? 1 : 0
  region           = local.home_region
  function_name    = local.budget_cleanup_name
  role             = aws_iam_role.budget_execution[0].arn
  handler          = "bedrock_budget_cleanup.handler"
  runtime          = "python3.13"
  filename         = data.archive_file.bedrock_budget_cleanup[0].output_path
  source_code_hash = data.archive_file.bedrock_budget_cleanup[0].output_base64sha256
  timeout          = 900
  memory_size      = 256
  tags             = local.tags
}

resource "aws_iam_role" "budget_manager" {
  count                = local.budget_local_enabled ? 1 : 0
  name                 = local.budget_manager_name
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = 3600
  tags                 = local.tags
}

resource "aws_iam_role_policy" "budget_manager" {
  count = local.budget_local_enabled ? 1 : 0
  name  = "InvokeBedrockBudgetBlocker"
  role  = aws_iam_role.budget_manager[0].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.bedrock_budget_blocker[0].arn }]
  })
}

resource "aws_cloudformation_stack" "bedrock_budget_registration" {
  #checkov:skip=CKV_AWS_124:The stack only holds an SNS-backed registration custom resource.
  count  = local.budget_local_enabled && var.notify_spike ? 1 : 0
  region = local.home_region
  name   = "DirecteamBedrockBudgetRegistration"
  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      BudgetRegistration = {
        Type = "AWS::CloudFormation::CustomResource"
        Properties = {
          ServiceToken   = var.notification_topic_arn
          ServiceTimeout = var.notification_timeout
          feature        = "bedrock_budget_enforcement"
          eventStatus    = "enabled"
          directeamId    = local.directeam_id
          accountId      = local.account_id
          region         = local.home_region
          stackVersion   = "v${local.module_version}"
        }
      }
    }
  })
  depends_on = [aws_iam_role_policy.budget_manager, aws_cloudformation_stack.registration, aws_cloudformation_stack.bedrock_budget_cleanup]
  tags       = local.tags
}

resource "aws_cloudformation_stack" "bedrock_budget_cleanup" {
  #checkov:skip=CKV_AWS_124:The stack only holds a cleanup custom resource that reports directly to CloudFormation.
  count  = local.budget_local_enabled ? 1 : 0
  region = local.home_region
  name   = "DirecteamBedrockBudgetCleanup"
  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      BudgetCleanup = {
        Type = "Custom::BedrockBudgetCleanup"
        Properties = {
          ServiceToken   = aws_lambda_function.bedrock_budget_cleanup[0].arn
          ServiceTimeout = 3600
        }
      }
    }
  })
  depends_on = [
    aws_iam_role_policy.budget_manager,
    aws_iam_role_policy.budget_execution,
    aws_lambda_function.bedrock_budget_blocker,
  ]
  tags = local.tags
}

resource "aws_cloudformation_stack_set" "bedrock_budget" {
  count            = length(local.budget_member_accounts) > 0 ? 1 : 0
  name             = "DirecteamBedrockBudgetEnforcement"
  description      = "Deploy Bedrock budget enforcement to Bedrock logs accounts"
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  call_as          = var.stackset_call_as
  template_body    = jsonencode(local.budget_member_template)
  parameters = {
    ExternalId  = local.external_id
    DirecteamId = local.directeam_id
  }
  managed_execution { active = true }
  operation_preferences {
    max_concurrent_percentage    = var.stackset_max_concurrent_percentage
    failure_tolerance_percentage = var.stackset_failure_tolerance_percentage
    region_concurrency_type      = "PARALLEL"
  }
  tags = local.tags
  lifecycle {
    ignore_changes = [administration_role_arn]
    precondition {
      condition     = length(local.budget_source) <= local.member_template_limit && length(local.budget_cleanup_source) <= local.member_template_limit
      error_message = "The Bedrock budget Lambda source exceeds the CloudFormation template size limit."
    }
    precondition {
      condition     = length(jsonencode(local.budget_member_template)) <= local.member_template_limit
      error_message = "The Bedrock budget member template exceeds the CloudFormation template limit."
    }
  }
  depends_on = [aws_cloudformation_stack_instances.bedrock_logs, aws_cloudformation_stack_set_instance.spike, terraform_data.spike_stack_update]
}

resource "aws_cloudformation_stack_instances" "bedrock_budget" {
  count          = length(local.budget_member_accounts) > 0 ? 1 : 0
  stack_set_name = aws_cloudformation_stack_set.bedrock_budget[0].name
  regions        = [local.home_region]
  call_as        = var.stackset_call_as
  retain_stacks  = false
  deployment_targets {
    organizational_unit_ids = local.target_ou_ids
    accounts                = local.budget_member_accounts
    account_filter_type     = "INTERSECTION"
  }
  operation_preferences {
    concurrency_mode             = "SOFT_FAILURE_TOLERANCE"
    max_concurrent_percentage    = var.stackset_max_concurrent_percentage
    failure_tolerance_percentage = var.stackset_failure_tolerance_percentage
    region_concurrency_type      = "PARALLEL"
  }
}
