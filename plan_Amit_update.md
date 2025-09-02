# Offline Nextflow in AWS — Improvement Plan (v2)

## Intent
- Run nf-core pipelines in AWS with two modes:
  - Dev: online, uses direct/quay registry via internet, Docker engine runtime.
  - Prod: offline/air‑gapped, code and inputs from S3, containers via Nexus Proxy (no dedicated mirroring), Docker engine runtime.

## Current State (repo summary)
- Pipelines prepared under `demo/`, `bamtofastq/`, `rnaseq/`, `sarek/` with:
  - `setup.sh`: downloads a pinned nf-core release, stages sources locally.
  - `test.config`: forces S3 inputs, disables remote configs, points `docker.registry` to Nexus.
  - `justfile`: targets to test online, push code to S3, pull to offline host, and run with `-offline`.
  - `prepare_*_offline_test.sh`: mirrors small test datasets to S3 and emits `offline/inputs3.csv`.
- ENV files set `NXF_PLUGIN_AUTOINSTALL=false`, `NXF_HOME`, `S3_ROOT`, `ROOT_DIR`.

Gaps/opportunities (unchanged):
- Duplication across pipelines (setup, prepare scripts, justfiles, ENV vs .env naming).
- No automated container mirroring to Nexus or image manifest generation.
- No pre-cache of Nextflow plugins (e.g., `nf-amazon`) for offline runs.
- No single top-level orchestrator; manual sequencing across folders.
- Limited guardrails (version pinning summary, integrity checks, smoke tests, docs).

Response — ENV structure and loading

Amit asked for two env files: a system-wide and a pipeline‑specific file.

Recommended pattern:
- `env/System-ENV`: common settings kept under version control (pushed with code).
- Per‑pipeline `Pipeline-ENV` inside each pipeline folder for that pipeline.
- Root `justfile` uses `set dotenv-filename := "env/System-ENV"`.
- Per‑pipeline `justfile` uses `set dotenv-filename := "Pipeline-ENV"`.
- Scripts still `source ENV` files directly where needed to keep parity with `export` style.

Example contents remain as suggested by Amit:
set dotenv-filename := "env/System-ENV"
{
# .env
export REGISTRY_PROXY=nexus-docker-quay.ship.gov.sg
export HOME_DIR="${HOME}"
export OFFLINE_DIR="${HOME_DIR}/offline"

export S3SERVICE="s3://trust-dev-team"
export S3_ROOT="s3://lifebit-user-data-nextflow/offline"
export ROOT_DIR="${HOME_DIR}/offline"

export NXF_LOG_FILE=/tmp/runs.log
export NXF_HOME="$HOME/.nextflow"
export NXF_WORK=/tmp/nxf-work
export NXF_PLUGIN_AUTOINSTALL=false
}

set dotenv-filename := "Pipeline-ENV"
{
export PIPELINE=sarek
export REVISION=3.4.4

}

## Plan (phased, incremental)

1) Standardize layout and configs
- Create `scripts/` and `profiles/` at repo root; move shared scripts there.
- Provide `profiles/offline.config` for common offline toggles used by all pipelines.
- Unify env handling via `.env.template` and per-pipeline `.env` (or `ENV`) consistently.
- Add a top-level `justfile` to orchestrate all pipelines with common verbs.

Response — One or two justfiles, and symlinks
- Keep two: a root `justfile` (rare/ops tasks) and a per‑pipeline `justfile` (frequent tasks).
- Per‑pipeline `justfile` can be a thin wrapper that delegates to root or owns only the frequent recipes.
- Symlink is fine if convenient: create `pipeline/<name>/justfile -> ../../Justfile`.
- If not using symlinks, put small wrappers in each pipeline dir to call root via `just --working-directory .. <recipe>`.

2) Pipeline staging (code)
- Replace per-folder `setup.sh` with `scripts/stage_pipeline.sh`:
  - Inputs: `--name <pipeline> --revision <tag> --dest pipelines/<name>`.
  - Uses `nf-core pipelines download --container-system none` and rsyncs into place.
  - Emits `pipelines/<name>/manifest.json` (name, revision, commit, date).

