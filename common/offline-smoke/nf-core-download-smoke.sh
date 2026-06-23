#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/offline-smoke/nf-core-download-smoke.sh [options]

Purpose:
  Deterministic staged nf-core offline checks:
  1) host/tool probe
  2) nextflow inspect probe
  3) nf-core pipelines download
  4) docker image load
  5) nextflow offline run (full smoke)

Options:
  --workspace DIR            Output workspace. Default: /mnt/data5/nfcore-offline-smoke
  --pipeline NAME            nf-core pipeline. Default: nf-core/testpipeline
  --revision REV             Pipeline revision. Default: 3.2.1
  --profile PROFILE          Nextflow profile. Default: docker,test
  --stages STAGE[,STAGE...]  Comma-separated stages. Default: host-probe,nextflow-inspect
  --skip-run                 Alias for: --stages host-probe,nextflow-inspect,download,docker-load
  --run-smoke                Alias for: --stages full-smoke
  --help                     Show this help

Supported stages:
  host-probe       local host+tool checks (command presence and disk checks)
  nextflow-inspect  run `nextflow inspect` against selected pipeline
  download         download pipeline assets and docker TARs
  docker-load      load docker TARs
  offline-run      run nextflow offline from local workflow
  full-smoke       full path: host-probe, nextflow-inspect, download, docker-load, offline-run

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
stages_csv="host-probe,nextflow-inspect"

nextflow_bin="${NEXTFLOW_BIN:-nextflow}"
nfcore_bin="${NFCORE_BIN:-nf-core}"
min_root_free_gb="${MIN_ROOT_FREE_GB:-2}"
min_workspace_free_gb="${MIN_WORKSPACE_FREE_GB:-10}"

append_stage() {
  local stage="$1"
  local existing
  for existing in "${selected_stages[@]}"; do
    [[ "$existing" == "$stage" ]] && return 0
  done
  selected_stages+=("$stage")
}

normalize_stage_request() {
  local raw="$1"
  IFS=',' read -r -a requested <<< "$raw"
  for requested_stage in "${requested[@]}"; do
    requested_stage="${requested_stage//[[:space:]]/}"
    case "$requested_stage" in
      host-probe|host|local-probe|host-tool-probe)
        append_stage "host-probe"
        ;;
      nextflow-inspect|inspect|nextflow-inspection)
        append_stage "nextflow-inspect"
        ;;
      download|nfcore-download|download-pipeline)
        append_stage "download"
        ;;
      docker-load|dockerload|load-docker)
        append_stage "docker-load"
        ;;
      offline-run|run|nextflow-run)
        append_stage "offline-run"
        ;;
      full-smoke|smoke|full)
        append_stage "host-probe"
        append_stage "nextflow-inspect"
        append_stage "download"
        append_stage "docker-load"
        append_stage "offline-run"
        ;;
      run-smoke)
        append_stage "host-probe"
        append_stage "nextflow-inspect"
        append_stage "download"
        append_stage "docker-load"
        append_stage "offline-run"
        ;;
      *)
        echo "ERROR: unknown stage: $requested_stage" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if (( ${#selected_stages[@]} == 0 )); then
    append_stage "host-probe"
    append_stage "nextflow-inspect"
  fi
}

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
    --stages)
      stages_csv="${2:?missing value for --stages}"
      shift 2
      ;;
    --skip-run)
      stages_csv="host-probe,nextflow-inspect,download,docker-load"
      shift
      ;;
    --run-smoke)
      stages_csv="full-smoke"
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

selected_stages=()
normalize_stage_request "$stages_csv"

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

has_stage() {
  local wanted="$1"
  local stage
  for stage in "${selected_stages[@]}"; do
    [[ "$stage" == "$wanted" ]] && return 0
  done
  return 1
}

if [[ -z "${NEXTFLOW_BIN:-}" ]] && { has_stage "download" || has_stage "docker-load" || has_stage "offline-run"; } && command -v nextflow-25.04 >/dev/null 2>&1; then
  nextflow_bin="nextflow-25.04"
fi

safe_name="${pipeline#nf-core/}"
safe_revision="${revision//./_}"
results_dir="$workspace/results"
download_dir="$workspace/downloads/$safe_name"
workflow_dir="$download_dir/$safe_revision"
docker_dir="$download_dir/docker-images"
work_dir="$workspace/work/$safe_name"
out_dir="$results_dir/${safe_name}-run-out"
log_dir="$results_dir/logs"

mkdir -p "$results_dir" "$log_dir" "$workspace/downloads" "$workspace/work" "$workspace/bin"

nextflow_path="$(command -v "$nextflow_bin" || true)"
if [[ -n "$nextflow_path" ]]; then
  ln -sf "$nextflow_path" "$workspace/bin/nextflow"
fi
export PATH="$workspace/bin:$PATH"
if [[ -z "${NXF_VER:-}" ]] && [[ -n "$nextflow_path" ]]; then
  detected_nxf_ver="$("$nextflow_bin" -version | awk '{for (i = 1; i <= NF; i++) if ($i == "version") {print $(i + 1); exit}}')"
  if [[ -n "$detected_nxf_ver" ]]; then
    export NXF_VER="$detected_nxf_ver"
  fi
fi

export NXF_OFFLINE=true

record_stage_status() {
  printf '%s=%s\n' "$1" "$2" > "$results_dir/$1.status"
}

