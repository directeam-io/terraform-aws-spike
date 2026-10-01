# Spike AWS Onboarding - Terraform module

Terraform module that connects your AWS environment to **Spike** by Directeam.

It creates the `DirecteamFinOpsReadOnlyAccess` IAM role that Spike assumes (with your External ID) to read
cost, usage, and resource metadata, and a CUR 2.0 data export (created once, in the management account) that Spike
reads billing data from.
You can install it on a whole AWS Organization, on selected linked accounts, or on individual accounts.

## Choose how to install

| You want to onboard | Run from | `deployment_mode` | Example |
| --- | --- | --- | --- |
| The whole organization (current and future accounts) | Management account | `organization` | [`examples/organization`](examples/organization) |
| The management account plus specific linked accounts | Management account | `organization` + `member_account_ids` | [`examples/organization-selected-accounts`](examples/organization-selected-accounts) |
| Specific OUs | Management account | `organization` + `organizational_unit_ids` | see [Target specific OUs](#target-specific-ous) |
| One account (standalone, or a linked account on its own) | That account | `account` | [`examples/single-account`](examples/single-account) |
| The whole organization from a StackSets delegated administrator | Delegated administrator account | `organization` + `stackset_call_as` | see [Delegated administrator](#delegated-administrator) |
| Several linked accounts without using the management account | Each account (provider aliases) | `account` | [`examples/multiple-accounts`](examples/multiple-accounts) |

## Quick start

1. From the Spike onboarding screen, install the generated `DirecteamTerraformBootstrap` stack. Skip this step when `DirecteamFinOpsStackSet` or `DirecteamFinOpsReadOnlyAccess` already exists.
2. Create a new folder with a `main.tf`:

   ```hcl
   provider "aws" {
     region = "us-east-1"
   }

   module "spike" {
     source  = "directeam-io/spike/aws"
     version = "1.2.1"

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

**In the account you run Terraform in** (the role and CUR export are skipped when `stackset_call_as = "DELEGATED_ADMIN"`):

| Resource | Name | Purpose |
| --- | --- | --- |
| IAM role | `DirecteamFinOpsReadOnlyAccess` | Assumed by Spike. Trusts only Directeam's `DirecteamAccessDelegator` roles, and only with your External ID. Max session 1 hour. |
| IAM managed policies | `DirecteamFinOpsReadOnlyAccess-*` | Read-only permissions, split across several policies to stay within IAM size limits. See [`policies/`](policies). |
| S3 bucket (organization mode, or `enable_cur_export`) | `dt-cur-<account-id>` | Receives the CUR 2.0 export. Public access blocked, customer-managed KMS encryption, versioned, TLS-only, bucket-owner-enforced. Spike's `DirecteamCurDataAccess` role can only list, read, and decrypt. |
| CUR 2.0 data export (organization mode, or `enable_cur_export`) | `dt-cur-parquet-<account-id>` | Hourly, resource-level Parquet export. |
| CloudFormation stack | `DirecteamFinOpsRegistration` | Notifies Spike that onboarding finished (disable with `notify_spike = false`). |

**In member accounts** (organization mode only), a service-managed CloudFormation StackSet named
`DirecteamFinOpsReadOnlyAccess` deploys the role and read-only policies. Optional Bedrock invocation logging uses a
separate `DirecteamBedrockInvocationLogs` StackSet so it can coexist with an existing CloudFormation-owned role.

**Optionally, Bedrock invocation logs** only in the accounts and regions that use Bedrock - see
[Bedrock invocation logs](#bedrock-invocation-logs).

Every feature works the same in account mode: accounts outside an organization, or customers without management
account access, get the same resources deployed directly by Terraform instead of through the StackSet.

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
- `python3` and the AWS CLI on the machine running Terraform are required for onboarding identity discovery, and
  for Bedrock usage discovery when no explicit account map is provided.
- Install the Spike-generated `DirecteamTerraformBootstrap` stack before the first Terraform run. If the matching
  `DirecteamFinOpsStackSet` or `DirecteamFinOpsReadOnlyAccess` stack already exists, Terraform reads the identity from
  that stack instead and preserves its resources.
- The credentials running Terraform need permissions to manage IAM roles and policies, CloudFormation stacks and
  StackSets, S3 buckets, BCM Data Exports, and to read AWS Organizations.
- By default, the module detects a successful `DirecteamFinOpsStackSet` or `DirecteamFinOpsReadOnlyAccess`
  CloudFormation stack and preserves its role, StackSet, CUR, and registration resources. Set
  `base_onboarding_mode = "create"` to disable detection, or `"existing"` to require the CloudFormation stack.

The AWS provider can be configured for any region. The module pins the resources that must live in
`us-east-1` (CUR bucket and export, registration stack, member stacks) on its own.

## Usage

### Whole organization

```hcl
module "spike" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode = "organization"
}
```

The organization root is discovered automatically and accounts that join later are onboarded automatically
(`auto_deployment = true`).

### Selected linked accounts only

```hcl
module "spike" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode = "organization"

  member_account_ids = ["111111111111", "222222222222"]
}
```

Only the listed accounts (plus the management account) receive the role. The StackSet uses an `INTERSECTION` filter,
so automatic deployment still never gives the role to an account unless you add it to the list.

### Target specific OUs

```hcl
module "spike" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

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
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode   = "organization"
  role_access_level = "limited"
}
```

### Single account

```hcl
module "spike" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode = "account"

  # Only for a standalone account, or the management account. Linked accounts are covered by the management
  # account's export.
  # enable_cur_export = true
}
```

Don't use account mode on an account that already receives the role from the organization StackSet; the role
name is the same in both cases and the second deployment will fail.

### Delegated administrator

Run from a StackSets delegated administrator account to deploy the role to the organization's member accounts, without
using the management account for that:

```hcl
module "spike" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode  = "organization"
  stackset_call_as = "DELEGATED_ADMIN"
}
```

StackSets never deploy to the management account, and only the management account can export the whole
organization's costs. So install the management account separately, from that account:

```hcl
module "spike_management" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode   = "account"
  enable_cur_export = true
}
```

Bedrock invocation logs can't be discovered automatically from a delegated administrator; set
`bedrock_invocation_logs_accounts` explicitly.

### Bedrock invocation logs

Lets Spike attribute Amazon Bedrock usage to individual calls: model, caller, and token counts. Turn it on with one
flag. The module finds where Bedrock is used from AWS Cost Explorer while planning, so buckets are only created in
accounts and regions with Bedrock spend and nothing needs to be listed:

```hcl
module "spike" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode = "organization"

  enable_bedrock_invocation_logs = true
}
```

Set `enable_bedrock_invocation_logs = false` to remove the feature everywhere.

**How discovery works.** `terraform plan` runs `scripts/discover_bedrock_usage.py`, which queries Cost Explorer for
Bedrock spend per account and region over the last `bedrock_invocation_logs_lookback_days` days (default 90).
Run from the management account it sees every account in the organization (narrowed by `member_account_ids` if set);
in account mode it sees the current account. Things to know:

- Requires `python3` and the AWS CLI on the machine running Terraform, using the same credentials as the AWS provider
  (`ce:GetCostAndUsage` and `sts:GetCallerIdentity`). The script stops with an error if those credentials belong to a
  different account than the provider, for example when the provider uses `assume_role`.
- Cost Explorer must be enabled, and data appears up to 24 hours after usage. A brand new Bedrock workload is picked up
  by a later `terraform apply`.
- The result is re-evaluated on every plan. A newly detected account/region gets a bucket; one with no Bedrock spend in
  the lookback window loses its logging and bucket (and the stored logs, which are only a rolling copy for Spike).
- Each run makes a few Cost Explorer API calls (about $0.01 each).
- Not available as a StackSets delegated administrator (Cost Explorer only shows that account's own spend), where you
  must set the map below.

**Setting the list yourself.** To pin the list, when Cost Explorer or the AWS CLI isn't available to Terraform, or to
include a region that hasn't been billed yet, set the map. Discovery is skipped. In account mode, pass the same map to
every module instance; each account only uses its own entry:

```hcl
  bedrock_invocation_logs_accounts = {
    "111111111111" = ["us-east-1"]
    "222222222222" = ["us-east-1", "eu-west-1"]
  }
