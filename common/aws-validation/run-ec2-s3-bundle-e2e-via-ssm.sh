#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/run-ec2-s3-bundle-e2e-via-ssm.sh --instance-id i-... [options]

Purpose:
  Run an offline Nextflow E2E on an EC2 host from a prebuilt S3 bundle.

Options:
  --profile NAME             Default: ${AWS_PROFILE:-default}
  --region REGION            Default: ${AWS_REGION:-ap-southeast-1}
  --instance-id ID           Required
  --bundle-s3-uri URI        Required unless NEXTFLOW_OFFLINE_BUNDLE_S3_URI is set
  --remote-root DIR          Default: /opt/nextflow-offline
  --workspace DIR            Default: <remote-root>/s3-bundle-e2e
  --pipeline-dir NAME        Default: testpipeline
  --revision-dir NAME        Default: 3_2_1
  --profile-name NAME        Default: docker,test
  --max-cpus N               Optional Nextflow process CPU cap
  --max-memory SIZE          Optional Nextflow process memory cap, for example "2 GB"
  --param KEY=VALUE          Extra Nextflow parameter; repeatable
  --out-dir DIR              Local evidence dir
  --help

The script expects the target host already has:
- aws CLI
- Docker
- Java
- Nextflow at <remote-root>/bin/nextflow or in PATH

The S3 bundle must contain:
- <revision-dir>/
- docker-images/docker-load.sh
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

load_env_file

profile="${AWS_PROFILE:-default}"
region="${AWS_REGION:-ap-southeast-1}"
instance_id=""
bundle_s3_uri="${NEXTFLOW_OFFLINE_BUNDLE_S3_URI:-}"
remote_root="/opt/nextflow-offline"
workspace=""
pipeline_dir="testpipeline"
revision_dir="3_2_1"
profile_name="docker,test"
max_cpus=""
max_memory=""
out_dir="$HOME/.AGENTS-temp/offline/s3-bundle-e2e-$(date +%Y%m%d-%H%M%S)"
declare -a nextflow_params=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --instance-id) instance_id="${2:?missing --instance-id value}"; shift 2 ;;
    --bundle-s3-uri) bundle_s3_uri="${2:?missing --bundle-s3-uri value}"; shift 2 ;;
    --remote-root) remote_root="${2:?missing --remote-root value}"; shift 2 ;;
    --workspace) workspace="${2:?missing --workspace value}"; shift 2 ;;
    --pipeline-dir) pipeline_dir="${2:?missing --pipeline-dir value}"; shift 2 ;;
    --revision-dir) revision_dir="${2:?missing --revision-dir value}"; shift 2 ;;
    --profile-name) profile_name="${2:?missing --profile-name value}"; shift 2 ;;
    --max-cpus) max_cpus="${2:?missing --max-cpus value}"; shift 2 ;;
    --max-memory) max_memory="${2:?missing --max-memory value}"; shift 2 ;;
    --param) nextflow_params+=("${2:?missing --param value}"); shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$instance_id" =~ ^i-[a-z0-9]+$ ]]; then
  echo "ERROR: --instance-id is required" >&2
  exit 1
fi

if [[ -z "$bundle_s3_uri" ]]; then
  echo "ERROR: --bundle-s3-uri or NEXTFLOW_OFFLINE_BUNDLE_S3_URI is required" >&2
  exit 2
fi

if [[ -z "$workspace" ]]; then
  workspace="$remote_root/s3-bundle-e2e"
fi

mkdir -p "$out_dir"
commands_file="$out_dir/remote-commands.sh"
params_tsv="$out_dir/nextflow-params.tsv"
: > "$params_tsv"
for param in "${nextflow_params[@]}"; do
  if [[ "$param" != *=* ]]; then
    echo "ERROR: --param must use KEY=VALUE: $param" >&2
    exit 2
  fi
  printf '%s\t%s\n' "${param%%=*}" "${param#*=}" >> "$params_tsv"
done
params_b64=""
if [[ -s "$params_tsv" ]]; then
  params_b64="$(base64 -w0 "$params_tsv")"
fi

cat > "$commands_file" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

bundle_s3_uri="__BUNDLE_S3_URI__"
remote_root="__REMOTE_ROOT__"
workspace="__WORKSPACE__"
pipeline_dir="__PIPELINE_DIR__"
revision_dir="__REVISION_DIR__"
profile_name="__PROFILE_NAME__"
max_cpus="__MAX_CPUS__"
max_memory="__MAX_MEMORY__"
nextflow_params_b64="__NEXTFLOW_PARAMS_B64__"

