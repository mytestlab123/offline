#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-testpipeline-bamtofastq-testdata-smoke.sh [options]

Compatibility wrapper for:
  run-nfcore-testdata-smoke.sh --pipeline testpipeline --pipeline bamtofastq

Options:
  --out-dir DIR   Output directory. Default: out/test-data-smoke/testpipeline-bamtofastq
  --upload        Also upload files. Requires --s3-root or S3_ROOT.
  --s3-root URI   Private S3 root for upload/config.
  --help          Show this help.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="${script_dir}/run-nfcore-testdata-smoke.sh"

out_dir="${OUT_DIR:-out/test-data-smoke/testpipeline-bamtofastq}"
s3_root="${S3_ROOT:-}"
upload=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      [[ -n "${2-}" ]] || { echo "ERROR: --out-dir requires a value" >&2; exit 2; }
      out_dir="$2"
      shift 2
      ;;
    --upload)
      upload=1
      shift
      ;;
    --s3-root)
      [[ -n "${2-}" ]] || { echo "ERROR: --s3-root requires a value" >&2; exit 2; }
      s3_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

args=(
  --pipeline testpipeline
  --pipeline bamtofastq
  --out-dir "$out_dir"
  --download
)

[[ -x "$runner" ]] || {
  echo "ERROR: compatibility runner missing or not executable: $runner" >&2
  exit 1
}

if [[ "$upload" -eq 1 ]]; then
  args+=(--upload --s3-root "$s3_root")
fi

exec "$runner" "${args[@]}"