```

**Existing core onboarding.** When `DirecteamFinOpsStackSet` or `DirecteamFinOpsReadOnlyAccess` already exists, the module automatically preserves it, reads its onboarding identity, and adds only the selected optional resources. No core-control flag is needed:

```hcl
module "spike_bedrock_logs" {
  source  = "directeam-io/spike/aws"
  version = "1.2.1"

  deployment_mode = "account"

  enable_bedrock_invocation_logs = true
  bedrock_invocation_logs_accounts = {
    "111111111111" = ["us-east-1", "eu-west-1"]
  }
}
```

Bedrock can only deliver logs to a bucket in the same account and region, so each account/region pair with Bedrock usage gets a
`dt-bedrock-invocation-logs-<account-id>-<region>` bucket, and Spike reads it through its role in that account. Logs
are written under `invocation-logs/AWSLogs/<account-id>/BedrockModelInvocationLogs/<region>/`.

| | Details |
| --- | --- |
| What is logged | Metadata only: model, caller identity, token counts. Prompts, responses, embeddings, images, and video are never delivered. |
| Who can read it | Only the `DirecteamFinOpsReadOnlyAccess` role in the same account, through a `BedrockInvocationLogsRead-<region>` inline policy scoped to that one bucket. |
| Retention | Buckets use rotating customer-managed KMS keys and versioning. Current and noncurrent objects expire after `bedrock_invocation_logs_retention_days` (default 30). |
| Account you run Terraform in (and account mode) | Configured directly by Terraform. **This replaces any invocation logging configuration you already have in the regions that use Bedrock.** |
| Member accounts (organization mode) | Deployed through the separate `DirecteamBedrockInvocationLogs` StackSet. Each member stack checks the account/region map and only creates logging resources where Bedrock is used. A small Lambda configures logging, publishes account/Region lifecycle status to Directeam, and **leaves customer-owned invocation logging unchanged**. |
| Removal | Logging is turned off and the buckets are emptied and deleted. Configurations you created yourself are never touched. |

Regions must be enabled in the corresponding accounts. Nothing is uploaded to your accounts to deploy the StackSet:
the Bedrock template is sent inline. Terraform validates CloudFormation's 51,200-byte inline-template limit and fails
planning if the selected account/Region map exceeds it; narrow the map with `bedrock_invocation_logs_accounts`.

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
| <a name="requirement_external"></a> [external](#requirement\_external) | >= 2.3 |

### Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |
| <a name="provider_external"></a> [external](#provider\_external) | >= 2.3 |

### Resources

| Name | Type |
|------|------|
| [aws_bcmdataexports_export.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bcmdataexports_export) | resource |
| [aws_bedrock_model_invocation_logging_configuration.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_model_invocation_logging_configuration) | resource |
| [aws_cloudformation_stack.bedrock_registration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack) | resource |
| [aws_cloudformation_stack.registration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack) | resource |
| [aws_cloudformation_stack_instances.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack_instances) | resource |
| [aws_cloudformation_stack_set.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack_set) | resource |
| [aws_cloudformation_stack_set.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack_set) | resource |
| [aws_cloudformation_stack_set_instance.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack_set_instance) | resource |
| [aws_iam_policy.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.bedrock_logs_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.spike](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_ownership_controls.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.bedrock_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.cur](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_auto_deployment"></a> [auto\_deployment](#input\_auto\_deployment) | Automatically deploy the Spike role to eligible accounts that join the targeted OUs later. When member\_account\_ids is set, only listed accounts are eligible. | `bool` | `true` | no |
| <a name="input_base_onboarding_mode"></a> [base\_onboarding\_mode](#input\_base\_onboarding\_mode) | Controls ownership of the existing Directeam read-only onboarding resources.<br/>- "auto": detect the matching CloudFormation stack and preserve it when present.<br/>- "create": always create and manage the base role, StackSet, CUR, and registration with Terraform. Identity is read from DirecteamTerraformBootstrap unless compatibility inputs are provided.<br/>- "existing": require the base onboarding to exist and manage only optional Terraform features such as Bedrock logs. | `string` | `"auto"` | no |
| <a name="input_bedrock_invocation_logs_accounts"></a> [bedrock\_invocation\_logs\_accounts](#input\_bedrock\_invocation\_logs\_accounts) | Optional override for the accounts and regions that get Bedrock invocation logging, as a map of account ID to<br/>region list. Leave null (default) to discover them automatically from AWS Cost Explorer at plan time: the module<br/>then looks for Bedrock spend in the last bedrock\_invocation\_logs\_lookback\_days days. Set it to pin the list, for<br/>example when Cost Explorer or the AWS CLI isn't available to Terraform, when running as a delegated administrator,<br/>or to add a region that hasn't been billed yet. An empty map deploys nothing.<br/>A dt-bedrock-invocation-logs-<account-id>-<region> bucket is created only for the resulting account/region pairs, readable only<br/>by the Spike role in that account. The buckets only hold a rolling copy for Spike to collect, and are deleted with<br/>their contents when the feature is turned off or an account/region stops using Bedrock. | `map(list(string))` | `null` | no |
| <a name="input_bedrock_invocation_logs_lookback_days"></a> [bedrock\_invocation\_logs\_lookback\_days](#input\_bedrock\_invocation\_logs\_lookback\_days) | How many days of AWS Cost Explorer data are searched for Bedrock usage when bedrock\_invocation\_logs\_accounts is null. Accounts and regions without Bedrock spend in this window stop being logged. | `number` | `90` | no |
| <a name="input_bedrock_invocation_logs_retention_days"></a> [bedrock\_invocation\_logs\_retention\_days](#input\_bedrock\_invocation\_logs\_retention\_days) | Days Bedrock invocation logs are kept in each account before they expire. | `number` | `30` | no |
| <a name="input_cur_bucket_force_destroy"></a> [cur\_bucket\_force\_destroy](#input\_cur\_bucket\_force\_destroy) | Allow Terraform to delete the CUR bucket even when it still contains report data. Leave false in production. | `bool` | `false` | no |
| <a name="input_deployment_mode"></a> [deployment\_mode](#input\_deployment\_mode) | How Spike is installed:<br/>- "organization": run from the AWS Organizations management account (or a CloudFormation StackSets delegated administrator).<br/>  Creates the Spike role in the current account and deploys it to member accounts through a service-managed StackSet.<br/>- "account": create the Spike role in the current account only. Use this for standalone accounts, or for individual<br/>  linked accounts when you don't want to (or can't) deploy from the management account. | `string` | n/a | yes |
| <a name="input_directeam_id"></a> [directeam\_id](#input\_directeam\_id) | Optional compatibility fallback for the Directeam customer ID. By default, the module reads it from existing Directeam onboarding or the DirecteamTerraformBootstrap stack. | `string` | `null` | no |
| <a name="input_enable_bedrock_invocation_logs"></a> [enable\_bedrock\_invocation\_logs](#input\_enable\_bedrock\_invocation\_logs) | Collect Amazon Bedrock invocation logs for Spike, only in the accounts and regions that use Bedrock. Logs contain<br/>metadata only (model, caller identity, token counts); prompts, responses, and embeddings are never delivered.<br/>Where Bedrock is used is found automatically from AWS Cost Explorer, unless bedrock\_invocation\_logs\_accounts is set.<br/>- Current account: logging is configured directly and REPLACES any existing invocation logging configuration in<br/>  its regions that use Bedrock.<br/>- Member accounts (organization mode): deployed by a separate Bedrock-only StackSet. Account/region pairs that<br/>  already have invocation logging configured are left unchanged and skipped. | `bool` | `false` | no |
| <a name="input_enable_cloudwatch_logs_read_access"></a> [enable\_cloudwatch\_logs\_read\_access](#input\_enable\_cloudwatch\_logs\_read\_access) | Allow Spike to read CloudWatch Logs content (log events, Logs Insights queries, live tail). CloudWatch metrics access is not affected. | `bool` | `true` | no |
| <a name="input_enable_cur_export"></a> [enable\_cur\_export](#input\_enable\_cur\_export) | Create an S3 bucket and a CUR 2.0 (Parquet) data export that Spike reads cost data from. Spike needs it once, from<br/>the management account, because it sees the costs of every account.<br/>- deployment\_mode = "organization": on by default in the management account; set false to disable it. Not created<br/>  when running as a delegated administrator; install the management account with deployment\_mode = "account" and<br/>  enable\_cur\_export = true instead.<br/>- deployment\_mode = "account": off by default, since a linked account's export only contains its own costs. Set it<br/>  to true for the management account or for a standalone account that isn't part of an AWS Organization. | `bool` | `null` | no |
| <a name="input_enable_eks_read_access"></a> [enable\_eks\_read\_access](#input\_enable\_eks\_read\_access) | Allow Spike read-only access to the Kubernetes API of your EKS clusters (eks:AccessKubernetesApi). The cluster access entries themselves are still controlled by you. | `bool` | `false` | no |
| <a name="input_enable_log_management"></a> [enable\_log\_management](#input\_enable\_log\_management) | Allow Spike to configure S3 server access logging and VPC flow logs, delivered to a dt-logs-<account-id> bucket. | `bool` | `false` | no |
| <a name="input_external_id"></a> [external\_id](#input\_external\_id) | Optional compatibility fallback for the Spike External ID. By default, the module reads it from existing Directeam onboarding or the DirecteamTerraformBootstrap stack. | `string` | `null` | no |
| <a name="input_member_account_ids"></a> [member\_account\_ids](#input\_member\_account\_ids) | Deploy the Spike role ONLY to these member accounts (they must belong to organizational\_unit\_ids).<br/>Leave empty to deploy to every account in the targeted OUs. The StackSet uses an INTERSECTION filter so accounts<br/>outside this list never receive the role, including when automatic deployment is enabled. | `list(string)` | `[]` | no |
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
| <a name="output_base_onboarding_created"></a> [base\_onboarding\_created](#output\_base\_onboarding\_created) | Whether this module creates the base read-only onboarding resources. |
| <a name="output_base_onboarding_source"></a> [base\_onboarding\_source](#output\_base\_onboarding\_source) | Whether base read-only onboarding remains CloudFormation-owned or is managed by Terraform. |
| <a name="output_bedrock_invocation_log_buckets"></a> [bedrock\_invocation\_log\_buckets](#output\_bedrock\_invocation\_log\_buckets) | Bedrock invocation log bucket in the current account, by region. |
| <a name="output_bedrock_invocation_logs_accounts"></a> [bedrock\_invocation\_logs\_accounts](#output\_bedrock\_invocation\_logs\_accounts) | Accounts and regions where Bedrock invocation logging is deployed for Spike. |
| <a name="output_bedrock_stack_set_id"></a> [bedrock\_stack\_set\_id](#output\_bedrock\_stack\_set\_id) | ID of the Bedrock-only StackSet. Null when no member-account Bedrock logging is deployed. |
| <a name="output_bedrock_stack_set_name"></a> [bedrock\_stack\_set\_name](#output\_bedrock\_stack\_set\_name) | Name of the Bedrock-only StackSet. Null when no member-account Bedrock logging is deployed. |
| <a name="output_cur_bucket_arn"></a> [cur\_bucket\_arn](#output\_cur\_bucket\_arn) | ARN of the CUR 2.0 bucket. Null when no export is created in this account. |
| <a name="output_cur_bucket_name"></a> [cur\_bucket\_name](#output\_cur\_bucket\_name) | S3 bucket that receives the CUR 2.0 export. Null when no export is created in this account. |
| <a name="output_cur_export_arn"></a> [cur\_export\_arn](#output\_cur\_export\_arn) | ARN of the CUR 2.0 data export. Null when no export is created in this account. |
| <a name="output_existing_onboarding_stack_name"></a> [existing\_onboarding\_stack\_name](#output\_existing\_onboarding\_stack\_name) | Detected or declared existing CloudFormation onboarding stack name. |
| <a name="output_member_account_ids"></a> [member\_account\_ids](#output\_member\_account\_ids) | Member accounts that received the Spike role through the StackSet. |
| <a name="output_onboarding_identity_source"></a> [onboarding\_identity\_source](#output\_onboarding\_identity\_source) | Whether onboarding identity came from CloudFormation stack parameters or compatibility input variables. |
| <a name="output_onboarding_identity_stack_name"></a> [onboarding\_identity\_stack\_name](#output\_onboarding\_identity\_stack\_name) | CloudFormation stack that supplied the Directeam customer and External IDs. |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | ARN of the Spike role in the current account. Null when running as a StackSets delegated administrator. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | Name of the Spike role, identical in every account it's deployed to. |
| <a name="output_stack_set_id"></a> [stack\_set\_id](#output\_stack\_set\_id) | ID of the StackSet that deploys the Spike role to member accounts. Null in account mode. |
| <a name="output_stack_set_name"></a> [stack\_set\_name](#output\_stack\_set\_name) | Name of the StackSet that deploys the Spike role to member accounts. Null in account mode. |
| <a name="output_target_organizational_unit_ids"></a> [target\_organizational\_unit\_ids](#output\_target\_organizational\_unit\_ids) | Organization root or OU IDs targeted by the StackSet. |
<!-- END_TF_DOCS -->
