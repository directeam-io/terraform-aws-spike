data "aws_caller_identity" "current" {}

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
  create_cur_export = coalesce(var.enable_cur_export, local.is_organization && !local.is_delegated_admin)
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

  cur_bucket_name = "dt-cur-${local.account_id}"
  cur_export_name = "dt-cur-parquet-${local.account_id}"
  cur_prefix      = "hourly"
}
