variable "external_id" {
  description = "External ID from the Spike onboarding screen."
  type        = string
}

variable "directeam_id" {
  description = "Directeam ID from the Spike onboarding screen."
  type        = string
}

variable "member_account_ids" {
  description = "Linked accounts to onboard. Accounts that aren't listed never receive the Spike role."
  type        = list(string)
  default     = ["111111111111", "222222222222"]
}
