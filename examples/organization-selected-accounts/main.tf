# Onboard the management account plus a specific list of linked accounts.
# Accounts that aren't listed (including accounts that join the organization later) never receive the role.
# Run with credentials for the organization management account.

module "spike" {
  source = "../.."

  deployment_mode    = "organization"
  member_account_ids = var.member_account_ids
}
