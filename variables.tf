################################################################################
# Spike onboarding identity
################################################################################

variable "external_id" {
  description = "Optional compatibility fallback for the Spike External ID. By default, the module reads it from existing Directeam onboarding or the DirecteamTerraformBootstrap stack."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.external_id == null ? true : length(var.external_id) >= 2 && length(var.external_id) <= 1224
    error_message = "external_id must be null or between 2 and 1224 characters."
  }

  validation {
    condition     = var.external_id == null ? true : can(regex("^[\\w+=,.@:/-]+$", var.external_id))
    error_message = "external_id may only contain alphanumeric characters and any of: +=,.@:/-"
  }
}

variable "directeam_id" {
  description = "Optional compatibility fallback for the Directeam customer ID. By default, the module reads it from existing Directeam onboarding or the DirecteamTerraformBootstrap stack."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.directeam_id == null ? true : length(var.directeam_id) >= 2 && length(var.directeam_id) <= 1224
    error_message = "directeam_id must be null or between 2 and 1224 characters."
  }
}

variable "deployment_mode" {
  description = <<-EOT
    How Spike is installed:
    - "organization": run from the AWS Organizations management account (or a CloudFormation StackSets delegated administrator).
      Creates the Spike role in the current account and deploys it to member accounts through a service-managed StackSet.
    - "account": create the Spike role in the current account only. Use this for standalone accounts, or for individual
      linked accounts when you don't want to (or can't) deploy from the management account.
  EOT
  type        = string

  validation {
    condition     = contains(["organization", "account"], var.deployment_mode)
    error_message = "deployment_mode must be either \"organization\" or \"account\"."
  }
}

variable "base_onboarding_mode" {
  description = <<-EOT
    Controls ownership of the existing Directeam read-only onboarding resources.
    - "auto": detect the matching CloudFormation stack and preserve it when present.
    - "create": always create and manage the base role, StackSet, CUR, and registration with Terraform. Identity is read from DirecteamTerraformBootstrap unless compatibility inputs are provided.
    - "existing": require the base onboarding to exist and manage only optional Terraform features such as Bedrock logs.
  EOT
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "create", "existing"], var.base_onboarding_mode)
    error_message = "base_onboarding_mode must be auto, create, or existing."
  }
}

variable "update_spike_stack" {
  description = <<-EOT
    Keep the existing Spike CloudFormation onboarding stack (DirecteamFinOpsStackSet or DirecteamFinOpsReadOnlyAccess)
    on the Spike template version released with this module version. On apply, the detected stack is updated through
    a change set with its current parameters; the stack stays CloudFormation-owned and is never deleted by Terraform.
    Upgrading the module later updates the stack to the newer template version. Updates that would delete, replace, or
    recreate core resources are refused without changing anything. Only applies when existing onboarding is detected.
    Requires spike_template_base_url.
  EOT
  type        = bool
  default     = false
}

variable "spike_template_base_url" {
  description = "Base URL of the Spike CloudFormation templates, provided by Directeam. Required when update_spike_stack is true."
  type        = string
  default     = null

  validation {
    condition     = var.spike_template_base_url == null || can(regex("^https://[^/\\s]+(/[^\\s]*)?$", var.spike_template_base_url))
    error_message = "spike_template_base_url must be an https:// URL."
  }
}

################################################################################
# Role permissions
################################################################################

variable "role_access_level" {
  description = <<-EOT
    Permission set for the role created in the current account.
    - "full": read-only access to resource metadata, billing, cost, and usage data (default).
    - "limited": billing, AWS Organizations, CloudFormation, and commitment (RI / Savings Plans) data only. Typically used
      in management accounts that don't run workloads. The enable_*_access and enable_log_management options don't
      apply to this level.
    Member accounts that receive the role through the StackSet always get the "full" permission set.
  EOT
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "limited"], var.role_access_level)
    error_message = "role_access_level must be either \"full\" or \"limited\"."
  }
}

variable "enable_cloudwatch_logs_read_access" {
  description = "Allow Spike to read CloudWatch Logs content (log events, Logs Insights queries, live tail). CloudWatch metrics access is not affected."
  type        = bool
  default     = true
}

