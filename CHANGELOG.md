# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `DirecteamSpikeReadOnlyAccess` role for the current account, with `full` and `limited` access levels.
- Organization-wide deployment through a service-managed StackSet, targeting the whole organization, specific OUs,
  or specific member accounts. Supports running as a StackSets delegated administrator.
- Optional CloudWatch Logs content, EKS, and log management permissions.
- CUR 2.0 (Parquet) data export with a hardened S3 bucket, created once in the management account (or with
  `enable_cur_export` in account mode).
- Automatic Spike registration on apply and removal.
- Optional Bedrock invocation logs (`enable_bedrock_invocation_logs`): metadata-only logging to a bucket that only
  the Spike role in that account can read. Accounts and regions that use Bedrock are discovered from Cost Explorer at
  plan time (`bedrock_invocation_logs_lookback_days`), or set explicitly with `bedrock_invocation_logs_accounts`.
  Deployed through the same Spike StackSet in organization mode, and directly in account mode. Member accounts keep
  any logging they already configured.
