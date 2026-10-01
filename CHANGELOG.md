# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