variable "enable_eks_read_access" {
  description = "Allow Spike read-only access to the Kubernetes API of your EKS clusters (eks:AccessKubernetesApi). The cluster access entries themselves are still controlled by you."
  type        = bool
  default     = false
}

variable "enable_log_management" {
  description = "Allow Spike to configure S3 server access logging and VPC flow logs, delivered to a dt-logs-<account-id> bucket."
  type        = bool
  default     = false
}

################################################################################
# Bedrock invocation logs
################################################################################

variable "enable_bedrock_invocation_logs" {
  description = <<-EOT
    Collect Amazon Bedrock invocation logs for Spike, only in the accounts and regions that use Bedrock. Logs contain
    metadata only (model, caller identity, token counts); prompts, responses, and embeddings are never delivered.
    Where Bedrock is used is found automatically from AWS Cost Explorer, unless bedrock_invocation_logs_accounts is set.
    - Current account: logging is configured directly and REPLACES any existing invocation logging configuration in
      its regions that use Bedrock.
    - Member accounts (organization mode): deployed by a separate Bedrock-only StackSet. Account/region pairs that
      already have invocation logging configured are left unchanged and skipped.
  EOT
  type        = bool
  default     = false
}

variable "bedrock_invocation_logs_accounts" {
  description = <<-EOT
    Optional override for the accounts and regions that get Bedrock invocation logging, as a map of account ID to
    region list. Leave null (default) to discover them automatically from AWS Cost Explorer at plan time: the module
    then looks for Bedrock spend in the last bedrock_invocation_logs_lookback_days days. Set it to pin the list, for
    example when Cost Explorer or the AWS CLI isn't available to Terraform, when running as a delegated administrator,
    or to add a region that hasn't been billed yet. An empty map deploys nothing.
    A dt-bedrock-invocation-logs-<account-id>-<region> bucket is created only for the resulting account/region pairs, readable only
    by the Spike role in that account. The buckets only hold a rolling copy for Spike to collect, and are deleted with
    their contents when the feature is turned off or an account/region stops using Bedrock.
  EOT
  type        = map(list(string))
  default     = null

  validation {
    condition     = var.bedrock_invocation_logs_accounts == null || alltrue([for account_id in keys(coalesce(var.bedrock_invocation_logs_accounts, {})) : can(regex("^\\d{12}$", account_id))])
    error_message = "Each bedrock_invocation_logs_accounts key must be a 12-digit AWS account ID."
  }

  validation {
    condition = var.bedrock_invocation_logs_accounts == null || alltrue(flatten([
      for regions in values(coalesce(var.bedrock_invocation_logs_accounts, {})) : [for region in regions : can(regex("^[a-z]{2}(-[a-z]+)+-\\d$", region))]
    ]))
    error_message = "Each bedrock_invocation_logs_accounts region must be an AWS region name, e.g. us-east-1."
  }

  validation {
    condition = var.bedrock_invocation_logs_accounts == null || alltrue([
      for regions in values(coalesce(var.bedrock_invocation_logs_accounts, {})) : length(regions) > 0 && length(regions) == length(distinct(regions))
    ])
    error_message = "Each bedrock_invocation_logs_accounts entry must list at least one region, without duplicates."
  }
}

variable "bedrock_invocation_logs_lookback_days" {
  description = "How many days of AWS Cost Explorer data are searched for Bedrock usage when bedrock_invocation_logs_accounts is null. Accounts and regions without Bedrock spend in this window stop being logged."
  type        = number
  default     = 90

  validation {
    condition     = var.bedrock_invocation_logs_lookback_days >= 7 && var.bedrock_invocation_logs_lookback_days <= 365
    error_message = "bedrock_invocation_logs_lookback_days must be between 7 and 365."
  }
}

variable "bedrock_invocation_logs_retention_days" {
  description = "Days Bedrock invocation logs are kept in each account before they expire."
  type        = number
  default     = 30

  validation {
    condition     = var.bedrock_invocation_logs_retention_days >= 1 && var.bedrock_invocation_logs_retention_days <= 3650
    error_message = "bedrock_invocation_logs_retention_days must be between 1 and 3650."
  }
}

################################################################################
# LiteLLM logs
################################################################################

