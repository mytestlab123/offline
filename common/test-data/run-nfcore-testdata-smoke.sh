#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-nfcore-testdata-smoke.sh [options]

Purpose:
  Deterministically run small nf-core/test-datasets smoke checks for one or more
  pipelines with optional download/upload.

Defaults:
  - dry-run only
  - no S3 upload unless --upload is set
  - file list defaults to
    common/test-data/file-lists/<pipeline>-smoke.txt

Options:
  --pipeline NAME         Pipeline/branch target. Can be repeated.
  --branch NAME           Alias for --pipeline. Can be repeated.
  --files PATH            File list for the most recent --pipeline/--branch.
                          Can be set once per target entry.
  --out-dir DIR           Output directory. Default: out/test-data-smoke
  --download              Download files in addition to dry-run.
  --upload                Upload downloaded files. Implies --download.
  --s3-root URI           Private S3 root for upload/config.
  --help                  Show this help.

Notes:
  --pipeline/--branch entries are processed in order. Each entry may set its own
  --files list. If --files is not provided, the script uses:
  common/test-data/file-lists/<pipeline>-smoke.txt

Examples:
  # deterministic dry-run only for bamtofastq
  run-nfcore-testdata-smoke.sh --pipeline bamtofastq

  # two targets, one dry-run and one download
  run-nfcore-testdata-smoke.sh \
    --pipeline bamtofastq --files common/test-data/file-lists/bamtofastq-smoke.txt \
    --pipeline testpipeline --download

  # download and upload with S3 root
  run-nfcore-testdata-smoke.sh \
    --pipeline bamtofastq --download --upload --s3-root s3://mybucket/offline
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mirror_script="${repo_root}/common/test-data/mirror-nfcore-test-datasets.sh"

out_dir="${OUT_DIR:-out/test-data-smoke}"
s3_root="${S3_ROOT:-}"
download=0
upload=0

declare -a pipeline_names=()
declare -a pipeline_files=()
current_pipeline_index=-1

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

validate_pipeline_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid pipeline/branch name: $1"
}

add_pipeline_target() {
  local pipeline="$1"
  validate_pipeline_name "$pipeline"
  pipeline_names+=("$pipeline")
  pipeline_files+=("")
  current_pipeline_index=$(( ${#pipeline_names[@]} - 1 ))
}

set_pipeline_files() {
  local files_path="$1"
  if (( current_pipeline_index < 0 )); then
    fail "--files requires --pipeline or --branch first"
  fi
  if [[ -n "${pipeline_files[$current_pipeline_index]}" ]]; then
    fail "--files already set for ${pipeline_names[$current_pipeline_index]}"
  fi
  pipeline_files["$current_pipeline_index"]="$files_path"
}

branch_check_status() {
  local branch="$1"
  local log_path="$2"
  if git ls-remote --exit-code --heads https://github.com/nf-core/test-datasets.git "$branch" > "$log_path" 2>&1; then
    echo "exists"
    return 0
  fi
  local rc=$?
  if [[ "$rc" -eq 2 ]]; then
    echo "missing"
    return 0
  fi
  echo "check_failed"
  return 0
}

run_mirror() {
  local pipeline="$1"
  local files_path="$2"
  local target_dir="$3"
  local out_log="$4"
  local mode="$5"
  local -a mirror_args=("--branch" "$pipeline" "--files" "$files_path" "--out-dir" "$target_dir")
  local -a extra_args=()

  if [[ "$mode" == "download" || "$mode" == "download_upload" ]]; then
    extra_args+=(--download)
  fi
  if [[ "$mode" == "download_upload" ]]; then
    extra_args+=(--upload --s3-root "$s3_root")
  fi

  local status=failed
  if "${mirror_script}" "${mirror_args[@]}" "${extra_args[@]}" > "$out_log" 2>&1; then
    status=ok
  fi
  echo "$status"
}

append_summary() {
  local pipeline="$1"
  local branch_exists_flag="$2"
  local mode="$3"
  local status="$4"
  local manifest="$5"
  local log_path="$6"
  local files_path="$7"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pipeline" "$branch_exists_flag" "$mode" "$status" "$manifest" "$log_path" "$files_path" >> "$summary"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline|--branch)
      [[ -n "${2-}" ]] || fail "--pipeline/--branch requires a value"
      add_pipeline_target "$2"
      shift 2
      ;;
    --files)
      [[ -n "${2-}" ]] || fail "--files requires a value"
      set_pipeline_files "$2"
      shift 2
      ;;
    --out-dir)
      [[ -n "${2-}" ]] || fail "--out-dir requires a value"
      out_dir="$2"
      shift 2
      ;;
    --download)
      download=1
      shift
      ;;
    --upload)
      upload=1
      download=1
      shift
      ;;
    --s3-root)
      [[ -n "${2-}" ]] || fail "--s3-root requires a value"
      s3_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "${#pipeline_names[@]}" -gt 0 ]] || fail "use --pipeline or --branch at least once"

