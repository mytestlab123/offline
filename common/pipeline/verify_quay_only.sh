#!/usr/bin/env bash
set -euo pipefail

# Verify that all declared containers resolve to quay.io (or Nexus proxy of quay).
# Run from within a staged pipeline directory (contains conf/modules.config etc.).

ALLOW_PREFIXES_REGEX='^(quay\.io/|nexus-docker-quay\.)'

found=0
while IFS= read -r line; do
  img="${line#*=}"
  img="${img//\"/}"
  img="${img//\'/}"
  img="${img// /}"
  img="${img#,}"
  if [[ ! "$img" =~ $ALLOW_PREFIXES_REGEX ]]; then
    echo "NON-QUAY: $img"
    found=1
  fi
done < <(rg -n "container\s*=\s*['\"]([^'\"]+)['\"]" -N --no-heading conf modules . 2>/dev/null | awk -F: '{sub(/.*=\s*/,"",$0); print $0}')

if [[ $found -ne 0 ]]; then
  echo "[x] Non-quay containers detected"; exit 1
fi
echo "[✔] All containers appear quay-only"