Response — manifest vs VERSION
- `manifest.json` helps reproducibility (records name, revision, commit, dates) but is optional if you prefer simplicity.
- Adopt Amit’s preference: keep a simple `Pipeline-ENV` (or `VERSION`) within each pipeline folder with:
  - `export PIPELINE=<name>`
  - `export REVISION=<tag>`
- Root staging script will write/update this file when staging.

3) Data mirroring (tests and small refs)
- Consolidate to `scripts/mirror_testdata.sh`:
  - Parses a given `conf/test.config`, fetches samplesheet, trims N rows, downloads referenced HTTP assets.
  - Writes `offline/inputs3.csv` and syncs staged assets to `s3://.../<pipeline>/data`.
  - Produces `SHA256SUMS` and a small `data.manifest.json`.

Response — integrity and data manifest
- Default: no `SHA256SUMS` and no `data.manifest.json`.
- Optional flags can enable them later if needed for audits: `--with-checksums`, `--emit-manifest`.
- If ever used, `data.manifest.json` simply enumerates mirrored files + S3 URIs to cross‑check `inputs3.csv` alignment.

4) Container handling with Nexus Proxy (no mirroring)
- Add `scripts/collect_images.sh` to emit `images.txt` per pipeline:
  - Derive containers from `conf/modules.config`, `modules.json`, and `nextflow config` resolution.
- Add `scripts/mirror_images_to_nexus.sh` (requires `skopeo` or `crane`):
  - `skopeo copy docker://quay.io/... docker://<nexus>/<repo>/...` for each pinned tag/digest.
  - Optionally `docker pull` from Nexus and `docker save` to tarballs as offline fallback.
- Verify: `scripts/verify_images.sh` pulls from Nexus and reports digests.

Decision
- No mirroring step. Rely on Nexus Proxy; choose pipeline revisions that resolve exclusively from quay.io.

Enhancement
- Add helper scripts:
  - `scripts/verify_quay_only.sh`: parses resolved container list and fails if any non‑quay registry appears.
  - `scripts/suggest_quay_revision.sh`: given a pipeline name, queries a shortlist of tags and prints ones where all images are quay‑hosted.


5) Nextflow/plugin offline cache
- Add `plugins.txt` (e.g., `nf-amazon@<ver>`, others if needed).
- Add `scripts/cache_nextflow_plugins.sh` that runs online to preinstall into `$NXF_HOME/plugins/` and tars them to `s3://.../nextflow/plugins/`.
- Offline bootstrap pulls this cache and sets `NXF_PLUGIN_AUTOINSTALL=false` (already set).

Decision
- Keep your current rsync‑style approach. No tar/compression.
- Add `plugins.list` (e.g., `nf-amazon@2.9.3,nf-validation@1.1.3,nf-prov@1.2.2`).
- Add small helpers:
  - `scripts/plugins_install.sh` (Dev): installs from `plugins.list` and syncs to S3 path.
  - `scripts/plugins_sync_offline.sh` (Prod): syncs from S3 to `$NXF_HOME/plugins`.


6) Orchestration (two justfiles + recipe names)
- Targets (operate per `PIPELINE` env):
  - `stage`: stage nf-core code.
  - `mirror:data`: run testdata mirroring and push manifests.
  - `images:list` and `images:mirror`: generate and mirror containers to Nexus.
  - `push:code`: sync `pipelines/<name>` to S3 (exclude `work/`).
  - `dev:smoke`: online `-stub` run using Nexus proxy.
  - `prod:bootstrap`: offline host bootstrap (code + plugins + login to Nexus).
  - `prod:run`: offline run with `-offline -profile test,offline`.

