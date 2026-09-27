# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `DirecteamSpikeReadOnlyAccess` role for the current account, with `full` and `limited` access levels.
- Organization-wide deployment through a service-managed StackSet, targeting the whole organization, specific OUs,
  or specific member accounts. Supports running as a StackSets delegated administrator.
- Optional CloudWatch Logs content, EKS, and log management permissions.
- CUR 2.0 (Parquet) data export with a hardened S3 bucket.
- Automatic Spike registration on apply and removal.
