#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/sync-repo-to-s3.sh [options]

Purpose:
  Sync this repo's deterministic validation code to the approved S3 repo path
  so private EC2 hosts can pull it without GitLab access.

Options:
  --profile NAME      Default: ${AWS_PROFILE:-default}
  --region REGION     Default: ${AWS_REGION:-ap-southeast-1}
  --s3-uri URI        Required unless NEXTFLOW_OFFLINE_REPO_S3_URI is set
  --dry-run
  --help
EOF
}

load_env_file() {
  local script_dir repo_root env_file nounset_was_on
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/../.." && pwd)"
  env_file="${NEXTFLOW_OFFLINE_ENV_FILE:-$repo_root/.env}"
  if [[ -f "$env_file" ]]; then
    nounset_was_on=0
    case "$-" in *u*) nounset_was_on=1; set +u ;; esac
    set -a
    # shellcheck source=/dev/null
    . "$env_file"
    set +a
    if [[ "$nounset_was_on" == "1" ]]; then
      set -u
    fi
  fi
}

load_env_file

profile="${AWS_PROFILE:-default}"
region="${AWS_REGION:-ap-southeast-1}"
s3_uri="${NEXTFLOW_OFFLINE_REPO_S3_URI:-}"
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --s3-uri) s3_uri="${2:?missing --s3-uri value}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ -z "$s3_uri" ]]; then
  echo "ERROR: --s3-uri or NEXTFLOW_OFFLINE_REPO_S3_URI is required" >&2
  exit 2
fi

args=(
  s3 sync .
  "$s3_uri"
  --region "$region"
  --delete
  --no-follow-symlinks
  --exclude "*"
  --include "AGENTS.md"
  --include "README.md"
  --include "GETTING_STARTED.md"
  --include "justfile"
  --include ".gitignore"
  --include "common/*"
  --include "common/**"
  --include "tests/*"
  --include "tests/**"
  --include "archive/offline-pipeline-references/*"
  --include "archive/offline-pipeline-references/**"
  --exclude ".git/*"
  --exclude ".nextflow/*"
  --exclude "out/*"
  --exclude "null/*"
  --exclude "summarize.md"
  --exclude "*/.nextflow/*"
  --exclude "*/work/*"
)

if [[ "$dry_run" == "true" ]]; then
  args+=(--dryrun)
fi

AWS_PROFILE="$profile" aws "${args[@]}"