need_cmd git
need_cmd awk
need_cmd sed
need_cmd sha256sum
[[ -x "$mirror_script" ]] || fail "helper is not executable: $mirror_script"

if [[ "$upload" -eq 1 ]]; then
  [[ -n "$s3_root" ]] || fail "--upload requires --s3-root or S3_ROOT"
  [[ "$s3_root" =~ ^s3:// ]] || fail "s3 root must start with s3://"
  need_cmd aws
  need_cmd curl
fi

if [[ "$download" -eq 1 ]]; then
  need_cmd curl
fi

mkdir -p "$out_dir"
summary="${out_dir}/summary.tsv"
result="${out_dir}/RESULT.md"

printf 'pipeline\tbranch_exists\tmode\tstatus\tmanifest\tlogs\tfiles\n' > "$summary"

overall_failed=0

for idx in "${!pipeline_names[@]}"; do
  pipeline="${pipeline_names[$idx]}"
  files_path="${pipeline_files[$idx]}"
  [[ -n "$files_path" ]] || files_path="${repo_root}/common/test-data/file-lists/${pipeline}-smoke.txt"

  target_dir="${out_dir}/${pipeline}"
  mkdir -p "$target_dir"

  branch_log="${target_dir}/branch-check.log"
  branch_status="$(branch_check_status "$pipeline" "$branch_log")"
  if [[ "$branch_status" == "missing" ]]; then
    append_summary "$pipeline" "no" "none" "branch_missing" "" "$branch_log" "$files_path"
    continue
  fi
  if [[ "$branch_status" == "check_failed" ]]; then
    append_summary "$pipeline" "unknown" "none" "branch_check_failed" "" "$branch_log" "$files_path"
    overall_failed=1
    continue
  fi

  if [[ ! -f "$files_path" ]]; then
    append_summary "$pipeline" "yes" "none" "files_missing" "" "$branch_log" "$files_path"
    overall_failed=1
    continue
  fi

  mode="dry-run"
  dry_run_log="${target_dir}/dry-run.log"
  dry_run_status="$(run_mirror "$pipeline" "$files_path" "${target_dir}/dry-run" "$dry_run_log" "dry")"
  if [[ "$dry_run_status" != "ok" ]]; then
    append_summary "$pipeline" "yes" "dry-run" "dry_run_failed" "" "$dry_run_log" "$files_path"
    overall_failed=1
    continue
  fi

  final_manifest="${target_dir}/dry-run/manifest.tsv"
  final_log="$dry_run_log"

  if [[ "$download" -eq 1 ]]; then
    mode="download"
    download_log="${target_dir}/download.log"
    download_status="$(run_mirror "$pipeline" "$files_path" "${target_dir}/download" "$download_log" "download")"
    final_manifest="${target_dir}/download/manifest.tsv"
    final_log="$download_log"
    if [[ "$download_status" != "ok" ]]; then
      append_summary "$pipeline" "yes" "$mode" "download_failed" "$final_manifest" "$download_log" "$files_path"
      overall_failed=1
      continue
    fi
  fi

  if [[ "$upload" -eq 1 ]]; then
    mode="download+upload"
    upload_log="${target_dir}/upload.log"
    upload_status="$(run_mirror "$pipeline" "$files_path" "${target_dir}/upload" "$upload_log" "download_upload")"
    final_manifest="${target_dir}/upload/manifest.tsv"
    final_log="$upload_log"
    if [[ "$upload_status" != "ok" ]]; then
      append_summary "$pipeline" "yes" "$mode" "upload_failed" "$final_manifest" "$upload_log" "$files_path"
      overall_failed=1
      continue
    fi
  fi

  append_summary "$pipeline" "yes" "$mode" "ok" "$final_manifest" "$final_log" "$files_path"
done

cat > "$result" <<EOF
# RESULT - nf-core test-data smoke

Result:
- done

Output:
- ${out_dir}

Summary:
$(awk -F'\t' 'NR > 1 {
  printf "- %-16s branch_exists=%s mode=%s status=%s manifest=%s\n", $1, $2, $3, $4, $5
}' "$summary")

Notes:
- branch_missing is recorded without failing the runner.
- branch_check_failed fails the runner because live upstream status is unknown.
- Files for each target default to common/test-data/file-lists/<pipeline>-smoke.txt.
- No upload run unless --upload is set.
- Dry-run is the default mode.
- See summary.tsv for per-target logs, file lists, and manifests.
EOF

if [[ "$overall_failed" -ne 0 ]]; then
  exit 1
fi

echo "RESULT: $result"
echo "SUMMARY: $summary"
