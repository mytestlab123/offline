#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/ecr-validation-repo-lifecycle.sh [options]

Purpose:
  Inventory retained validation ECR repositories and prepare explicitly gated
  cleanup commands. Default mode is read-only inventory.

Options:
  --profile NAME              Default: ${AWS_PROFILE:-default}
  --region REGION             Default: ${AWS_REGION:-ap-southeast-1}
  --repo-prefix PREFIX        Default: nextflow-offline/e2e-
  --repo-name NAME            Include one exact repository name; repeatable
  --allowlist-file PATH       Newline-delimited exact repository names
  --out-dir DIR               Default: ~/.AGENTS-temp/offline/ecr-validation-repo-lifecycle-<timestamp>
  --repositories-json PATH    Use saved describe-repositories JSON instead of AWS
  --images-dir DIR            Use saved per-repo describe-images JSON files
  --dry-run-delete            Write delete commands but do not execute
  --delete                    Delete only explicitly allowlisted repositories
  --confirm-delete-retained-validation-repos
                              Required with --delete
  --help

Safety:
  Inventory is the default. Delete mode requires --delete, an explicit
  allowlist, and --confirm-delete-retained-validation-repos. Wildcard cleanup is
  not supported.
EOF
}

load_env_file() {
  local script_dir repo_root env_file nounset_was_on
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/../.." && pwd)"
  env_file="${NEXTFLOW_OFFLINE_ENV_FILE:-$repo_root/.env}"
  if [[ -f "$env_file" ]]; then
    nounset_was_on=0
    case "$-" in *u*) nounset_was_on=1; set +u ;; esac
    set -a
    # shellcheck source=/dev/null
    . "$env_file"
    set +a
    if [[ "$nounset_was_on" == "1" ]]; then
      set -u
    fi
  fi
}

safe_repo_file() {
  local name="$1"
  printf '%s\n' "${name//\//__}"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $1" >&2
    exit 2
  fi
}

load_env_file
need_cmd jq

profile="${AWS_PROFILE:-default}"
region="${AWS_REGION:-ap-southeast-1}"
repo_prefix="nextflow-offline/e2e-"
out_dir="$HOME/.AGENTS-temp/offline/ecr-validation-repo-lifecycle-$(date +%Y%m%d-%H%M%S)"
repositories_json=""
images_dir=""
dry_run_delete="false"
delete="false"
confirm_delete="false"
declare -a repo_names=()
declare -a allowlist_files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --repo-prefix) repo_prefix="${2:?missing --repo-prefix value}"; shift 2 ;;
    --repo-name) repo_names+=("${2:?missing --repo-name value}"); shift 2 ;;
    --allowlist-file) allowlist_files+=("${2:?missing --allowlist-file value}"); shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --repositories-json) repositories_json="${2:?missing --repositories-json value}"; shift 2 ;;
    --images-dir) images_dir="${2:?missing --images-dir value}"; shift 2 ;;
    --dry-run-delete) dry_run_delete="true"; shift ;;
    --delete) delete="true"; shift ;;
    --confirm-delete-retained-validation-repos) confirm_delete="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$delete" == "true" && "$confirm_delete" != "true" ]]; then
  echo "ERROR: --delete requires --confirm-delete-retained-validation-repos" >&2
  exit 2
fi

