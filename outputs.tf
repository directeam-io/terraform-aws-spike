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

output "cur_bucket_name" {
  description = "S3 bucket that receives the CUR 2.0 export. Null when the export is disabled."
  value       = try(aws_s3_bucket.cur[0].id, null)
}

output "cur_bucket_arn" {
  description = "ARN of the CUR 2.0 bucket. Null when the export is disabled."
  value       = try(aws_s3_bucket.cur[0].arn, null)
}

output "cur_export_arn" {
  description = "ARN of the CUR 2.0 data export. Null when the export is disabled."
  value       = try(aws_bcmdataexports_export.cur[0].arn, null)
}
