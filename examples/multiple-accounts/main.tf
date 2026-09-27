# Onboard several linked accounts one by one, without deploying from the management account.
# Add one provider (in versions.tf) and one module block per account.

module "spike_production" {
  source = "../.."

  providers = {
    aws = aws.production
  }

  external_id     = var.external_id
  directeam_id    = var.directeam_id
  deployment_mode = "account"
}

module "spike_staging" {
  source = "../.."

  providers = {
    aws = aws.staging
  }

  external_id     = var.external_id
  directeam_id    = var.directeam_id
  deployment_mode = "account"
}
