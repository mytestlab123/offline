# Nextflow Offline Status - 2026-06-24

This is the public-safe restart snapshot for the offline Nextflow work. Keep
private runtime values in `.env` files or local evidence packets, not here.

## Current Aim

Build a repeatable model for Nextflow-based private pipelines in offline
environments:

1. pin pipeline source to a release or controlled internal tag
2. stage workflow source through a private artifact path
3. stage tiny test data through a private artifact path
4. supply containers through ECR, S3 Docker TAR bundles, or a verified Nexus
   Docker proxy
5. prove the run from a private EC2 host through SSM

## Current Proof Level

| Pipeline | Proof level | Notes |
| --- | --- | --- |
| `nf-core/demo` | private E2E passed | Tiny proof for toolchain and private image path behavior. |
| `nf-core/testpipeline` | ECR and S3-bundle paths covered | Best regression target for this repo. |
| `bamtofastq` | ECR path covered | Small real workflow after `testpipeline`. |
| `rnaseq` | small-host ECR smoke covered | Private tiny data, ECR overrides, FastQC, and MultiQC. |
| `scrnaseq` | small-host ECR smoke covered | Private tiny data and ECR overrides; smoke skips only the minimal-data `CONCAT_H5AD` edge case. |
| `sarek` | planned | Needs input-data and resource-sizing probe before full E2E. |

## Important Code Map

Container discovery:

- `common/container-inventory/extract-container-hosts.sh`
- `common/container-inventory/verify-nexus-container-access.sh`

ECR image path:

- `common/aws-validation/generate-ecr-container-overrides.sh`
- `common/aws-validation/mirror-ecr-images-from-manifest.sh`
- `common/aws-validation/copy-ecr-images-with-crane-container.sh`
- `common/aws-validation/verify-ecr-images-from-manifest.sh`
- `common/aws-validation/run-ec2-ecr-pull-proof-via-ssm.sh`
- `common/aws-validation/run-ec2-ecr-workflow-via-ssm.sh`

S3 Docker TAR path:

- `common/offline-smoke/nf-core-download-smoke.sh`
- `common/aws-validation/stage-offline-bundle-to-s3.sh`
- `common/aws-validation/run-ec2-s3-bundle-e2e-via-ssm.sh`

Test data:

- `common/test-data/README.md`
- `common/aws-validation/stage-rnaseq-tiny-data-to-s3.sh`
- `common/aws-validation/stage-scrnaseq-tiny-data-to-s3.sh`

Coverage tracker:

- `common/aws-validation/E2E_COVERAGE.md`

## Image Supply Decision

Use this order for private E2E:

1. ECR for retained deterministic pipeline image paths.
2. S3 Docker TAR bundles for fully offline preload/fallback.
3. Nexus Docker proxy only where the private endpoint path is proven.

Direct public registry access is not accepted as final private runtime proof.

## Resource Rule

Start small-host smoke tests with:

```text
--max-cpus 1
--max-memory "2 GB"
```

Increase only after evidence proves CPU, memory, disk, or runtime pressure.

## Restart Order

For future work, read:

1. `AGENTS.md`
2. `PIPELINE_RELEASE_CONTRACT.md`
3. `common/aws-validation/E2E_COVERAGE.md`
4. this file
5. local ignored files such as `CONTEXT.md`, `SPEC.md`, or `summarize.md` only
   if they exist in the working copy

## Next Likely Work

- Pause this lane while Amit changes direction.
- On restart, either:
  - plan `sarek` private E2E from input data and sizing first, or
  - prepare an Ops walkthrough from the current code and visual explanation.
