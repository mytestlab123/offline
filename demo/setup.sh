#!/usr/bin/env bash
set -Eeuo pipefail

export PIPELINE=demo
export REVISION=1.0.1
export BUNDLE_DIR="pipe"

# prerequisites
for c in nf-core nextflow aws podman rsync; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found"; exit 1; }
done

# pull and stage pipeline code at repo root if missing
if [[ ! -f main.nf || ! -d conf ]]; then
  echo "[i] Downloading ${PIPELINE} ${REVISION} into ${BUNDLE_DIR}"
  rm -rf "$BUNDLE_DIR"
  nf-core pipelines download "$PIPELINE" \
    --revision "$REVISION" \
    --container-system none \
    --compress none \
    --outdir "$BUNDLE_DIR" --force
  if [[ ! -d "${BUNDLE_DIR}/1_0_1" ]]; then
    echo "ERROR: expected ${BUNDLE_DIR}/1_0_1 not found"; exit 1
  fi
  echo "[i] Staging pipeline sources into $(pwd)"
  rsync -a "${BUNDLE_DIR}/1_0_1/" .
fi

mkdir -p offline

echo "[i] Setup completed for ${PIPELINE} ${REVISION}"
