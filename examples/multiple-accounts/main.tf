# Onboard several linked accounts one by one, without deploying from the management account.
# Add one provider (in versions.tf) and one module block per account.

module "spike_production" {
  source = "../.."

  providers = {
    aws = aws.production
  }

  deployment_mode      = "account"
  base_onboarding_mode = "create"
}

module "spike_staging" {
  source = "../.."

  providers = {
    aws = aws.staging
  }

  deployment_mode      = "account"
  base_onboarding_mode = "create"
}
