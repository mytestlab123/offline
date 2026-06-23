#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/stage-nextflow-tools-to-s3.sh [options]

Purpose:
  Package the local Nextflow/nf-core/Java tool bundle and upload it to the
  approved offline data/artifact S3 path for private EC2 restore.

Options:
  --profile NAME       Default: ${AWS_PROFILE:-default}
  --region REGION      Default: ${AWS_REGION:-ap-southeast-1}
  --tools-root DIR     Default: /mnt/data5/nextflow-tools
  --s3-uri URI         Required unless NEXTFLOW_OFFLINE_TOOLS_S3_URI is set
  --out-dir DIR
  --skip-upload
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
tools_root="/mnt/data5/nextflow-tools"
s3_uri="${NEXTFLOW_OFFLINE_TOOLS_S3_URI:-}"
out_dir="$HOME/.AGENTS-temp/offline/nextflow-tools-stage-$(date +%Y%m%d-%H%M%S)"
skip_upload="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --tools-root) tools_root="${2:?missing --tools-root value}"; shift 2 ;;
    --s3-uri) s3_uri="${2:?missing --s3-uri value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --skip-upload) skip_upload="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -d "$tools_root" ]]; then
  echo "ERROR: tools root missing: $tools_root" >&2
  exit 1
fi

if [[ -z "$s3_uri" ]]; then
  echo "ERROR: --s3-uri or NEXTFLOW_OFFLINE_TOOLS_S3_URI is required" >&2
  exit 2
fi

mkdir -p "$out_dir"
archive="$out_dir/nextflow-tools.tar.gz"

tar -C "$(dirname "$tools_root")" -czf "$archive" "$(basename "$tools_root")"
sha256sum "$archive" | tee "$out_dir/nextflow-tools.tar.gz.sha256"
du -h "$archive" | tee "$out_dir/archive-size.txt"

if [[ "$skip_upload" == "false" ]]; then
  AWS_PROFILE="$profile" aws s3 cp "$archive" "$s3_uri" --region "$region"
  AWS_PROFILE="$profile" aws s3 cp "$out_dir/nextflow-tools.tar.gz.sha256" "$s3_uri.sha256" --region "$region"
fi

cat > "$out_dir/RESULT.md" <<EOF
# Nextflow Tools Stage Result

Tools root: \`$tools_root\`
Archive: \`$archive\`
S3 URI: \`$s3_uri\`
SHA256: \`$out_dir/nextflow-tools.tar.gz.sha256\`
Uploaded: \`$([[ "$skip_upload" == "false" ]] && echo yes || echo no)\`
EOF

cat "$out_dir/RESULT.md"
