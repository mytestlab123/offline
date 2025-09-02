#!/usr/bin/env bash
set -Eeuo pipefail

# Shared pipeline setup: stage nf-core sources and symlink companion files

# Load pipeline ENV from the calling directory
source ENV

PIPELINE="${PIPELINE:-demo}"
REVISION="${REVISION:-1.0.0}"
VER="${VER:-${REVISION//./_}}"
TARGET_DIR="${TARGET_DIR:-$PIPELINE}"
BUNDLE_DIR="${BUNDLE_DIR:-pipe}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CALL_DIR="$(pwd)"

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

Options:
  -p, --pipeline NAME     Pipeline name (default from ENV or demo)
  -r, --revision VER      Pipeline revision/tag (default from ENV or 1.0.0)
  -t, --target DIR        Target dir to create/use (default: $PIPELINE)
  -f, --force             Force re-download into BUNDLE_DIR
  -h, --help              Show this help

Env overrides:
  PIPELINE, REVISION, VER, TARGET_DIR, BUNDLE_DIR, FORCE_DOWNLOAD
EOF
}

# Arg parsing (overrides ENV)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--pipeline) PIPELINE="$2"; TARGET_DIR="${TARGET_DIR:-$2}"; shift 2 ;;
    -r|--revision) REVISION="$2"; VER="${VER:-${REVISION//./_}}"; shift 2 ;;
    -t|--target)   TARGET_DIR="$2"; shift 2 ;;
    -f|--force)    FORCE_DOWNLOAD=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1"; usage; exit 2 ;;
  esac
done

# Recompute VER if REVISION changed via args
VER="${VER:-${REVISION//./_}}"

for c in nf-core nextflow aws docker rsync; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found"; exit 1; }
done

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

echo "[i] Workspace: $(pwd)"
echo "[i] PIPELINE=${PIPELINE}  REVISION=${REVISION}  VER=${VER}  BUNDLE_DIR=${BUNDLE_DIR}"

need_stage=0
if [[ "$FORCE_DOWNLOAD" == "1" ]]; then
  need_stage=1
elif [[ ! -f main.nf || ! -d conf ]]; then
  need_stage=1
fi

if [[ "$need_stage" == "1" ]]; then
  echo "[i] Downloading ${PIPELINE}@${REVISION} into ${BUNDLE_DIR}"
  rm -rf "${BUNDLE_DIR}"
  nf-core pipelines download "${PIPELINE}" \
    --revision "${REVISION}" \
    --container-system none \
    --compress none \
    --outdir "${BUNDLE_DIR}" --force

  [[ -d "${BUNDLE_DIR}/${VER}" ]] || { echo "ERROR: expected ${BUNDLE_DIR}/${VER} not found"; exit 1; }

  echo "[i] Staging pipeline sources into $(pwd)"
  SRC_DIR="${BUNDLE_DIR}/${VER}"
  [[ -d "$SRC_DIR" ]] || { echo "ERROR: missing $SRC_DIR"; exit 1; }
  # Create a stable snapshot to avoid rsync 'vanished file' warnings
  SNAP_DIR="$(mktemp -d)"
  # small delay to let fs settle if the downloader is still finishing up
  sleep 1; sync || true
  if ! cp -a "$SRC_DIR/." "$SNAP_DIR/" 2>/dev/null; then
    echo "[w] initial copy failed, retrying after short delay..."
    sleep 1; sync || true
    cp -a "$SRC_DIR/." "$SNAP_DIR/"
  fi
  rsync -a --delete "$SNAP_DIR/" .
  rm -rf "$SNAP_DIR"

  # Minimal verification
  [[ -f main.nf && -d conf ]] || { echo "ERROR: staged content incomplete (missing main.nf or conf/)"; exit 1; }

  # Optional: bring local helper script into staged dir if present
  for f in quay_check.sh; do
    if [[ -f "${CALL_DIR}/$f" ]]; then
      rm -f "$f" && ln -sv "${CALL_DIR}/$f" "$f"
    fi
  done
else
  echo "[i] Pipeline files already present; skipping download (use --force to re-download)."
fi

mkdir -p conf

# Symlink companion files from the caller directory
set +e
rm -f justfile && ln -sv "${CALL_DIR}/justfile" justfile 2>/dev/null || true
rm -f ENV && ln -sv "${CALL_DIR}/ENV" ENV 2>/dev/null || true
rm -f conf/test.config && ln -sv "${CALL_DIR}/test.config" conf/test.config 2>/dev/null || true

# Fallback to common/pipeline/justfile if caller lacks justfile
if [[ ! -e justfile && -f "${SCRIPT_DIR}/justfile" ]]; then
  ln -sv "${SCRIPT_DIR}/justfile" justfile
fi

rm -rf "${BUNDLE_DIR}"
echo "[i] Setup completed for ${PIPELINE} ${REVISION} in $(pwd)"
