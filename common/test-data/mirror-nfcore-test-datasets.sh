#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  mirror-nfcore-test-datasets.sh --branch BRANCH --files FILE [options]
  mirror-nfcore-test-datasets.sh --pipeline NAME --file PATH [--file PATH ...] [options]

Purpose:
  Mirror selected files from nf-core/test-datasets into a deterministic local
  cache, and optionally upload them to a private S3 prefix.

Defaults:
  - dry-run only
  - no S3 upload unless --upload is set
  - no private values embedded in repo files

Options:
  --branch NAME         nf-core/test-datasets branch, for example rnaseq
  --pipeline NAME       Alias for --branch NAME
  --files FILE          Text file with one dataset path per line
  --file PATH           Add one dataset path; can be repeated
  --out-dir DIR         Output directory. Default: out/test-data/<branch>
  --s3-root URI         Private root for upload/config, or env S3_ROOT
  --download            Download files to the local cache
  --upload              Upload downloaded files to S3. Requires --s3-root
  --force               Overwrite local files
  --retry N             curl retry count. Default: 3
  --help                Show this help

Examples:
  common/test-data/mirror-nfcore-test-datasets.sh \
    --branch rnaseq \
    --file data/fastq/test_R1.fastq.gz

  common/test-data/mirror-nfcore-test-datasets.sh \
    --branch rnaseq \
    --files rnaseq-files.txt \
    --download

  common/test-data/mirror-nfcore-test-datasets.sh \
    --branch rnaseq \
    --files rnaseq-files.txt \
    --download --upload --s3-root "$S3_ROOT"
EOF
}

branch=""
files_file=""
out_dir=""
s3_root="${S3_ROOT:-}"
download=0
upload=0
force=0
retry_count="${CURL_RETRY_COUNT:-3}"
declare -a requested_files=()

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ -n "${2-}" ]] || fail "--branch requires a value"
      branch="$2"
      shift 2
      ;;
    --pipeline)
      [[ -n "${2-}" ]] || fail "--pipeline requires a value"
      branch="$2"
      shift 2
      ;;
    --files)
      [[ -n "${2-}" ]] || fail "--files requires a value"
      files_file="$2"
      shift 2
      ;;
    --file)
      [[ -n "${2-}" ]] || fail "--file requires a value"
      requested_files+=("$2")
      shift 2
      ;;
    --out-dir)
      [[ -n "${2-}" ]] || fail "--out-dir requires a value"
      out_dir="$2"
      shift 2
      ;;
    --s3-root)
      [[ -n "${2-}" ]] || fail "--s3-root requires a value"
      s3_root="$2"
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
    --force)
      force=1
      shift
      ;;
    --retry)
      [[ -n "${2-}" ]] || fail "--retry requires a value"
      retry_count="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$branch" ]] || fail "--branch or --pipeline is required"
