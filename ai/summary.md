KISS Prompt: nf-core pipelines (Dev/Prod)

Assumptions
- Docker only; Nexus Proxy for offline pulls; quay-only pipeline revisions.
- Single `ENV` per pipeline; shared logic in `common/pipeline` via symlinks.

Per-pipeline Setup
1) cd <pipeline>; source ~/.env; source ENV
2) ./setup.sh -f
3) cd <pipeline> (staged folder)

Frequent Recipes (just)
- test: online quick run (quay override)
- preview: online preview
- up: upload code/config to `s3://$S3_ROOT/$PIPELINE/$PIPELINE` (follow symlinks; exclude .nextflow)
- down: download to `$ROOT_DIR/$PIPELINE/$PIPELINE` (follow symlinks; exclude .nextflow)
- run: offline run with `-offline`
- stub2: offline stub run

Data Check
- just check_data

Plugins
- echo 'nf-amazon@<ver>,nf-validation@<ver>,nf-prov@<ver>' > plugins.list
- just plugins_install PLUGINS_S3=s3://lifebit-user-data-nextflow/pipe/plugins/
- On offline host: just plugins_sync PLUGINS_S3=s3://lifebit-user-data-nextflow/pipe/plugins/

Quay Helpers
- Preferred: standalone script `quay_check.sh` in each pipeline (no justfile dependency).
- Setup places it into the staged folder if present at pipeline root.
- Usage: `./quay_check.sh [--allow 'regex'] [--print-all]` (default allow: quay.io and Nexus-quay).
- Optional: `REVISIONS="<v1> <v2>" just suggest_revision` (dev-only net access).

Notes
- up/down use `--follow-symlinks` and exclude `.nextflow/*`.
- Ensure `S3_ROOT`, `ROOT_DIR`, `NXF_HOME`, `NXF_WORK` set in ENV.
