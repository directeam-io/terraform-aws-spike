# Onboard the whole AWS Organization to Spike.
# Run with credentials for the organization management account.

module "spike" {
  source = "../.."

  deployment_mode = "organization"
}
