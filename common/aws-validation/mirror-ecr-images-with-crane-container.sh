#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/mirror-ecr-images-with-crane-container.sh --image-manifest FILE [options]

Purpose:
  Create/retain ECR repositories and copy source images to ECR with crane.
  This avoids Docker pull/tag/push and does not store image layers in the
  local Docker image cache.

Options:
  --profile NAME           Default: ${AWS_PROFILE:-default}
  --region REGION          Default: ${AWS_REGION:-ap-southeast-1}
  --image-manifest FILE    Required. TSV with source_image/repository_name/tag/ecr_image.
  --ec2-role-arn ARN       Optional. Add repository policy allowing this role to pull.
  --crane-image IMAGE      Default: gcr.io/go-containerregistry/crane:debug
  --out-dir DIR            Default: ~/.AGENTS-temp/offline/ecr-crane-mirror-<timestamp>
  --continue-on-error      Continue after per-image copy failure and write failed-images.tsv.
  --dry-run                Write plan only; do not create/copy.
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

load_env_file

profile="${AWS_PROFILE:-default}"
region="${AWS_REGION:-ap-southeast-1}"
image_manifest=""
ec2_role_arn=""
crane_image="gcr.io/go-containerregistry/crane:debug"
out_dir="$HOME/.AGENTS-temp/offline/ecr-crane-mirror-$(date +%Y%m%d-%H%M%S)"
continue_on_error="false"
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --image-manifest) image_manifest="${2:?missing --image-manifest value}"; shift 2 ;;
    --ec2-role-arn) ec2_role_arn="${2:?missing --ec2-role-arn value}"; shift 2 ;;
    --crane-image) crane_image="${2:?missing --crane-image value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --continue-on-error) continue_on_error="true"; shift ;;
    --dry-run) dry_run="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$image_manifest" && -f "$image_manifest" ]] || die "--image-manifest must be an existing file"

need aws
need docker
need jq
need python3

mkdir -p "$out_dir"
cp "$image_manifest" "$out_dir/image-manifest.tsv"

python3 - "$image_manifest" "$out_dir/manifest-validation.tsv" <<'PY'
import csv
import re
import sys

manifest, validation_out = sys.argv[1:]
repo_re = re.compile(r"^[a-z0-9]+([._/-]?[a-z0-9]+)*$")
tag_re = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
ecr_re = re.compile(r"^(?P<registry>[0-9]{12}\.dkr\.ecr\.[A-Za-z0-9-]+\.amazonaws(?:\.com(?:\.cn)?|\.com))/(?:.+):.+$")
errors = []
rows = []

with open(manifest, newline="", encoding="utf-8") as handle:
    reader = csv.reader(handle, delimiter="\t")
    header = next(reader, None)
    if header != ["source_image", "repository_name", "tag", "ecr_image"]:
        errors.append(f"invalid header: {header}")
    for line_number, row in enumerate(reader, start=2):
        if len(row) != 4:
            errors.append(f"line {line_number}: expected 4 columns, got {len(row)}")
            continue
        source_image, repository_name, tag, ecr_image = [value.strip() for value in row]
        rows.append((line_number, source_image, repository_name, tag, ecr_image))
        if not source_image:
            errors.append(f"line {line_number}: source_image is empty")
        if not repo_re.match(repository_name) or len(repository_name) > 256:
            errors.append(f"line {line_number}: invalid repository_name: {repository_name}")
        if not tag_re.match(tag):
            errors.append(f"line {line_number}: invalid tag: {tag}")
        match = ecr_re.match(ecr_image)
        if not match:
            errors.append(f"line {line_number}: invalid ecr_image: {ecr_image}")
        else:
            expected_ecr_image = f"{match.group('registry')}/{repository_name}:{tag}"
            if ecr_image != expected_ecr_image:
                errors.append(
                    f"line {line_number}: ecr_image does not match repository_name/tag: {ecr_image}"
                )

with open(validation_out, "w", encoding="utf-8") as handle:
    handle.write("line\tsource_image\trepository_name\ttag\tecr_image\n")
    for row in rows:
        handle.write("\t".join(str(value) for value in row) + "\n")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY

repository_policy="$out_dir/ecr-repository-policy.json"
if [[ -n "$ec2_role_arn" ]]; then
  jq -n --arg role "$ec2_role_arn" '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "AllowValidationEc2Pull",
        Effect: "Allow",
        Principal: {AWS: $role},
        Action: [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
      }
    ]
  }' > "$repository_policy"
