# CloudOS CLI Smoke Template

This is a copy-and-edit template for the first manual CloudOS CLI validation.
Replace placeholders from `.env.cloudos.local`.

## 1. Install CLI Locally

```bash
python3 -m venv ~/.AGENTS-temp/offline/cloudos-cli/venv
~/.AGENTS-temp/offline/cloudos-cli/venv/bin/pip install --upgrade pip cloudos-cli
~/.AGENTS-temp/offline/cloudos-cli/venv/bin/cloudos --version
```

## 2. Configure Or Use Explicit Credentials

Interactive profile:

```bash
cloudos configure --profile "$CLOUDOS_PROFILE"
cloudos configure list-profiles
```

For scripted smoke tests, prefer environment variables loaded from a local
uncommitted file:

```bash
set -a
. ./.env.cloudos.local
set +a

CLOUDOS_AUTH_ARGS=(
  --profile "$CLOUDOS_PROFILE"
  --cloudos-url "$CLOUDOS_URL"
  --apikey "$CLOUDOS_APIKEY"
  --workspace-id "$CLOUDOS_WORKSPACE_ID"
)
```

## 3. Discovery Checks

```bash
cloudos project list "${CLOUDOS_AUTH_ARGS[@]}"
cloudos queue list "${CLOUDOS_AUTH_ARGS[@]}"
cloudos workflow list "${CLOUDOS_AUTH_ARGS[@]}"
```

If those fail, stop and fix CloudOS credentials or permissions before running a
job.

## 4. Prepare Small Job Inputs

Create a small job config and params file in the approved private storage area.
The params file for `cloudos job run --params-file` must be in S3, Azure Blob,
or CloudOS File Explorer. It is not a local file path.

Example local config to upload:

```text
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

Example params JSON to upload and adjust:

```json
{
  "input": "s3://example-bucket/nextflow-offline/cloudos/testpipeline/input.csv",
  "outdir": "s3://example-bucket/nextflow-offline/cloudos/testpipeline/out",
  "validate_params": false
}
```

## 5. Submit One Bounded Job

Use the smallest workflow first and keep the cost/runtime gate low.

```bash
cloudos job run \
  "${CLOUDOS_AUTH_ARGS[@]}" \
  --project-name "$CLOUDOS_PROJECT_NAME" \
  --workflow-name "$CLOUDOS_WORKFLOW_NAME" \
  --last \
  --job-name "$CLOUDOS_JOB_NAME" \
  --job-queue "$CLOUDOS_JOB_QUEUE" \
  --nextflow-profile "$CLOUDOS_NEXTFLOW_PROFILE" \
  --nextflow-version "$CLOUDOS_NEXTFLOW_VERSION" \
  --execution-platform "$CLOUDOS_EXECUTION_PLATFORM" \
  --repository-platform "$CLOUDOS_REPOSITORY_PLATFORM" \
  --instance-type "$CLOUDOS_INSTANCE_TYPE" \
  --instance-disk "$CLOUDOS_INSTANCE_DISK_GB" \
  --cost-limit "$CLOUDOS_COST_LIMIT" \
  --wait-completion \
  --wait-time "$CLOUDOS_WAIT_SECONDS" \
  --params-file "s3://example-bucket/nextflow-offline/cloudos/testpipeline/params.json"
```

Do not run a large workflow until this job proves the queue, storage, private
registry path, and resource caps.

## 6. Check And Stop If Needed

```bash
cloudos job list "${CLOUDOS_AUTH_ARGS[@]}" --filter-job-name "$CLOUDOS_JOB_NAME"
cloudos job status "${CLOUDOS_AUTH_ARGS[@]}" --job-id "<job-id>"
cloudos job logs "${CLOUDOS_AUTH_ARGS[@]}" --job-id "<job-id>"
cloudos job results "${CLOUDOS_AUTH_ARGS[@]}" --job-id "<job-id>"
cloudos job cost "${CLOUDOS_AUTH_ARGS[@]}" --job-id "<job-id>"
```

Abort only when the run exceeds the agreed cost/runtime boundary:

```bash
cloudos job abort "${CLOUDOS_AUTH_ARGS[@]}" --job-ids "<job-id>"
```

## 7. Result Packet

Save a compact local result under `~/.AGENTS-temp/offline/`:

```text
CloudOS version:
Profile:
Workflow:
Queue:
Job ID:
Status:
Cost:
Logs path:
Results path:
Registry path tested:
Conclusion:
Blocker:
Next action:
```
