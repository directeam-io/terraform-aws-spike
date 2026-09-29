data "aws_caller_identity" "current" {}

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

data "aws_organizations_organization" "current" {
  count = local.is_organization ? 1 : 0

  # Roots are only needed when the targets must be discovered.
  return_organization_only = length(var.organizational_unit_ids) > 0
}

locals {
  module_version = "1.0.0"

  role_name               = "DirecteamSpikeReadOnlyAccess"
  stack_set_name          = "DirecteamSpikeReadOnlyAccess"
  registration_stack_name = "DirecteamSpikeRegistration"

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

  # A delegated administrator is itself a member account and receives the role through the StackSet.
  create_local_role = !local.is_delegated_admin
  # Spike needs one CUR export, from the management account, which sees every account's costs. Account mode only
  # creates it when asked to (the management account itself, or a standalone account).
  create_cur_export = local.is_organization ? !local.is_delegated_admin : coalesce(var.enable_cur_export, false)
  deploy_stack_set  = local.is_organization

  organization           = one(data.aws_organizations_organization.current)
  management_account_id  = try(local.organization.master_account_id, null)
  organization_root_id   = try(local.organization.roots[0].id, null)
  target_ou_ids          = length(var.organizational_unit_ids) > 0 ? var.organizational_unit_ids : compact([local.organization_root_id])
  has_account_filter     = length(var.member_account_ids) > 0
  auto_deployment_active = var.auto_deployment && !local.has_account_filter

  tags = merge(
    var.tags,
    {
      CreatedBy          = "Directeam"
      Product            = "Spike"
      ManagedBy          = "Terraform"
      SpikeModuleVersion = local.module_version
    },
  )

  bedrock_logs_bucket_prefix = "dt-bedrock-logs"
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

  local_bedrock_logs_regions = local.create_local_role ? toset(lookup(local.bedrock_logs_accounts, local.account_id, [])) : toset([])

  # StackSets never deploy to the management account, which is handled directly by this module.
  member_bedrock_logs = local.deploy_stack_set ? {
    for account_id, regions in local.bedrock_logs_accounts : account_id => regions
    if account_id != local.management_account_id && !(local.create_local_role && account_id == local.account_id)
  } : {}

  member_bedrock_logs_accounts_by_region = {
    for region in distinct(flatten(values(local.member_bedrock_logs))) :
    region => sort([for account_id, regions in local.member_bedrock_logs : account_id if contains(regions, region)])
  }
  member_bedrock_logs_enabled = length(local.member_bedrock_logs) > 0

  # The home region is already covered by the organization-wide stack instances.
  member_bedrock_logs_extra_regions = {
    for region, accounts in local.member_bedrock_logs_accounts_by_region : region => accounts if region != local.home_region
  }

  deployed_bedrock_logs = merge(
    length(local.local_bedrock_logs_regions) > 0 ? { (local.account_id) = sort(tolist(local.local_bedrock_logs_regions)) } : {},
    { for account_id, regions in local.member_bedrock_logs : account_id => sort(regions) },
  )

  cur_bucket_name = "dt-cur-${local.account_id}"
  cur_export_name = "dt-cur-parquet-${local.account_id}"
  cur_prefix      = "hourly"
}
