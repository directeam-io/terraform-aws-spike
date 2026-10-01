check "organization_inputs_ignored_in_account_mode" {
  assert {
    condition     = local.is_organization || (length(var.organizational_unit_ids) == 0 && length(var.member_account_ids) == 0)
    error_message = "organizational_unit_ids and member_account_ids only apply to deployment_mode = \"organization\" and are ignored."
  }
}

check "management_account_not_in_member_accounts" {
  assert {
    condition     = !contains(var.member_account_ids, coalesce(local.management_account_id, "none"))
    error_message = "member_account_ids contains the management account. StackSets never deploy to the management account; the role is created there directly by this module."
  }
}

check "bedrock_invocation_logs_accounts_listed" {
  assert {
    condition     = !var.enable_bedrock_invocation_logs || length(local.bedrock_logs_accounts) > 0
    error_message = "enable_bedrock_invocation_logs is true but no accounts or regions with Bedrock usage were found (Cost Explorer shows no Bedrock spend in the last ${var.bedrock_invocation_logs_lookback_days} days, or bedrock_invocation_logs_accounts is empty), so no Bedrock invocation logging is deployed."
  }
}

check "local_role_options_ignored_for_limited_access" {
  assert {
    condition     = var.role_access_level == "full" || !(var.enable_eks_read_access || var.enable_log_management)
    error_message = "enable_eks_read_access and enable_log_management don't apply to the role in the current account when role_access_level = \"limited\"; they still apply to member accounts."
  }
}
