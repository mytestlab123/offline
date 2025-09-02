#!/usr/bin/env bash
set -euo pipefail

# Suggest pipeline revisions whose containers are quay-only by sampling provided revisions.
# Usage: suggest_quay_revision.sh --pipeline NAME --revisions "v1 v2 v3"

PIPELINE="${PIPELINE:-}"
REVISIONS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--pipeline) PIPELINE="$2"; shift 2 ;;
    -r|--revisions) REVISIONS="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 --pipeline NAME --revisions \"v1 v2 v3\""; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$PIPELINE" ]] || { echo "ERROR: provide --pipeline"; exit 1; }
[[ -n "$REVISIONS" ]] || { echo "ERROR: provide --revisions \"v1 v2\""; exit 1; }

oklist=()
for rev in $REVISIONS; do
  tmpd="$(mktemp -d)"
  echo "[i] Checking ${PIPELINE}@${rev}"
  nf-core pipelines download "$PIPELINE" --revision "$rev" --container-system none --compress none --outdir "$tmpd/pipe" --force >/dev/null 2>&1 || { echo "  - download failed"; rm -rf "$tmpd"; continue; }
  # find staged dir
  staged="$(find "$tmpd/pipe" -maxdepth 2 -type d -name '*_*' | head -n1)"
  if [[ -z "$staged" ]]; then echo "  - stage missing"; rm -rf "$tmpd"; continue; fi
  if (cd "$staged" && bash -c "$(dirname "$0")/verify_quay_only.sh") >/dev/null 2>&1; then
    echo "  ✔ quay-only"
    oklist+=("$rev")
  else
    echo "  ✖ not quay-only"
  fi
  rm -rf "$tmpd"
done

if [[ ${#oklist[@]} -gt 0 ]]; then
  echo "[i] Suggested quay-only revisions: ${oklist[*]}"
  exit 0
else
  echo "[x] No quay-only revisions found in provided list"
  exit 1
fi

