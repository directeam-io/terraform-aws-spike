variable "external_id" {
  description = "External ID from the Spike onboarding screen."
  type        = string
}

variable "directeam_id" {
  description = "Directeam ID from the Spike onboarding screen."
  type        = string
}

variable "enable_cur_export" {
  description = "Export this account's cost data. Set to true only for a standalone account or the management account; linked accounts are covered by the management account's export."
  type        = bool
  default     = false
}
