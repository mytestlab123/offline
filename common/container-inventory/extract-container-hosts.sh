#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  extract-container-hosts.sh --pipeline NAME [options]

Options:
  -p, --pipeline NAME       Pipeline folder/name, for example sarek
  -r, --revision VERSION    Revision override. Defaults from PIPELINE/ENV
  --profile PROFILE         Nextflow profile for inspect. Default: test,docker
  --source DIR              Local Nextflow source dir override
  --inspect-json FILE       Use existing nextflow inspect JSON
  --input-list FILE         Use existing newline-delimited container list
  --static                  Static scan local source when inspect is unavailable
  --out-root DIR            Output root. Default: out/container-inventory
  --force                   Replace existing output directory for pipeline
  -h, --help                Show help

Outputs:
  all.txt
  summary.tsv
  hosts/<host>.txt
  hosts/implicit.txt
  hosts/unknown.txt
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

pipeline=""
revision=""
profile="test,docker"
source_dir=""
inspect_json=""
input_list=""
out_root="out/container-inventory"
force=0
static_scan=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--pipeline) pipeline="$2"; shift 2 ;;
    -r|--revision) revision="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --source) source_dir="$2"; shift 2 ;;
    --inspect-json) inspect_json="$2"; shift 2 ;;
    --input-list) input_list="$2"; shift 2 ;;
    --out-root) out_root="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --static) static_scan=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$pipeline" ]] || { usage >&2; exit 2; }

need awk
need sed
need sort
need wc

env_file="${repo_root}/${pipeline}/ENV"
if [[ -f "$env_file" ]]; then
  # shellcheck disable=SC1090
  source "$env_file"
fi

revision="${revision:-${REVISION:-}}"
pipeline="${pipeline:-${PIPELINE:-}}"
out_dir="${repo_root}/${out_root}/${pipeline}"
host_dir="${out_dir}/hosts"
raw_dir="${out_dir}/raw"

if [[ "$force" == "1" ]]; then
  rm -rf "$out_dir"
fi
mkdir -p "$host_dir" "$raw_dir"

if [[ -z "$source_dir" ]]; then
  if [[ -f "${repo_root}/${pipeline}/${pipeline}/main.nf" ]]; then
    source_dir="${repo_root}/${pipeline}/${pipeline}"
  elif [[ -f "${repo_root}/${pipeline}/main.nf" ]]; then
    source_dir="${repo_root}/${pipeline}"
  fi
fi

if [[ -n "$source_dir" && -L "${source_dir}/conf/test.config" && ! -e "${source_dir}/conf/test.config" ]]; then
  echo "[w] ignoring local source with broken conf/test.config symlink: ${source_dir}" >&2
  source_dir=""
fi

containers_tmp="${raw_dir}/containers.raw"
: > "$containers_tmp"

extract_from_json() {
  local file="$1"
  need jq
  jq -r '.. | objects | .container? // empty | strings' "$file"
}

extract_from_static_source() {
  local dir="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -A 3 -g '*.nf' -g '*.config' -g 'nextflow.config' -n "container" "$dir" \
      | rg -No "['\"](docker://)?([A-Za-z0-9.-]+(:[0-9]+)?/)?(biocontainers|nf-core|nfcore|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/[A-Za-z0-9._/-]+:[A-Za-z0-9._+:-]+['\"]" \
      | sed -E "s/^[^'\"]*['\"]//; s/['\"]$//"
  else
    find "$dir" -type f \( -name '*.nf' -o -name '*.config' -o -name 'nextflow.config' \) -print0 \
      | xargs -0 grep -A 3 -h "container" \
      | grep -Eo "['\"](docker://)?([A-Za-z0-9.-]+(:[0-9]+)?/)?(biocontainers|nf-core|nfcore|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/[A-Za-z0-9._/-]+:[A-Za-z0-9._+:-]+['\"]" \
      | sed -E "s/^['\"]//; s/['\"]$//"
  fi
}

run_nextflow_inspect() {
  need nextflow
  need jq
  local json="${raw_dir}/inspect.json"
  local inspect_out="${raw_dir}/inspect-out"
  mkdir -p "$inspect_out"

  if [[ -n "$source_dir" && -f "${source_dir}/main.nf" ]]; then
    (
      cd "$source_dir"
      nextflow inspect . -profile "$profile" --outdir "$inspect_out" -concretize true -format json > "$json"
    )
  else
    [[ -n "$revision" ]] || die "revision required when inspecting nf-core/${pipeline}"
    nextflow inspect "nf-core/${pipeline}" -r "$revision" -profile "$profile" --outdir "$inspect_out" -concretize true -format json > "$json"
  fi

  extract_from_json "$json"
}

if [[ -n "$input_list" ]]; then
  [[ -f "$input_list" ]] || die "input list not found: $input_list"
  cat "$input_list" > "$containers_tmp"
elif [[ -n "$inspect_json" ]]; then
  [[ -f "$inspect_json" ]] || die "inspect JSON not found: $inspect_json"
  cp "$inspect_json" "${raw_dir}/inspect.json"
  extract_from_json "$inspect_json" > "$containers_tmp"
elif command -v nextflow >/dev/null 2>&1; then
  run_nextflow_inspect > "$containers_tmp"
elif [[ "$static_scan" == "1" && -n "$source_dir" && -d "$source_dir" ]]; then
  extract_from_static_source "$source_dir" > "$containers_tmp"
else
  die "no input available. Install nextflow, pass --inspect-json, pass --input-list, or use --static with local source"
fi

normalize_container() {
  sed -E \
    -e 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    -e 's#^(docker|podman|singularity|oras)://##' \
    -e '/^$/d'
}

normalize_container < "$containers_tmp" | sort -u > "${out_dir}/all.txt"

: > "${out_dir}/summary.tsv"
printf 'host\tcount\tfile\n' > "${out_dir}/summary.tsv"

safe_host_file() {
  local host="$1"
  echo "$host" | sed -E 's#[^A-Za-z0-9_.-]#_#g'
}

host_for_container() {
  local image="$1"
  local first="${image%%/*}"
  if [[ "$image" != */* ]]; then
    echo "unknown"
  elif [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    echo "$first"
  else
    echo "implicit"
  fi
}

while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  host="$(host_for_container "$image")"
  file="${host_dir}/$(safe_host_file "$host").txt"
  printf '%s\n' "$image" >> "$file"
done < "${out_dir}/all.txt"

for expected in quay.io community.wave.seqera.io docker.io ghcr.io implicit unknown; do
  touch "${host_dir}/$(safe_host_file "$expected").txt"
done

for file in "${host_dir}"/*.txt; do
  sort -u "$file" -o "$file"
  count="$(wc -l < "$file" | awk '{print $1}')"
  host="$(basename "$file" .txt)"
  printf '%s\t%s\t%s\n' "$host" "$count" "$file" >> "${out_dir}/summary.tsv"
done

total="$(wc -l < "${out_dir}/all.txt" | awk '{print $1}')"
{
  echo "pipeline=${pipeline}"
  echo "revision=${revision:-unknown}"
  echo "profile=${profile}"
  echo "source=${source_dir:-nf-core/${pipeline}}"
  echo "total_unique_containers=${total}"
  echo "out_dir=${out_dir}"
} > "${out_dir}/metadata.env"

echo "[ok] ${pipeline}: ${total} unique containers"
echo "[ok] output: ${out_dir}"
