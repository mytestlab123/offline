#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/stage-workflow-source-to-s3.sh --source-dir DIR --s3-uri URI [options]

Purpose:
  Stage a local Nextflow workflow source directory to S3 so private EC2 hosts
  can run it without Git or public internet.

Options:
  --profile NAME       Default: ${AWS_PROFILE:-default}
  --region REGION      Default: ${AWS_REGION:-ap-southeast-1}
  --source-dir DIR     Required. Directory containing main.nf and nextflow.config.
  --s3-uri URI         Required unless NEXTFLOW_OFFLINE_WORKFLOW_S3_URI is set.
  --dry-run            Show planned sync only.
  --delete             Remove destination objects not present locally.
  --help

The sync is non-destructive by default.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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
source_dir=""
s3_uri="${NEXTFLOW_OFFLINE_WORKFLOW_S3_URI:-}"
dry_run="false"
delete_extra="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --source-dir) source_dir="${2:?missing --source-dir value}"; shift 2 ;;
    --s3-uri) s3_uri="${2:?missing --s3-uri value}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --delete) delete_extra="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$source_dir" && -d "$source_dir" ]] || die "--source-dir must be an existing directory"
[[ -f "$source_dir/main.nf" ]] || die "main.nf not found under source dir"
[[ -f "$source_dir/nextflow.config" ]] || die "nextflow.config not found under source dir"
[[ -n "$s3_uri" && "$s3_uri" == s3://* ]] || die "--s3-uri must be an s3:// URI"

args=(
  s3 sync
  "$source_dir/"
  "$s3_uri"
  --region "$region"
  --no-follow-symlinks
  --exclude ".git/*"
  --exclude ".nextflow/*"
  --exclude "work/*"
  --exclude ".nf-test/*"
  --exclude ".pytest_cache/*"
)

if [[ "$delete_extra" == "true" ]]; then
  args+=(--delete)
fi

if [[ "$dry_run" == "true" ]]; then
  args+=(--dryrun)
fi

AWS_PROFILE="$profile" aws "${args[@]}"
