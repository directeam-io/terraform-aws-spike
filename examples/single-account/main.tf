# Onboard a single AWS account (standalone, or one linked account without going through the management account).
# Run with credentials for the account being onboarded.

module "spike" {
  source = "../.."

  deployment_mode   = "account"
  enable_cur_export = var.enable_cur_export
}