Decision
- Root `justfile` (rare/ops): `stage`, `mirror:data`, `verify:quay`, `suggest:revision`, `dev:smoke`, `prod:bootstrap`.
- Per‑pipeline `justfile` (frequent):
  - `up`: upload code/config to S3 (previously `push`).
  - `down`: download code/config from S3 (previously `pull`).
  - `run`: offline `-offline -profile test`.
  - `stub`: offline stub run.
  - `preview`: online preview.
  - `test`: online quick run.
- Short names enable zsh aliases and completion. We’ll add concise, one‑line descriptions to each recipe.

7) Dev online smoke tests
- Add consistent `-stub` and `-preview` runs; store logs and `DAG.svg` to `artifacts/` then to S3.
- Add a quick validator that asserts: Nexus reachable, images resolvable, S3 inputs present.

Decision
- Keep only `stub` and `preview`. No artifact upload.
- Drop network validators for Dev; rely on immediate run feedback. We’ll retain a lightweight `just check:data` (optional) to print S3 dataset presence.

8) Prod offline bootstrap
- `scripts/bootstrap_offline.sh` does:
  - `aws s3 sync` of `pipelines/<name>` and `offline/` to target host.
  - Pulls Nextflow plugin cache; ensures `$NXF_HOME/plugins` is populated.
  - Logs into Nexus, validates CA, and tests a single `docker pull` from Nexus.
  - Runs `nextflow run . -offline -profile test,offline -resume`.

Decision
- Minimal bootstrap only: S3 sync code + plugins, ensure dirs, then run. No Nexus login/CA checks.

9) Security and reliability
- Enforce S3 SSE (KMS) on sync; optional bucket policies and VPC endpoints.
- Prefer image digests over tags in `images.txt` where practical.
- Keep manifests with SHA256 sums for data and plugins.
- Add `NXF_OPTS='-Xms1g -Xmx4g'` defaults and consistent `NXF_WORK` on fast local disk.

Decision
- Skip hardening for now. Leave as future work items.


10) Documentation and CI
- Add a root `README.md` with architecture diagrams and runbooks for Dev/Prod.
- Provide `docs/offline-checklist.md` with a pre-flight list for air‑gapped runs.
- Optional CI: smoke `-stub` run in Dev to catch obvious regressions (skips heavy downloads).

Decision
- Defer docs and CI.


## Acceptance Criteria
- Dev: `just stage`, `just mirror:data`, `just verify:quay`, `just preview`/`just test`, `just up` (as needed).
- Prod: `just down`, `just run` (plugins pre-synced via `plugins_sync_offline.sh`).
- Plugins available offline; pipeline code/config and inputs synced via S3; containers resolve via Nexus Proxy.

## Open Questions
- Final decision on Docker vs Podman in Prod (current configs mix both).
- Any larger reference datasets to mirror (e.g., iGenomes) beyond test inputs?
- Nexus layout/naming (single proxy repo vs hosted repos per source: quay, dockerhub).


Open confirmations
- ENV format: keep `export VAR=...` style in both `env/System-ENV` and per‑pipeline `Pipeline-ENV`.
- Two justfiles approach is acceptable? (root and per‑pipeline wrappers/symlinks).
- Symlinks vs wrappers: do you prefer symlinks for per‑pipeline `justfile`?

Next steps (proposed minimal implementation set)
- Create `env/System-ENV` and migrate shared settings.
- Add root `justfile` with rare/ops recipes listed above.
- Add per‑pipeline thin `justfile` exposing: `up`, `down`, `run`, `stub`, `preview`, `test` using `Pipeline-ENV`.
- Add `scripts/verify_quay_only.sh` and `scripts/suggest_quay_revision.sh`.
- Add `plugins.list`, `scripts/plugins_install.sh`, `scripts/plugins_sync_offline.sh`.
- Replace per‑folder `setup.sh` with `scripts/stage_pipeline.sh` and call it from root `justfile`.

