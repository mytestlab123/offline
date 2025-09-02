#!/usr/bin/env bash
set -Eeuo pipefail

# Mirror nf-core test inputs to S3 and emit offline config.
# Creates: offline/inputs3.csv (default 1 row), offline/offline_test.conf
# Heavy data only in /tmp; repo stays light.

ROWS="${ROWS:-1}"
PARAM_NAME="${PARAM_NAME:-input}"
CONF_PATH="${CONF_PATH:-./conf/test.config}"
PIPELINE_NAME="${PIPELINE:-${PIPELINE_NAME:-$(basename "$(pwd)")}}"
: "${S3_ROOT:?Set S3_ROOT (e.g., s3://bucket/offline) in env or ENV}"

usage(){ cat <<EOF
Usage: mirror_testdata.sh [--rows N] [--param-name NAME] [--conf PATH] [--pipeline NAME]
Env: S3_ROOT required; PIPELINE optional (defaults to current dir name)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rows)       ROWS="$2"; shift 2 ;;
    --param-name) PARAM_NAME="$2"; shift 2 ;;
    --conf)       CONF_PATH="$2"; shift 2 ;;
    --pipeline)   PIPELINE_NAME="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$ROWS" =~ ^[0-9]+$ && $ROWS -ge 1 ]] || { echo "ERROR: rows must be integer >=1" >&2; exit 1; }
[[ -f "$CONF_PATH" ]] || { echo "ERROR: Missing $CONF_PATH" >&2; exit 1; }

S3_PIPE_ROOT="${S3_ROOT%/}/${PIPELINE_NAME}"
S3_DATA_PREFIX="${S3_PIPE_ROOT}/data"

for c in aws curl awk head tail sed; do command -v "$c" >/dev/null || { echo "ERROR: '$c' not found" >&2; exit 1; }; done

echo "[i] Pipeline        : ${PIPELINE_NAME}"
echo "[i] Param name      : ${PARAM_NAME}"
echo "[i] S3 data prefix  : ${S3_DATA_PREFIX}"
echo "[i] Test config     : ${CONF_PATH}"
echo "[i] Rows (trim)     : ${ROWS}"

# Extract samplesheet URL safely
LINE="$(awk -v P="${PARAM_NAME}" '$0 ~ "^[[:space:]]*(params\\.)?" P "[[:space:]]*=" { print; exit }' "${CONF_PATH}")" || true
[[ -n "$LINE" ]] || { echo "ERROR: Could not find '${PARAM_NAME}' in ${CONF_PATH}" >&2; exit 1; }
VAL="${LINE#*=}"; VAL="$(printf '%s' "$VAL" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
case "$VAL" in \"*) VAL="${VAL#\"}";; \'*) VAL="${VAL#\'}";; esac
VAL="${VAL%[; ]}"; case "$VAL" in *\" ) VAL="${VAL%\"}";; *\') VAL="${VAL%\'}";; esac
INPUT_URL="$VAL"
[[ "$INPUT_URL" == http* ]] || { echo "ERROR: Parsed value is not http(s): '$INPUT_URL'" >&2; exit 1; }
echo "[i] Samplesheet URL : ${INPUT_URL}"

TMP_DIR="$(mktemp -d /tmp/${PIPELINE_NAME}-offline.XXXXXX)"
STAGE_DIR="$(mktemp -d /tmp/${PIPELINE_NAME}-stage.XXXXXX)"
cleanup(){ rm -rf "$TMP_DIR" "$STAGE_DIR"; }
trap cleanup EXIT

SHEET_FULL="${TMP_DIR}/samplesheet.csv"
curl -fsSL "$INPUT_URL" -o "$SHEET_FULL"

SHEET_TRIM="${TMP_DIR}/samplesheet.trim.csv"
{ head -n 1 "$SHEET_FULL"; tail -n +2 "$SHEET_FULL" | head -n "$ROWS"; } > "$SHEET_TRIM"
echo "[i] Trimmed CSV rows: ${ROWS}"

# Download assets referenced by the trimmed CSV
mapfile -t URLS < <(awk -F',' 'NR>1{for(i=1;i<=NF;i++) if($i ~ /^https?:\/\//) print $i}' "$SHEET_TRIM" | sort -u)
for u in "${URLS[@]:-}"; do
  [[ -z "${u:-}" ]] && continue
  f="${TMP_DIR}/$(basename "$u")"
  echo "[i] Fetch: $u -> $f"
  curl -fsSL "$u" -o "$f"
done

# Write offline/inputs3.csv rewriting any http(s) fields to s3://.../<basename>
mkdir -p offline
SHEET_S3_LOCAL="offline/inputs3.csv"
awk -v S3="${S3_DATA_PREFIX}" -F',' 'BEGIN{OFS=","} NR==1{print; next} { for(i=1;i<=NF;i++){ if($i ~ /^https?:\/\//){ split($i,a,"/"); $i=S3"/"a[length(a)] } } print }' "$SHEET_TRIM" > "$SHEET_S3_LOCAL"
echo "[i] Wrote: ${SHEET_S3_LOCAL}"

# Stage referenced basenames + inputs3.csv for S3
cp -f "$SHEET_S3_LOCAL" "$STAGE_DIR/inputs3.csv"
awk -F',' 'NR>1{for(i=1;i<=NF;i++) if($i ~ /^s3:\/\//){split($i,a,"/"); print a[length(a)]}}' "$SHEET_S3_LOCAL" | sort -u | while read -r base; do
  [[ -z "$base" ]] && continue
  src="${TMP_DIR}/${base}"
  [[ -f "$src" ]] || { echo "WARN: missing $src" >&2; continue; }
  cp -f "$src" "$STAGE_DIR/"
done

echo "[i] Sync stage -> ${S3_DATA_PREFIX}"
aws s3 sync "$STAGE_DIR" "$S3_DATA_PREFIX" --no-follow-symlinks

# Emit generic offline test profile
cat > offline/offline_test.conf <<EOF
/* Offline test profile for nf-core/${PIPELINE_NAME} */
params {
  config_profile_name        = 'Offline test profile'
  config_profile_description = 'Minimal offline test dataset to check pipeline function'
  max_cpus   = 4
  max_memory = '6.GB'
  max_time   = '6.h'
  ${PARAM_NAME} = '${S3_DATA_PREFIX}/inputs3.csv'
  outdir        = '/tmp/out-${PIPELINE_NAME}'
  genome                       = null
  igenomes_ignore              = true
  pipelines_testdata_base_path = null
  custom_config_base           = null
  validate_params              = false
}
EOF

echo "SUCCESS ✅ offline/inputs3.csv (rows=${ROWS}) and offline/offline_test.conf ready; uploaded assets to ${S3_DATA_PREFIX}."

