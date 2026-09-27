# Spike AWS Onboarding - Terraform module

Terraform module that connects your AWS environment to **Spike** by Directeam.

It creates the `DirecteamSpikeReadOnlyAccess` IAM role that Spike assumes (with your External ID) to read
cost, usage, and resource metadata, and optionally a CUR 2.0 data export that Spike reads billing data from.
You can install it on a whole AWS Organization, on selected linked accounts, or on individual accounts.

## Choose how to install

| You want to onboard | Run from | `deployment_mode` | Example |
| --- | --- | --- | --- |
| The whole organization (current and future accounts) | Management account | `organization` | [`examples/organization`](examples/organization) |
| The management account plus specific linked accounts | Management account | `organization` + `member_account_ids` | [`examples/organization-selected-accounts`](examples/organization-selected-accounts) |
| Specific OUs | Management account | `organization` + `organizational_unit_ids` | see [Target specific OUs](#target-specific-ous) |
| One account (standalone, or a linked account on its own) | That account | `account` | [`examples/single-account`](examples/single-account) |
| Several linked accounts without using the management account | Each account (provider aliases) | `account` | [`examples/multiple-accounts`](examples/multiple-accounts) |

## Quick start

1. Get your **External ID** and **Directeam ID** from the Spike onboarding screen.
2. Create a new folder with a `main.tf`:

   ```hcl
   provider "aws" {
     region = "us-east-1"
   }

   module "spike" {
     source = "git::https://github.com/directeam-io/terraform-spike-aws-onboarding.git?ref=v1.0.0"

     external_id     = "<external-id-from-spike>"
     directeam_id    = "<directeam-id-from-spike>"
     deployment_mode = "organization" # or "account"
   }
   ```

3. Run it with credentials for the management account (organization mode) or the target account (account mode):

   ```bash
   terraform init
   terraform apply
   ```

Spike is notified automatically when `apply` finishes, and onboarding completes in the Spike console.

## What gets created

**In the account you run Terraform in** (skipped for the role and CUR export when `stackset_call_as = "DELEGATED_ADMIN"`):

| Resource | Name | Purpose |
| --- | --- | --- |
| IAM role | `DirecteamSpikeReadOnlyAccess` | Assumed by Spike. Trusts only Directeam's `DirecteamAccessDelegator` roles, and only with your External ID. Max session 1 hour. |
| IAM managed policies | `DirecteamSpikeReadOnlyAccess-*` | Read-only permissions, split across several policies to stay within IAM size limits. See [`policies/`](policies). |
| S3 bucket (organization mode) | `dt-cur-<account-id>` | Receives the CUR 2.0 export. Public access blocked, SSE-S3 encryption, TLS-only, bucket-owner-enforced. Spike's `DirecteamCurDataAccess` role can only list and read. |
| CUR 2.0 data export (organization mode) | `dt-cur-parquet-<account-id>` | Hourly, resource-level Parquet export. |
| CloudFormation stack | `DirecteamSpikeRegistration` | Notifies Spike that onboarding finished (disable with `notify_spike = false`). |

**In member accounts** (organization mode only), through a service-managed CloudFormation StackSet named
`DirecteamSpikeReadOnlyAccess`: the same role and read-only policies. Member stacks are created in `us-east-1`
(IAM is global, so one region is enough).

All permissions are read-only, except the optional `enable_log_management` policy, which lets Spike turn on
S3 access logs and VPC flow logs.

## Prerequisites

- Terraform `>= 1.5` (or OpenTofu `>= 1.6`) and the AWS provider `>= 6.0`.
- **Organization mode:**
  - Run from the organization **management account**, or from a
    [CloudFormation StackSets delegated administrator](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/stacksets-orgs-delegated-admin.html)
    with `stackset_call_as = "DELEGATED_ADMIN"`.
  - Trusted access for CloudFormation StackSets must be enabled in AWS Organizations (CloudFormation console >
    StackSets > **Activate trusted access**, or
    `aws organizations enable-aws-service-access --service-principal member.org.stacksets.cloudformation.amazonaws.com`).
- The credentials running Terraform need permissions to manage IAM roles and policies, CloudFormation stacks and
  StackSets, S3 buckets, BCM Data Exports, and to read AWS Organizations.

The AWS provider can be configured for any region. The module pins the resources that must live in
`us-east-1` (CUR bucket and export, registration stack, member stacks) on its own.

## Usage

### Whole organization

```hcl
module "spike" {
  source = "git::https://github.com/directeam-io/terraform-spike-aws-onboarding.git?ref=v1.0.0"

  external_id     = "<external-id-from-spike>"
  directeam_id    = "<directeam-id-from-spike>"
  deployment_mode = "organization"
}
```

The organization root is discovered automatically and accounts that join later are onboarded automatically
(`auto_deployment = true`).

### Selected linked accounts only

```hcl
module "spike" {
  source = "git::https://github.com/directeam-io/terraform-spike-aws-onboarding.git?ref=v1.0.0"

  external_id     = "<external-id-from-spike>"
  directeam_id    = "<directeam-id-from-spike>"
  deployment_mode = "organization"

  member_account_ids = ["111111111111", "222222222222"]
}
```

Only the listed accounts (plus the management account) receive the role. Automatic deployment is turned off in
this mode so new accounts never receive the role unless you add them to the list.

### Target specific OUs

```hcl
module "spike" {
  source = "git::https://github.com/directeam-io/terraform-spike-aws-onboarding.git?ref=v1.0.0"

  external_id     = "<external-id-from-spike>"
  directeam_id    = "<directeam-id-from-spike>"
  deployment_mode = "organization"

  organizational_unit_ids = ["ou-ab12-11111111", "ou-ab12-22222222"]
}
```

`organizational_unit_ids` and `member_account_ids` can be combined: the role is deployed only to the listed
accounts that are inside the listed OUs.

### Management account with billing-only access

If your management account doesn't run workloads, you can give Spike only billing, Organizations, CloudFormation,
and commitment (RI / Savings Plans) data there. Member accounts still get the full read-only role.

```hcl
module "spike" {
  source = "git::https://github.com/directeam-io/terraform-spike-aws-onboarding.git?ref=v1.0.0"

  external_id       = "<external-id-from-spike>"
  directeam_id      = "<directeam-id-from-spike>"
  deployment_mode   = "organization"
  role_access_level = "limited"
}
```

### Single account

```hcl
module "spike" {
  source = "git::https://github.com/directeam-io/terraform-spike-aws-onboarding.git?ref=v1.0.0"

  external_id     = "<external-id-from-spike>"
  directeam_id    = "<directeam-id-from-spike>"
  deployment_mode = "account"

  # Only for standalone accounts that are not part of an AWS Organization.
  enable_cur_export = true
}
```

Don't use account mode on an account that already receives the role from the organization StackSet; the role
name is the same in both cases and the second deployment will fail.

## Updating and removing

- **Update:** bump `ref` in `source` and run `terraform apply`. Member accounts are updated through the StackSet.
- **Change targets:** editing `organizational_unit_ids` or `member_account_ids` re-deploys the StackSet instances,
  which briefly removes and recreates the role in the targeted member accounts.
- **Remove:** `terraform destroy` removes the role from every account and notifies Spike. The CUR bucket is kept if
  it still contains data, unless `cur_bucket_force_destroy = true`.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |

### Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |

### Resources

| Name | Type |
|------|------|
| [aws_bcmdataexports_export.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bcmdataexports_export) | resource |
| [aws_cloudformation_stack.registration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack) | resource |
| [aws_cloudformation_stack_set.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack_set) | resource |
| [aws_cloudformation_stack_set_instance.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack_set_instance) | resource |
| [aws_iam_policy.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_s3_bucket.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_ownership_controls.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_auto_deployment"></a> [auto\_deployment](#input\_auto\_deployment) | Automatically deploy the Spike role to accounts that join the targeted OUs later. Ignored (forced off) when member\_account\_ids is set. | `bool` | `true` | no |
| <a name="input_cur_bucket_force_destroy"></a> [cur\_bucket\_force\_destroy](#input\_cur\_bucket\_force\_destroy) | Allow Terraform to delete the CUR bucket even when it still contains report data. Leave false in production. | `bool` | `false` | no |
| <a name="input_deployment_mode"></a> [deployment\_mode](#input\_deployment\_mode) | How Spike is installed:<br/>- "organization": run from the AWS Organizations management account (or a CloudFormation StackSets delegated administrator).<br/>  Creates the Spike role in the current account and deploys it to member accounts through a service-managed StackSet.<br/>- "account": create the Spike role in the current account only. Use this for standalone accounts, or for individual<br/>  linked accounts when you don't want to (or can't) deploy from the management account. | `string` | n/a | yes |
| <a name="input_directeam_id"></a> [directeam\_id](#input\_directeam\_id) | Your Directeam customer ID, provided by Spike. Used to link this deployment to your Spike tenant. | `string` | n/a | yes |
| <a name="input_enable_cloudwatch_logs_read_access"></a> [enable\_cloudwatch\_logs\_read\_access](#input\_enable\_cloudwatch\_logs\_read\_access) | Allow Spike to read CloudWatch Logs content (log events, Logs Insights queries, live tail). CloudWatch metrics access is not affected. | `bool` | `true` | no |
| <a name="input_enable_cur_export"></a> [enable\_cur\_export](#input\_enable\_cur\_export) | Create an S3 bucket and a CUR 2.0 (Parquet) data export that Spike reads cost data from.<br/>Defaults to true in "organization" mode (the management account sees the whole organization's costs) and false in<br/>"account" mode. | `bool` | `null` | no |
| <a name="input_enable_eks_read_access"></a> [enable\_eks\_read\_access](#input\_enable\_eks\_read\_access) | Allow Spike read-only access to the Kubernetes API of your EKS clusters (eks:AccessKubernetesApi). The cluster access entries themselves are still controlled by you. | `bool` | `false` | no |
| <a name="input_enable_log_management"></a> [enable\_log\_management](#input\_enable\_log\_management) | Allow Spike to configure S3 server access logging and VPC flow logs, delivered to a dt-logs-<account-id> bucket. | `bool` | `false` | no |
| <a name="input_external_id"></a> [external\_id](#input\_external\_id) | External ID provided by Spike. Required in every sts:AssumeRole call Spike makes into your accounts. | `string` | n/a | yes |
| <a name="input_member_account_ids"></a> [member\_account\_ids](#input\_member\_account\_ids) | Deploy the Spike role ONLY to these member accounts (they must belong to organizational\_unit\_ids).<br/>Leave empty to deploy to every account in the targeted OUs. When set, automatic deployment to new accounts is<br/>disabled so accounts outside this list never receive the role. | `list(string)` | `[]` | no |
| <a name="input_notification_timeout"></a> [notification\_timeout](#input\_notification\_timeout) | Seconds CloudFormation waits for Spike to acknowledge a registration notification. | `number` | `300` | no |
| <a name="input_notification_topic_arn"></a> [notification\_topic\_arn](#input\_notification\_topic\_arn) | Spike onboarding SNS topic. Don't change unless instructed by Spike. | `string` | `"arn:aws:sns:us-east-1:250260913666:directeam-onboarding-topic-f7a69a4b"` | no |
| <a name="input_notify_spike"></a> [notify\_spike](#input\_notify\_spike) | Notify Spike when the deployment finishes so onboarding completes automatically. Uses a CloudFormation custom resource backed by Spike's SNS topic. | `bool` | `true` | no |
| <a name="input_organizational_unit_ids"></a> [organizational\_unit\_ids](#input\_organizational\_unit\_ids) | IDs of the organization root (r-xxxx) or OUs (ou-xxxx-xxxxxxxx) to deploy the Spike role to. Leave empty to target the whole organization (the root is discovered automatically). | `list(string)` | `[]` | no |
| <a name="input_retain_stacks_on_account_removal"></a> [retain\_stacks\_on\_account\_removal](#input\_retain\_stacks\_on\_account\_removal) | Keep the Spike role in accounts that leave the targeted OUs. Only applies when automatic deployment is on. | `bool` | `false` | no |
| <a name="input_role_access_level"></a> [role\_access\_level](#input\_role\_access\_level) | Permission set for the role created in the current account.<br/>- "full": read-only access to resource metadata, billing, cost, and usage data (default).<br/>- "limited": billing, AWS Organizations, CloudFormation, and commitment (RI / Savings Plans) data only. Typically used<br/>  in management accounts that don't run workloads. The enable\_*\_access and enable\_log\_management options don't<br/>  apply to this level.<br/>Member accounts that receive the role through the StackSet always get the "full" permission set. | `string` | `"full"` | no |
| <a name="input_stackset_call_as"></a> [stackset\_call\_as](#input\_stackset\_call\_as) | Set to "DELEGATED\_ADMIN" when running from a CloudFormation StackSets delegated administrator account instead of the management account. In that case the role is only deployed through the StackSet, and no role or CUR export is created in the current account. | `string` | `"SELF"` | no |
| <a name="input_stackset_failure_tolerance_percentage"></a> [stackset\_failure\_tolerance\_percentage](#input\_stackset\_failure\_tolerance\_percentage) | Percentage of accounts that can fail before the StackSet stops the operation. | `number` | `0` | no |
| <a name="input_stackset_max_concurrent_percentage"></a> [stackset\_max\_concurrent\_percentage](#input\_stackset\_max\_concurrent\_percentage) | Maximum percentage of accounts the StackSet deploys to at the same time. | `number` | `100` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags for every resource this module creates (including the resources deployed to member accounts). | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
|------|-------------|
| <a name="output_cur_bucket_arn"></a> [cur\_bucket\_arn](#output\_cur\_bucket\_arn) | ARN of the CUR 2.0 bucket. Null when the export is disabled. |
| <a name="output_cur_bucket_name"></a> [cur\_bucket\_name](#output\_cur\_bucket\_name) | S3 bucket that receives the CUR 2.0 export. Null when the export is disabled. |
| <a name="output_cur_export_arn"></a> [cur\_export\_arn](#output\_cur\_export\_arn) | ARN of the CUR 2.0 data export. Null when the export is disabled. |
| <a name="output_member_account_ids"></a> [member\_account\_ids](#output\_member\_account\_ids) | Member accounts that received the Spike role through the StackSet. |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | ARN of the Spike role in the current account. Null when running as a StackSets delegated administrator. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | Name of the Spike role, identical in every account it's deployed to. |
| <a name="output_stack_set_id"></a> [stack\_set\_id](#output\_stack\_set\_id) | ID of the StackSet that deploys the Spike role to member accounts. Null in account mode. |
| <a name="output_stack_set_name"></a> [stack\_set\_name](#output\_stack\_set\_name) | Name of the StackSet that deploys the Spike role to member accounts. Null in account mode. |
| <a name="output_target_organizational_unit_ids"></a> [target\_organizational\_unit\_ids](#output\_target\_organizational\_unit\_ids) | Organization root or OU IDs targeted by the StackSet. |
<!-- END_TF_DOCS -->
