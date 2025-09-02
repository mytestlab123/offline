# Offline Nextflow in AWS (KISS)

Purpose
- Run nf-core pipelines in AWS with two modes:
  - Dev (online): uses quay.io directly, Docker engine.
  - Prod (offline): code/data from S3; containers via Nexus Proxy; Docker engine.

Key Ideas
- Single ENV per pipeline (no global auto-load). Source manually: `source ~/.env; source ENV`.
- Shared logic via symlinks to `common/pipeline/` (`setup.sh`, `justfile`).
- S3 sync uses `--follow-symlinks` so linked files upload as content.
- No security hardening, no container mirroring; choose quay‑only revisions.

Repo Layout
- `common/pipeline/` – shared `setup.sh`, `justfile`, helpers.
- `common/quay/select_quay_revision.sh` – pick quay‑only pipeline tag.
- `common/data/mirror_testdata.sh` – mirror nf-core test inputs to S3 and emit offline config.
- `<pipeline>/` (demo, rnaseq, sarek, bamtofastq) – ENV, test.config, symlinks.

Per‑Pipeline Quick Start
1) cd `<pipeline>`; `source ~/.env; source ENV`
2) `./setup.sh -f` (stages nf-core sources and links ENV/justfile/test.config)
3) cd `<pipeline>` (staged folder)
4) Common recipes (via `just`):
   - `test` / `preview` (online; quay override)
   - `up` / `down` (S3 code sync; follows symlinks; excludes `.nextflow/*`)
   - `run` (offline full run) / `stub2` (offline stub)
   - `check_data` (print S3 and local artifacts)

ENV Expectations
- PIPELINE, REVISION
- S3_ROOT (e.g., `s3://lifebit-user-data-nextflow/offline`), ROOT_DIR (local mirror root)
- NXF_HOME, NXF_WORK, NXF_PLUGIN_AUTOINSTALL=false
- Optional: `PLUGINS_S3=s3://lifebit-user-data-nextflow/pipe/plugins/`

Plugins (optional)
- Dev install + upload: create `plugins.list` (CSV of plugins), then:
  - `PLUGINS_S3=... just plugins_install`
- Offline sync:
  - `PLUGINS_S3=... just plugins_sync`

Choosing a Quay‑only Revision (manual, one‑time)
- `bash common/quay/select_quay_revision.sh --pipeline sarek`
- Review `/tmp/out/sarek/<tag>/container.conf` and `/tmp/out/sarek/selected_tag.txt`.
- Repeat for `rnaseq`, `scrnaseq` as needed.

Test‑Data Mirroring (implemented)
- `bash common/data/mirror_testdata.sh --rows 1 --param-name input --conf ./conf/test.config`
- Writes `offline/inputs3.csv` and `offline/offline_test.conf`; uploads assets to `s3://$S3_ROOT/$PIPELINE/data/`.

Notes
- ARG is passed to all runs to avoid remote config fetches:
  `--custom_config_base null --custom_config_version null --pipelines_testdata_base_path null`
- Use `--follow-symlinks` in S3 sync to avoid stale symlink stubs.
- For offline hosts, ensure Nexus Proxy access to quay is working (pre‑validated).

More
- See GETTING_STARTED.md for step‑by‑step demos (demo + rnaseq).

GitLab Repo Creation (optional)
- Script: `common/create_git_repo.sh`
- Requires: `GITLAB_PAT` env; optional `GITLAB_HOST` (defaults to 100.123.206.229)
- Usage:
  - `GITLAB_PAT=... GITLAB_HOST=<host> bash common/create_git_repo.sh <repo_name> [visibility] [group_id]`
  - Example: `GITLAB_PAT=... bash common/create_git_repo.sh myservice public 2`

Future Work (agreed)
- Nextflow pinning per environment: set `NXF_VER` in your `~/.env` (not in pipeline ENV).
  - Dev: `export NXF_VER=24.04.4`
  - Prod: `export NXF_VER=24.10.5`
