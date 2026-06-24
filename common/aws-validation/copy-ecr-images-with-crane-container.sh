#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/copy-ecr-images-with-crane-container.sh --failed-images FILE [options]

Purpose:
  Copy source images to ECR with the crane container. This is a fallback for
  source images that Docker can pull but cannot push due local content-store
  blob issues.

Options:
  --profile NAME           Default: ${AWS_PROFILE:-dev}
  --region REGION          Default: ${AWS_REGION:-ap-southeast-1}
  --failed-images FILE     TSV from mirror-ecr-images-from-manifest.sh.
  --crane-image IMAGE      Default: gcr.io/go-containerregistry/crane:debug
  --out-dir DIR            Default: ~/.AGENTS-temp/offline/ecr-crane-copy-<timestamp>
  --dry-run                Write plan only; do not copy.
  --help

The script intentionally does not delete ECR repositories.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

profile="${AWS_PROFILE:-dev}"
region="${AWS_REGION:-ap-southeast-1}"
failed_images=""
crane_image="gcr.io/go-containerregistry/crane:debug"
out_dir="$HOME/.AGENTS-temp/offline/ecr-crane-copy-$(date +%Y%m%d-%H%M%S)"
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --failed-images) failed_images="${2:?missing --failed-images value}"; shift 2 ;;
    --crane-image) crane_image="${2:?missing --crane-image value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$failed_images" && -f "$failed_images" ]] || die "--failed-images must be an existing file"

need aws
need docker

mkdir -p "$out_dir"
cp "$failed_images" "$out_dir/failed-images.tsv"

awk -F '\t' 'NR == 1 {
  if ($1 != "source_image" || $4 != "ecr_image") {
    exit 2
  }
}' "$failed_images" || die "failed image TSV header is invalid"

{
  echo "source_image	ecr_image	action"
  tail -n +2 "$failed_images" | while IFS=$'\t' read -r source_image _repository_name _tag ecr_image _stage; do
    [[ -n "$source_image" && -n "$ecr_image" ]] || continue
    echo "$source_image	$ecr_image	planned"
  done
} > "$out_dir/plan.tsv"

if [[ "$dry_run" == "true" ]]; then
  cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - Crane Container ECR Copy

Status: dry_run

Failed-image source:
- $failed_images

Evidence:
- $out_dir/plan.tsv
RESULT
  cat "$out_dir/RESULT.md"
  exit 0
fi

account_id="$(aws --profile "$profile" --region "$region" sts get-caller-identity --query Account --output text)"
registry="$account_id.dkr.ecr.$region.amazonaws.com"
aws --profile "$profile" --region "$region" ecr get-login-password \
  | docker login --username AWS --password-stdin "$registry" \
  > "$out_dir/ecr-login.txt"

copied_count=0
failed_count=0
copy_failures="$out_dir/copy-failures.tsv"
echo "source_image	ecr_image" > "$copy_failures"

while IFS=$'\t' read -r source_image _repository_name _tag ecr_image _stage; do
  [[ -n "$source_image" && -n "$ecr_image" ]] || continue
  safe_name="$(printf '%s' "$ecr_image" | tr -c 'A-Za-z0-9_.-' '_')"
  if docker run --rm \
    -v "$HOME/.docker/config.json:/root/.docker/config.json:ro" \
    "$crane_image" cp "$source_image" "$ecr_image" \
    > "$out_dir/crane-copy-$safe_name.log" \
    2> "$out_dir/crane-copy-$safe_name.stderr"; then
    copied_count=$((copied_count + 1))
  else
    failed_count=$((failed_count + 1))
    echo "$source_image	$ecr_image" >> "$copy_failures"
  fi
done < <(tail -n +2 "$failed_images")

status="copied"
if [[ "$failed_count" -gt 0 ]]; then
  status="partial"
fi

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - Crane Container ECR Copy

Status: $status

Profile/region:
- $profile / $region

Counts:
- copied_images: $copied_count
- failed_images: $failed_count

Failed-image source:
- $failed_images

Evidence:
- $out_dir/plan.tsv
- $out_dir/copy-failures.tsv

Cleanup:
- ECR repositories retained by design.
RESULT

cat "$out_dir/RESULT.md"
