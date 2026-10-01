data "aws_caller_identity" "current" {}

data "aws_cloudformation_stack" "bootstrap" {
  count = var.base_onboarding_mode == "create" && (var.external_id == null || var.directeam_id == null) ? 1 : 0

  name = "DirecteamTerraformBootstrap"

  lifecycle {
    postcondition {
      condition     = try(length(self.parameters.ExternalId) >= 2 && length(self.parameters.DirecteamId) >= 2, false)
      error_message = "DirecteamTerraformBootstrap must contain ExternalId and DirecteamId parameters."
    }
  }
}

data "external" "existing_onboarding" {
  count = var.base_onboarding_mode != "create" ? 1 : 0

  program = ["python3", "${path.module}/scripts/discover_existing_onboarding.py"]

  query = {
    account_id      = local.account_id
    deployment_mode = var.deployment_mode
  }

  lifecycle {
    postcondition {
      condition     = try(self.result.identity_found == "true", false) || (var.external_id != null && var.directeam_id != null)
      error_message = "Install the Spike-generated DirecteamTerraformBootstrap stack before running Terraform, or provide external_id and directeam_id as compatibility fallbacks."
    }
  }
}

# Finds where Bedrock is used from Cost Explorer (plan time). Runs the AWS CLI with the credentials Terraform runs with.
data "external" "bedrock_usage" {
  count = var.enable_bedrock_invocation_logs && var.bedrock_invocation_logs_accounts == null ? 1 : 0

  program = ["python3", "${path.module}/scripts/discover_bedrock_usage.py"]

  query = {
    account_id    = local.account_id
    lookback_days = tostring(var.bedrock_invocation_logs_lookback_days)
  }

  lifecycle {
    precondition {
      condition     = !local.is_delegated_admin
      error_message = "Bedrock usage can't be discovered automatically when running as a delegated administrator, because Cost Explorer only shows this account's own spend. Set bedrock_invocation_logs_accounts explicitly."
    }
  }
}

check "existing_base_onboarding" {
  assert {
    condition     = var.base_onboarding_mode != "existing" || local.existing_onboarding_detected
    error_message = "base_onboarding_mode = \"existing\" requires a successful Directeam CloudFormation onboarding stack in us-east-1."
  }
}

data "aws_organizations_organization" "current" {
  count = local.is_organization ? 1 : 0

  # Roots are only needed when the targets must be discovered.
  return_organization_only = length(var.organizational_unit_ids) > 0
}

