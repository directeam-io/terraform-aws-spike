# Onboard the whole AWS Organization to Spike.
# Run with credentials for the organization management account.

module "spike" {
  source = "../.."

  external_id     = var.external_id
  directeam_id    = var.directeam_id
  deployment_mode = "organization"
}
