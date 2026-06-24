#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/run-dev-ecr-bamtofastq-e2e-via-ssm.sh --instance-id i-... --bundle-s3-uri s3://... [options]

Purpose:
  Prove nf-core/bamtofastq can run on a DEV EC2 host using temporary DEV ECR
  image mirrors populated from approved S3 Docker TARs.

Options:
  --profile NAME       Default: ${AWS_PROFILE:-dev}
  --region REGION      Default: ${AWS_REGION:-ap-southeast-1}
  --instance-id ID     Required
  --bundle-s3-uri URI  Required. S3 prefix containing 2_1_1/ and docker-images/
  --repo-prefix NAME   Default: nextflow-offline/e2e-bamtofastq-YYYYMMDD
  --remote-root DIR    Default: /opt/nextflow-offline/ecr-bamtofastq-e2e
  --out-dir DIR        Local evidence dir
  --keep-repos         Keep temporary ECR repositories after proof
  --help

No public registries, AWS Batch, Terraform, network changes, or broad Docker
cleanup are performed.
EOF
}

profile="${AWS_PROFILE:-dev}"
region="${AWS_REGION:-ap-southeast-1}"
instance_id=""
bundle_s3_uri=""
today="$(date +%Y%m%d)"
repo_prefix="nextflow-offline/e2e-bamtofastq-$today"
remote_root="/opt/nextflow-offline/ecr-bamtofastq-e2e"
out_dir="$HOME/.AGENTS-temp/offline/dev-ecr-bamtofastq-e2e-$(date +%Y%m%d-%H%M%S)"
keep_repos="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --instance-id) instance_id="${2:?missing --instance-id value}"; shift 2 ;;
    --bundle-s3-uri) bundle_s3_uri="${2:?missing --bundle-s3-uri value}"; shift 2 ;;
    --repo-prefix) repo_prefix="${2:?missing --repo-prefix value}"; shift 2 ;;
    --remote-root) remote_root="${2:?missing --remote-root value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --keep-repos) keep_repos="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$instance_id" =~ ^i-[a-z0-9]+$ ]]; then
  echo "ERROR: --instance-id is required" >&2
  exit 1
fi

if [[ -z "$bundle_s3_uri" ]]; then
  echo "ERROR: --bundle-s3-uri is required" >&2
  exit 2
fi

bundle_s3_uri="${bundle_s3_uri%/}/"
mkdir -p "$out_dir"

account_id="$(aws --profile "$profile" --region "$region" sts get-caller-identity --query Account --output text)"
created_date="$(date +%F)"

aws --profile "$profile" --region "$region" ec2 describe-instances \
  --instance-ids "$instance_id" \
  --output json > "$out_dir/instance.json"

public_ip="$(jq -r '.Reservations[].Instances[].PublicIpAddress // "null"' "$out_dir/instance.json")"
state="$(jq -r '.Reservations[].Instances[].State.Name' "$out_dir/instance.json")"
instance_profile_arn="$(jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn // empty' "$out_dir/instance.json")"

if [[ "$state" != "running" ]]; then
  echo "ERROR: instance is not running: $state" >&2
  exit 1
fi

if [[ "$public_ip" != "null" ]]; then
  echo "ERROR: instance has public IP: $public_ip" >&2
  exit 1
fi

if [[ -z "$instance_profile_arn" ]]; then
  echo "ERROR: instance has no IAM instance profile" >&2
  exit 1
fi

aws --profile "$profile" --region "$region" s3 ls "${bundle_s3_uri}2_1_1/main.nf" > "$out_dir/s3-workflow-ls.txt"
aws --profile "$profile" --region "$region" s3 ls "${bundle_s3_uri}docker-images/docker-load.sh" > "$out_dir/s3-docker-load-ls.txt"

instance_profile_name="${instance_profile_arn##*/}"
ec2_role_arn="$(aws --profile "$profile" --region "$region" iam get-instance-profile \
  --instance-profile-name "$instance_profile_name" \
  --query 'InstanceProfile.Roles[0].Arn' \
  --output text)"