Process: Research ⇒ Planning ⇒ POC ⇒ Coding (for bash + Linux + AWS)
- Research: capture decisions and constraints in a short issue/RFC; link to upstream docs and chosen revisions.
- Planning: define 3–6 concrete tasks with inputs/outputs and acceptance criteria; note explicit non‑goals.
- POC: build a minimal, disposable script or branch proving the riskiest assumption (e.g., quay‑only resolution for a pipeline tag); timebox to hours, not days.
- Coding: convert POC into idempotent scripts (`set -euo pipefail`), add `just` recipes, parametrize via env, and document one‑liners in comments.
- Validation: run `stub`/`preview` locally; add a `check:data` helper; keep logs local unless needed.
- Handoff: update env files, and list the exact commands to run in Dev and Prod.

I want simple and short names for "justfile" recipes
and
I also want two groups:
# Convenience groups
online:
    just test up

offline:
    just down run

Only Docker
As of now, I am only focusing for test.config and minimum reference datasets

No need for "Nexus layout/naming (single proxy repo vs hosted repos per source: quay, dockerhub).", as of now Nexus works perfectly

I don't want to add extra layer of "Tighten security (S3 SSE/KMS, image digests)"
}

====================
Updated


## Open Questions
- Final decision on Docker vs Podman in Prod (current configs mix both). ==> 100% Docker
- Any larger reference datasets to mirror (e.g., iGenomes) beyond test inputs? = NO
- Nexus layout/naming (single proxy repo vs hosted repos per source: quay, dockerhub). = NO


Open confirmations
- ENV format: keep `export VAR=...` style in both `env/System-ENV` and per‑pipeline `Pipeline-ENV`. - yes
- Two justfiles approach is acceptable? (root and per‑pipeline wrappers/symlinks). - yes
- Symlinks vs wrappers: do you prefer symlinks for per‑pipeline `justfile`? - symlinks

Next steps (proposed minimal implementation set)
- Create `env/System-ENV` and migrate shared settings.
- Add root `justfile` with rare/ops recipes listed above.
- Add per‑pipeline thin `justfile` exposing: `up`, `down`, `run`, `stub`, `preview`, `test` using `Pipeline-ENV`.
- Add `scripts/verify_quay_only.sh` and `scripts/suggest_quay_revision.sh`.
- Add `plugins.list`, `scripts/plugins_install.sh`, `scripts/plugins_sync_offline.sh`.
- Replace per‑folder `setup.sh` with `scripts/stage_pipeline.sh` and call it from root `justfile`.

Process: Research ⇒ Planning ⇒ POC ⇒ Coding (for bash + Linux + AWS)
- Research: capture decisions and constraints in a short issue/RFC; link to upstream docs and chosen revisions.
- Planning: define 3–6 concrete tasks with inputs/outputs and acceptance criteria; note explicit non‑goals.
- POC: build a minimal, disposable script or branch proving the riskiest assumption (e.g., quay‑only resolution for a pipeline tag); t
imebox to hours, not days.
- Coding: convert POC into idempotent scripts (`set -euo pipefail`), add `just` recipes, parametrize via env, and document one‑liners
in comments.
- Validation: run `stub`/`preview` locally; add a `check:data` helper; keep logs local unless needed.
- Handoff: update env files, and list the exact commands to run in Dev and Prod.



>> Good

More:

Also during execution of "setup.sh", I copy files "ENV, justfile, test.config" into downloaded pipeline folder (which I added in .gitignore example: "sarek/sarek"). I prefer I should create symlink. 
Example: 
Considering ${SCRIPT_DIR}=sarek
ls -sv ENV sarek/ENV
ls -sv justfile sarek/justfile
ls -sv test.config sarek/conf/test.config
Backup "test.config"
Also create and copy "inputs3.csv" into ${SCRIPT_DIR}/
Also add small scritp (for future): to add pipeline folder into internal gitlab server using curl + git commands. You refer script in root "new_repo.sh"

Follow the KISS (Keep it short and stupid) framework.
Let me know if Codex CLI need any latest shell/Linux cli for faster terminal operations @~/.codex/AGENTS.md
