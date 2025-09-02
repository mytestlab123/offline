# Offline Nextflow in AWS — Improvement Plan

## Intent
- Run nf-core pipelines in AWS with two modes:
  - Dev: online, uses Nexus as a proxy registry, verifies configs and inputs.
  - Prod: offline/air‑gapped, code and small inputs from S3, containers via Nexus, Docker engine runtime.

## Current State (repo summary)
- Pipelines prepared under `demo/`, `bamtofastq/`, `rnaseq/`, `sarek/` with:
  - `setup.sh`: downloads a pinned nf-core release, stages sources locally.
  - `test.config`: forces S3 inputs, disables remote configs, points `docker.registry` to Nexus.
  - `justfile`: targets to test online, push code to S3, pull to offline host, and run with `-offline`.
  - `prepare_*_offline_test.sh`: mirrors small test datasets to S3 and emits `offline/inputs3.csv`.
- ENV files set `NXF_PLUGIN_AUTOINSTALL=false`, `NXF_HOME`, `S3_ROOT`, `ROOT_DIR`.

Gaps/opportunities:
- Duplication across pipelines (setup, prepare scripts, justfiles, ENV vs .env naming).
- No automated container mirroring to Nexus or image manifest generation.
- No pre-cache of Nextflow plugins (e.g., `nf-amazon`) for offline runs.
- No single top-level orchestrator; manual sequencing across folders.
- Limited guardrails (version pinning summary, integrity checks, smoke tests, docs).

## Plan (phased, incremental)

1) Standardize layout and configs
- Create `scripts/` and `profiles/` at repo root; move shared scripts there.
- Provide `profiles/offline.config` for common offline toggles used by all pipelines.
- Unify env handling via `.env.template` and per-pipeline `.env` (or `ENV`) consistently.
- Add a top-level `justfile` to orchestrate all pipelines with common verbs.

2) Pipeline staging (code)
- Replace per-folder `setup.sh` with `scripts/stage_pipeline.sh`:
  - Inputs: `--name <pipeline> --revision <tag> --dest pipelines/<name>`.
  - Uses `nf-core pipelines download --container-system none` and rsyncs into place.
  - Emits `pipelines/<name>/manifest.json` (name, revision, commit, date).

3) Data mirroring (tests and small refs)
- Consolidate to `scripts/mirror_testdata.sh`:
  - Parses a given `conf/test.config`, fetches samplesheet, trims N rows, downloads referenced HTTP assets.
  - Writes `offline/inputs3.csv` and syncs staged assets to `s3://.../<pipeline>/data`.
  - Produces `SHA256SUMS` and a small `data.manifest.json`.

4) Container mirroring to Nexus
- Add `scripts/collect_images.sh` to emit `images.txt` per pipeline:
  - Derive containers from `conf/modules.config`, `modules.json`, and `nextflow config` resolution.
- Add `scripts/mirror_images_to_nexus.sh` (requires `skopeo` or `crane`):
  - `skopeo copy docker://quay.io/... docker://<nexus>/<repo>/...` for each pinned tag/digest.
  - Optionally `docker pull` from Nexus and `docker save` to tarballs as offline fallback.
- Verify: `scripts/verify_images.sh` pulls from Nexus and reports digests.

5) Nextflow/plugin offline cache
- Add `plugins.txt` (e.g., `nf-amazon@<ver>`, others if needed).
- Add `scripts/cache_nextflow_plugins.sh` that runs online to preinstall into `$NXF_HOME/plugins/` and tars them to `s3://.../nextflow/plugins/`.
- Offline bootstrap pulls this cache and sets `NXF_PLUGIN_AUTOINSTALL=false` (already set).

6) Orchestration (top-level justfile)
- Targets (operate per `PIPELINE` env):
  - `stage`: stage nf-core code.
  - `mirror:data`: run testdata mirroring and push manifests.
  - `images:list` and `images:mirror`: generate and mirror containers to Nexus.
  - `push:code`: sync `pipelines/<name>` to S3 (exclude `work/`).
  - `dev:smoke`: online `-stub` run using Nexus proxy.
  - `prod:bootstrap`: offline host bootstrap (code + plugins + login to Nexus).
  - `prod:run`: offline run with `-offline -profile test,offline`.

7) Dev online smoke tests
- Add consistent `-stub` and `-preview` runs; store logs and `DAG.svg` to `artifacts/` then to S3.
- Add a quick validator that asserts: Nexus reachable, images resolvable, S3 inputs present.

8) Prod offline bootstrap
- `scripts/bootstrap_offline.sh` does:
  - `aws s3 sync` of `pipelines/<name>` and `offline/` to target host.
  - Pulls Nextflow plugin cache; ensures `$NXF_HOME/plugins` is populated.
  - Logs into Nexus, validates CA, and tests a single `docker pull` from Nexus.
  - Runs `nextflow run . -offline -profile test,offline -resume`.

9) Security and reliability
- Enforce S3 SSE (KMS) on sync; optional bucket policies and VPC endpoints.
- Prefer image digests over tags in `images.txt` where practical.
- Keep manifests with SHA256 sums for data and plugins.
- Add `NXF_OPTS='-Xms1g -Xmx4g'` defaults and consistent `NXF_WORK` on fast local disk.

10) Documentation and CI
- Add a root `README.md` with architecture diagrams and runbooks for Dev/Prod.
- Provide `docs/offline-checklist.md` with a pre-flight list for air‑gapped runs.
- Optional CI: smoke `-stub` run in Dev to catch obvious regressions (skips heavy downloads).

## Acceptance Criteria
- One-command flow per pipeline in Dev: `just stage mirror:data images:list images:mirror dev:smoke push:code`.
- One-command flow per pipeline in Prod: `just prod:bootstrap prod:run`.
- All Nextflow plugins available offline; pipeline code and inputs synced from S3; containers served from Nexus without internet.
- Reproducible manifests for code, data, images, and plugins.

## Open Questions
- Final decision on Docker vs Podman in Prod (current configs mix both).
- Any larger reference datasets to mirror (e.g., iGenomes) beyond test inputs?
- Nexus layout/naming (single proxy repo vs hosted repos per source: quay, dockerhub).
