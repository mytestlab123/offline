# CloudOS Manifest Examples

These files are example CloudOS release manifests for local planning and review.
They intentionally use placeholders only and are not ready for production use.

These files should remain public-safe and must not contain private values such as:

- PATs and private API keys
- Private GitLab hostnames or repository URLs
- Private S3 buckets or other cloud endpoints
- Account IDs, instance IDs, VPC/subnet IDs, or endpoint IDs

Before creating a live manifest:

- publish a private GitLab tag that matches the exact upstream release
- verify the tag and evidence path in your private environment
- confirm container manifest and runtime path visibility from CloudOS execution hosts
- confirm input data manifest and base path
- confirm params JSON path and resource caps
- confirm explicit output path and retention policy
- record code, data, container, and CloudOS run proof paths

Difference from S3/SSM smoke tests:

- S3/SSM tests validate private host bootstrap, bundle restore, and offline
  Nextflow behavior.
- CloudOS manifests drive a Tool registration and Batch Analysis run against a
  private GitLab workflow source, so they are the final release contract for
  production/private execution.
