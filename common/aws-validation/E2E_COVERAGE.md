# Nextflow Offline E2E Coverage

This file tracks which offline validation steps are backed by repo-owned code.
It is intentionally public-safe: keep account IDs, VPC IDs, endpoint IDs,
hostnames, and real bucket names in a local `.env` or evidence packet, not here.

## Current Coverage

| Step | Repo-owned code | Status | Notes |
| --- | --- | --- | --- |
| Create a private validation EC2 | `create-dev-validation-ec2.sh` | covered | Enforces private host basics and SSM-first access. |
| Sync this repo to private artifact storage | `sync-repo-to-s3.sh` | covered | Lets private hosts fetch code without Git access. |
| Stage Nextflow/nf-core tool bundle | `stage-nextflow-tools-to-s3.sh` | covered | Supports private hosts without public package installs during validation. |
| Stage a downloaded pipeline bundle | `stage-offline-bundle-to-s3.sh` | covered | Uses non-destructive sync by default and validates Docker TAR integrity before upload. |
| Run host, S3, Nexus, Docker, and inspect probes through SSM | `run-dev-ec2-smoke-via-ssm.sh` | covered | Probe-first workflow before full runs. |
| Extract container inventory by host | `../container-inventory/extract-container-hosts.sh` | covered | Supports live inspect, inspect JSON, image list, and static fallback. |
| Verify Nexus container access from a private EC2 | `../container-inventory/verify-nexus-container-access.sh` | covered | Pulls through Nexus and checks public registry access is blocked. |
| Local nf-core download/load/offline smoke | `../offline-smoke/nf-core-download-smoke.sh` | covered | Small local proof before large pipeline work. |
| Run an S3 bundle on EC2 through SSM | `run-ec2-s3-bundle-e2e-via-ssm.sh` | covered | Executes a staged local workflow bundle with resource caps. |
| Run a minimal DEV ECR image-path proof | `run-dev-ecr-nextflow-e2e-via-ssm.sh` | covered | Proves EC2 can pull a mirrored image from ECR. |
| Run `nf-core/testpipeline` through DEV ECR | `run-dev-ecr-testpipeline-e2e-via-ssm.sh` | covered | Small end-to-end workflow validation path. |
| Run `bamtofastq` through DEV ECR | `run-dev-ecr-bamtofastq-e2e-via-ssm.sh` | covered | Pipeline-specific ECR validation path. |
| Generate generic ECR process overrides | `generate-ecr-container-overrides.sh` | covered | Converts `nextflow inspect` process/container mappings into an ECR manifest and Nextflow config. |
| Mirror generic image manifest to ECR | `mirror-ecr-images-from-manifest.sh` | covered | Creates or reuses retained ECR repositories and pushes source images. |
| Copy Docker-failed mirror rows to ECR | `copy-ecr-images-with-crane-container.sh` | covered | Fallback for images Docker can pull but cannot push from local content-store state. |
| Verify mirrored ECR manifests | `verify-ecr-images-from-manifest.sh` | covered | Readback gate after Docker and crane mirror steps. |
| Prove private EC2 can pull ECR images | `run-ec2-ecr-pull-proof-via-ssm.sh` | covered | Runtime pull gate before a full Nextflow ECR run. |
| Stage downloaded workflow source to private artifact storage | `stage-workflow-source-to-s3.sh` | covered | Keeps workflow execution Git-free on private EC2 hosts. |
| Stage tiny rnaseq offline data | `stage-rnaseq-tiny-data-to-s3.sh` | covered | Creates deterministic FASTQ/FASTA/GTF smoke data for small validation hosts. |
| Run a generic private S3 workflow with ECR images | `run-ec2-ecr-workflow-via-ssm.sh` | covered | Runs private workflow source and private data with generated ECR container overrides. |
| Run `scrnaseq` through DEV ECR | none yet | blocked | Needs accessible offline input data before a real E2E runner is useful. |
| Run `rnaseq` through DEV ECR | generic ECR workflow runner | covered | Tiny offline data smoke passed with ECR image overrides, FastQC, and MultiQC. |
| Run larger pipelines such as `sarek` through DEV ECR | generic manifest/config path exists | planned | Full execution needs mirrored images, input data, and resource sizing. |
| Retained ECR repo lifecycle review | `ecr-validation-repo-lifecycle.sh` | covered/read-only | Cleanup remains explicit allowlist and approval gated. |

## Definition Of Done For One Pipeline E2E

A pipeline is considered fully covered only when all of these are true:

1. Container inventory is generated and reviewed.
2. Non-approved public registry dependencies are absent or explicitly handled.
3. Input data is available from an approved offline/private path.
4. Runtime resource caps are set for small validation hosts.
5. Images are supplied through the selected private path, such as ECR, S3 Docker
   TAR preload, or a verified Nexus Docker proxy.
6. The workflow runs from a local or private bundle without Git or public
   registry access.
7. The result packet records command, evidence path, changed resources, retained
   resources, cleanup state, and the next safe action.

For S3 Docker TAR preload, the bundle must pass
`stage-offline-bundle-to-s3.sh --validate-only` before upload or EC2 execution.

## Current Known Blocker

`rnaseq` has a complete small-host ECR smoke path. It uses private workflow
source, private tiny input data, generated ECR container overrides, and
`1 CPU / 2 GB` caps. The smoke confirms FastQC and MultiQC execution; it is not
a biological correctness test.

`scrnaseq` is not fully code-owned yet because the customized workflow points
to input data that is not available from the approved offline/private
validation path. Do not add a final `scrnaseq` ECR runner until the input
dataset is available or a realistic synthetic dataset is approved.

## Next Good Code Additions

- Reuse the generic ECR workflow runner for the next pipeline after its input
  data and resource caps are proven.
- Add `scrnaseq` and `sarek` runners or wrapper examples only after their
  offline input data and resource caps are proven.
