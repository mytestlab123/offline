Agent Guide

Project Name: "Nextflow Offline"

Purpose
- Keep runs fast and reproducible for nf-core pipelines in AWS.

Task Management
- The old `ai/` task folder is archived under `archive/ai-20260623/`.
- Do not use archived `ai/` files as active instructions.
- For active tasks, use the repo root `AGENTS.md`, current user request, and
  short repo-owned docs.

Defaults
- Docker only; Nexus Proxy serves quay.io.
- No container mirroring; choose quay-only tags.
- Single `ENV` per pipeline; source manually: `source ~/.env; source ENV`.
- Prefer modern CLI tools: rg, fd, bat, jq, yq.

Conventions
- Shared logic lives in `common/pipeline` and is symlinked into each pipeline.
- S3 sync uses `--follow-symlinks` and excludes `.nextflow/*`.
- Use short `just` recipes: `test`, `preview`, `up`, `down`, `run`, `stub2`, `check_data`.
- The five pipeline directories are customized offline working references, not
  clean upstream checkouts: `demo`, `bamtofastq`, `rnaseq`, `sarek`,
  `scrnaseq`. Preserve their offline deltas until they are documented.

Dev Flow
- Pick a quay-only revision with `common/quay/select_quay_revision.sh`.
- Stage: `./setup.sh -f` then `just preview`.
- Optional plugins: `PLUGINS_S3=... just plugins_install`.

Prod Flow
- Sync plugins: `PLUGINS_S3=... just plugins_sync` (offline host).
- `just down` then `just run`.

Style
- Be concise; print only actionable output.
- Use `set -euo pipefail` and clear errors.
- Avoid heavy logs; no uploads of DAGs/artifacts.

Do Not
- Add security hardening or mirroring unless requested.
- Create extra ENV layers; keep a single `ENV` per pipeline.
