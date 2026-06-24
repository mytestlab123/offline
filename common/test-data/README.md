# nf-core Test Data Mirror

Use this directory when curated nf-core test data is a better source than
inventing new tiny data.

## Rule

Prefer `nf-core/test-datasets` first.

Create custom generated data only when:

- upstream data is too large for a smoke test
- upstream data does not exercise the path we need
- the pipeline needs synthetic structure that is easier to control locally

## Why

`nf-core/test-datasets` is organized by branch:

- one branch per pipeline, for example `rnaseq`, `sarek`, `scrnaseq`
- one `modules` branch for module-level fixtures

This matches how nf-core pipelines commonly use:

- `params.pipelines_testdata_base_path`
- `params.modules_testdata_base_path`

For offline/private validation, mirror only selected small files into the
private data path and point those params at the private mirror.

## Scripts

```bash
common/test-data/mirror-nfcore-test-datasets.sh \
  --branch rnaseq \
  --files rnaseq-files.txt
```

Default mode is dry-run. It writes:

- `out/test-data/<branch>/manifest.tsv`
- `out/test-data/<branch>/testdata.offline.config`

Download locally:

```bash
common/test-data/mirror-nfcore-test-datasets.sh \
  --branch rnaseq \
  --files rnaseq-files.txt \
  --download
```

Upload only when explicitly approved and the private root is set:

```bash
common/test-data/mirror-nfcore-test-datasets.sh \
  --branch rnaseq \
  --files rnaseq-files.txt \
  --download \
  --upload \
  --s3-root "$S3_ROOT"
```

`common/test-data/run-nfcore-testdata-smoke.sh` wraps deterministic smoke runs
for one or more pipelines. It accepts repeated `--pipeline`/`--branch` entries,
defaults file lists to `common/test-data/file-lists/<pipeline>-smoke.txt`, writes
`summary.tsv`, and records `branch_missing` without failing.

```bash
common/test-data/run-nfcore-testdata-smoke.sh \
  --pipeline bamtofastq \
  --pipeline testpipeline --download
```

Compatibility wrapper for existing call sites:

```bash
common/test-data/run-testpipeline-bamtofastq-testdata-smoke.sh
```

Code-quality validation for additional pipelines:

```bash
common/test-data/run-nfcore-testdata-smoke.sh \
  --pipeline rnaseq \
  --pipeline scrnaseq \
  --download
```

This validates our mirror code, file lists, downloads, SHA256 manifests, and
offline base-path config generation. It does not prove a full Nextflow run.

## Finding Upstream Files

Use nf-core tools where available:

```bash
nf-core test-datasets list-branches
nf-core test-datasets list remote --branch rnaseq
nf-core test-datasets search --branch rnaseq fastq
```

Then copy the selected relative paths into a small file list. Do not mirror a
whole branch unless the size is understood.

## Safety

- No S3 upload happens unless `--upload` is set.
- No S3 delete is supported.
- Do not commit private bucket names or generated manifests with private paths.
- Keep large downloaded data out of git.
- Review file sizes before adding new file lists; do not mirror whole branches
  for smoke checks.
