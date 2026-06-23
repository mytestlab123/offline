# Issues from ai/tasks.md — rnasplice (offline)

Date: 2025-09-03

| ID | Category | Observation (from ai/tasks.md) | Impact | Proposed Fix | Status |
|----|----------|---------------------------------|--------|--------------|--------|
| I-1 | Test data URIs | `conf/test.config` used HTTP GitHub URLs for `input`, `contrasts`, `fasta`, `gtf`. | Offline runs fetch remote data; breaks in PROD/offline VPC. | Set ENV-driven S3 base and point params to S3; mirror artifacts via `just mirror`. | Fixed |
| I-2 | Container profile | Run log shows `-profile test` only; `gffread: command not found`. | Tools missing without container; pipeline fails. | Use `-profile test,docker` for online/offline runs. Update just targets accordingly. | Fixed (justfile updated) |
| I-3 | Offline run profiles | Offline `run/stub/preview` just targets did not include `docker` and no `quay.io` registry override. | Offline run may use host tools or fail if images not pre-pulled. | Include `-profile test,docker -offline` and set `docker { registry = "quay.io" }`. | Fixed (justfile updated) |
| I-4 | Igenomes path | Params show `igenomes_base = s3://ngi-igenomes/igenomes/` in output. | Public S3 not allowed in PROD; may be unused if `igenomes_ignore=true`. | Keep `igenomes_ignore=true`; if needed, set internal `igenomes_base` S3. | Info |
| I-5 | nf-core/config warning | "Could not load nf-core/config profiles" warning printed. | Cosmetic; not blocking. | Accept or vend private nf-core/config if required. | Info |
| I-6 | Offline config scope | `rnasplice/rnasplice/offline/offline_test.conf` was legacy-only. | Drift risk and confusion. | Remove file; rely only on `conf/test.config`. | Fixed |
| I-7 | Duplication of config | `common/data/mirror_testdata.sh` generated offline/offline_test.conf. | Two sources of truth; drift risk. | Remove generation; rely solely on `conf/test.config`. | Fixed |

Updates
- rnasplice/conf/test.config now derives S3 paths from ENV (S3_ROOT, PIPELINE) and points to inputs3.csv, contrastsheet.csv, and reference files under `${S3_ROOT}/${PIPELINE}/data`.
- rnasplice/justfile `mirror` now uploads `input` (trimmed), `fasta`, `gtf`, and `contrasts`.
- common/data/mirror_testdata.sh no longer creates `offline/offline_test.conf`.
 - rnaseq/test.config and rnaseq/rnaseq/conf/test.config point to `data/samplesheet/inputs3.csv` and keep `fasta`/`gtf` at `data/*` for DEV online tests. Plan: move to `data/reference/*` in private PROD S3.

Proposed config example (local root `test.config` or `conf/test.config`):

```
params {
  // Offline base for mirrored test data
  pipelines_testdata_base_path = "${S3_ROOT}/${PIPELINE}/data"

  // S3-backed inputs
  input     = "${pipelines_testdata_base_path}/samplesheet/samplesheet.csv"
  contrasts = "${pipelines_testdata_base_path}/samplesheet/contrastsheet.csv"
  fasta     = "${pipelines_testdata_base_path}/reference/X.fa.gz"
  gtf       = "${pipelines_testdata_base_path}/reference/genes_chrX.gtf"

  // Offline toggles
  igenomes_ignore = true
}
```

Notes
- Ensure `${S3_ROOT}` and `${PIPELINE}` are exported (see rnasplice/ENV and `just verify_env`).
- Nextflow `-offline` expects images/data pre-fetched; Nexus proxy should serve quay.io.
- Prefer `-profile test,docker` for parity across online/offline.

Additional findings (multi-pipeline)
| ID | Category | Observation | Impact | Proposed Fix | Status |
|----|----------|-------------|--------|--------------|--------|
| I-8 | TMP space | `curl: (23) Failure writing output to destination` during mirroring. | TMP filled or constrained path caused failures. | Honor `TMPDIR`; use `${HOME}/tmp` in runs or increase space. | Fixed (scripts honor TMPDIR) |
| I-9 | S3 layout | Legacy flat objects remain from prior runs (e.g., rnasplice `X.fa.gz` at data/ root). | Cosmetic; can confuse readers. | Optional cleanup or leave; config points to subfolders. | Info |
| I-10 | rnaseq refs layout | rnaseq refs are S3-backed but not under `data/reference/`. | Inconsistent layout across pipelines. | Optionally move to `data/reference/*` and update conf. | Proposal |
| I-11 | Upstream test configs | `conf/test_fastq.config` exists upstream but not used for mirroring. | None; may confuse devs about origin. | Mirroring reads `conf/original.test.config` if present; document in ai/tasks.md. | Fixed (flow clarified) |
