#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/offline-smoke/nf-core-download-smoke.sh [options]

Purpose:
  Small nf-core offline bundle smoke test using nf-core/testpipeline.

Options:
  --workspace DIR        Output workspace. Default: /mnt/data5/nfcore-offline-smoke
  --pipeline NAME        nf-core pipeline. Default: nf-core/testpipeline
  --revision REV         Pipeline revision. Default: 3.2.1
  --profile PROFILE      Nextflow profile. Default: docker,test
  --skip-run             Download and load Docker images only
  --help                 Show this help

Environment:
  NEXTFLOW_BIN           Nextflow binary. Default: nextflow
  NFCORE_BIN             nf-core binary. Default: nf-core
  MIN_ROOT_FREE_GB       Minimum free space required on /. Default: 2
  MIN_WORKSPACE_FREE_GB  Minimum free space required for workspace. Default: 10
EOF
}

workspace="/mnt/data5/nfcore-offline-smoke"
pipeline="nf-core/testpipeline"
revision="3.2.1"
profile="docker,test"
run_pipeline=1

nextflow_bin="${NEXTFLOW_BIN:-nextflow}"
nfcore_bin="${NFCORE_BIN:-nf-core}"
min_root_free_gb="${MIN_ROOT_FREE_GB:-2}"
min_workspace_free_gb="${MIN_WORKSPACE_FREE_GB:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      workspace="${2:?missing value for --workspace}"
      shift 2
      ;;
    --pipeline)
      pipeline="${2:?missing value for --pipeline}"
      shift 2
      ;;
    --revision)
      revision="${2:?missing value for --revision}"
      shift 2
      ;;
    --profile)
      profile="${2:?missing value for --profile}"
      shift 2
      ;;
    --skip-run)
      run_pipeline=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

free_gb_for_path() {
  local path="$1"
  df -BG --output=avail "$path" | awk 'NR==2 {gsub(/G/, "", $1); print $1}'
}

require_free_gb() {
  local path="$1"
  local minimum="$2"
  local available
  available="$(free_gb_for_path "$path")"
  if [[ "$available" -lt "$minimum" ]]; then
    echo "ERROR: $path has ${available}G free; need at least ${minimum}G" >&2
    exit 1
  fi
}

safe_name="${pipeline#nf-core/}"
safe_revision="${revision//./_}"
results_dir="$workspace/results"
download_dir="$workspace/downloads/$safe_name"
workflow_dir="$download_dir/$safe_revision"
docker_dir="$download_dir/docker-images"
work_dir="$workspace/work/$safe_name"
out_dir="$results_dir/${safe_name}-run-out"

mkdir -p "$results_dir" "$workspace/downloads" "$workspace/work"

require_cmd "$nextflow_bin"
require_cmd "$nfcore_bin"
require_cmd docker

nextflow_path="$(command -v "$nextflow_bin")"
mkdir -p "$workspace/bin"
ln -sf "$nextflow_path" "$workspace/bin/nextflow"
export PATH="$workspace/bin:$PATH"
if [[ -z "${NXF_VER:-}" ]]; then
  detected_nxf_ver="$("$nextflow_bin" -version | awk '{for (i = 1; i <= NF; i++) if ($i == "version") {print $(i + 1); exit}}')"
  if [[ -n "$detected_nxf_ver" ]]; then
    export NXF_VER="$detected_nxf_ver"
  fi
fi

require_free_gb / "$min_root_free_gb"
require_free_gb "$workspace" "$min_workspace_free_gb"

{
  echo "# Tool versions"
  date
  echo
  "$nextflow_bin" -version || true
  echo
  "$nfcore_bin" --version
  echo
  docker version
  echo
  docker info --format 'DockerRoot={{.DockerRootDir}} Driver={{.Driver}} Server={{.ServerVersion}}'
  echo
  df -h / "$workspace"
} > "$results_dir/00-tool-versions.txt" 2>&1

"$nextflow_bin" inspect "$pipeline" \
  -r "$revision" \
  -profile "$profile" \
  -format json \
  > "$results_dir/${safe_name}.inspect.json" \
  2> "$results_dir/${safe_name}.inspect.err"

"$nfcore_bin" pipelines download "$pipeline" \
  --revision "$revision" \
  --outdir "$download_dir" \
  --compress none \
  --container-system docker \
  --force \
  --parallel-downloads 2 \
  > "$results_dir/${safe_name}-download.log" 2>&1

find "$download_dir" -maxdepth 3 -type f | sort > "$results_dir/${safe_name}-download-tree.txt"

if [[ ! -d "$workflow_dir" ]]; then
  echo "ERROR: expected workflow directory missing: $workflow_dir" >&2
  exit 1
fi

if [[ ! -x "$docker_dir/docker-load.sh" && ! -f "$docker_dir/docker-load.sh" ]]; then
  echo "ERROR: expected docker-load.sh missing: $docker_dir/docker-load.sh" >&2
  exit 1
fi

(
  cd "$docker_dir"
  bash docker-load.sh
) > "$results_dir/${safe_name}-docker-load.log" 2>&1

docker images > "$results_dir/docker-images-after-load.txt" 2>&1

if [[ "$run_pipeline" -eq 1 ]]; then
  mkdir -p "$out_dir" "$work_dir"
  (
    cd "$workspace"
    "$nextflow_bin" run "$workflow_dir" \
      -profile "$profile" \
      -offline \
      --outdir "$out_dir" \
      -w "$work_dir"
  ) > "$results_dir/offline-run-result.txt" 2>&1
  cp "$workspace/.nextflow.log" "$results_dir/offline-run-nextflow-log.txt" 2>/dev/null || true
  echo "offline_run=success" > "$results_dir/offline-run.status"
else
  echo "offline_run=skipped" > "$results_dir/offline-run.status"
fi

df -h / "$workspace" > "$results_dir/disk-final.txt"

cat > "$results_dir/RESULT.md" <<EOF
# nf-core Offline Smoke Result

Pipeline: $pipeline
Revision: $revision
Profile: $profile
Workspace: $workspace

Result: success

Evidence:
- versions: $results_dir/00-tool-versions.txt
- inspect JSON: $results_dir/${safe_name}.inspect.json
- download log: $results_dir/${safe_name}-download.log
- download tree: $results_dir/${safe_name}-download-tree.txt
- docker load log: $results_dir/${safe_name}-docker-load.log
- docker images: $results_dir/docker-images-after-load.txt
- offline run status: $results_dir/offline-run.status
- disk final: $results_dir/disk-final.txt

Note:
This proves local source plus Docker TAR loading plus Nextflow offline mode.
It does not prove GCC no-Internet or Nexus-only behavior.
EOF

echo "OK: $results_dir/RESULT.md"
