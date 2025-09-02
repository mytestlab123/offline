#!/usr/bin/env bash
set -euo pipefail

# Sync Nextflow plugins from S3 onto this offline host.
# Usage: plugins_sync_offline.sh --s3 s3://bucket/path

S3_SRC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --s3) S3_SRC="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 --s3 s3://bucket/path"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$S3_SRC" ]] || { echo "ERROR: provide --s3 s3://..."; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws cli not found"; exit 1; }

NXF_HOME_DIR="${NXF_HOME:-$HOME/.nextflow}"
mkdir -p "$NXF_HOME_DIR/plugins"
echo "[i] Syncing from $S3_SRC to $NXF_HOME_DIR/plugins"
aws s3 sync "$S3_SRC" "$NXF_HOME_DIR/plugins"
echo "[i] Plugins present: $(ls -1 "$NXF_HOME_DIR/plugins" | wc -l)"