declare -a image_keys=("fastqc" "multiqc" "samtools117" "ubuntu")
declare -A tar_names=(
  [fastqc]="biocontainers-fastqc-0.12.1--hdfd78af_0.tar"
  [multiqc]="biocontainers-multiqc-1.21--pyhdfd78af_0.tar"
  [samtools117]="biocontainers-samtools-1.17--h00cdaf9_0.tar"
  [ubuntu]="nf-core-ubuntu-20.04.tar"
)
declare -A loaded_images=(
  [fastqc]="quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0"
  [multiqc]="quay.io/biocontainers/multiqc:1.21--pyhdfd78af_0"
  [samtools117]="quay.io/biocontainers/samtools:1.17--h00cdaf9_0"
  [ubuntu]="quay.io/nf-core/ubuntu:20.04"
)
declare -A tags=(
  [fastqc]="0.12.1--hdfd78af_0"
  [multiqc]="1.21--pyhdfd78af_0"
  [samtools117]="1.17--h00cdaf9_0"
  [ubuntu]="20.04"
)

declare -A repo_names=()
declare -A ecr_images=()
created_repos=()
cleanup_status="not_started"

cleanup_repos() {
  if [[ "$keep_repos" == "true" ]]; then
    cleanup_status="kept_by_request"
    return 0
  fi
  cleanup_status="deleted"
  local repo
  for repo in "${created_repos[@]}"; do
    if ! aws --profile "$profile" --region "$region" ecr delete-repository \
      --repository-name "$repo" \
      --force >> "$out_dir/ecr-delete-repositories.jsonl" 2>> "$out_dir/ecr-delete-repositories.stderr"; then
      cleanup_status="delete_failed"
    fi
  done
}
trap cleanup_repos EXIT

repo_policy="$out_dir/ecr-repository-policy.json"
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
}' > "$repo_policy"

for key in "${image_keys[@]}"; do
  repo_names[$key]="$repo_prefix-$key"
  ecr_images[$key]="$account_id.dkr.ecr.$region.amazonaws.com/${repo_names[$key]}:${tags[$key]}"

  aws --profile "$profile" --region "$region" ecr create-repository \
    --repository-name "${repo_names[$key]}" \
    --image-scanning-configuration scanOnPush=false \
    --encryption-configuration encryptionType=AES256 \
    --tags \
      Key=Name,Value=nextflow-offline-ecr-bamtofastq-"$key"-"$today" \
      Key=dev,Value=amit \
      Key=project,Value=nextflow-offline \
      Key=created,Value="$created_date" \
      Key=tools,Value=cdx \
      Key=environment,Value=dev \
      Key=owner,Value=amit \
      Key=version,Value=e2e-"$today" \
      Key=TTL,Value=24-06-26 \
      Key=purpose,Value=temporary-dev-ecr-bamtofastq-e2e \
      Key=phase,Value=ecr-bamtofastq-e2e \
    >> "$out_dir/ecr-create-repositories.jsonl"
  created_repos+=("${repo_names[$key]}")

  aws --profile "$profile" --region "$region" ecr set-repository-policy \
    --repository-name "${repo_names[$key]}" \
    --policy-text "file://$repo_policy" \
    >> "$out_dir/ecr-set-repository-policies.jsonl"

  tar_path="$out_dir/${tar_names[$key]}"
  aws --profile "$profile" --region "$region" s3 cp \
    "${bundle_s3_uri}docker-images/${tar_names[$key]}" \
    "$tar_path" \
    --no-progress
  docker load -i "$tar_path" >> "$out_dir/local-docker-load.txt"
  docker tag "${loaded_images[$key]}" "${ecr_images[$key]}"
done

aws --profile "$profile" --region "$region" ecr get-login-password \
  | docker login --username AWS --password-stdin "$account_id.dkr.ecr.$region.amazonaws.com" \
  > "$out_dir/local-ecr-login.txt"

for key in "${image_keys[@]}"; do
  docker push --platform linux/amd64 "${ecr_images[$key]}" >> "$out_dir/local-docker-push.txt"
done

remote_commands="$out_dir/remote-commands.sh"
parameters_file="$out_dir/ssm-parameters.json"

cat > "$remote_commands" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

region="__REGION__"
bundle_s3_uri="__BUNDLE_S3_URI__"
remote_root="__REMOTE_ROOT__"
fastqc_image="__FASTQC_IMAGE__"
multiqc_image="__MULTIQC_IMAGE__"
samtools117_image="__SAMTOOLS117_IMAGE__"
samtools119_image="__SAMTOOLS119_IMAGE__"
ubuntu_image="__UBUNTU_IMAGE__"

