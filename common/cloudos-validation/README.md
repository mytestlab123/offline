# CloudOS Offline Validation

This directory documents the first small CloudOS CLI validation path for offline
Nextflow work.

The first workflow target is:

```text
nf-core/testpipeline
```

## Auth Model

`cloudos-cli` is open source and can be installed locally for command discovery.
Real project, workflow, and job operations still require a Lifebit CloudOS
Platform profile or equivalent command credentials.

Use raw AWS Batch or direct Nextflow automation if the goal is self-hosted AWS
execution without CloudOS Platform.

## Private Values

This is a public repo. Keep private values out of committed files:

- CloudOS URL and API key
- workspace ID and project name
- private queue names
- internal registry hostnames
- S3 bucket names
- account, VPC, endpoint, subnet, and security-group IDs

Create a local file when needed:

```bash
cp common/cloudos-validation/env.example .env.cloudos.local
vim .env.cloudos.local
```

## First Validation Path

Use live Nexus Docker pulls from the private runtime network. Do not preload S3
Docker TARs for the first CloudOS path unless Nexus pull validation fails.

Expected high-level flow:

1. Install `cloudos-cli` on the local operator host.
2. Configure a CloudOS profile.
3. Confirm project, queue, and workflow visibility.
4. Prepare small offline test inputs in approved storage.
5. Submit one tiny `nf-core/testpipeline` job with conservative resource caps.
6. Wait for completion or stop quickly if the cost/runtime gate is hit.
7. Record CloudOS job ID, status, logs path, results path, and blocker.

## Safety Gates

- Start with a tiny workflow only.
- Use low resource values first.
- Set a low cost limit.
- Use a bounded wait time.
- Stop or abort the job if it runs unexpectedly long.
- Confirm the target CloudOS/AWS Batch path can reach the approved private
  Nexus Docker registry before treating the run as an offline proof.
- If the production private path lacks permission, repeat discovery in the
  approved development environment.

## Resource Caps

Use small process caps for validation hosts. Some nf-core modules override
global process settings through labels, so cap the common labels too.

Example Nextflow config content:

```groovy
process {
  cpus = 1
  memory = '2 GB'

  withLabel: 'process_single' {
    cpus = 1
    memory = '2 GB'
  }

  withLabel: 'process_low' {
    cpus = 1
    memory = '2 GB'
  }

  withLabel: 'process_medium' {
    cpus = 1
    memory = '2 GB'
  }

  withLabel: 'process_high' {
    cpus = 1
    memory = '2 GB'
  }
}
```

## Evidence To Save

Save one compact result packet for each run:

- CloudOS CLI version
- profile name used, without secrets
- project, workflow, and queue names, if safe to record
- job ID
- job status
- job cost, if available
- job logs path
- job workdir/results path
- Nexus registry used, as a placeholder in public notes
- conclusion and blocker

Keep private evidence under `~/.AGENTS-temp/offline/`, not in this public repo.
