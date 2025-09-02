#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------
# Defaults (can be overridden by env or args)
# -------------------------------
source ENV
PIPELINE="${PIPELINE:-demo}"
REVISION="${REVISION:-1.0.1}"
VER="${VER:-${REVISION//./_}}"
TARGET_DIR="${TARGET_DIR:-$PIPELINE}"
BUNDLE_DIR="${BUNDLE_DIR:-pipe}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"   # 1 = always re-download into BUNDLE_DIR

# Resolve script directory (so copies work no matter where you run from)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

Options:
  -p, --pipeline NAME     Pipeline name (default: demo)
  -r, --revision VER      Pipeline revision/tag (default: 1.0.1)
  -t, --target DIR        Target dir to create/use (default: $PIPELINE)
  -f, --force             Force re-download into BUNDLE_DIR
  -h, --help              Show this help

Env overrides:
  PIPELINE, REVISION, VER, TARGET_DIR, BUNDLE_DIR, FORCE_DOWNLOAD

Examples:
  ./setup.sh
  ./setup.sh -p demo -r 1.0.1
  PIPELINE=myflow TARGET_DIR=work ./setup.sh -f
EOF
}

# -------------------------------
# Arg parsing
# -------------------------------
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

# -------------------------------
# Preconditions
# -------------------------------
for c in nf-core nextflow aws docker rsync; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found"; exit 1; }
done

# -------------------------------
# Prepare target workspace
# -------------------------------
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

echo "[i] Workspace: $(pwd)"
echo "[i] PIPELINE=${PIPELINE}  REVISION=${REVISION}  VER=${VER}  BUNDLE_DIR=${BUNDLE_DIR}"

# -------------------------------
# Download & stage pipeline (only if missing, unless --force)
# -------------------------------
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

  if [[ ! -d "${BUNDLE_DIR}/${VER}" ]]; then
    echo "ERROR: expected ${BUNDLE_DIR}/${VER} not found"; exit 1
  fi
  echo "[i] Staging pipeline sources into $(pwd)"
  rsync -a "${BUNDLE_DIR}/${VER}/" .
  #rsync -a --delete "${BUNDLE_DIR}/${VER}/" .
else
  echo "[i] Pipeline files already present; skipping download (use --force to re-download)."
fi

# Ensure conf/ exists for symlink target
mkdir -p conf

# -------------------------------
# Symlink companion files from script dir
# -------------------------------
if [[ -f "${SCRIPT_DIR}/justfile" ]]; then
  rm -f justfile && ln -sv "${SCRIPT_DIR}/justfile" justfile
fi
if [[ -f "${SCRIPT_DIR}/ENV" ]]; then
  rm -f ENV && ln -sv "${SCRIPT_DIR}/ENV" ENV
fi
if [[ -f "${SCRIPT_DIR}/test.config" ]]; then
  rm -f conf/test.config && ln -sv "${SCRIPT_DIR}/test.config" conf/test.config
fi

# -------------------------------
# Clean up downloaded bundle (optional)
# -------------------------------
rm -rf "${BUNDLE_DIR}"

echo "[i] Setup completed for ${PIPELINE} ${REVISION} in $(pwd)"
