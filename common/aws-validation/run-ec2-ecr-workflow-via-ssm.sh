#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/run-ec2-ecr-workflow-via-ssm.sh --instance-id i-... --workflow-s3-uri URI --data-s3-uri URI --ecr-config FILE [options]

Purpose:
  Run a private EC2 Nextflow workflow from S3 source using ECR container
  overrides and local/offline input data.

Options:
  --profile NAME             Default: ${AWS_PROFILE:-default}
  --region REGION            Default: ${AWS_REGION:-ap-southeast-1}
  --instance-id ID           Required.
  --workflow-s3-uri URI      Required unless NEXTFLOW_OFFLINE_WORKFLOW_S3_URI is set.
  --data-s3-uri URI          Required unless NEXTFLOW_OFFLINE_RNASEQ_TINY_DATA_S3_URI is set.
  --ecr-config FILE          Required. Nextflow config with ECR container overrides.
  --remote-root DIR          Default: /opt/nextflow-offline
  --workspace DIR            Default: <remote-root>/ecr-workflow-e2e
  --workflow-name NAME       Default: rnaseq
  --profile-name NAME        Default: docker
  --max-cpus N               Default: 1
  --max-memory SIZE          Default: 2 GB
  --param KEY=VALUE          Extra Nextflow parameter; repeatable.
  --out-dir DIR              Local evidence dir.
  --help

This runner currently creates an rnaseq samplesheet when --workflow-name rnaseq.
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

validate_placeholder_value() {
  local name="$1" value="$2"
  [[ "$value" != *$'\n'* ]] || die "$name must not contain newlines"
  [[ "$value" != *"#"* ]] || die "$name must not contain #"
}

load_env_file

profile="${AWS_PROFILE:-default}"
region="${AWS_REGION:-ap-southeast-1}"
instance_id=""
workflow_s3_uri="${NEXTFLOW_OFFLINE_WORKFLOW_S3_URI:-}"
data_s3_uri="${NEXTFLOW_OFFLINE_RNASEQ_TINY_DATA_S3_URI:-}"
ecr_config=""
remote_root="/opt/nextflow-offline"
workspace=""
workflow_name="rnaseq"
profile_name="docker"
max_cpus="1"
max_memory="2 GB"
out_dir="$HOME/.AGENTS-temp/offline/ecr-workflow-e2e-$(date +%Y%m%d-%H%M%S)"
declare -a nextflow_params=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --instance-id) instance_id="${2:?missing --instance-id value}"; shift 2 ;;
    --workflow-s3-uri) workflow_s3_uri="${2:?missing --workflow-s3-uri value}"; shift 2 ;;
    --data-s3-uri) data_s3_uri="${2:?missing --data-s3-uri value}"; shift 2 ;;
    --ecr-config) ecr_config="${2:?missing --ecr-config value}"; shift 2 ;;
    --remote-root) remote_root="${2:?missing --remote-root value}"; shift 2 ;;
    --workspace) workspace="${2:?missing --workspace value}"; shift 2 ;;
    --workflow-name) workflow_name="${2:?missing --workflow-name value}"; shift 2 ;;
    --profile-name) profile_name="${2:?missing --profile-name value}"; shift 2 ;;
    --max-cpus) max_cpus="${2:?missing --max-cpus value}"; shift 2 ;;
    --max-memory) max_memory="${2:?missing --max-memory value}"; shift 2 ;;
    --param) nextflow_params+=("${2:?missing --param value}"); shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$instance_id" =~ ^i-[a-z0-9]+$ ]] || die "--instance-id is required"
