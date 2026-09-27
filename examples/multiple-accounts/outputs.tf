output "role_arns" {
  description = "ARN of the Spike role in each onboarded account."
  value = {
    production = module.spike_production.role_arn
    staging    = module.spike_staging.role_arn
  }
}
