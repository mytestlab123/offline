#!/usr/bin/env bash
# Mirrors nf-core/bamtofastq v2.1.1 test inputs to S3 and emits:
#   - offline/inputs3.csv (S3 URIs)
#   - offline/offline_test.conf (offline-safe test profile)
#
# Heavy files are staged only in /tmp; repo stays light.

set -Eeuo pipefail

# ── Require S3_ROOT (e.g., s3://lifebit-user-data-nextflow/offline)
: "${S3_ROOT:?Set S3_ROOT in environment or .env}"

# ── Derive repo root + pipeline name from this script’s location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PIPELINE="$(basename "${REPO_ROOT}")"        # expects 'bamtofastq'
CONF_TEST="${REPO_ROOT}/conf/test.config"    # upstream test profile (v2.1.1)

# ── S3 layout
S3_PIPE_ROOT="${S3_ROOT}/${PIPELINE}"
S3_DATA_PREFIX="${S3_PIPE_ROOT}/data"

# ── Temp workspace (auto-clean)
TMP_DIR="$(mktemp -d /tmp/${PIPELINE}-offline.XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

# ── Tools
for c in aws curl awk; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found"; exit 1; }
done
[[ -f "${CONF_TEST}" ]] || { echo "ERROR: Missing ${CONF_TEST}"; exit 1; }

echo "[i] Repo root       : ${REPO_ROOT}"
echo "[i] Pipeline        : ${PIPELINE}"
echo "[i] Using S3 prefix : ${S3_DATA_PREFIX}"
echo "[i] Temp workspace  : ${TMP_DIR}"

# 1) Parse upstream samplesheet URL from conf/test.config (v2.1.1)
INPUT_URL="$(awk -F'=' '
  /^[[:space:]]*input[[:space:]]*=/{
    v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); gsub(/[";]/,"",v); print v
  }' "${CONF_TEST}")"
[[ "${INPUT_URL}" == http* ]] || { echo "ERROR: Could not parse input URL from ${CONF_TEST}"; exit 1; }
echo "[i] Upstream samplesheet: ${INPUT_URL}"

# 2) Download samplesheet -> /tmp
SHEET_LOCAL="${TMP_DIR}/samplesheet.csv"
curl -fsSL "${INPUT_URL}" -o "${SHEET_LOCAL}"
echo "[i] Saved samplesheet: ${SHEET_LOCAL}"

# 3) Download referenced assets (mapped/index columns) -> /tmp
mapfile -t URLS < <(awk -F',' 'NR>1{if($2 ~ /^https?:\/\//) print $2; if($3 ~ /^https?:\/\//) print $3}' "${SHEET_LOCAL}" | sort -u)
for u in "${URLS[@]:-}"; do
  [[ -z "${u:-}" ]] && continue
  f="${TMP_DIR}/$(basename "$u")"
  echo "[i] Fetch: $u -> $f"
  curl -fsSL "$u" -o "$f"
done

# 4) Create S3-rewritten samplesheet -> repo/offline/inputs3.csv (light)
mkdir -p "${REPO_ROOT}/offline"
SHEET_S3="${REPO_ROOT}/offline/inputs3.csv"
awk -v S3="${S3_DATA_PREFIX}" -F',' 'BEGIN{OFS=","}
NR==1{print; next}
{
  # Columns: sample_id,mapped,index,file_type  (index may be empty)
  m=$2; if (m ~ /^https?:\/\//) {split(m,a,"/"); m=a[length(a)]} else {gsub(/^.*\//,"",m)}
  if (m!="") $2=S3"/"m;

  if ($3!="") {
    i=$3; if (i ~ /^https?:\/\//) {split(i,b,"/"); i=b[length(b)]} else {gsub(/^.*\//,"",i)}
    if (i!="") $3=S3"/"i;
  }
  print
}' "${SHEET_LOCAL}" > "${SHEET_S3}"
echo "[i] Wrote: ${SHEET_S3}"

# 5) Push /tmp payload to S3 (no heavy files in repo)
echo "[i] Sync /tmp payload -> ${S3_DATA_PREFIX}"
aws s3 sync "${TMP_DIR}" "${S3_DATA_PREFIX}" --no-follow-symlinks

# 6) Emit offline/offline_test.conf (offline-safe clone of test profile)
OFF_CONF="${REPO_ROOT}/offline/offline_test.conf"
cat > "${OFF_CONF}" <<EOF
/*
Offline test profile for nf-core/bamtofastq 2.1.1
Uses S3-hosted test inputs and disables remote lookups.
*/

params {
    config_profile_name        = 'Offline test profile'
    config_profile_description = 'Minimal offline test dataset to check pipeline function'

    // Match upstream test bounds
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

podman.enabled = true
EOF
echo "[i] Wrote: ${OFF_CONF}"

echo
echo "SUCCESS ✅  Generated small artefacts in ./offline/, mirrored data to S3."
echo "Next:"
echo "  just check_data"
echo "  just run"

