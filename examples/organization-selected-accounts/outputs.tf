output "role_arn" {
  description = "ARN of the Spike role in the management account."
  value       = module.spike.role_arn
}

output "member_account_ids" {
  description = "Member accounts that received the Spike role."
  value       = module.spike.member_account_ids
}

output "cur_bucket_name" {
  description = "S3 bucket that receives the CUR 2.0 export."
  value       = module.spike.cur_bucket_name
}
