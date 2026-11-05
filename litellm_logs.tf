################################################################################
# LiteLLM logs: read access to customer-owned LiteLLM proxy S3 logger buckets.
#
# Unlike Bedrock invocation logs, the buckets are pre-existing and
# customer-owned: nothing is created in the customer account. The module only
# grants the Spike role read access (the buckets must be in the same account,
# where an identity policy alone is sufficient) and registers them with Spike
# through the litellm_registration custom resource in registration.tf.
################################################################################

data "aws_iam_role" "litellm_logs_reader" {
  count = length(var.litellm_logs_bucket_arns) > 0 && !local.create_local_role ? 1 : 0

  name = local.role_name
}

data "aws_iam_policy_document" "litellm_logs_read" {
  statement {
    sid = "ListLitellmLogs"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = var.litellm_logs_bucket_arns
  }

  statement {
    sid       = "ReadLitellmLogs"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [for arn in var.litellm_logs_bucket_arns : "${arn}/*"]
  }
}

resource "aws_iam_role_policy" "litellm_logs_read" {
  count = length(var.litellm_logs_bucket_arns) > 0 ? 1 : 0

  name   = "LiteLLMLogsRead"
  role   = local.create_local_role ? aws_iam_role.spike[0].name : data.aws_iam_role.litellm_logs_reader[0].name
  policy = data.aws_iam_policy_document.litellm_logs_read.json

  depends_on = [terraform_data.spike_stack_update]
}