if [[ "$delete" == "true" && ${#repo_names[@]} -eq 0 && ${#allowlist_files[@]} -eq 0 ]]; then
  echo "ERROR: --delete requires --repo-name or --allowlist-file" >&2
  exit 2
fi

mkdir -p "$out_dir/images"

repo_allowlist="$out_dir/repo-allowlist.txt"
: > "$repo_allowlist"
for repo_name in "${repo_names[@]}"; do
  printf '%s\n' "$repo_name" >> "$repo_allowlist"
done
for allowlist_file in "${allowlist_files[@]}"; do
  if [[ ! -f "$allowlist_file" ]]; then
    echo "ERROR: allowlist file not found: $allowlist_file" >&2
    exit 2
  fi
  sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$allowlist_file" >> "$repo_allowlist"
done
sort -u "$repo_allowlist" -o "$repo_allowlist"

if [[ -n "$repositories_json" ]]; then
  cp "$repositories_json" "$out_dir/repositories.json"
else
  AWS_PROFILE="$profile" aws --region "$region" ecr describe-repositories \
    --output json > "$out_dir/repositories.json"
fi

jq --arg prefix "$repo_prefix" --rawfile allow "$repo_allowlist" '
  ($allow | split("\n") | map(select(length > 0))) as $allowlist
  | .repositories
  | map(select(
      (if ($allowlist | length) > 0 then (.repositoryName as $n | $allowlist | index($n)) else false end)
      or
      (if $prefix == "" then false else (.repositoryName | startswith($prefix)) end)
    ))
  | sort_by(.repositoryName)
' "$out_dir/repositories.json" > "$out_dir/selected-repositories.json"

jq -r '.[].repositoryName' "$out_dir/selected-repositories.json" > "$out_dir/selected-repositories.txt"

while IFS= read -r repo_name; do
  [[ -n "$repo_name" ]] || continue
  safe_name="$(safe_repo_file "$repo_name")"
  if [[ -n "$images_dir" && -f "$images_dir/$safe_name.json" ]]; then
    cp "$images_dir/$safe_name.json" "$out_dir/images/$safe_name.json"
  else
    AWS_PROFILE="$profile" aws --region "$region" ecr describe-images \
      --repository-name "$repo_name" \
      --output json > "$out_dir/images/$safe_name.json" 2> "$out_dir/images/$safe_name.stderr" || \
      jq -n --arg repo "$repo_name" '{imageDetails: [], error: ("describe-images failed for " + $repo)}' > "$out_dir/images/$safe_name.json"
  fi
done < "$out_dir/selected-repositories.txt"

inventory_jsonl="$out_dir/inventory.jsonl"
: > "$inventory_jsonl"
while IFS= read -r repo_name; do
  [[ -n "$repo_name" ]] || continue
  safe_name="$(safe_repo_file "$repo_name")"
  jq -n \
    --arg repo "$repo_name" \
    --slurpfile repos "$out_dir/selected-repositories.json" \
    --slurpfile images "$out_dir/images/$safe_name.json" '
      ($repos[0][] | select(.repositoryName == $repo)) as $r
      | ($images[0].imageDetails // []) as $imgs
      | {
          repositoryName: $repo,
          repositoryUri: ($r.repositoryUri // ""),
          createdAt: (($r.createdAt // "") | tostring),
          imageCount: ($imgs | length),
          taggedImageCount: ($imgs | map(select((.imageTags // []) | length > 0)) | length),
          latestImagePushedAt: (($imgs | map(.imagePushedAt // empty) | sort | last) // ""),
          cleanupRecommendation: (
            if ($repo | test("/e2e-|validation|temporary|tmp")) then
              "review-retained-validation-repo"
            else
              "keep-or-review-manually"
            end
          )
        }
    ' >> "$inventory_jsonl"
done < "$out_dir/selected-repositories.txt"

jq -s '.' "$inventory_jsonl" > "$out_dir/inventory.json"

{
  printf 'repository\tcreated_at\timage_count\ttagged_image_count\tlatest_image_pushed_at\tcleanup_recommendation\n'
  jq -r '.[] | [
    .repositoryName,
    .createdAt,
    (.imageCount | tostring),
    (.taggedImageCount | tostring),
    .latestImagePushedAt,
    .cleanupRecommendation
  ] | @tsv' "$out_dir/inventory.json"
} > "$out_dir/inventory.tsv"

{
  printf '| Repository | Created | Images | Tagged images | Latest push | Recommendation |\n'
  printf '| --- | --- | ---: | ---: | --- | --- |\n'
  jq -r '.[] | "| \(.repositoryName) | \(.createdAt) | \(.imageCount) | \(.taggedImageCount) | \(.latestImagePushedAt) | \(.cleanupRecommendation) |"' "$out_dir/inventory.json"
} > "$out_dir/inventory.md"

delete_commands="$out_dir/delete-commands.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n\n'
  printf '# Review before running. Generated for explicitly allowlisted repositories only.\n'
} > "$delete_commands"
chmod +x "$delete_commands"

if [[ "$dry_run_delete" == "true" || "$delete" == "true" ]]; then
  if [[ ! -s "$repo_allowlist" ]]; then
    echo "ERROR: delete planning requires --repo-name or --allowlist-file" >&2
    exit 2
  fi
  while IFS= read -r repo_name; do
    [[ -n "$repo_name" ]] || continue
    if ! grep -Fxq "$repo_name" "$out_dir/selected-repositories.txt"; then
      echo "ERROR: allowlisted repo was not selected by inventory: $repo_name" >&2
      exit 2
    fi
    printf 'AWS_PROFILE=%q aws --region %q ecr delete-repository --repository-name %q --force\n' \
      "$profile" "$region" "$repo_name" >> "$delete_commands"
  done < "$repo_allowlist"
fi

if [[ "$delete" == "true" ]]; then
  while IFS= read -r repo_name; do
    [[ -n "$repo_name" ]] || continue
    AWS_PROFILE="$profile" aws --region "$region" ecr delete-repository \
      --repository-name "$repo_name" \
      --force > "$out_dir/delete-${repo_name//\//__}.json"
  done < "$repo_allowlist"
fi

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - ECR Validation Repository Lifecycle

Status: done

Mode:
- inventory
- dry_run_delete: $dry_run_delete
- delete: $delete

Inputs:
- profile: $profile
- region: $region
- repo_prefix: $repo_prefix

Outputs:
- inventory_json: $out_dir/inventory.json
- inventory_tsv: $out_dir/inventory.tsv
- inventory_md: $out_dir/inventory.md
- delete_commands: $delete_commands

Safety:
- Default mode is read-only inventory.
- Delete mode requires --delete, explicit allowlist, and confirmation token.
RESULT

cat "$out_dir/inventory.md"
printf '\nResult: %s\n' "$out_dir/RESULT.md"