run_id="ecr-bamtofastq-e2e-$(date +%Y%m%d-%H%M%S)"
run_dir="$remote_root/results/$run_id"
bundle_dir="$remote_root/downloads/bamtofastq"
workflow_dir="$bundle_dir/2_1_1"
data_dir="$run_dir/data"
mkdir -p "$run_dir" "$bundle_dir" "$data_dir"
exec > >(tee "$run_dir/stdout.txt") 2> >(tee "$run_dir/stderr.txt" >&2)

status="started"
blocker=""
nextflow_status="not_run"

write_result() {
  cat > "$run_dir/RESULT.md" <<RESULT
# RESULT - DEV ECR nf-core/bamtofastq E2E

Date: $(date)

Status: $status

Input:
- bundle_s3_uri: $bundle_s3_uri
- workflow_dir: $workflow_dir
- sample_sheet: $run_dir/input.csv
- fastqc_image: $fastqc_image
- multiqc_image: $multiqc_image
- samtools117_image: $samtools117_image
- samtools119_image: $samtools119_image
- ubuntu_image: $ubuntu_image

Checks:
- nextflow_status: $nextflow_status

Evidence:
- stdout: $run_dir/stdout.txt
- stderr: $run_dir/stderr.txt
- nextflow_log: $run_dir/nextflow.log
- ecr_config: $run_dir/ecr-containers.config
- input: $run_dir/input.csv
- data_dir: $data_dir

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
nextflow_bin="$(command -v nextflow || command -v nextflow-25.04 || true)"
if [[ -z "$nextflow_bin" ]]; then
  status="blocked"
  blocker="nextflow binary not found in PATH"
  exit 0
fi
"$nextflow_bin" -version

echo "== sync bundle =="
aws s3 sync "$bundle_s3_uri" "$bundle_dir" --no-progress
test -f "$workflow_dir/main.nf"

echo "== ecr login and pull images =="
registry="${fastqc_image%%/*}"
aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$registry"
docker pull "$fastqc_image"
docker pull "$multiqc_image"
docker pull "$samtools117_image"
docker pull "$samtools119_image"
docker pull "$ubuntu_image"

echo "== create tiny offline bam input =="
cat > "$data_dir/reference.fa" <<'FASTA'
>chr1
ACGTACGTACGTACGTACGTACGTACGTACGT
FASTA

cat > "$data_dir/input.sam" <<'SAM'
@HD	VN:1.6	SO:coordinate
@SQ	SN:chr1	LN:32
read1	0	chr1	1	60	8M	*	0	0	ACGTACGT	FFFFFFFF
read2	0	chr1	9	60	8M	*	0	0	ACGTACGT	FFFFFFFF
SAM

docker run --rm -v "$data_dir:/data" "$samtools119_image" samtools faidx /data/reference.fa
docker run --rm -v "$data_dir:/data" "$samtools119_image" samtools view -bS /data/input.sam -o /data/sample.bam
docker run --rm -v "$data_dir:/data" "$samtools119_image" samtools index /data/sample.bam

cat > "$run_dir/input.csv" <<CSV
sample_id,mapped,index,file_type
tiny,$data_dir/sample.bam,$data_dir/sample.bam.bai,bam
CSV

cat > "$run_dir/ecr-containers.config" <<CONF
process {
  cpus = 1
  memory = '2 GB'

  withLabel: 'process_single' {
    cpus = 1
    memory = '2 GB'
  }
  withLabel: 'process_low' {
    cpus = 1
    memory = '2 GB'
  }
  withLabel: 'process_medium' {
    cpus = 1
    memory = '2 GB'
  }
  withLabel: 'process_high' {
    cpus = 1
    memory = '2 GB'
  }
  withName: 'CHECK_IF_PAIRED_END' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools117_image'
  }
  withName: 'SAMTOOLS_CHR' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_PE' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_CHR_INDEX' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_COLLATEFASTQ_SINGLE_END' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_FLAGSTAT' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_IDXSTATS' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_STATS' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_INDEX' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_FAIDX' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_VIEW_MAP_MAP' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_VIEW_MAP_UNMAP' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_VIEW_UNMAP_MAP' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_VIEW_UNMAP_UNMAP' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'SAMTOOLS_MERGE_UNMAP' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'COLLATE_FASTQ_MAP' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'COLLATE_FASTQ_UNMAP' {
    cpus = 1
    memory = '2 GB'
    container = '$samtools119_image'
  }
  withName: 'FASTQC' {
    cpus = 1
    memory = '2 GB'
    container = '$fastqc_image'
  }
  withName: 'FASTQC_PRE_CONVERSION' {
    cpus = 1
    memory = '2 GB'
    container = '$fastqc_image'
  }
  withName: 'FASTQC_POST_CONVERSION' {
    cpus = 1
    memory = '2 GB'
    container = '$fastqc_image'
  }
  withName: 'CAT_FASTQ' {
    cpus = 1
    memory = '2 GB'
    container = '$ubuntu_image'
  }
  withName: 'MULTIQC' {
    cpus = 1
    memory = '2 GB'
    container = '$multiqc_image'
  }
}
CONF

