variable "external_id" {
  description = "External ID from the Spike onboarding screen."
  type        = string
}

variable "directeam_id" {
  description = "Directeam ID from the Spike onboarding screen."
  type        = string
}

variable "production_deployment_role_arn" {
  description = "Existing role in the production account that Terraform assumes to deploy the Spike role."
  type        = string
}

variable "staging_deployment_role_arn" {
  description = "Existing role in the staging account that Terraform assumes to deploy the Spike role."
  type        = string
}
