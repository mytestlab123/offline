#!/usr/bin/env bash
set -Eeuo pipefail

# Mirror a single URL-valued Nextflow param from a config file to S3.
# - Reads value of PARAM from CONF (expects http(s) or s3 URI)
# - If http(s), downloads to /tmp and uploads to ${S3_ROOT}/${PIPELINE}/data/<basename>
# - If already s3://, no-op (prints target and verifies presence)
#
# Usage:
#   mirror_param_url.sh --param-name fasta --conf ./conf/test.config [--pipeline scrnaseq]
# Env:
#   S3_ROOT required; PIPELINE optional (defaults from --pipeline or CWD name)

PARAM_NAME=""
CONF_PATH="${CONF_PATH:-./conf/test.config}"
PIPELINE_NAME="${PIPELINE:-${PIPELINE_NAME:-$(basename "$(pwd)")}}"

usage(){ cat <<EOF
Usage: mirror_param_url.sh --param-name NAME [--conf PATH] [--pipeline NAME]
Env: S3_ROOT required; PIPELINE optional (defaults to current dir name)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --param-name) PARAM_NAME="$2"; shift 2 ;;
    --conf)       CONF_PATH="$2"; shift 2 ;;
    --pipeline)   PIPELINE_NAME="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

: "${S3_ROOT:?Set S3_ROOT (e.g., s3://bucket/offline) in env or ENV}"
[[ -n "$PARAM_NAME" ]] || { echo "ERROR: --param-name required" >&2; usage; exit 2; }
[[ -f "$CONF_PATH" ]] || { echo "ERROR: Missing conf file: $CONF_PATH" >&2; exit 1; }

for c in aws curl awk sed; do command -v "$c" >/dev/null || { echo "ERROR: '$c' not found" >&2; exit 1; }; done

S3_PIPE_ROOT="${S3_ROOT%/}/${PIPELINE_NAME}"
S3_DATA_PREFIX="${S3_PIPE_ROOT}/data"

echo "[i] Pipeline       : ${PIPELINE_NAME}"
echo "[i] Param name     : ${PARAM_NAME}"
echo "[i] S3 data prefix : ${S3_DATA_PREFIX}"
echo "[i] Test config    : ${CONF_PATH}"

LINE="$(awk -v P="${PARAM_NAME}" '$0 ~ "^[[:space:]]*(params\\.)?" P "[[:space:]]*=" { print; exit }' "${CONF_PATH}")" || true
[[ -n "$LINE" ]] || { echo "ERROR: Could not find '${PARAM_NAME}' in ${CONF_PATH}" >&2; exit 1; }
VAL="${LINE#*=}"; VAL="$(printf '%s' "$VAL" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
case "$VAL" in \"*) VAL="${VAL#\"}";; \'*) VAL="${VAL#\'}";; esac
VAL="${VAL%[; ]}"; case "$VAL" in *\" ) VAL="${VAL%\"}";; *\') VAL="${VAL%\'}";; esac

if [[ "$VAL" =~ ^https?:// ]]; then
  base="$(basename "${VAL%%\?*}")"
  tmp="$(mktemp -t "${PIPELINE_NAME}-${PARAM_NAME}.XXXXXX")"
  echo "[i] Fetch: $VAL -> $tmp"
  curl -fsSL "$VAL" -o "$tmp"
  dest="${S3_DATA_PREFIX}/${base}"
  echo "[i] Upload: $tmp -> $dest"
  aws s3 cp "$tmp" "$dest"
  rm -f "$tmp"
  echo "OK ${PARAM_NAME}=${dest}"
elif [[ "$VAL" =~ ^s3:// ]]; then
  echo "[i] ${PARAM_NAME} already S3: $VAL"
  aws s3 ls "$VAL" >/dev/null || echo "WARN: $VAL not found in S3 (check permissions/path)" >&2
  echo "OK ${PARAM_NAME}=${VAL}"
else
  echo "ERROR: Unsupported URI for ${PARAM_NAME}: '$VAL' (expect http(s) or s3)" >&2
  exit 2
fi

