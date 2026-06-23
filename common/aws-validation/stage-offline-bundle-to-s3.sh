#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/stage-offline-bundle-to-s3.sh --bundle-dir DIR [options]

Purpose:
  Upload a proven nf-core offline bundle to the approved S3 data/artifact path.

Options:
  --profile NAME       Default: ${AWS_PROFILE:-default}
  --region REGION      Default: ${AWS_REGION:-ap-southeast-1}
  --bundle-dir DIR     Required. Example: .../downloads/testpipeline
  --s3-uri URI         Required unless NEXTFLOW_OFFLINE_BUNDLE_S3_URI is set
  --dry-run
  --delete             Remove destination objects not present locally
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
bundle_dir=""
s3_uri="${NEXTFLOW_OFFLINE_BUNDLE_S3_URI:-}"
dry_run="false"
delete_extra="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --bundle-dir) bundle_dir="${2:?missing --bundle-dir value}"; shift 2 ;;
    --s3-uri) s3_uri="${2:?missing --s3-uri value}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --delete) delete_extra="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$bundle_dir" || ! -d "$bundle_dir" ]]; then
  echo "ERROR: --bundle-dir must be an existing directory" >&2
  exit 1
fi

if [[ -z "$s3_uri" ]]; then
  echo "ERROR: --s3-uri or NEXTFLOW_OFFLINE_BUNDLE_S3_URI is required" >&2
  exit 2
fi

if [[ ! -f "$bundle_dir/docker-images/docker-load.sh" ]]; then
  echo "ERROR: expected docker-load.sh missing: $bundle_dir/docker-images/docker-load.sh" >&2
  exit 1
fi

if ! find "$bundle_dir" -maxdepth 1 -type d -name "*_*_*" | grep -q .; then
  echo "ERROR: expected workflow revision directory like 3_2_1 under $bundle_dir" >&2
  exit 1
fi

args=(
  s3 sync
  "$bundle_dir/"
  "$s3_uri"
  --region "$region"
  --no-follow-symlinks
)

if [[ "$delete_extra" == "true" ]]; then
  args+=(--delete)
fi

if [[ "$dry_run" == "true" ]]; then
  args+=(--dryrun)
fi

AWS_PROFILE="$profile" aws "${args[@]}"
