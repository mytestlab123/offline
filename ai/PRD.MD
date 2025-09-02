# PRD: Offline Nextflow in AWS (KISS)

Objective
- Run nf-core pipelines in AWS with two modes: Dev (online via quay) and Prod (offline via S3 + Nexus Proxy), using Docker only.

Scope
- Pipelines: demo, rnaseq, sarek, bamtofastq.
- Data: minimal test datasets only; no large references.
- Images: no mirroring; choose quay-only revisions so Nexus Proxy fully serves pulls.
- Security: no hardening beyond defaults.

Constraints
- Air-gapped Prod (no internet). S3 and Nexus reachable via VPC endpoints.
- Single `ENV` per pipeline; operator sources: `source ~/.env; source ENV`.
- Use symlinks to share logic (`common/pipeline`).

User Story
- As an operator, I can stage a specific nf-core pipeline revision, sync code/config via S3, and run it offline with containers resolving via Nexus, without touching the internet.

Architecture
- Shared: `common/pipeline/setup.sh` stages nf-core sources; symlinks `ENV`, `justfile`, and `conf/test.config` into the staged folder. S3 sync uses `--follow-symlinks`.
- Per pipeline: `ENV`, `test.config`, and symlinks to shared `setup.sh` and `justfile`.
- Quay-only selection: manual script `common/quay/select_quay_revision.sh` using `nextflow inspect` to reject wave containers.

Operational Flows
- Dev (online)
  1) `cd <pipeline>; source ~/.env; source ENV`
  2) `./setup.sh -f`; `cd <pipeline>`
  3) `just preview` (or `test`)
  4) `just up` to sync code/config to S3 (follows symlinks; excludes `.nextflow/*`).

- Prod (offline)
  1) `cd <pipeline>; source ~/.env; source ENV`
  2) `just down` to pull code/config from S3
  3) `just run` (offline)

Environment
- Required: `PIPELINE`, `REVISION`, `S3_ROOT`, `ROOT_DIR`, `NXF_HOME`, `NXF_WORK`, `NXF_PLUGIN_AUTOINSTALL=false`.
- Optional: `PLUGINS_S3` if syncing Nextflow plugins via S3.

Non-Goals
- No container mirroring, no digest pinning, no checksum manifests.
- No heavy data curation; only test datasets.

Acceptance Criteria
- Dev and Prod flows run for all listed pipelines.
- S3 sync reflects updates due to `--follow-symlinks`.
- Quay-only tags are selected using the manual script; Nexus Proxy successfully serves pulls.

References
- plan.md (initial intent and gaps)
- plan_Amit_update.md (decisions: Docker-only, single ENV, no hardening, symlink strategy)
- prompt.md (quay-only revision discovery with `nextflow inspect`)

Future Work (approved)
- Pin Nextflow version per environment
  - Dev: `NXF_VER=24.04.4`; Prod: `NXF_VER=24.10.5`.
  - Placement: set in operator `~/.env` (keeps pipeline ENV stable and portable).
  - Success: `nextflow -version` prints the pinned version on both Dev and Prod before runs.

- Unify test‑data mirroring
  - Add `common/data/mirror_testdata.sh` implementing current per‑pipeline logic (flags: `--rows`, `--param-name`, `--conf`).
  - Update pipelines to call the common script; remove duplicated `prepare_offline_test.sh`.
  - Success: each pipeline produces `offline/inputs3.csv` and syncs assets to `s3://$S3_ROOT/$PIPELINE/data/` identically via the shared script.
