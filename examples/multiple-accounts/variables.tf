variable "production_deployment_role_arn" {
  description = "Existing role in the production account that Terraform assumes to deploy the Spike role."
  type        = string
}

variable "staging_deployment_role_arn" {
  description = "Existing role in the staging account that Terraform assumes to deploy the Spike role."
  type        = string
}