locals {
  module_version = "1.2.0"

  role_name                       = "DirecteamFinOpsReadOnlyAccess"
  stack_set_name                  = "DirecteamFinOpsReadOnlyAccess"
  bedrock_stack_set_name          = "DirecteamBedrockInvocationLogs"
  registration_stack_name         = "DirecteamFinOpsRegistration"
  bedrock_registration_stack_name = "DirecteamBedrockInvocationLogsRegistration"

  # Spike's SNS-backed custom resources and CUR 2.0 data exports are only available in us-east-1.
  home_region = "us-east-1"

  account_id = data.aws_caller_identity.current.account_id

  spike_trusted_principal_arns = [
    "arn:aws:iam::250260913666:role/DirecteamAccessDelegator",
    "arn:aws:iam::510301156393:role/DirecteamAccessDelegator",
  ]
  spike_cur_reader_arn = "arn:aws:iam::250260913666:role/DirecteamCurDataAccess"

  is_organization    = var.deployment_mode == "organization"
  is_delegated_admin = local.is_organization && var.stackset_call_as == "DELEGATED_ADMIN"

  existing_identity_discovered   = try(data.external.existing_onboarding[0].result.identity_found == "true", false)
  bootstrap_identity_discovered  = length(data.aws_cloudformation_stack.bootstrap) > 0
  identity_discovered            = local.existing_identity_discovered || local.bootstrap_identity_discovered
  external_id                    = local.existing_identity_discovered ? data.external.existing_onboarding[0].result.external_id : local.bootstrap_identity_discovered ? try(data.aws_cloudformation_stack.bootstrap[0].parameters.ExternalId, var.external_id != null ? var.external_id : "") : var.external_id != null ? var.external_id : ""
  directeam_id                   = local.existing_identity_discovered ? data.external.existing_onboarding[0].result.directeam_id : local.bootstrap_identity_discovered ? try(data.aws_cloudformation_stack.bootstrap[0].parameters.DirecteamId, var.directeam_id != null ? var.directeam_id : "") : var.directeam_id != null ? var.directeam_id : ""
  identity_stack_name            = local.existing_identity_discovered ? data.external.existing_onboarding[0].result.identity_stack_name : local.bootstrap_identity_discovered ? data.aws_cloudformation_stack.bootstrap[0].name : ""
  existing_onboarding_detected   = try(data.external.existing_onboarding[0].result.exists == "true", false)
  existing_onboarding_stack_name = local.existing_onboarding_detected ? data.external.existing_onboarding[0].result.stack_name : ""
  manage_base_onboarding         = !local.existing_onboarding_detected

  # A delegated administrator is itself a member account and receives the role through the StackSet.
  create_local_role       = local.manage_base_onboarding && !local.is_delegated_admin
  configure_local_bedrock = !local.is_delegated_admin
  # Spike needs one CUR export, from the management account, which sees every account's costs. Account mode only
  # creates it when asked to (the management account itself, or a standalone account).
  create_cur_export = local.manage_base_onboarding && !local.is_delegated_admin && coalesce(var.enable_cur_export, local.is_organization)
  deploy_stack_set  = local.manage_base_onboarding && local.is_organization

  organization           = one(data.aws_organizations_organization.current)
  management_account_id  = try(local.organization.master_account_id, null)
  organization_root_id   = try(local.organization.roots[0].id, null)
  target_ou_ids          = length(var.organizational_unit_ids) > 0 ? var.organizational_unit_ids : compact([local.organization_root_id])
  has_account_filter     = length(var.member_account_ids) > 0
  auto_deployment_active = var.auto_deployment

  tags = merge(
    var.tags,
    {
      CreatedBy          = "Directeam"
      Product            = "Spike"
      ManagedBy          = "Terraform"
      SpikeModuleVersion = local.module_version
    },
  )

  bedrock_logs_bucket_prefix = "dt-bedrock-invocation-logs"
  bedrock_logs_key_prefix    = "invocation-logs"

  # Accounts and regions that use Bedrock: the explicit map when given, otherwise what Cost Explorer reports.
  bedrock_discovery_enabled = var.enable_bedrock_invocation_logs && var.bedrock_invocation_logs_accounts == null

  bedrock_discovered_accounts = local.bedrock_discovery_enabled ? {
    for account_id, regions in jsondecode(data.external.bedrock_usage[0].result.accounts) : account_id => tolist(regions)
    if local.is_organization ? (account_id == local.management_account_id || !local.has_account_filter || contains(var.member_account_ids, account_id)) : account_id == local.account_id
  } : {}

  bedrock_logs_accounts = !var.enable_bedrock_invocation_logs ? {} : (
    var.bedrock_invocation_logs_accounts == null ? local.bedrock_discovered_accounts : var.bedrock_invocation_logs_accounts
  )

  local_bedrock_logs_regions = local.configure_local_bedrock ? toset(lookup(local.bedrock_logs_accounts, local.account_id, [])) : toset([])

  # StackSets never deploy to the management account, which is handled directly by this module.
  member_bedrock_logs = local.is_organization ? {
    for account_id, regions in local.bedrock_logs_accounts : account_id => regions
    if account_id != local.management_account_id && !(local.create_local_role && account_id == local.account_id)
  } : {}

  member_bedrock_logs_extra_regions = {
    for region in distinct(flatten(values(local.member_bedrock_logs))) :
    region => sort([for account_id, regions in local.member_bedrock_logs : account_id if contains(regions, region)])
    if region != local.home_region
  }
  member_bedrock_logs_accounts_by_region = merge(
    local.member_bedrock_logs_extra_regions,
    contains(distinct(flatten(values(local.member_bedrock_logs))), local.home_region) ? {
      (local.home_region) = sort([
        for account_id, regions in local.member_bedrock_logs : account_id if contains(regions, local.home_region)
      ])
    } : {},
  )
  member_bedrock_logs_enabled = length(local.member_bedrock_logs) > 0

  deployed_bedrock_logs = merge(
    length(local.local_bedrock_logs_regions) > 0 ? { (local.account_id) = sort(tolist(local.local_bedrock_logs_regions)) } : {},
    { for account_id, regions in local.member_bedrock_logs : account_id => sort(regions) },
  )

  cur_bucket_name = "dt-cur-${local.account_id}"
  cur_export_name = "dt-cur-parquet-${local.account_id}"
  cur_prefix      = "hourly"
}
