# Manage only this additional policy, not the existing delegator role or trust.
# This shared platform grant has a separate lifecycle from customer enforcement.
resource "aws_iam_role_policy" "bedrock_budget_delegator" {
  count = var.enable_bedrock_budget_delegator_access ? 1 : 0

  name = "DirecteamAssumeBedrockBudgetManager"
  role = "DirecteamAccessDelegator"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeCustomerBedrockBudgetManager"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::*:role/DirecteamBedrockBudgetManager"
    }]
  })

  lifecycle {
    precondition {
      condition     = contains(local.spike_trusted_principal_arns, "arn:aws:iam::${local.account_id}:role/DirecteamAccessDelegator")
      error_message = "enable_bedrock_budget_delegator_access must only be enabled in a Directeam delegator account, not in customer accounts."
    }
  }
}
