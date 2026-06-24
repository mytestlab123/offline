#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/verify-ecr-images-from-manifest.sh --image-manifest FILE [options]

Purpose:
  Verify that every ECR image URI in a generated image manifest has a readable
  registry manifest. This is the deterministic readback gate after Docker and
  crane mirror steps.

Options:
  --profile NAME           Default: ${AWS_PROFILE:-dev}
  --region REGION          Default: ${AWS_REGION:-ap-southeast-1}
  --image-manifest FILE    Required. TSV with source_image/repository_name/tag/ecr_image.
  --out-dir DIR            Default: ~/.AGENTS-temp/offline/ecr-image-readback-<timestamp>
  --help
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
image_manifest=""
out_dir="$HOME/.AGENTS-temp/offline/ecr-image-readback-$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --image-manifest) image_manifest="${2:?missing --image-manifest value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$image_manifest" && -f "$image_manifest" ]] || die "--image-manifest must be an existing file"

need aws
need docker

mkdir -p "$out_dir"
cp "$image_manifest" "$out_dir/image-manifest.tsv"

awk -F '\t' 'NR == 1 {
  if ($1 != "source_image" || $4 != "ecr_image") {
    exit 2
  }
}' "$image_manifest" || die "image manifest header is invalid"

awk -F '\t' 'NR > 1 && $4 != "" {
  split($4, parts, "/")
  print parts[1]
}' "$image_manifest" | sort -u > "$out_dir/ecr-registries.txt"

while IFS= read -r registry; do
  [[ -n "$registry" ]] || continue
  aws --profile "$profile" --region "$region" ecr get-login-password |
    docker login --username AWS --password-stdin "$registry" \
      >> "$out_dir/ecr-login.log" 2>> "$out_dir/ecr-login.stderr"
done < "$out_dir/ecr-registries.txt"

readback="$out_dir/ecr-manifest-readback.tsv"
errors="$out_dir/ecr-manifest-readback.stderr"
: > "$readback"
: > "$errors"
echo "source_image	ecr_image	status" >> "$readback"

while IFS=$'\t' read -r source_image _repository_name _tag ecr_image; do
  [[ -n "$source_image" && -n "$ecr_image" ]] || continue
  safe_name="$(printf '%s' "$ecr_image" | tr -c 'A-Za-z0-9_.-' '_')"
  if docker manifest inspect "$ecr_image" > "$out_dir/manifest-$safe_name.json" 2>> "$errors"; then
    echo "$source_image	$ecr_image	ok" >> "$readback"
  else
    echo "$source_image	$ecr_image	failed" >> "$readback"
  fi
done < <(tail -n +2 "$image_manifest")

ok_count="$(awk -F '\t' '$3 == "ok" {count++} END {print count+0}' "$readback")"
fail_count="$(awk -F '\t' '$3 == "failed" {count++} END {print count+0}' "$readback")"
status="passed"
if [[ "$fail_count" -gt 0 ]]; then
  status="failed"
fi

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - ECR Manifest Readback

Status: $status

Profile/region:
- $profile / $region

Counts:
- ok: $ok_count
- failed: $fail_count

Evidence:
- $readback
- $errors
RESULT

cat "$out_dir/RESULT.md"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
