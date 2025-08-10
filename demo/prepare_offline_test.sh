#!/usr/bin/env bash
# Universal: mirror nf-core test inputs to S3 and emit offline config
# - Creates: offline/inputs3.csv (default 1 row), offline/offline_test.conf
# - Heavy data only in /tmp; repo stays light.

set -Eeuo pipefail

# ── CLI / ENV
ROWS="${ROWS:-${BTFQ_ROWS:-1}}"                  # default 1
PARAM_NAME="${PARAM_NAME:-input}"                # override if pipeline uses e.g. 'reads'
CONF_PATH="${CONF_PATH:-./conf/test.config}"     # test profile to parse
: "${S3_ROOT:?Set S3_ROOT (e.g., s3://bucket/offline) in env or .env}"

# Parse optional flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rows)       ROWS="${2:?}"; shift 2 ;;
    --param-name) PARAM_NAME="${2:?}"; shift 2 ;;
    --conf)       CONF_PATH="${2:?}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ "$ROWS" =~ ^[0-9]+$ ]] || { echo "ERROR: rows must be integer" >&2; exit 1; }
(( ROWS >= 1 )) || { echo "ERROR: rows must be >=1" >&2; exit 1; }

# ── Derive repo root + pipeline name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PIPELINE="$(basename "${REPO_ROOT}")"            # e.g., bamtofastq or demo

# ── S3 layout
S3_PIPE_ROOT="${S3_ROOT}/${PIPELINE}"
S3_DATA_PREFIX="${S3_PIPE_ROOT}/data"

# ── Tools & inputs
for c in aws curl awk head tail sed; do command -v "$c" >/dev/null || { echo "ERROR: '$c' not found" >&2; exit 1; }; done
[[ -f "${CONF_PATH}" ]] || { echo "ERROR: Missing ${CONF_PATH}" >&2; exit 1; }

echo "[i] Pipeline        : ${PIPELINE}"
echo "[i] Param name      : ${PARAM_NAME}"
echo "[i] S3 data prefix  : ${S3_DATA_PREFIX}"
echo "[i] Test config     : ${CONF_PATH}"
echo "[i] Rows (trim)     : ${ROWS}"

# 1) Extract samplesheet URL safely (handles 'single' or "double" quotes; keeps https://\)
LINE="$(awk -v P="${PARAM_NAME}" '
  $0 ~ "^[[:space:]]*(params\\.)?" P "[[:space:]]*=" { print; exit }
' "${CONF_PATH}")" || true

if [[ -z "${LINE}" ]]; then
  echo "ERROR: Could not find assignment for '${PARAM_NAME}' in ${CONF_PATH}" >&2
  exit 1
fi

