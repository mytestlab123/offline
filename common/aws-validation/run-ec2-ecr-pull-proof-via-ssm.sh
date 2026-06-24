#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/run-ec2-ecr-pull-proof-via-ssm.sh --instance-id i-... --image ECR_URI [--image ECR_URI ...]

Purpose:
  Prove that a private EC2 host can log in to ECR and pull selected mirrored
  images. Use this after the manifest readback gate and before a full Nextflow
  ECR pipeline run.

Options:
  --profile NAME           Default: ${AWS_PROFILE:-dev}
  --region REGION          Default: ${AWS_REGION:-ap-southeast-1}
  --instance-id ID         Required.
  --image ECR_URI          ECR image URI to pull. Repeatable.
  --out-dir DIR            Default: ~/.AGENTS-temp/offline/ec2-ecr-pull-proof-<timestamp>
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
instance_id=""
out_dir="$HOME/.AGENTS-temp/offline/ec2-ecr-pull-proof-$(date +%Y%m%d-%H%M%S)"
declare -a images=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --instance-id) instance_id="${2:?missing --instance-id value}"; shift 2 ;;
    --image) images+=("${2:?missing --image value}"); shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$instance_id" =~ ^i-[a-z0-9]+$ ]] || die "--instance-id is required"
[[ "${#images[@]}" -gt 0 ]] || die "at least one --image is required"

need aws
need jq

mkdir -p "$out_dir"
images_tsv="$out_dir/images.tsv"
: > "$images_tsv"
for image in "${images[@]}"; do
  [[ "$image" =~ ^[0-9]{12}\.dkr\.ecr\.[A-Za-z0-9-]+\.amazonaws\.com/.+:.+$ ]] ||
    die "--image must be an ECR image URI: $image"
  printf '%s\n' "$image" >> "$images_tsv"
done
images_b64="$(base64 -w0 "$images_tsv")"

commands_file="$out_dir/remote-commands.sh"
cat > "$commands_file" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

region="__REGION__"
images_b64="__IMAGES_B64__"

run_dir="/tmp/ecr-pull-proof-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/stdout.txt") 2> >(tee "$run_dir/stderr.txt" >&2)

echo "== identity =="
date
hostname
aws sts get-caller-identity --output json

echo "== docker =="
docker --version

printf '%s' "$images_b64" | base64 -d > "$run_dir/images.tsv"
awk -F/ '{print $1}' "$run_dir/images.tsv" | sort -u > "$run_dir/registries.txt"

echo "== ecr login =="
while IFS= read -r registry; do
  [[ -n "$registry" ]] || continue
  aws ecr get-login-password --region "$region" |
    docker login --username AWS --password-stdin "$registry"
done < "$run_dir/registries.txt"

echo "image	status	details" > "$run_dir/pulls.tsv"
while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  echo "== pull $image =="
  if docker pull "$image"; then
    details="$(docker image inspect "$image" --format '{{.Id}} {{.Os}}/{{.Architecture}} {{.Size}}')"
    echo "$image	ok	$details" >> "$run_dir/pulls.tsv"
  else
    echo "$image	failed	pull_failed" >> "$run_dir/pulls.tsv"
  fi
done < "$run_dir/images.tsv"

failed_count="$(awk -F '\t' '$2 == "failed" {count++} END {print count+0}' "$run_dir/pulls.tsv")"
if [[ "$failed_count" -gt 0 ]]; then
  echo "RESULT: failed"
  cat "$run_dir/pulls.tsv"
  exit 1
fi

echo "RESULT: passed"
cat "$run_dir/pulls.tsv"
REMOTE

sed -i \
  -e "s#__REGION__#${region}#g" \
  -e "s#__IMAGES_B64__#${images_b64}#g" \
  "$commands_file"
chmod +x "$commands_file"

params_file="$out_dir/parameters.json"
jq -n --rawfile commands "$commands_file" '{commands:[$commands]}' > "$params_file"

AWS_PROFILE="$profile" aws ssm send-command \
  --region "$region" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "nextflow offline ECR pull proof" \
  --parameters "file://$params_file" \
  --output json > "$out_dir/send-command.json"

command_id="$(jq -r '.Command.CommandId' "$out_dir/send-command.json")"
printf '%s\n' "$command_id" > "$out_dir/command-id.txt"
echo "SSM_COMMAND_ID=$command_id"

for _ in $(seq 1 180); do
  AWS_PROFILE="$profile" aws ssm get-command-invocation \
    --region "$region" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --output json > "$out_dir/invocation.json" 2>"$out_dir/invocation.err" || true
  status="$(jq -r '.Status // "Pending"' "$out_dir/invocation.json" 2>/dev/null || echo Pending)"
  case "$status" in
    Success|Failed|Cancelled|TimedOut|Cancelling)
      break
      ;;
  esac
  sleep 10
done

status="$(jq -r '.Status // "Unknown"' "$out_dir/invocation.json")"
response_code="$(jq -r '.ResponseCode // "Unknown"' "$out_dir/invocation.json")"
jq -r '.StandardOutputContent // ""' "$out_dir/invocation.json" > "$out_dir/stdout.txt"
jq -r '.StandardErrorContent // ""' "$out_dir/invocation.json" > "$out_dir/stderr.txt"

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - EC2 ECR Pull Proof

Status: $status
ResponseCode: $response_code

Input:
- instance_id: $instance_id
- profile: $profile
- region: $region
- image_count: ${#images[@]}

Evidence:
- $out_dir/send-command.json
- $out_dir/invocation.json
- $out_dir/stdout.txt
- $out_dir/stderr.txt
- $out_dir/images.tsv
RESULT

cat "$out_dir/RESULT.md"

if [[ "$status" != "Success" ]]; then
  exit 1
fi