echo "== nextflow run =="
export NXF_HOME="$remote_root/.nextflow"
export NXF_OFFLINE=true
export NXF_PLUGIN_AUTOINSTALL=false
set +e
"$nextflow_bin" -log "$run_dir/nextflow.log" run "$workflow_dir" \
  -profile docker \
  -offline \
  -c "$run_dir/ecr-containers.config" \
  --input "$run_dir/input.csv" \
  --fasta "$data_dir/reference.fa" \
  --outdir "$run_dir/out" \
  -w "$run_dir/work"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  status="passed"
  nextflow_status="passed"
else
  status="failed"
  nextflow_status="failed_rc_$rc"
  blocker="nextflow run failed; inspect nextflow_log and stderr"
fi
exit "$rc"
REMOTE

sed -i \
  -e "s#__REGION__#$region#g" \
  -e "s#__BUNDLE_S3_URI__#$bundle_s3_uri#g" \
  -e "s#__REMOTE_ROOT__#$remote_root#g" \
  -e "s#__FASTQC_IMAGE__#${ecr_images[fastqc]}#g" \
  -e "s#__MULTIQC_IMAGE__#${ecr_images[multiqc]}#g" \
  -e "s#__SAMTOOLS117_IMAGE__#${ecr_images[samtools117]}#g" \
  -e "s#__SAMTOOLS119_IMAGE__#${ecr_images[samtools117]}#g" \
  -e "s#__UBUNTU_IMAGE__#${ecr_images[ubuntu]}#g" \
  "$remote_commands"

jq -n --rawfile script "$remote_commands" '{commands: [$script]}' > "$parameters_file"

command_id="$(aws --profile "$profile" --region "$region" ssm send-command \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "nextflow offline DEV ECR bamtofastq e2e" \
  --parameters "file://$parameters_file" \
  --query Command.CommandId \
  --output text)"

echo "$command_id" > "$out_dir/command-id.txt"
for _ in $(seq 1 120); do
  aws --profile "$profile" --region "$region" ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --output json > "$out_dir/invocation.json"
  remote_status="$(jq -r '.Status' "$out_dir/invocation.json")"
  case "$remote_status" in
    Pending|InProgress|Delayed) sleep 15 ;;
    *) break ;;
  esac
done

jq -r '.StandardOutputContent' "$out_dir/invocation.json" > "$out_dir/stdout.txt"
jq -r '.StandardErrorContent' "$out_dir/invocation.json" > "$out_dir/stderr.txt"
remote_status="$(jq -r '.Status' "$out_dir/invocation.json")"

cleanup_repos
trap - EXIT

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - DEV ECR nf-core/bamtofastq E2E

Date: $(date)

Status: $remote_status

Account/profile/region:

- $account_id / $profile / $region

EC2:

- instance_id: $instance_id
- state: $state
- public_ip: $public_ip

ECR images:

- fastqc: ${ecr_images[fastqc]}
- multiqc: ${ecr_images[multiqc]}
- samtools117: ${ecr_images[samtools117]}
- samtools119: mapped to samtools117 for this tiny validation because the 1.19.2 TAR is an OCI index without platform metadata
- ubuntu: ${ecr_images[ubuntu]}
- cleanup: $cleanup_status

Bundle:

- $bundle_s3_uri

Evidence:

- command_id: $command_id
- invocation: $out_dir/invocation.json
- stdout: $out_dir/stdout.txt
- stderr: $out_dir/stderr.txt
- local_push: $out_dir/local-docker-push.txt
- remote_root: $remote_root/results/

Conclusion:

- See SSM status and remote RESULT.md under remote_root.
RESULT

if [[ "$remote_status" != "Success" ]]; then
  exit 1
fi
