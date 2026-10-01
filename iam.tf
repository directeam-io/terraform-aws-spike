data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AllowSpikeAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.spike_trusted_principal_arns
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.external_id]
    }
  }
}

resource "aws_iam_role" "spike" {
  count = local.create_local_role ? 1 : 0

  name                 = local.role_name
  description          = "Directeam Spike read-only access role"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = 3600
  tags                 = local.tags
}

resource "aws_iam_policy" "spike" {
  for_each = local.create_local_role ? local.local_role_policies : {}

  name        = "${local.role_name}-${each.key}"
  description = local.policy_descriptions[each.key]
  policy      = each.value
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "spike" {
  for_each = aws_iam_policy.spike

  role       = aws_iam_role.spike[0].name
  policy_arn = each.value.arn
}
