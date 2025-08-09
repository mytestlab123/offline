#!/usr/bin/env bash
# prepare_bamtofastq_offline_test.sh
# Goal: Use your existing layout + ENV to mirror nf-core/bamtofastq v2.1.1 test inputs to S3
#       and generate an offline test config that points to S3.
#
# Uses:
#   OFFLINE_DIR (e.g., /home/ec2-user/offline)
#   S3_ROOT     (e.g., s3://lifebit-user-data-nextflow/offline)
#
# Layout assumed (given):
#   $OFFLINE_DIR/bamtofastq/
#     ├─ bamtofastq -> pipe/2_1_1
#     ├─ data/ (we will place samples + CSVs here)
#     ├─ offline.conf / online.conf / profile.conf (left untouched)
#     └─ pipe/2_1_1/conf/test.config (source of the test profile)
#
# Result:
#   - Downloads upstream test samplesheet + objects into $PIPE_DIR/data
#   - Creates inputs3.csv that references the S3 locations
#   - aws s3 sync to ${S3_ROOT}/bamtofastq/data
#   - Writes $PIPE_DIR/offline_test.conf pointing to the S3 CSV and staying offline-safe

set -Eeuo pipefail

# --- Check required env ---
: "${OFFLINE_DIR:?OFFLINE_DIR env is required}"
: "${S3_ROOT:?S3_ROOT env is required (e.g., s3://bucket/offline)}"

PIPE_DIR="${OFFLINE_DIR}/bamtofastq"
REV_DIR="2_1_1"     # matches your folder name
TEST_CFG_LOCAL="${PIPE_DIR}/pipe/${REV_DIR}/conf/test.config"
DATA_DIR="${PIPE_DIR}/data"
S3_PIPE_ROOT="${S3_ROOT}/bamtofastq"
S3_DATA_PREFIX="${S3_PIPE_ROOT}/data"

# --- Pre-flight checks ---
for cmd in aws curl awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found"; exit 1; }
done

[[ -f "${TEST_CFG_LOCAL}" ]] || { echo "ERROR: Missing ${TEST_CFG_LOCAL}"; exit 1; }
mkdir -p "${DATA_DIR}"

echo "[i] Using:"
echo "    OFFLINE_DIR = ${OFFLINE_DIR}"
echo "    S3_ROOT     = ${S3_ROOT}"
echo "    PIPE_DIR    = ${PIPE_DIR}"
echo "    DATA_DIR    = ${DATA_DIR}"
echo "    TEST_CFG    = ${TEST_CFG_LOCAL}"
echo "    S3 prefix   = ${S3_DATA_PREFIX}"

# --- 1) Parse input URL from local test.config (v2.1.1) ---
INPUT_URL="$(awk -F'=' '
  /^[[:space:]]*input[[:space:]]*=/{
    val=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",val);
    gsub(/[";]/,"",val); print val
  }' "${TEST_CFG_LOCAL}")"

if [[ -z "${INPUT_URL}" || "${INPUT_URL}" != http* ]]; then
  echo "ERROR: Could not parse a HTTP(S) samplesheet URL from ${TEST_CFG_LOCAL}"
  exit 1
fi
echo "[i] Upstream test samplesheet: ${INPUT_URL}"

# --- 2) Download samplesheet locally ---
SHEET_LOCAL="${DATA_DIR}/test_bam_samplesheet.csv"
curl -fsSL "${INPUT_URL}" -o "${SHEET_LOCAL}"
echo "[i] Saved samplesheet to ${SHEET_LOCAL}"

# --- 3) Download any remote assets referenced by the samplesheet (mapped/index columns) ---
mapfile -t URLS < <(awk -F',' 'NR>1{if($2 ~ /^https?:\/\//) print $2; if($3 ~ /^https?:\/\//) print $3}' "${SHEET_LOCAL}" | sort -u)
for u in "${URLS[@]:-}"; do
  [[ -z "${u:-}" ]] && continue
  f="${DATA_DIR}/$(basename "$u")"
  echo "[i] Downloading asset: $u -> $f"
  curl -fsSL "$u" -o "$f"
done

# --- 4) Create S3-rewritten samplesheet (inputs3.csv) that points to mirrored objects ---
SHEET_S3="${DATA_DIR}/inputs3.csv"
awk -v S3="${S3_DATA_PREFIX}" -F',' 'BEGIN{OFS=","}
NR==1{print; next}
{
  # Expected columns: sample_id,mapped,index,file_type  (index may be empty)
  mfile=$2; if (mfile ~ /^https?:\/\//) {split(mfile,a,"/"); mfile=a[length(a)]} else {gsub(/^.*\//,"",mfile)}
  if (mfile!="") $2=S3"/"mfile;

  if ($3!="") {
    idx=$3;
    if (idx ~ /^https?:\/\//) {split(idx,b,"/"); idx=b[length(b)]} else {gsub(/^.*\//,"",idx)}
    if (idx!="") $3=S3"/"idx;
  }
  print
}' "${SHEET_LOCAL}" > "${SHEET_S3}"
echo "[i] Wrote S3-rewritten samplesheet: ${SHEET_S3}"

# --- 5) Optional integrity manifest (best-effort) ---
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${DATA_DIR}" && sha256sum * > SHA256SUMS || true)
elif command -v shasum >/dev/null 2>&1; then
  (cd "${DATA_DIR}" && shasum -a 256 * > SHA256SUMS || true)
fi

# --- 6) Sync data folder to S3 (keeps your existing local files) ---
echo "[i] Syncing ${DATA_DIR} -> ${S3_DATA_PREFIX}"
aws s3 sync "${DATA_DIR}" "${S3_DATA_PREFIX}" --no-follow-symlinks

# --- 7) Generate offline_test.conf at repo root (mirrors test.config, uses S3 CSV) ---
OFF_CFG="${PIPE_DIR}/offline_test.conf"
cat > "${OFF_CFG}" <<EOF
/*
Offline test profile for nf-core/bamtofastq 2.1.1
Uses S3-hosted test inputs and disables remote lookups.
*/

params {
    config_profile_name        = 'Offline test profile'
    config_profile_description = 'Minimal offline test dataset to check pipeline function'

    // Match upstream test resource bounds
    max_cpus   = 2
    max_memory = '6.GB'
    max_time   = '6.h'

    // Offline inputs (S3 CSV produced by this script)
    input   = '${S3_DATA_PREFIX}/inputs3.csv'
    outdir  = '/tmp/out-bamtofastq'   // required by schema

    // Keep references disabled for tests
    genome          = null
    igenomes_ignore = true

    // Prevent any remote config/plugin fetches
    custom_config_base = ''
    validate_params    = true
}

// Prefer Podman in CloudOS; Docker is fine on builders
podman.enabled = true
EOF

echo "[i] Wrote offline config: ${OFF_CFG}"

# --- 8) Done + hints ---
cat <<EOM

SUCCESS ✅

Local artefacts:
  - ${SHEET_LOCAL}
  - ${SHEET_S3}
  - ${OFF_CFG}

S3 locations:
  - ${S3_DATA_PREFIX}/inputs3.csv
  - ${S3_DATA_PREFIX}/<bam|cram> (+ .bai/.crai if present)
  - ${S3_DATA_PREFIX}/SHA256SUMS (if generated)

Run offline (example):
  cd "${PIPE_DIR}"
  export NXF_OFFLINE=true NXF_PLUGIN_AUTOINSTALL=false
  nextflow run ./bamtofastq \\
    -c ./offline_test.conf \\
    -c ./pipe/container.conf \\
    -profile podman -offline \\
    --outdir /tmp/out-bamtofastq -resume

EOM