variable "litellm_logs_bucket_arns" {
  description = <<-EOT
    S3 bucket ARNs where the customer's LiteLLM proxy writes its S3 logger output (one JSON object per request).
    Buckets must be in the account where this module runs; the Spike role in that account gets read-only access to
    them and the buckets are registered with Spike for collection. Spike reads metadata only (model, tokens, cost,
    request tags); prompt and response content is never read. Recommended: enable LiteLLM's content redaction so
    content never reaches the bucket.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.litellm_logs_bucket_arns : can(regex("^arn:aws:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", arn))])
    error_message = "Each litellm_logs_bucket_arns entry must be a full S3 bucket ARN, e.g. arn:aws:s3:::my-litellm-logs."
  }
}

################################################################################
# Service Quotas Automatic Management
################################################################################

variable "enable_service_quotas_auto_management" {
  description = <<-EOT
    Opt in to AWS Service Quotas Automatic Management: AWS monitors quota utilization and notifies at 80% and 95%
    through AWS Health. One opt-in per region.
    - Current account: enabled directly in every region enabled in the account. A region where it is already on
      fails to apply with "Account already has an opt-in"; the other regions are still enabled. Import that region
      into Terraform, or leave it out of service_quotas_auto_management_regions.
    - Member accounts (organization mode): deployed to linked accounts through a service-managed StackSet in every
      region that needs no opt-in; the management account itself is always configured directly by this module. A
      region where it is already on is left untouched and is not turned off on removal.
    - A list in service_quotas_auto_management_regions overrides the regions for both.
  EOT
  type        = bool
  default     = false
}

variable "service_quotas_auto_management_opt_in_type" {
  description = "NotifyOnly sends utilization notifications. NotifyAndAdjust additionally submits quota increase requests automatically; AWS currently makes it unavailable on some accounts, where enablement fails with the AWS error. Auto-adjust requests can also be rejected without detailed reasons, where a manual request might still be approved."
  type        = string
  default     = "NotifyOnly"

  validation {
    condition     = contains(["NotifyOnly", "NotifyAndAdjust"], var.service_quotas_auto_management_opt_in_type)
    error_message = "service_quotas_auto_management_opt_in_type must be \"NotifyOnly\" or \"NotifyAndAdjust\"."
  }
}

variable "service_quotas_auto_management_regions" {
  description = "Regions where Service Quotas Automatic Management is enabled. Leave null for every region enabled in the current account, and every region that does not require opt-in in member accounts. Set a list to use the same regions for both."
  type        = list(string)
  default     = null

  validation {
    condition     = var.service_quotas_auto_management_regions == null || alltrue([for region in coalesce(var.service_quotas_auto_management_regions, []) : can(regex("^[a-z]{2}(-[a-z]+)+-\\d$", region))])
    error_message = "Each service_quotas_auto_management_regions entry must be an AWS region name, e.g. us-east-1."
  }

  validation {
    condition     = var.service_quotas_auto_management_regions == null || length(coalesce(var.service_quotas_auto_management_regions, [])) > 0
    error_message = "service_quotas_auto_management_regions must not be empty; set it to null to use the default regions."
  }

  validation {
    condition     = var.service_quotas_auto_management_regions == null || length(distinct(coalesce(var.service_quotas_auto_management_regions, []))) == length(coalesce(var.service_quotas_auto_management_regions, []))
    error_message = "service_quotas_auto_management_regions must not contain duplicates."
  }
}

variable "service_quotas_auto_management_exclusion_list" {
  description = "Map of AWS service code to quota codes excluded from Automatic Management, e.g. { dynamodb = [\"L-F98FE922\"] }."
  type        = map(list(string))
  default     = {}
}

################################################################################
# Cost and Usage Report (CUR 2.0) export
################################################################################

variable "enable_cur_export" {
  description = <<-EOT
    Create an S3 bucket and a CUR 2.0 (Parquet) data export that Spike reads cost data from. Spike needs it once, from
    the management account, because it sees the costs of every account.
    - deployment_mode = "organization": on by default in the management account; set false to disable it. Not created
      when running as a delegated administrator; install the management account with deployment_mode = "account" and
      enable_cur_export = true instead.
    - deployment_mode = "account": off by default, since a linked account's export only contains its own costs. Set it
      to true for the management account or for a standalone account that isn't part of an AWS Organization.
  EOT
  type        = bool
  default     = null
}

