# Pipeline Release Contract

Purpose:
- Define how a pipeline becomes a stable private CloudOS Tool.
- Keep CloudOS runs reproducible by pinning exact upstream and private GitLab
  versions.

## Final Aim

CloudOS runs a pipeline as a Tool.

The Tool points to a hosted private GitLab repository using a PAT. CloudOS then
runs Batch Analysis inside the workspace with approved data, parameters,
containers, and output location.

Runtime should not depend on public GitHub, public container registries, or
floating branches.

## Source Of Truth

Use exact upstream release tags.

Examples:

- `nf-core/rnaseq` upstream tag `3.26.0`
- `nf-core/sarek` upstream tag `3.8.0`

Do not use:

- `main`
- `dev`
- `latest`
- floating branches
- floating container tags

## Private GitLab Tag Rule

Private GitLab must carry the pipeline version that CloudOS will use.

If the pipeline is unchanged from upstream:

```text
upstream: nf-core/rnaseq 3.26.0
gitlab tag: v3.26.0
```

If Trust/CloudOS/offline changes are added:

```text
upstream: nf-core/rnaseq 3.26.0
gitlab tag: v3.26.0-trust.1
```

Use a new suffix for each approved local change:

```text
v3.26.0-trust.1
v3.26.0-trust.2
v3.26.0-trust.3
```

For major/minor upgrades, create a new line of proof:

```text
v3.26.0-trust.1
v3.27.0-trust.1
```

## Final CloudOS Manifest

Each promoted Tool should have one release manifest.

```yaml
pipeline: rnaseq
upstream_repo: nf-core/rnaseq
upstream_version: 3.26.0
gitlab_repo: <private GitLab repo URL>
gitlab_ref: v3.26.0-trust.1
cloudos_tool_name: rnaseq
cloudos_tool_version: 3.26.0-trust.1

workflow_source:
  type: gitlab
  ref: v3.26.0-trust.1
  auth: pat

data:
  manifest: <private data manifest path>
  base_path: <private data base path>

containers:
  manifest: <private container manifest path>
  runtime_path: ecr-or-approved-private-registry

params:
  file: <params file path>
  resource_caps: <cpu-memory-time contract>

output:
  path: <CloudOS workspace or private output path>
  retention: <retention rule>

evidence:
  code_tag_proof: <path>
  data_manifest_proof: <path>
  container_manifest_proof: <path>
  cloudos_run_proof: <path>
```

Keep private values in environment files, local evidence, or private manifests.
Do not commit secrets, PATs, account IDs, private hostnames, or real private
bucket names into public repo files.

## Promotion Gates

A pipeline tag is CloudOS-ready only when all gates pass:

1. Upstream release tag is pinned.
2. Private GitLab repo exists.
3. Private GitLab tag exists and is immutable for the run.
4. Container inventory is generated from that exact tag.
5. Container images are available from ECR or approved private registry.
6. Input data is available from approved private data path.
7. Parameter file is pinned and saved.
8. Output path is explicit.
9. Small private/offline smoke run has passed.
10. CloudOS Tool can access the GitLab tag using PAT.
11. CloudOS Batch Analysis run has evidence.

## Role Of Current Scripts

Current scripts are still useful, but they are not the final product by
themselves.

- `common/test-data/` proves selected data can be mirrored deterministically.
- `common/aws-validation/` proves private EC2, ECR, S3, and SSM mechanics.
- Future CloudOS validation should consume the same manifests and pinned tags.

## Recommended Flow

1. Pick upstream release tag.
2. Import or mirror the pipeline to private GitLab.
3. Apply only required offline/CloudOS changes.
4. Tag private GitLab with `v<upstream>-trust.<n>`.
5. Generate container inventory from that exact tag.
6. Mirror images to approved private runtime path.
7. Mirror selected test data to approved private data path.
8. Create params file and output path contract.
9. Run private EC2 smoke if needed.
10. Register or update CloudOS Tool to the private GitLab tag.
11. Run CloudOS Batch Analysis.
12. Save release manifest and evidence.

## Current Position

Current E2E work proves the offline mechanics for small smoke runs.

The next maturity step is to make the GitLab tag plus CloudOS Tool manifest the
release unit.