[[ -n "$workflow_s3_uri" && "$workflow_s3_uri" == s3://* ]] || die "--workflow-s3-uri must be an s3:// URI"
[[ -n "$data_s3_uri" && "$data_s3_uri" == s3://* ]] || die "--data-s3-uri must be an s3:// URI"
[[ -n "$ecr_config" && -f "$ecr_config" ]] || die "--ecr-config must be an existing file"
[[ "$workflow_name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--workflow-name has invalid characters"
[[ "$max_cpus" =~ ^[0-9]+$ ]] || die "--max-cpus must be an integer"
[[ "$max_memory" =~ ^[0-9]+[[:space:]]*(MB|GB|MiB|GiB|M|G)$ ]] || die "--max-memory must look like '2 GB'"

need aws
need jq

if [[ -z "$workspace" ]]; then
  workspace="$remote_root/ecr-workflow-e2e"
fi

mkdir -p "$out_dir"
params_tsv="$out_dir/nextflow-params.tsv"
: > "$params_tsv"
for param in "${nextflow_params[@]}"; do
  [[ "$param" == *=* ]] || die "--param must use KEY=VALUE: $param"
  printf '%s\t%s\n' "${param%%=*}" "${param#*=}" >> "$params_tsv"
done
params_b64=""
if [[ -s "$params_tsv" ]]; then
  params_b64="$(base64 -w0 "$params_tsv")"
fi
ecr_config_b64="$(base64 -w0 "$ecr_config")"

validate_placeholder_value region "$region"
validate_placeholder_value workflow_s3_uri "$workflow_s3_uri"
validate_placeholder_value data_s3_uri "$data_s3_uri"
validate_placeholder_value remote_root "$remote_root"
validate_placeholder_value workspace "$workspace"
validate_placeholder_value workflow_name "$workflow_name"
validate_placeholder_value profile_name "$profile_name"
validate_placeholder_value max_cpus "$max_cpus"
validate_placeholder_value max_memory "$max_memory"
validate_placeholder_value params_b64 "$params_b64"
validate_placeholder_value ecr_config_b64 "$ecr_config_b64"

commands_file="$out_dir/remote-commands.sh"
cat > "$commands_file" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

region="__REGION__"
workflow_s3_uri="__WORKFLOW_S3_URI__"
data_s3_uri="__DATA_S3_URI__"
remote_root="__REMOTE_ROOT__"
workspace="__WORKSPACE__"
workflow_name="__WORKFLOW_NAME__"
profile_name="__PROFILE_NAME__"
max_cpus="__MAX_CPUS__"
max_memory="__MAX_MEMORY__"
nextflow_params_b64="__NEXTFLOW_PARAMS_B64__"
ecr_config_b64="__ECR_CONFIG_B64__"

run_id="$workflow_name-ecr-e2e-$(date +%Y%m%d-%H%M%S)"
run_dir="$workspace/results/$run_id"
workflow_dir="$workspace/workflows/$workflow_name"
data_dir="$workspace/data/$workflow_name"
nextflow_bin="$remote_root/bin/nextflow"

mkdir -p "$run_dir" "$workflow_dir" "$data_dir" "$workspace/work"
exec > >(tee "$run_dir/stdout.txt") 2> >(tee "$run_dir/stderr.txt" >&2)

status="started"
blocker=""
run_status="not_run"

write_result() {
  cat > "$run_dir/RESULT.md" <<RESULT
# RESULT - EC2 ECR Workflow E2E

Date: $(date)

Status: $status

Input:
- workflow_name: $workflow_name
- workflow_s3_uri: $workflow_s3_uri
- data_s3_uri: $data_s3_uri
- workflow_dir: $workflow_dir
- data_dir: $data_dir
- profile: $profile_name
- max_cpus: $max_cpus
- max_memory: $max_memory

Checks:
- run_status: $run_status

Evidence:
- stdout: $run_dir/stdout.txt
- stderr: $run_dir/stderr.txt
- nextflow_log: $run_dir/nextflow.log
- ecr_config: $run_dir/ecr-containers.config
- smoke_config: $run_dir/smoke.config
- params_tsv: $run_dir/nextflow-params.tsv
- outdir: $run_dir/out

Blocker:
$blocker
RESULT
}
trap write_result EXIT

echo "== versions =="
date
hostname
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

echo "== sync workflow and data =="
aws s3 sync "$workflow_s3_uri" "$workflow_dir" --no-progress
aws s3 sync "$data_s3_uri" "$data_dir" --no-progress
test -f "$workflow_dir/main.nf"
test -f "$workflow_dir/nextflow.config"
if [[ -d "$workflow_dir/bin" ]]; then
  find "$workflow_dir/bin" -type f -exec chmod 0755 {} +
fi

printf '%s' "$ecr_config_b64" | base64 -d > "$run_dir/ecr-containers.config"
if [[ -n "$nextflow_params_b64" ]]; then
  printf '%s' "$nextflow_params_b64" | base64 -d > "$run_dir/nextflow-params.tsv"
else
  : > "$run_dir/nextflow-params.tsv"
fi

if [[ "$workflow_name" == "rnaseq" ]]; then
  test -f "$data_dir/tiny_R1.fastq.gz"
  test -f "$data_dir/tiny_R2.fastq.gz"
  test -f "$data_dir/genome.fasta"
  test -f "$data_dir/genes_with_empty_tid.gtf.gz"
  cat > "$run_dir/samplesheet.csv" <<CSV
sample,fastq_1,fastq_2,strandedness
tiny,$data_dir/tiny_R1.fastq.gz,$data_dir/tiny_R2.fastq.gz,unstranded
CSV
  {
    printf 'input\t%s\n' "$run_dir/samplesheet.csv"
    printf 'fasta\t%s\n' "$data_dir/genome.fasta"
    printf 'gtf\t%s\n' "$data_dir/genes_with_empty_tid.gtf.gz"
  } >> "$run_dir/nextflow-params.tsv"
fi

nextflow_extra_args=()
while IFS=$'\t' read -r key value; do
  [[ -n "${key:-}" ]] || continue
  nextflow_extra_args+=("--$key" "$value")
done < "$run_dir/nextflow-params.tsv"

cat > "$run_dir/smoke.config" <<CONF
params {
  genome = null
  igenomes_ignore = true
  pipelines_testdata_base_path = ''
  custom_config_base = ''
  validate_params = false
  skip_bbsplit = true
  skip_alignment = true
  skip_pseudo_alignment = true
  skip_trimming = true
  skip_linting = true
  skip_qc = false
  skip_fastqc = false
  skip_multiqc = false
  skip_preseq = true
  skip_dupradar = true
  skip_qualimap = true
  skip_rseqc = true
  skip_biotype_qc = true
  skip_deseq2_qc = true
  max_cpus = $max_cpus
  max_memory = '$max_memory'
  max_time = '1.h'
}

process {
  cpus = $max_cpus
  memory = '$max_memory'
  time = '1.h'
  shell = ['/bin/bash','-ueo','pipefail']

  withLabel: 'process_single' {
    cpus = $max_cpus
    memory = '$max_memory'
  }
  withLabel: 'process_low' {
    cpus = $max_cpus
    memory = '$max_memory'
  }
  withLabel: 'process_medium' {
    cpus = $max_cpus
    memory = '$max_memory'
  }
  withLabel: 'process_high' {
    cpus = $max_cpus
    memory = '$max_memory'
  }
}
CONF

echo "== ecr login =="
awk -F"'" '/container = / {print $2}' "$run_dir/ecr-containers.config" |
  awk -F/ '{print $1}' |
  sort -u > "$run_dir/ecr-registries.txt"
while IFS= read -r registry; do
  [[ -n "$registry" ]] || continue
  aws ecr get-login-password --region "$region" |
    docker login --username AWS --password-stdin "$registry"
done < "$run_dir/ecr-registries.txt"

echo "== nextflow offline run =="
export NXF_HOME="$remote_root/.nextflow"
export NXF_OFFLINE=true
export NXF_PLUGIN_AUTOINSTALL=false
set +e
"$nextflow_bin" -log "$run_dir/nextflow.log" run "$workflow_dir" \
  -profile "$profile_name" \
  -offline \
  -c "$run_dir/ecr-containers.config" \
  -c "$run_dir/smoke.config" \
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
  exit "$run_rc"
fi

echo "== disk after =="
df -hT / "$workspace" /var/lib/docker 2>/dev/null || df -hT
find "$run_dir" -maxdepth 3 -type f | sort | sed -n '1,220p'
REMOTE

sed -i \
  -e "s#__REGION__#${region}#g" \
  -e "s#__WORKFLOW_S3_URI__#${workflow_s3_uri}#g" \
  -e "s#__DATA_S3_URI__#${data_s3_uri}#g" \
  -e "s#__REMOTE_ROOT__#${remote_root}#g" \
  -e "s#__WORKSPACE__#${workspace}#g" \
  -e "s#__WORKFLOW_NAME__#${workflow_name}#g" \
  -e "s#__PROFILE_NAME__#${profile_name}#g" \
  -e "s#__MAX_CPUS__#${max_cpus}#g" \
  -e "s#__MAX_MEMORY__#${max_memory}#g" \
  -e "s#__NEXTFLOW_PARAMS_B64__#${params_b64}#g" \
  -e "s#__ECR_CONFIG_B64__#${ecr_config_b64}#g" \
  "$commands_file"
chmod +x "$commands_file"

params_file="$out_dir/parameters.json"
jq -n --rawfile commands "$commands_file" '{commands:[$commands]}' > "$params_file"

AWS_PROFILE="$profile" aws ssm send-command \
  --region "$region" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "nextflow offline ECR workflow e2e" \
  --parameters "file://$params_file" \
  --output json > "$out_dir/send-command.json"

command_id="$(jq -r '.Command.CommandId' "$out_dir/send-command.json")"
printf '%s\n' "$command_id" > "$out_dir/command-id.txt"
echo "SSM_COMMAND_ID=$command_id"

for _ in $(seq 1 240); do
  AWS_PROFILE="$profile" aws ssm get-command-invocation \
    --region "$region" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --output json > "$out_dir/invocation.json" 2>"$out_dir/invocation.err" || true
  if ! jq empty "$out_dir/invocation.json" >/dev/null 2>&1; then
    printf '{"Status":"Pending","ResponseCode":null}\n' > "$out_dir/invocation.json"
  fi
  status="$(jq -r '.Status // "Pending"' "$out_dir/invocation.json" 2>/dev/null || echo Pending)"
  case "$status" in
    Success|Failed|Cancelled|TimedOut|Cancelling)
      break
      ;;
  esac
  sleep 15
done

status="$(jq -r '.Status // "Unknown"' "$out_dir/invocation.json")"
response_code="$(jq -r '.ResponseCode // "Unknown"' "$out_dir/invocation.json")"
jq -r '.StandardOutputContent // ""' "$out_dir/invocation.json" > "$out_dir/stdout.txt"
jq -r '.StandardErrorContent // ""' "$out_dir/invocation.json" > "$out_dir/stderr.txt"

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - EC2 ECR Workflow E2E

Status: $status
ResponseCode: $response_code

Input:
- instance_id: $instance_id
- profile: $profile
- region: $region
- workflow_name: $workflow_name
- workflow_s3_uri: $workflow_s3_uri
- data_s3_uri: $data_s3_uri

Evidence:
- $out_dir/send-command.json
- $out_dir/invocation.json
- $out_dir/stdout.txt
- $out_dir/stderr.txt
- $out_dir/parameters.json
RESULT

cat "$out_dir/RESULT.md"

if [[ "$status" != "Success" ]]; then
  exit 1
fi