fi

{
  echo "source_image	repository_name	tag	ecr_image	action"
  tail -n +2 "$image_manifest" | while IFS=$'\t' read -r source_image repository_name tag ecr_image; do
    [[ -n "$source_image" && -n "$repository_name" && -n "$tag" && -n "$ecr_image" ]] || continue
    echo "$source_image	$repository_name	$tag	$ecr_image	planned"
  done
} > "$out_dir/plan.tsv"

if [[ "$dry_run" == "true" ]]; then
  cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - Crane Container ECR Mirror

Status: dry_run

Manifest:
- $image_manifest

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

created_count=0
reused_count=0
copied_count=0
failed_count=0
successful_images="$out_dir/successful-images.tsv"
failed_images="$out_dir/failed-images.tsv"
echo "source_image	repository_name	tag	ecr_image" > "$successful_images"
echo "source_image	repository_name	tag	ecr_image	stage" > "$failed_images"

while IFS=$'\t' read -r source_image repository_name tag ecr_image; do
  [[ -n "$source_image" && -n "$repository_name" && -n "$tag" && -n "$ecr_image" ]] || continue

  if aws --profile "$profile" --region "$region" ecr describe-repositories \
    --repository-names "$repository_name" \
    >> "$out_dir/ecr-describe-repositories.jsonl" 2>> "$out_dir/ecr-describe-repositories.stderr"; then
    reused_count=$((reused_count + 1))
  else
    aws --profile "$profile" --region "$region" ecr create-repository \
      --repository-name "$repository_name" \
      --image-scanning-configuration scanOnPush=false \
      --encryption-configuration encryptionType=AES256 \
      --tags \
        Key=Name,Value="$(basename "$repository_name")" \
        Key=dev,Value=amit \
        Key=project,Value=nextflow-offline \
        Key=created,Value="$(date +%F)" \
        Key=tools,Value=cdx \
        Key=environment,Value=dev \
        Key=owner,Value=amit \
        Key=version,Value=ecr-crane-mirror \
        Key=TTL,Value=review-month-end \
        Key=purpose,Value=nextflow-offline-ecr-mirror \
        Key=phase,Value=ecr-pipeline-e2e \
        >> "$out_dir/ecr-create-repositories.jsonl" \
        2>> "$out_dir/ecr-create-repositories.stderr"
    created_count=$((created_count + 1))
  fi

  if [[ -n "$ec2_role_arn" ]]; then
    aws --profile "$profile" --region "$region" ecr set-repository-policy \
      --repository-name "$repository_name" \
      --policy-text "file://$repository_policy" \
      >> "$out_dir/ecr-set-repository-policies.jsonl" \
      2>> "$out_dir/ecr-set-repository-policies.stderr"
  fi

  safe_name="$(printf '%s' "$ecr_image" | tr -c 'A-Za-z0-9_.-' '_')"
  if docker run --rm \
    -v "$HOME/.docker/config.json:/root/.docker/config.json:ro" \
    "$crane_image" cp "$source_image" "$ecr_image" \
    > "$out_dir/crane-copy-$safe_name.log" \
    2> "$out_dir/crane-copy-$safe_name.stderr"; then
    copied_count=$((copied_count + 1))
    echo "$source_image	$repository_name	$tag	$ecr_image" >> "$successful_images"
  else
    failed_count=$((failed_count + 1))
    echo "$source_image	$repository_name	$tag	$ecr_image	copy" >> "$failed_images"
    [[ "$continue_on_error" == "true" ]] && continue
    die "crane copy failed for $source_image"
  fi
done < <(tail -n +2 "$image_manifest")

status="copied"
if [[ "$failed_count" -gt 0 ]]; then
  status="partial"
fi

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - Crane Container ECR Mirror

Status: $status

Profile/region:
- $profile / $region

Counts:
- created_repositories: $created_count
- reused_repositories: $reused_count
- copied_images: $copied_count
- failed_images: $failed_count

Manifest:
- $image_manifest

Evidence:
- $out_dir/plan.tsv
- $out_dir/successful-images.tsv
- $out_dir/failed-images.tsv

Cleanup:
- ECR repositories retained by design.
RESULT

cat "$out_dir/RESULT.md"

if [[ "$failed_count" -gt 0 ]]; then
  exit 1
fi
