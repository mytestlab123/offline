#!/usr/bin/env bash
# Usage:
#   ./create_repo.sh <repo_name> [visibility] [group_id] <SRC_DIR> <DST_DIR> [ENV_FILE] [--delete-existing] [--force]
# Example:
#   ./create_repo.sh sarek3 public 2 "$HOME/offline/sarek/sarek" "$HOME/git/sarek3" "$HOME/ENV" --delete-existing --force
#
# Requires: curl jq git rsync
# Env: GITLAB_HOST (e.g., 100.123.206.229), GITLAB_PAT (api scope), NAMESPACE_PATH (e.g., amit)

set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
for c in curl jq git rsync; do need "$c"; done

GITLAB_HOST="${GITLAB_HOST:-100.123.206.229}"
NAMESPACE_PATH="${NAMESPACE_PATH:-amit}"     # used for existence checks
: "${GITLAB_PAT:?Set GITLAB_PAT with your PAT}"

REPO_NAME="${1:-}"; [[ -n "${REPO_NAME}" ]] || { echo "repo_name required"; exit 1; }
VISIBILITY="${2:-private}"
GROUP_ID="${3:-2}"
SRC_DIR="${4:-}"; [[ -d "${SRC_DIR:-}" ]] || { echo "SRC_DIR not found: ${SRC_DIR:-}"; exit 1; }
DST_DIR="${5:-}"; [[ -n "${DST_DIR}" ]] || { echo "DST_DIR required"; exit 1; }
ENV_FILE="${6:-}"
shift 6 || true
EXTRA_FLAGS=("$@")
DELETE_EXISTING=0
FORCE_DST=0
for f in "${EXTRA_FLAGS[@]:-}"; do
  case "$f" in
    --delete-existing) DELETE_EXISTING=1 ;;
    --force) FORCE_DST=1 ;;
  esac
done

# Load ENV if provided (sets PIPELINE and REVISION for README and branch)
if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
  set -a; source "${ENV_FILE}"; set +a
fi
PIPELINE="${PIPELINE:-${REPO_NAME}}"
REVISION="${REVISION:-0.0.0}"

api() { curl -sS -H "PRIVATE-TOKEN: $GITLAB_PAT" "$@"; }
api_json() { api "$@" | jq -r '.'; }

# URL-encoded project path for GET/DELETE: namespace%2Frepo
enc_path="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote('${NAMESPACE_PATH}/${REPO_NAME}', safe=''))
PY
)"

echo ">> Checking if project exists: ${NAMESPACE_PATH}/${REPO_NAME}"
exists_json="$(api_json "http://${GITLAB_HOST}/api/v4/projects/${enc_path}" || true)"
proj_id="$(echo "$exists_json" | jq -r '.id // empty')"

if [[ -n "$proj_id" ]]; then
  if [[ "$DELETE_EXISTING" -eq 1 ]]; then
    echo ">> Deleting existing project id=$proj_id …"
    api -X DELETE "http://${GITLAB_HOST}/api/v4/projects/${proj_id}" >/dev/null
    sleep 2
  else
    echo "Project already exists. Use --delete-existing to recreate. Exiting."
    exit 1
  fi
fi

echo ">> Creating ${REPO_NAME} (${VISIBILITY}) in group ${GROUP_ID}…"
create_json="$(api_json -X POST \
  "http://${GITLAB_HOST}/api/v4/projects?name=${REPO_NAME}&namespace_id=${GROUP_ID}&visibility=${VISIBILITY}")"

http_url="$(echo "$create_json" | jq -r .http_url_to_repo)"
new_proj_id="$(echo "$create_json" | jq -r .id)"
[[ "$http_url" != "null" && -n "$http_url" ]] || { echo "Creation failed:"; echo "$create_json"; exit 1; }
echo ">> Repo URL: $http_url"

# Explicitly set default branch to main
if [[ -n "$new_proj_id" && "$new_proj_id" != "null" ]]; then
  api -X PUT "http://${GITLAB_HOST}/api/v4/projects/${new_proj_id}?default_branch=main" >/dev/null || true
fi

# Prepare local working tree
if [[ -d "$DST_DIR" && $(ls -A "$DST_DIR" 2>/dev/null | wc -l) -gt 0 ]]; then
  if [[ "$FORCE_DST" -eq 1 ]]; then
    if [[ "$DST_DIR" == "$SRC_DIR" ]]; then
      echo "Refusing to force-clean: DST_DIR equals SRC_DIR"; exit 1
    fi
    echo ">> Cleaning non-empty DST_DIR: $DST_DIR"
    rm -rf "$DST_DIR"
  else
    echo "DST_DIR exists and is not empty. Use --force to recreate. Exiting."; exit 1
  fi
fi
mkdir -p "$DST_DIR"
cd "$DST_DIR"

# Initialize minimal main
if [[ ! -d .git ]]; then
  git init -q
  git checkout -q -b main || true
fi

# Minimal README on main, using env values
cat > README.md <<EOF
# ${PIPELINE}

**Pipeline**: \`${PIPELINE}\`  
**Revision**: \`${REVISION}\`

> This main branch is intentionally minimal. The full pipeline sources live on the branch **\`${REVISION}\`**.
