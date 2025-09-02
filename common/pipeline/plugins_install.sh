#!/usr/bin/env bash
set -euo pipefail

# Install Nextflow plugins on a dev (online) host and optionally sync to S3.
# Usage: plugins_install.sh [--list FILE] [--s3 s3://bucket/path]
# Env: NXF_HOME (defaults to ~/.nextflow)

LIST_FILE="plugins.list"
S3_DST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_FILE="$2"; shift 2 ;;
    --s3)   S3_DST="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--list FILE] [--s3 s3://bucket/path]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -f "$LIST_FILE" ]] || { echo "ERROR: missing $LIST_FILE"; exit 1; }

PLUGINS_CSV="$(tr -d '\r' < "$LIST_FILE" | tr '\n' ',' | sed 's/,$//')"
[[ -n "$PLUGINS_CSV" ]] || { echo "ERROR: empty plugins list"; exit 1; }

echo "[i] Installing plugins: $PLUGINS_CSV"
nextflow plugin install "$PLUGINS_CSV"

NXF_HOME_DIR="${NXF_HOME:-$HOME/.nextflow}"
echo "[i] Plugins installed at: $NXF_HOME_DIR/plugins"

if [[ -n "$S3_DST" ]]; then
  command -v aws >/dev/null 2>&1 || { echo "ERROR: aws cli not found"; exit 1; }
  echo "[i] Sync to: $S3_DST"
  aws s3 sync "$NXF_HOME_DIR/plugins/" "$S3_DST"
fi

echo "[i] Done"