VAL="${LINE#*=}"                                         # take RHS after '='
VAL="$(printf '%s' "$VAL" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"   # trim
# drop one leading quote if present
case "$VAL" in
  \"*) VAL="${VAL#\"}";;
  \'*) VAL="${VAL#\'}";;
esac
# drop one trailing ; or quote (order matters)
VAL="${VAL%[; ]}"
case "$VAL" in
  *\" ) VAL="${VAL%\"}";;
  *\') VAL="${VAL%\'}";;
esac

INPUT_URL="$VAL"
[[ "${INPUT_URL}" == http* ]] || { echo "ERROR: Parsed value is not http(s): '${INPUT_URL}'" >&2; exit 1; }
echo "[i] Samplesheet URL : ${INPUT_URL}"

# 2) Download samplesheet → /tmp and trim to N rows
TMP_DIR="$(mktemp -d /tmp/${PIPELINE}-offline.XXXXXX)"
STAGE_DIR="$(mktemp -d /tmp/${PIPELINE}-stage.XXXXXX)"
cleanup(){ rm -rf "${TMP_DIR}" "${STAGE_DIR}"; }
trap cleanup EXIT

SHEET_FULL="${TMP_DIR}/samplesheet.csv"
curl -fsSL "${INPUT_URL}" -o "${SHEET_FULL}"

SHEET_TRIM="${TMP_DIR}/samplesheet.trim.csv"
{ head -n 1 "${SHEET_FULL}"; tail -n +2 "${SHEET_FULL}" | head -n "${ROWS}"; } > "${SHEET_TRIM}"
echo "[i] Trimmed CSV rows: ${ROWS}"

# 3) Download only assets referenced by the trimmed CSV (any http(s) field)
mapfile -t URLS < <(awk -F',' 'NR>1{for(i=1;i<=NF;i++) if($i ~ /^https?:\/\//) print $i}' "${SHEET_TRIM}" | sort -u)
for u in "${URLS[@]:-}"; do
  [[ -z "${u:-}" ]] && continue
  f="${TMP_DIR}/$(basename "$u")"
  echo "[i] Fetch: $u -> $f"
  curl -fsSL "$u" -o "$f"
done

# 4) Write offline/inputs3.csv rewriting any http(s) fields to s3://.../<basename>
mkdir -p "${REPO_ROOT}/offline"
SHEET_S3_LOCAL="${REPO_ROOT}/offline/inputs3.csv"
awk -v S3="${S3_DATA_PREFIX}" -F',' '
BEGIN{OFS=","}
NR==1{print; next}
{
  for(i=1;i<=NF;i++){
    if($i ~ /^https?:\/\//){ split($i,a,"/"); $i=S3"/"a[length(a)] }
  }
  print
}' "${SHEET_TRIM}" > "${SHEET_S3_LOCAL}"
echo "[i] Wrote: ${SHEET_S3_LOCAL}"

# 5) Stage referenced basenames + inputs3.csv for S3
cp -f "${SHEET_S3_LOCAL}" "${STAGE_DIR}/inputs3.csv"
awk -F',' 'NR>1{for(i=1;i<=NF;i++) if($i ~ /^s3:\/\//){split($i,a,"/"); print a[length(a)]}}' "${SHEET_S3_LOCAL}" \
 | sort -u | while read -r base; do
     [[ -z "$base" ]] && continue
     src="${TMP_DIR}/${base}"
     [[ -f "$src" ]] || { echo "WARN: missing $src" >&2; continue; }
     cp -f "$src" "${STAGE_DIR}/"
   done

# Optional integrity
if command -v sha256sum >/dev/null 2>&1; then (cd "${STAGE_DIR}" && sha256sum * > SHA256SUMS || true); fi

# 6) Sync to S3
echo "[i] Sync stage -> ${S3_DATA_PREFIX}"
aws s3 sync "${STAGE_DIR}" "${S3_DATA_PREFIX}" --no-follow-symlinks

# 7) Emit offline/offline_test.conf (generic; OK for demo/bamtofastq)
OFF_CONF="${REPO_ROOT}/offline/offline_test.conf"
cat > "${OFF_CONF}" <<EOF2
/*
Offline test profile for nf-core/${PIPELINE}
Uses S3-hosted test inputs and disables remote lookups.
*/

params {
    config_profile_name        = 'Offline test profile'
    config_profile_description = 'Minimal offline test dataset to check pipeline function'

    // Bounds for quick runs
    max_cpus   = 4
    max_memory = '6.GB'
    max_time   = '6.h'

    // Offline inputs (S3 CSV produced by this script)
    ${PARAM_NAME} = '${S3_DATA_PREFIX}/inputs3.csv'
    outdir        = '/tmp/out-${PIPELINE}'

    // Offline toggles
    genome                         = null
    igenomes_ignore                = true
    pipelines_testdata_base_path   = null
    custom_config_base             = null
    validate_params                = false
}

podman.enabled = true
EOF2

echo "[i] Wrote: ${OFF_CONF}"
echo "SUCCESS ✅  ./offline/inputs3.csv (rows=${ROWS}) and ./offline/offline_test.conf ready; uploaded assets to ${S3_DATA_PREFIX}."
