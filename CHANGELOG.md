# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Service Quotas Automatic Management default regions: with `service_quotas_auto_management_regions` unset, the
  current account now uses every region enabled in the account and member accounts use every region that needs no
  opt-in, instead of the home region only. Regions already on in the current account fail to apply until imported;
  see the README, "Upgrading to 1.5.0". Set the list to keep the old behavior.
- Service Quotas Automatic Management in member accounts now skips a region where it was already on: nothing is
  changed and the stack succeeds. Version 1.4.0 failed the member stack for such a region without changing it.
- On removal, member accounts turn off Service Quotas Automatic Management only where the module turned it on and the
  setting is still the one the module applied; a region you changed since is left on.
- `service_quotas_auto_management_regions` must not be an empty list or contain duplicates.

### Fixed

- Updating a Service Quotas member stack failed when auto management was on (the Lambda sent `OptInLevel` to
  `UpdateAutoManagement`, which the API rejects), for example when upgrading the module. The setting is now updated
  with the mode and exclusions only.
- The README import example for a current-account region that already has Service Quotas Automatic Management on
  works before Terraform 1.12 (it no longer relies on `identity`), and documents the apply failure for such regions.

## [1.4.0] - 2026-11-05

### Added

- `litellm_logs_bucket_arns`: registers customer-owned LiteLLM proxy S3 logger buckets with Spike and grants the
  Spike role read-only access to them. Buckets must be in the account where the module runs. Spike reads metadata
  only (model, tokens, cost, request tags); prompt and response content is never read.
- `enable_service_quotas_auto_management` with `service_quotas_auto_management_opt_in_type`,
  `service_quotas_auto_management_regions`, and `service_quotas_auto_management_exclusion_list`: opts accounts into
  AWS Service Quotas Automatic Management (80%/95% utilization notifications through AWS Health). Current account
  configured directly per region; member accounts (organization mode) deployed through a service-managed StackSet
  backed by a Lambda custom resource, since CloudFormation has no native resource for it.

### Changed

- Minimum AWS provider version raised to 6.40.0 for `aws_servicequotas_auto_management`.

## [1.3.0] - 2026-10-06

### Added

- `update_spike_stack` keeps an existing `DirecteamFinOpsStackSet` or `DirecteamFinOpsReadOnlyAccess` CloudFormation
  stack on the Spike template version released with the module (`v1.0.67`). The stack is updated in place through a
  change set with its current parameters and stays CloudFormation-owned. Updates that would delete, replace, or
  recreate core resources, drop parameters, or downgrade the stack are refused. Requires `spike_template_base_url`.
- `existing_onboarding_template_version` and `spike_template_version` outputs.

### Fixed

- Checkov findings on the KMS key policies and the CUR and Bedrock log buckets that don't apply to them are skipped
  with the reason, so CI passes again.

## [1.2.1] - 2026-10-01

### Fixed

- Detect successful AWS-generated `StackSet-DirecteamFinOpsReadOnlyAccess-*` stack instances so existing CloudFormation onboarding is preserved.

## [1.2.0] - 2026-10-01

### Added

- Automatic onboarding identity discovery from existing `DirecteamFinOpsStackSet`, `DirecteamFinOpsReadOnlyAccess`, or `DirecteamTerraformBootstrap` CloudFormation stack parameters.

### Changed

- `external_id` and `directeam_id` are optional compatibility fallbacks; standard installations use the Spike-generated bootstrap stack and do not pass them in Terraform configuration.
- `enable_cur_export = false` now disables CUR creation in organization mode; leaving it null preserves the default management-account export.

## [1.1.0] - 2026-10-01

### Added

- Automatic detection of existing `DirecteamFinOpsStackSet` and `DirecteamFinOpsReadOnlyAccess` CloudFormation onboarding, with `auto`, `create`, and `existing` ownership modes.
- Per-account and per-region Bedrock invocation-log lifecycle events containing the Directeam customer ID, account ID, region, bucket, status, and module version.
- A separate `DirecteamBedrockInvocationLogs` StackSet that can add Bedrock logging without taking ownership of existing read-only onboarding resources.

### Changed

- Base read-only roles, StackSets, CUR exports, and registration resources remain CloudFormation-owned when existing onboarding is detected.
- Bedrock invocation logging is deployed independently from the base read-only StackSet.
- CUR and Bedrock log buckets use rotating customer-managed KMS keys, versioning, and noncurrent-version lifecycle cleanup.

## [1.0.0] - 2026-09-29

### Added

- `DirecteamFinOpsReadOnlyAccess` IAM role for the current account, with `full` and `limited` access levels.
- Organization-wide deployment through a service-managed StackSet, targeting the whole organization, specific OUs,
  or selected member accounts. Supports StackSets delegated administrator installs.
- Optional CloudWatch Logs content, EKS, and log management permissions.
- CUR 2.0 (Parquet) export and `dt-cur-<account-id>` bucket in the management account (or with `enable_cur_export`
  in account mode for standalone or management-only installs).
- Automatic Spike registration on apply and removal.
- Optional Bedrock invocation logs (`enable_bedrock_invocation_logs`): metadata-only logging to
  `dt-bedrock-invocation-logs-<account-id>-<region>` buckets, with Cost Explorer discovery or an explicit account map.
  Deployed through the same StackSet in organization mode.
