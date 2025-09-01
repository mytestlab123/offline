#!/usr/bin/env bash
# prepare_demo_offline_test.sh (placed at repo root)
# Mirrors nf-core/demo v1.0.1 test inputs to S3 and emits:
#   - offline/inputs3.csv (S3 URIs; default 1 data row)
#   - offline/offline_test.conf (offline-safe test profile)

set -Eeuo pipefail

# ── CLI/ENV: rows to include (default 1)
ROWS="${DEMO_ROWS:-1}"
if [[ "${1:-}" == "--rows" && -n "${2:-}" ]]; then
  ROWS="$2"; shift 2
fi
[[ "$ROWS" =~ ^[0-9]+$ ]] || { echo "ERROR: rows must be an integer"; exit 1; }
(( ROWS >= 1 )) || { echo "ERROR: rows must be >= 1"; exit 1; }

# ── Require S3_ROOT (e.g., s3://lifebit-user-data-nextflow/offline)
: "${S3_ROOT:?Set S3_ROOT in environment or .env}"

# ── Derive repo root + pipeline name from this script’s location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"                 # script resides at repo root now
PIPELINE="$(basename "${REPO_ROOT}")"    # expects 'demo'
CONF_TEST="${REPO_ROOT}/conf/test.config" # upstream test profile (v1.0.1)

# ── S3 layout
S3_PIPE_ROOT="${S3_ROOT}/${PIPELINE}"
S3_DATA_PREFIX="${S3_PIPE_ROOT}/data"

# ── Temp work dirs (auto-clean)
TMP_DIR="$(mktemp -d /tmp/${PIPELINE}-offline.XXXXXX)"
STAGE_DIR="$(mktemp -d /tmp/${PIPELINE}-stage.XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}" "${STAGE_DIR}"; }
trap cleanup EXIT

# ── Tools
for c in aws curl awk head tail sed sort; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found"; exit 1; }
done
[[ -f "${CONF_TEST}" ]] || { echo "ERROR: Missing ${CONF_TEST}"; exit 1; }

echo "[i] Repo root       : ${REPO_ROOT}"
echo "[i] Pipeline        : ${PIPELINE}"
echo "[i] Using S3 prefix : ${S3_DATA_PREFIX}"
echo "[i] Temp workspace  : ${TMP_DIR}"
echo "[i] Rows selected   : ${ROWS}"

# 1) Parse upstream samplesheet URL from conf/test.config (v1.0.1)
INPUT_URL="$(awk -F'=' '
  /^[[:space:]]*input[[:space:]]*=/{
    v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); gsub(/[";]/,"",v); print v
  }' "${CONF_TEST}")"
[[ "${INPUT_URL}" == http* ]] || { echo "ERROR: Could not parse input URL from ${CONF_TEST}"; exit 1; }
echo "[i] Upstream samplesheet: ${INPUT_URL}"

# 2) Download full samplesheet -> /tmp
SHEET_FULL="${TMP_DIR}/samplesheet.csv"
curl -fsSL "${INPUT_URL}" -o "${SHEET_FULL}"
echo "[i] Saved samplesheet: ${SHEET_FULL}"

# 3) Build a trimmed samplesheet with header + first N rows
SHEET_TRIM="${TMP_DIR}/samplesheet.trim.csv"
{
  head -n 1 "${SHEET_FULL}"
  tail -n +2 "${SHEET_FULL}" | head -n "${ROWS}"
} > "${SHEET_TRIM}"
echo "[i] Trimmed samplesheet rows: ${ROWS}"

# 4) Download only assets referenced by the trimmed samplesheet (fastq_1, fastq_2)
mapfile -t URLS < <(awk -F',' 'NR>1{if($2 ~ /^https?:\/\//) print $2; if($3 ~ /^https?:\/\//) print $3}' "${SHEET_TRIM}" | sort -u)
for u in "${URLS[@]:-}"; do
  [[ -z "${u:-}" ]] && continue
  f="${TMP_DIR}/$(basename "$u")"
  echo "[i] Fetch: $u -> $f"
  curl -fsSL "$u" -o "$f"
done

# 5) Create S3-rewritten samplesheet -> repo/offline/inputs3.csv (light)
mkdir -p "${REPO_ROOT}/offline"
SHEET_S3_LOCAL="${REPO_ROOT}/offline/inputs3.csv"
awk -v S3="${S3_DATA_PREFIX}" -F',' 'BEGIN{OFS=","}
NR==1{print; next}
{
  # Columns: sample,fastq_1,fastq_2
  for (i=2; i<=3; i++) {
    if ($i!="") {
      v=$i;
      if (v ~ /^https?:\/\//) {split(v,a,"/"); v=a[length(a)]} else {gsub(/^.*\//,"",v)}
      if (v!="") $i=S3"/"v;
    }
  }
  print
}' "${SHEET_TRIM}" > "${SHEET_S3_LOCAL}"
echo "[i] Wrote: ${SHEET_S3_LOCAL}"

# 6) Stage only required payload for S3 (selected FASTQs + inputs3.csv)
cp -f "${SHEET_S3_LOCAL}" "${STAGE_DIR}/inputs3.csv"
awk -F',' 'NR>1{if($2!="") print $2; if($3!="") print $3}' "${SHEET_S3_LOCAL}" \
  | sed -E 's@.*/@@' | sort -u | while read -r base; do
    [[ -z "$base" ]] && continue
    src="${TMP_DIR}/${base}"
    [[ -f "$src" ]] || { echo "WARN: missing $src (skipping)"; continue; }
    cp -f "$src" "${STAGE_DIR}/"
  done

# Optional: integrity manifest
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${STAGE_DIR}" && sha256sum * > SHA256SUMS || true)
elif command -v shasum >/dev/null 2>&1; then
  (cd "${STAGE_DIR}" && shasum -a 256 * > SHA256SUMS || true)
fi

# 7) Upload the staged subset to S3
echo "[i] Sync stage -> ${S3_DATA_PREFIX}"
aws s3 sync "${STAGE_DIR}" "${S3_DATA_PREFIX}" --no-follow-symlinks

# 8) Emit offline/offline_test.conf with requested settings
OFF_CONF="${REPO_ROOT}/offline/offline_test.conf"
cat > "${OFF_CONF}" <<EOF
/*
Offline test profile for nf-core/demo 1.0.1
Reference: https://github.com/nf-core/demo/tree/1.0.1
Uses S3-hosted test inputs and disables remote lookups.
*/

params {
    config_profile_name        = 'Offline test profile'
    config_profile_description = 'Minimal offline test dataset to check pipeline function'

    // Resource bounds
    max_cpus   = 4
    max_memory = '6.GB'
    max_time   = '6.h'

    // Offline inputs (S3 CSV produced by this script)
    input   = '${S3_DATA_PREFIX}/inputs3.csv'
    outdir  = '/tmp/out-demo'

    // Offline toggles
    genome                      = null
    igenomes_ignore             = true
    pipelines_testdata_base_path = null
    custom_config_base           = null
    validate_params              = false
}

podman.enabled = true
EOF

echo "[i] Wrote: ${OFF_CONF}"

echo

echo "SUCCESS ✅  Created ./offline/inputs3.csv (rows=${ROWS}) and ./offline/offline_test.conf;"
echo "           uploaded only required assets to ${S3_DATA_PREFIX}."
echo "Next:"
echo "  just check_data"
echo "  just run"
