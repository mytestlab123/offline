# AWS Validation

Repo-owned scripts for deterministic AWS validation work.

## Private Values

This is a public repo. Keep private account IDs, subnet IDs, security-group IDs,
endpoint IDs, hostnames, and bucket names out of committed files.

Use a local `.env` file for private values:

```bash
cp .env.example .env
vim .env
```

The AWS validation scripts load `.env` automatically from the repo root. To use
a different file:

```bash
NEXTFLOW_OFFLINE_ENV_FILE=/path/to/private.env \
  common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id i-xxxxxxxxxxxxxxxxx
```

## Create Private Validation EC2

Plan only:

```bash
common/aws-validation/create-dev-validation-ec2.sh \
  --ami-id ami-xxxxxxxxxxxxxxxxx \
  --subnet-id subnet-xxxxxxxxxxxxxxxxx \
  --security-group-id sg-xxxxxxxxxxxxxxxxx \
  --iam-instance-profile my-ssm-instance-profile
```

Apply:

```bash
common/aws-validation/create-dev-validation-ec2.sh \
  --ami-id ami-xxxxxxxxxxxxxxxxx \
  --subnet-id subnet-xxxxxxxxxxxxxxxxx \
  --security-group-id sg-xxxxxxxxxxxxxxxxx \
  --iam-instance-profile my-ssm-instance-profile \
  --apply
```

The script enforces private validation basics:

- no public IP
- private subnet route check
- matching subnet/security-group VPC
- SSM instance profile
- tagged root EBS with delete-on-termination

## Run Smoke Through SSM

Default staged probe flow (safe):

```bash
common/aws-validation/run-dev-ec2-smoke-via-ssm.sh \
  --instance-id i-xxxxxxxxxxxxxxxxx \
  --repo-s3-uri s3://example-bucket/git/nextflow-offline/repo/ \
  --tools-s3-uri s3://example-bucket/nextflow-offline/tools/nextflow-tools.tar.gz \
  --nexus-host nexus-docker.example.internal
```

This runs, in order:

1. `host-tool-s3`
2. `network-probe`
3. `docker-nexus`
4. `nextflow-inspect`

No full smoke is executed by default.

Run one stage at a time:

```bash
common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id i-xxxxxxxxxxxxxxxxx --stages host-tool-s3
common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id i-xxxxxxxxxxxxxxxxx --stages network-probe
common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id i-xxxxxxxxxxxxxxxxx --stages docker-nexus
common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id i-xxxxxxxxxxxxxxxxx --stages nextflow-inspect
```

Run a prebuilt S3 bundle E2E on an EC2 host:

```bash
common/aws-validation/run-ec2-s3-bundle-e2e-via-ssm.sh \
  --instance-id i-xxxxxxxxxxxxxxxxx \
  --bundle-s3-uri s3://example-bucket/nextflow-offline/bundles/testpipeline-3.2.1/ \
  --max-cpus 1 \
  --max-memory "2 GB"
```

Run a DEV ECR image-path E2E on an EC2 host:

```bash
common/aws-validation/run-dev-ecr-nextflow-e2e-via-ssm.sh \
  --instance-id i-xxxxxxxxxxxxxxxxx \
  --source-tar-s3-uri s3://example-bucket/nextflow-offline/bundles/testpipeline-3.2.1/docker-images/biocontainers-fastqc-0.12.1--hdfd78af_0.tar \
  --loaded-image quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0 \
  --push-mode local
```

Use `--push-mode local` when the EC2 instance profile can pull from ECR but
cannot push image layers. The controller role creates a temporary ECR repo,
pushes the image, grants the EC2 role pull access through a temporary repository
policy, runs a tiny Nextflow Docker process on the EC2 host, and deletes the
temporary ECR repo after proof.

Run `nf-core/testpipeline` through temporary DEV ECR image mirrors:

```bash
common/aws-validation/run-dev-ecr-testpipeline-e2e-via-ssm.sh \
  --instance-id i-xxxxxxxxxxxxxxxxx \
  --bundle-s3-uri s3://example-bucket/nextflow-offline/bundles/testpipeline-3.2.1/
```

This creates temporary ECR repos for the testpipeline FastQC, MultiQC, and
FASTA validator images, pushes them from approved S3 Docker TARs, grants the
EC2 role pull access, runs the local S3-bundle workflow with ECR container
overrides and small resource caps, then deletes the temporary ECR repos.

Explicit full-smoke (separate command):

```bash
common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id i-xxxxxxxxxxxxxxxxx --run-full-smoke
```

Before any SSM run, first sync the repo to S3 so private EC2 hosts can fetch it without GitLab:

```bash
common/aws-validation/sync-repo-to-s3.sh \
  --s3-uri s3://example-bucket/git/nextflow-offline/repo/
```

Stage the offline tool bundle to the approved data/artifact path:

```bash
common/aws-validation/stage-nextflow-tools-to-s3.sh \
  --s3-uri s3://example-bucket/nextflow-offline/tools/nextflow-tools.tar.gz
```

Stage a proven offline pipeline bundle:

```bash
common/aws-validation/stage-offline-bundle-to-s3.sh \
  --bundle-dir /path/to/downloads/testpipeline \
  --s3-uri s3://example-bucket/nextflow-offline/bundles/testpipeline-3.2.1/
```

The bundle staging script does not delete destination objects by default. Use
`--delete` only when that destructive sync is explicitly approved.

```bash
common/aws-validation/run-dev-ec2-smoke-via-ssm.sh \
  --instance-id i-xxxxxxxxxxxxxxxxx \
  --repo-s3-uri s3://example-bucket/git/nextflow-offline/repo/ \
  --tools-s3-uri s3://example-bucket/nextflow-offline/tools/nextflow-tools.tar.gz \
  --nexus-host nexus-docker.example.internal
```

This verifies host state, restores tools from:

```text
s3://example-bucket/nextflow-offline/tools/nextflow-tools.tar.gz
```

syncs the repo from:

```text
s3://example-bucket/git/nextflow-offline/repo/
```

to:

```text
/opt/nextflow-offline/
```

Then it runs:

```text
/opt/nextflow-offline/common/offline-smoke/nf-core-download-smoke.sh
```

The script restores the repo-approved tool bundle from S3. On Amazon Linux 2023
it may install Python 3.12 and git from configured OS package repositories so
the bundled nf-core venv can run. It must not use public container registries
as runtime dependencies.

## Private Registry Decision

For private or no-Internet environments, use one of these image supply paths:

1. S3 Docker TAR preload
   - deterministic and easy to audit
   - good for validation, AMI bake, and controlled offline bundles
2. ECR mirror
   - best AWS-native runtime registry path when ECR endpoints are available
   - requires an image import or mirror step
   - a practical low-permission pattern is controller/CI push to ECR and EC2
     pull from ECR
3. Nexus Docker proxy
   - only valid after testing Docker CLI pull from inside the target VPC
   - a Nexus browser/API URL can work while Docker pull routing still fails

Do not assume a Nexus repository browser path is pull-compatible. Test the exact
Docker image reference from the target private network before using it in a
Nextflow config.

Keep environment-specific VPC IDs, endpoint IDs, account IDs, hostnames, and S3
bucket names out of this public repo. Store those values in a local evidence
packet under `~/.AGENTS-temp/offline/`.
