variable "external_id" {
  description = "External ID from the Spike onboarding screen."
  type        = string
}

variable "directeam_id" {
  description = "Directeam ID from the Spike onboarding screen."
  type        = string
}

variable "enable_cur_export" {
  description = "Export this account's own cost data. Only needed for standalone accounts that aren't part of an AWS Organization."
  type        = bool
  default     = false
}