run_id="s3-bundle-e2e-$(date +%Y%m%d-%H%M%S)"
run_dir="$workspace/results/$run_id"
bundle_dir="$workspace/downloads/$pipeline_dir"
workflow_dir="$bundle_dir/$revision_dir"
docker_dir="$bundle_dir/docker-images"
nextflow_bin="$remote_root/bin/nextflow"

mkdir -p "$run_dir" "$workspace/assets" "$workspace/work" "$workspace/out" "$bundle_dir"
exec > >(tee "$run_dir/stdout.txt") 2> >(tee "$run_dir/stderr.txt" >&2)

status="started"
blocker=""
run_status="not_run"

write_result() {
  cat > "$run_dir/RESULT.md" <<RESULT
# RESULT - EC2 S3 Bundle Nextflow E2E

Date: $(date)

Status: $status

Input:
- bundle_s3_uri: $bundle_s3_uri
- workspace: $workspace
- workflow_dir: $workflow_dir
- profile: $profile_name
- max_cpus: ${max_cpus:-none}
- max_memory: ${max_memory:-none}
- params_tsv: $run_dir/nextflow-params.tsv

Checks:
- run_status: $run_status

Evidence:
- stdout: $run_dir/stdout.txt
- stderr: $run_dir/stderr.txt
- nextflow_log: $run_dir/nextflow.log
- config: $run_dir/resource-caps.config
- outdir: $run_dir/out

Blocker:
$blocker
RESULT
}
trap write_result EXIT

echo "== versions =="
date
hostname
cat /etc/os-release || true
aws --version
docker --version
if [[ ! -x "$nextflow_bin" ]]; then
  nextflow_bin="$(command -v nextflow || true)"
fi
if [[ -z "$nextflow_bin" || ! -x "$nextflow_bin" ]]; then
  status="blocked"
  blocker="nextflow binary not found at remote root or PATH"
  exit 0
fi
"$nextflow_bin" -version

echo "== disk before =="
df -hT / "$workspace" /var/lib/docker 2>/dev/null || df -hT

echo "== sync bundle =="
aws s3 sync "$bundle_s3_uri" "$bundle_dir" --no-progress
test -d "$workflow_dir"
test -f "$docker_dir/docker-load.sh"

echo "== docker load =="
docker_load_rc=0
(
  cd "$docker_dir"
  bash docker-load.sh
) || docker_load_rc=$?
if [[ "$docker_load_rc" -ne 0 ]]; then
  status="blocked"
  run_status="docker_load_failed"
  blocker="docker-load.sh failed with rc $docker_load_rc; see $docker_dir/podman-load.log and $run_dir/stderr.txt"
  exit 0
fi
if [[ -f "$docker_dir/podman-load.log" ]] && grep -q '^ERROR:' "$docker_dir/podman-load.log"; then
  status="blocked"
  run_status="docker_load_failed"
  blocker="one or more Docker image TAR files failed to load; see $docker_dir/podman-load.log"
  exit 0
fi
docker images > "$run_dir/docker-images-after-load.txt"

echo "== local input =="
params_tsv="$run_dir/nextflow-params.tsv"
if [[ -n "$nextflow_params_b64" ]]; then
  printf '%s' "$nextflow_params_b64" | base64 -d > "$params_tsv"
else
  : > "$params_tsv"
fi
if ! awk -F '\t' '$1 == "input" { found=1 } END { exit(found ? 0 : 1) }' "$params_tsv"; then
  fastq_dir="$workspace/assets/fastq"
  mkdir -p "$fastq_dir"
  for fastq in sample_R1.fastq.gz sample_R2.fastq.gz sample_single.fastq.gz; do
    if [[ ! -f "$fastq_dir/$fastq" ]]; then
      printf '@SEQ_ID\nACGT\n+\n!!!!\n' | gzip -c > "$fastq_dir/$fastq"
    fi
  done
  cat > "$run_dir/input.csv" <<CSV
sample,fastq_1,fastq_2
SAMPLE_PAIRED_END,$fastq_dir/sample_R1.fastq.gz,$fastq_dir/sample_R2.fastq.gz
SAMPLE_SINGLE_END,$fastq_dir/sample_single.fastq.gz,
CSV
  printf 'input\t%s\n' "$run_dir/input.csv" >> "$params_tsv"
fi

