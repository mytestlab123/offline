# nf-core Offline Smoke

This directory has the smallest repeatable proof for nf-core offline bundle
handling.

Use it before large pipelines such as `rnaseq`, `sarek`, or `scrnaseq`.

## Why

Large nf-core pipelines can consume a lot of Docker/containerd disk space. First
prove the local toolchain with `nf-core/testpipeline`, then run heavier pipeline
downloads on a host or EC2 with enough storage.

## Disk Rule

Before a Docker image download or load:

- Docker root should be on a large volume, not the small root disk.
- containerd state should also be on a large volume.
- Keep at least 2G free on `/`.
- Keep at least 10G free in the smoke workspace.

Useful checks:

```bash
docker info --format 'DockerRoot={{.DockerRootDir}} Driver={{.Driver}} Server={{.ServerVersion}}'
df -h / /mnt/data5
```

## Small Smoke Test

Default:

```bash
common/offline-smoke/nf-core-download-smoke.sh
```

Small EC2 or CI runner with limited memory:

```bash
common/offline-smoke/nf-core-download-smoke.sh \
  --max-cpus 1 \
  --max-memory "2 GB"
```

With explicit tools and workspace:

```bash
NEXTFLOW_BIN=nextflow NFCORE_BIN=nf-core \
  common/offline-smoke/nf-core-download-smoke.sh \
  --workspace /mnt/data5/nfcore-offline-smoke
```

Download and load only:

```bash
common/offline-smoke/nf-core-download-smoke.sh --skip-run
```

Output:

```text
/mnt/data5/nfcore-offline-smoke/results/RESULT.md
```

## What This Proves

- `nf-core pipelines download` can create workflow source and Docker TAR files.
- `docker-load.sh` can load the TAR files into local Docker.
- `nextflow -offline` can run the local workflow using loaded images.
- Optional `--max-cpus` and `--max-memory` caps can keep tiny validation runs
  inside small EC2 host limits.

## What This Does Not Prove

- GCC EC2 has no public Internet.
- Nexus has all required images.
- Public registries are blocked.
- Large pipelines will fit on the current host.

Use `common/container-inventory/verify-nexus-container-access.sh` for the GCC
Nexus verification step.
