variable "member_account_ids" {
  description = "Linked accounts to onboard. Accounts that aren't listed never receive the Spike role."
  type        = list(string)
}
