#!/usr/bin/env bash
set -euo pipefail

# Choose the newest quay-only tag for an nf-core pipeline.
# - Clones/updates repo in /tmp/git/$PIPELINE
# - Checks tags newest→oldest using `nextflow inspect` and rejects any tag with community.wave images.
# - Writes results under /tmp/out/$PIPELINE/<tag>/ and /tmp/out/$PIPELINE/selected_tag.txt
#
# Usage:
#   select_quay_revision.sh --pipeline sarek [--repo https://github.com/nf-core/sarek] [--revisions "3.5.1 3.5.0 3.4.4"]
#

PIPELINE=""
REPO=""
REVISIONS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--pipeline) PIPELINE="$2"; shift 2 ;;
    --repo)        REPO="$2"; shift 2 ;;
    -r|--revisions) REVISIONS="$2"; shift 2 ;;
    -h|--help)     grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$PIPELINE" ]] || { echo "ERROR: --pipeline required" >&2; exit 1; }
REPO="${REPO:-https://github.com/nf-core/${PIPELINE}}"

for c in git nextflow awk grep sort tac sed tee; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing tool: $c" >&2; exit 1; }
done

GIT_DIR="/tmp/git/${PIPELINE}"
OUT_ROOT="/tmp/out/${PIPELINE}"
mkdir -p "$GIT_DIR" "$OUT_ROOT"

if [[ ! -d "$GIT_DIR/.git" ]]; then
  echo "[i] Cloning: $REPO -> $GIT_DIR"
  git clone --quiet "$REPO" "$GIT_DIR"
else
  echo "[i] Updating: $GIT_DIR"
  (cd "$GIT_DIR" && git fetch --tags --quiet)
fi

cd "$GIT_DIR"

# Candidate tags list
if [[ -z "$REVISIONS" ]]; then
  mapfile -t TAGS < <(git tag -l | sort -V | tac)
else
  # respect provided order
  read -r -a TAGS <<< "$REVISIONS"
fi

SELECTED=""
for tag in "${TAGS[@]}"; do
  [[ -n "$tag" ]] || continue
  echo "[i] Checking ${PIPELINE}@${tag}"
  git checkout -q "$tag" || { echo "  - skip (checkout failed)"; continue; }
  OUT_DIR="${OUT_ROOT}/${tag}"
  mkdir -p "$OUT_DIR"
  if ! nextflow inspect . -profile test --outdir "$OUT_DIR" -concretize true -format config \
       | tee "${OUT_DIR}/container.conf" >/dev/null; then
    echo "  - skip (nextflow inspect failed)"
    continue
  fi
  wave_cnt=$(grep -c 'community.wave.seqera.io' "${OUT_DIR}/container.conf" || true)
  if [[ "${wave_cnt}" -gt 0 ]]; then
    echo "  ✖ contains wave images (${wave_cnt})"
    continue
  fi
  quay_cnt=$(grep -c 'quay.io/' "${OUT_DIR}/container.conf" || true)
  echo "  ✔ quay-only (quay refs: ${quay_cnt})"
  SELECTED="$tag"
  break
done

if [[ -n "$SELECTED" ]]; then
  echo "$SELECTED" | tee "${OUT_ROOT}/selected_tag.txt"
  echo "[i] Selected quay-only tag: $SELECTED"
  exit 0
else
  echo "[x] No quay-only tag found in provided candidates" >&2
  exit 1
fi