[[ "$branch" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid branch name: $branch"
[[ "$retry_count" =~ ^[0-9]+$ ]] || fail "--retry must be an integer"

if [[ -n "$files_file" ]]; then
  [[ -f "$files_file" ]] || fail "files list not found: $files_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -z "$line" ]] && continue
    requested_files+=("$line")
  done < "$files_file"
fi

[[ "${#requested_files[@]}" -gt 0 ]] || fail "provide --file or --files"

if [[ "$upload" -eq 1 ]]; then
  [[ -n "$s3_root" ]] || fail "--upload requires --s3-root or S3_ROOT"
  [[ "$s3_root" =~ ^s3:// ]] || fail "S3 root must start with s3://"
  need_cmd aws
fi

need_cmd sed
need_cmd sha256sum
if [[ "$download" -eq 1 ]]; then
  need_cmd curl
fi

if [[ -z "$out_dir" ]]; then
  out_dir="out/test-data/${branch}"
fi

download_root="${out_dir}/files"
manifest="${out_dir}/manifest.tsv"
config="${out_dir}/testdata.offline.config"
mkdir -p "$download_root"

base_url="https://raw.githubusercontent.com/nf-core/test-datasets/refs/heads/${branch}"
target_base=""
if [[ -n "$s3_root" ]]; then
  target_base="${s3_root%/}/test-datasets/${branch}"
fi

validate_dataset_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *".."* ]] || return 1
  [[ "$path" != *"://"* ]] || return 1
  [[ "$path" =~ ^[A-Za-z0-9._/@=,+:-]+$ ]] || return 1
}

write_config() {
  local base_path="$1"
  {
    echo "/* Generated offline test-data base config for nf-core/test-datasets branch ${branch}. */"
    echo "params {"
    if [[ "$branch" == "modules" ]]; then
      echo "  modules_testdata_base_path = '${base_path%/}/'"
    else
      echo "  pipelines_testdata_base_path = '${base_path%/}/'"
    fi
    echo "}"
  } > "$config"
}

config_base="$download_root"
if [[ "$upload" -eq 1 ]]; then
  config_base="$target_base"
elif [[ -n "$target_base" ]]; then
  config_base="$target_base"
fi
write_config "$config_base"

printf 'branch\tpath\tsource_url\tlocal_path\ttarget_uri\tsha256\tstatus\n' > "$manifest"

status_fail=0
downloaded_count=0
cached_count=0
planned_count=0
uploaded_count=0
failed_count=0
for dataset_path in "${requested_files[@]}"; do
  validate_dataset_path "$dataset_path" || fail "invalid dataset path: $dataset_path"

  source_url="${base_url}/${dataset_path}"
  local_path="${download_root}/${dataset_path}"
  target_uri=""
  if [[ -n "$target_base" ]]; then
    target_uri="${target_base}/${dataset_path}"
  fi

  mkdir -p "$(dirname "$local_path")"

  sha=""
  status="planned"
  if [[ "$download" -eq 1 ]]; then
    if [[ -f "$local_path" && "$force" -eq 0 ]]; then
      status="cached"
      cached_count=$((cached_count + 1))
    else
      tmp_path="${local_path}.tmp.$$"
      rm -f "$tmp_path"
      if curl --fail --show-error --location --retry "$retry_count" --retry-delay 1 "$source_url" -o "$tmp_path"; then
        mv "$tmp_path" "$local_path"
        status="downloaded"
        downloaded_count=$((downloaded_count + 1))
      else
        rm -f "$tmp_path"
        status="download_failed"
        failed_count=$((failed_count + 1))
        status_fail=1
      fi
    fi
    if [[ -f "$local_path" ]]; then
      sha="$(sha256sum "$local_path" | awk '{print $1}')"
    fi
  fi

  if [[ "$upload" -eq 1 && "$status" != "download_failed" ]]; then
    if aws s3 cp "$local_path" "$target_uri" >/dev/null; then
      status="uploaded"
      uploaded_count=$((uploaded_count + 1))
    else
      status="upload_failed"
      failed_count=$((failed_count + 1))
      status_fail=1
    fi
  fi
  if [[ "$status" == "planned" ]]; then
    planned_count=$((planned_count + 1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$branch" "$dataset_path" "$source_url" "$local_path" "$target_uri" "$sha" "$status" >> "$manifest"
done

echo "Branch: $branch"
echo "Files: ${#requested_files[@]}"
echo "Manifest: $manifest"
echo "Config: $config"
echo "Counts: planned=${planned_count} downloaded=${downloaded_count} cached=${cached_count} uploaded=${uploaded_count} failed=${failed_count}"
if [[ "$download" -eq 0 ]]; then
  echo "Mode: dry-run. Add --download to fetch files."
elif [[ "$upload" -eq 0 ]]; then
  echo "Mode: local download only. Add --upload --s3-root <s3://...> to upload."
else
  echo "Mode: download and upload."
fi

exit "$status_fail"
