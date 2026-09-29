output "role_name" {
  description = "Name of the Spike role, identical in every account it's deployed to."
  value       = local.role_name
}

output "role_arn" {
  description = "ARN of the Spike role in the current account. Null when running as a StackSets delegated administrator."
  value       = try(aws_iam_role.spike[0].arn, null)
}

output "stack_set_name" {
  description = "Name of the StackSet that deploys the Spike role to member accounts. Null in account mode."
  value       = try(aws_cloudformation_stack_set.spike[0].name, null)
}

output "stack_set_id" {
  description = "ID of the StackSet that deploys the Spike role to member accounts. Null in account mode."
  value       = try(aws_cloudformation_stack_set.spike[0].stack_set_id, null)
}

output "target_organizational_unit_ids" {
  description = "Organization root or OU IDs targeted by the StackSet."
  value       = local.deploy_stack_set ? local.target_ou_ids : []
}

output "member_account_ids" {
  description = "Member accounts that received the Spike role through the StackSet."
  value       = try(sort(distinct([for s in aws_cloudformation_stack_set_instance.spike[0].stack_instance_summaries : s.account_id])), [])
}

output "bedrock_invocation_log_buckets" {
  description = "Bedrock invocation log bucket in the current account, by region."
  value       = { for region, bucket in aws_s3_bucket.bedrock_logs : region => bucket.id }
}

output "bedrock_invocation_logs_accounts" {
  description = "Accounts and regions where Bedrock invocation logging is deployed for Spike."
  value       = local.deployed_bedrock_logs
}
output "cur_bucket_name" {
  description = "S3 bucket that receives the CUR 2.0 export. Null when no export is created in this account."
  value       = try(aws_s3_bucket.cur[0].id, null)
}

output "cur_bucket_arn" {
  description = "ARN of the CUR 2.0 bucket. Null when no export is created in this account."
  value       = try(aws_s3_bucket.cur[0].arn, null)
}

output "cur_export_arn" {
  description = "ARN of the CUR 2.0 data export. Null when no export is created in this account."
  value       = try(aws_bcmdataexports_export.cur[0].arn, null)
}
