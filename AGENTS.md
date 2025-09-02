Agent Guide

Project Name: "Nextflow Offline"

Purpose
- Keep runs fast and reproducible for nf-core pipelines in AWS.

Task Management
- Always check ai directory for tasks.md, progress.md (TODO) and current.md
- tasks.md: Tasks description for current PR. This is Maanged by Developer i.e. Amit
- All following files must update and managed by Codex AI Agent
- progress.md: Progress list/ Updated TODO for current PR 
- current.md: Current Task from progress.md, it is always one Task
- issues.md: All history of issues/ PR/ tasks for future reference
- PRD.md: Project Requirement Document (Used for Long Term)

Defaults
- Docker only; Nexus Proxy serves quay.io.
- No container mirroring; choose quay-only tags.
- Single `ENV` per pipeline; source manually: `source ~/.env; source ENV`.
- Prefer modern CLI tools: rg, fd, bat, jq, yq.

Conventions
- Shared logic lives in `common/pipeline` and is symlinked into each pipeline.
- S3 sync uses `--follow-symlinks` and excludes `.nextflow/*`.
- Use short `just` recipes: `test`, `preview`, `up`, `down`, `run`, `stub2`, `check_data`.

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

