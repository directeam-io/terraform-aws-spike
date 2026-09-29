# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