variable "cur_bucket_force_destroy" {
  description = "Allow Terraform to delete the CUR bucket even when it still contains report data. Leave false in production."
  type        = bool
  default     = false
}

################################################################################
# Organization deployment (deployment_mode = "organization")
################################################################################

variable "organizational_unit_ids" {
  description = "IDs of the organization root (r-xxxx) or OUs (ou-xxxx-xxxxxxxx) to deploy the Spike role to. Leave empty to target the whole organization (the root is discovered automatically)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.organizational_unit_ids : can(regex("^(r-[a-z0-9]{4,32}|ou-[a-z0-9]{4,32}-[a-z0-9]{8,32})$", id))])
    error_message = "Each organizational_unit_ids entry must be a root ID (r-xxxx) or an OU ID (ou-xxxx-xxxxxxxx)."
  }
}

variable "member_account_ids" {
  description = <<-EOT
    Deploy the Spike role ONLY to these member accounts (they must belong to organizational_unit_ids).
    Leave empty to deploy to every account in the targeted OUs. The StackSet uses an INTERSECTION filter so accounts
    outside this list never receive the role, including when automatic deployment is enabled.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.member_account_ids : can(regex("^\\d{12}$", id))])
    error_message = "Each member_account_ids entry must be a 12-digit AWS account ID."
  }
}

variable "auto_deployment" {
  description = "Automatically deploy the Spike role to eligible accounts that join the targeted OUs later. When member_account_ids is set, only listed accounts are eligible."
  type        = bool
  default     = true
}

variable "retain_stacks_on_account_removal" {
  description = "Keep the Spike role in accounts that leave the targeted OUs. Only applies when automatic deployment is on."
  type        = bool
  default     = false
}

variable "stackset_call_as" {
  description = "Set to \"DELEGATED_ADMIN\" when running from a CloudFormation StackSets delegated administrator account instead of the management account. In that case the role is only deployed through the StackSet, and no role or CUR export is created in the current account."
  type        = string
  default     = "SELF"

  validation {
    condition     = contains(["SELF", "DELEGATED_ADMIN"], var.stackset_call_as)
    error_message = "stackset_call_as must be either \"SELF\" or \"DELEGATED_ADMIN\"."
  }
}

variable "stackset_max_concurrent_percentage" {
  description = "Maximum percentage of accounts the StackSet deploys to at the same time."
  type        = number
  default     = 100

  validation {
    condition     = var.stackset_max_concurrent_percentage >= 1 && var.stackset_max_concurrent_percentage <= 100
    error_message = "stackset_max_concurrent_percentage must be between 1 and 100."
  }
}

variable "stackset_failure_tolerance_percentage" {
  description = "Percentage of accounts that can fail before the StackSet stops the operation."
  type        = number
  default     = 0

  validation {
    condition     = var.stackset_failure_tolerance_percentage >= 0 && var.stackset_failure_tolerance_percentage <= 100
    error_message = "stackset_failure_tolerance_percentage must be between 0 and 100."
  }
}

################################################################################
# Spike registration
################################################################################

variable "notify_spike" {
  description = "Notify Spike when the deployment finishes so onboarding completes automatically. Uses a CloudFormation custom resource backed by Spike's SNS topic."
  type        = bool
  default     = true
}

variable "notification_topic_arn" {
  description = "Spike onboarding SNS topic. Don't change unless instructed by Spike."
  type        = string
  default     = "arn:aws:sns:us-east-1:250260913666:directeam-onboarding-topic-f7a69a4b"

  validation {
    condition     = can(regex("^arn:aws:sns:us-east-1:\\d{12}:.+$", var.notification_topic_arn))
    error_message = "notification_topic_arn must be an SNS topic ARN in us-east-1."
  }
}

variable "notification_timeout" {
  description = "Seconds CloudFormation waits for Spike to acknowledge a registration notification."
  type        = number
  default     = 300

  validation {
    condition     = var.notification_timeout >= 60 && var.notification_timeout <= 3600
    error_message = "notification_timeout must be between 60 and 3600 seconds."
  }
}

################################################################################
# General
################################################################################

variable "tags" {
  description = "Additional tags for every resource this module creates (including the resources deployed to member accounts)."
  type        = map(string)
  default     = {}
}
