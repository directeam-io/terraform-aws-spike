locals {
  policy_descriptions = {
    ReadOnly1              = "Spike read-only access (1/7)"
    ReadOnly2              = "Spike read-only access (2/7)"
    ReadOnly3              = "Spike read-only access (3/7)"
    ReadOnly4              = "Spike read-only access (4/7)"
    ReadOnly5              = "Spike read-only access (5/7)"
    ReadOnly6              = "Spike read-only access (6/7)"
    ReadOnly7              = "Spike read-only access (7/7)"
    CloudWatchLogsReadOnly = "Spike CloudWatch Logs content read-only access"
    EksReadOnly            = "Spike EKS read-only access"
    LogManagement          = "Spike management of S3 access logs and VPC flow logs"
    ManagementReadOnly     = "Spike management account read-only access - billing, Organizations, CloudFormation, and commitments"
  }

  # Split across several managed policies to stay under the 6,144-character IAM managed policy limit.
  read_only_policies = {
    for i in range(1, 8) : "ReadOnly${i}" => jsonencode(jsondecode(file("${path.module}/policies/read-only-${i}.json")))
  }

  optional_policies = merge(
    var.enable_cloudwatch_logs_read_access ? {
      CloudWatchLogsReadOnly = jsonencode(jsondecode(file("${path.module}/policies/cloudwatch-logs-read-only.json")))
    } : {},
    var.enable_eks_read_access ? {
      EksReadOnly = jsonencode(jsondecode(file("${path.module}/policies/eks-read-only.json")))
    } : {},
  )

  management_read_only_policy = jsonencode(jsondecode(file("${path.module}/policies/management-read-only.json")))

  # The log bucket ARN is account-specific, so the StackSet variant resolves it with Fn::Sub in each member account.
  log_management_statements = {
    s3_access_logging = {
      Sid      = "S3AccessLogging"
      Effect   = "Allow"
      Action   = ["s3:PutBucketLogging"]
      Resource = "arn:aws:s3:::*"
    }
    vpc_flow_logs = {
      Sid    = "VpcFlowLogs"
      Effect = "Allow"
      Action = [
        "ec2:CreateFlowLogs",
        "ec2:DeleteFlowLogs",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "logs:CreateLogDelivery",
        "logs:DeleteLogDelivery",
      ]
      Resource = "*"
    }
  }

  log_management_policy_local = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.log_management_statements.s3_access_logging,
      {
        Sid    = "LogBucket"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::dt-logs-${local.account_id}",
          "arn:aws:s3:::dt-logs-${local.account_id}/*",
        ]
      },
      local.log_management_statements.vpc_flow_logs,
    ]
  })

  log_management_policy_stack_set = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.log_management_statements.s3_access_logging,
      {
        Sid    = "LogBucket"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          { "Fn::Sub" = "arn:aws:s3:::dt-logs-$${AWS::AccountId}" },
          { "Fn::Sub" = "arn:aws:s3:::dt-logs-$${AWS::AccountId}/*" },
        ]
      },
      local.log_management_statements.vpc_flow_logs,
    ]
  })

  full_access_policies = merge(local.read_only_policies, local.optional_policies)

  local_role_policies = var.role_access_level == "limited" ? tomap({
    ManagementReadOnly = local.management_read_only_policy
    }) : merge(
    local.full_access_policies,
    var.enable_log_management ? { LogManagement = local.log_management_policy_local } : {},
  )

  member_role_policies = merge(
    local.full_access_policies,
    var.enable_log_management ? { LogManagement = local.log_management_policy_stack_set } : {},
  )
}
