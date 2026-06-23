# AGENTS.md

Scope: `common/container-inventory/`

## Purpose

This directory owns container inventory and GCC verification helpers for
Nextflow/nf-core offline readiness.

## Rules

- Keep scripts bash-only and KISS.
- Use `set -euo pipefail`.
- Do not push or mirror images from this directory.
- Do not edit Docker daemon configuration.
- Do not install packages on target EC2 instances.
- Generated outputs must stay under ignored `out/` paths or
  `~/.AGENTS-temp/offline/`.
- Do not delete generated evidence unless Amit says `cleanup`.

## Network Model

- DEV can use public registries for inspection and discovery.
- GCC/private EC2 validation must use SSM and Nexus Proxy.
- Default Nexus host for GCC verification is:
  `nexus-docker.ship.gov.sg`
- Public registry checks are expected to fail in GCC:
  `quay.io`, `docker.io`, `ghcr.io`, and `community.wave.seqera.io`.

## Safety

- `extract-container-hosts.sh` is local inventory only.
- `verify-nexus-container-access.sh` is controller-side SSM orchestration.
- Live SSM verification requires explicit instance ID, AWS profile, region, and
  inventory directory.
- Pulling images on the EC2 is approved only for the named validation target.
- If a script needs IAM, VPC, routing, security group, Docker config, package
  install, registry push, or image mirroring, stop and ask Amit.