nextflow_extra_args=()
while IFS=$'\t' read -r key value; do
  [[ -n "${key:-}" ]] || continue
  nextflow_extra_args+=("--$key" "$value")
done < "$params_tsv"

if [[ -n "$max_cpus" || -n "$max_memory" ]]; then
  write_cap_block() {
    if [[ -n "$max_cpus" ]]; then
      echo "  cpus = $max_cpus"
    fi
    if [[ -n "$max_memory" ]]; then
      echo "  memory = '$max_memory'"
    fi
  }
  {
    echo "process {"
    write_cap_block
    for selector in \
      "withLabel: 'process_single'" \
      "withLabel: 'process_low'" \
      "withLabel: 'process_medium'" \
      "withLabel: 'process_high'" \
      "withName: 'FASTQC'" \
      "withName: 'FASTAVALIDATOR'" \
      "withName: 'MULTIQC'" \
      "withName: 'SEQTK_TRIM'"; do
      echo "  $selector {"
      write_cap_block
      echo "  }"
    done
    echo "}"
  } > "$run_dir/resource-caps.config"
else
  : > "$run_dir/resource-caps.config"
fi

config_args=()
if [[ -s "$run_dir/resource-caps.config" ]]; then
  config_args=(-c "$run_dir/resource-caps.config")
fi

echo "== nextflow offline run =="
export NXF_HOME="$remote_root/.nextflow"
export NXF_OFFLINE=true
export NXF_PLUGIN_AUTOINSTALL=false
set +e
"$nextflow_bin" -log "$run_dir/nextflow.log" run "$workflow_dir" \
  -profile "$profile_name" \
  -offline \
  "${config_args[@]}" \
  --outdir "$run_dir/out" \
  "${nextflow_extra_args[@]}" \
  -w "$run_dir/work"
run_rc=$?
set -e

if [[ "$run_rc" -eq 0 ]]; then
  run_status="passed"
  status="passed"
else
  run_status="failed_rc_${run_rc}"
  blocker="nextflow offline run failed; see $run_dir/nextflow.log"
  status="blocked"
fi

echo "== disk after =="
df -hT / "$workspace" /var/lib/docker 2>/dev/null || df -hT
find "$run_dir" -maxdepth 3 -type f | sort | sed -n '1,220p'
REMOTE

sed -i \
  -e "s#__BUNDLE_S3_URI__#${bundle_s3_uri}#g" \
  -e "s#__REMOTE_ROOT__#${remote_root}#g" \
  -e "s#__WORKSPACE__#${workspace}#g" \
  -e "s#__PIPELINE_DIR__#${pipeline_dir}#g" \
  -e "s#__REVISION_DIR__#${revision_dir}#g" \
  -e "s#__PROFILE_NAME__#${profile_name}#g" \
  -e "s#__MAX_CPUS__#${max_cpus}#g" \
  -e "s#__MAX_MEMORY__#${max_memory}#g" \
  -e "s#__NEXTFLOW_PARAMS_B64__#${params_b64}#g" \
  "$commands_file"
chmod +x "$commands_file"

params_file="$out_dir/parameters.json"
jq -n --rawfile commands "$commands_file" '{commands:[$commands]}' > "$params_file"

AWS_PROFILE="$profile" aws ssm send-command \
  --region "$region" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "nextflow offline s3 bundle e2e" \
  --parameters "file://$params_file" \
  --output json | tee "$out_dir/send-command.json"

command_id="$(jq -r '.Command.CommandId' "$out_dir/send-command.json")"
printf '%s\n' "$command_id" > "$out_dir/command-id.txt"

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
jq -r '.StandardOutputContent // ""' "$out_dir/invocation.json" > "$out_dir/stdout.txt"
jq -r '.StandardErrorContent // ""' "$out_dir/invocation.json" > "$out_dir/stderr.txt"

cat > "$out_dir/RESULT.md" <<EOF
# EC2 S3 Bundle E2E Result

Instance: \`$instance_id\`
Profile: \`$profile\`
Region: \`$region\`
CommandId: \`$command_id\`
Status: \`$status\`
Bundle: \`$bundle_s3_uri\`

Evidence:
- \`$out_dir/send-command.json\`
- \`$out_dir/invocation.json\`
- \`$out_dir/stdout.txt\`
- \`$out_dir/stderr.txt\`
- \`$out_dir/parameters.json\`
EOF

cat "$out_dir/RESULT.md"

if [[ "$status" != "Success" ]]; then
  exit 1
fi