prepare_local_samplesheet() {
  local inspect_input="$workspace/assets/samplesheet.csv"
  local fastq_dir="$workspace/assets/fastq"
  mkdir -p "$(dirname "$inspect_input")"
  mkdir -p "$fastq_dir"
  for fastq in sample_R1.fastq.gz sample_R2.fastq.gz sample_single.fastq.gz; do
    if [[ ! -f "$fastq_dir/$fastq" ]]; then
      if command -v gzip >/dev/null 2>&1; then
        printf '@SEQ_ID\nACGT\n+\n!!!!\n' | gzip -c > "$fastq_dir/$fastq"
      else
        printf '@SEQ_ID\nACGT\n+\n!!!!\n' > "$fastq_dir/$fastq"
      fi
    fi
  done
  cat > "$inspect_input" <<EOF
sample,fastq_1,fastq_2
SAMPLE_PAIRED_END,$fastq_dir/sample_R1.fastq.gz,$fastq_dir/sample_R2.fastq.gz
SAMPLE_SINGLE_END,$fastq_dir/sample_single.fastq.gz,
EOF
  printf '%s\n' "$inspect_input"
}

run_host_probe() {
  require_free_gb / "$min_root_free_gb"
  require_free_gb "$workspace" "$min_workspace_free_gb"
  require_cmd "$nextflow_bin"
  require_cmd "$nfcore_bin"
  {
    echo "# Tool versions"
    date
    echo
    "$nextflow_bin" -version || true
    echo
    "$nfcore_bin" --version
    echo
    command -v docker && docker version || true
    echo
    command -v docker && docker info --format 'DockerRoot={{.DockerRootDir}} Driver={{.Driver}} Server={{.ServerVersion}}' || true
    echo
    df -h / "$workspace"
  } > "$results_dir/00-tool-versions.txt" 2>&1
  record_stage_status "host-probe" "ok"
}

run_nextflow_inspect() {
  local inspect_input
  inspect_input="$(prepare_local_samplesheet)"

  "$nextflow_bin" inspect "$pipeline" \
    -r "$revision" \
    -profile "$profile" \
    -format json \
    --input "$inspect_input" \
    --outdir "$out_dir" \
    --validate_params false \
    > "$results_dir/${safe_name}.inspect.json" \
    2> "$results_dir/${safe_name}.inspect.err"
  if [[ ! -s "$results_dir/${safe_name}.inspect.json" ]]; then
    echo "ERROR: inspect output missing: $results_dir/${safe_name}.inspect.json" >&2
    exit 1
  fi
  record_stage_status "nextflow-inspect" "ok"
}

run_download() {
  require_cmd "$nfcore_bin"
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
  record_stage_status "download" "ok"
}

run_docker_load() {
  if [[ ! -f "$docker_dir/docker-load.sh" ]]; then
    echo "ERROR: expected docker-load.sh missing: $docker_dir/docker-load.sh" >&2
    exit 1
  fi
  (
    cd "$docker_dir"
    bash docker-load.sh
  ) > "$results_dir/${safe_name}-docker-load.log" 2>&1
  docker images > "$results_dir/docker-images-after-load.txt" 2>&1
  record_stage_status "docker-load" "ok"
}

run_offline_run() {
  local run_input
  run_input="$(prepare_local_samplesheet)"
  mkdir -p "$out_dir" "$work_dir"
  (
    cd "$workspace"
    "$nextflow_bin" run "$workflow_dir" \
      -profile "$profile" \
      -offline \
      --input "$run_input" \
      --outdir "$out_dir" \
      -w "$work_dir"
  ) > "$results_dir/offline-run-result.txt" 2>&1
  cp "$workspace/.nextflow.log" "$results_dir/offline-run-nextflow-log.txt" 2>/dev/null || true
  echo "offline_run_result=success" > "$results_dir/offline-run.status"
}

if has_stage "host-probe"; then
  run_host_probe
fi

if has_stage "nextflow-inspect"; then
  run_nextflow_inspect
fi

if has_stage "download"; then
  run_download
fi

if has_stage "docker-load"; then
  run_docker_load
fi

if has_stage "offline-run"; then
  run_offline_run
fi

if has_stage "offline-run"; then
  echo "offline-run" > "$results_dir/offline-run.status"
else
  echo "offline-run=skipped" > "$results_dir/offline-run.status"
fi

df -h / "$workspace" > "$results_dir/disk-final.txt"
{
  echo "# nf-core Offline Probe Result"
  echo
  echo "Pipeline: $pipeline"
  echo "Revision: $revision"
  echo "Profile: $profile"
  echo "Workspace: $workspace"
  echo "Stages: ${selected_stages[*]}"
  echo
  echo "Result: success"
  echo
  echo "Executed stages:"
  for selected in "${selected_stages[@]}"; do
    echo "- ${selected}: $results_dir/${selected}.status"
  done
  echo
  echo "Evidence:"
  for file in \
    "00-tool-versions.txt" \
    "${safe_name}.inspect.json" \
    "${safe_name}.inspect.err" \
    "${safe_name}-download.log" \
    "${safe_name}-download-tree.txt" \
    "${safe_name}-docker-load.log" \
    "docker-images-after-load.txt" \
    "offline-run.status" \
    "offline-run-result.txt" \
    "offline-run-nextflow-log.txt" \
    "disk-final.txt"; do
    if [[ -f "$results_dir/$file" ]]; then
      echo "- $results_dir/$file"
    fi
  done
  echo
  if has_stage "full-smoke" || has_stage "offline-run"; then
    echo "Note:"
    echo "This includes local download, docker-load, and nextflow -offline run."
    echo "It does not prove private-network behavior unless run with explicit EC2 network probes."
  else
    echo "Note:"
    echo "This is a staged probe run; full private-host or runtime tests were not executed."
  fi
} > "$results_dir/RESULT.md"

echo "OK: $results_dir/RESULT.md"

if [[ ! -f "$results_dir/RESULT.md" ]]; then
  exit 1
fi
