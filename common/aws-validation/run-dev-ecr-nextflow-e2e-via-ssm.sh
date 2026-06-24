#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/run-dev-ecr-nextflow-e2e-via-ssm.sh --instance-id i-... [options]

Purpose:
  Prove a DEV-only ECR image path for a tiny local Nextflow run on an EC2 host.

Options:
  --profile NAME          Default: ${AWS_PROFILE:-dev}
  --region REGION         Default: ${AWS_REGION:-ap-southeast-1}
  --instance-id ID        Required
  --repo-name NAME        Default: nextflow-offline/e2e-fastqc-YYYYMMDD
  --source-image IMAGE    Default: approved Nexus FastQC image
  --source-tar-s3-uri URI Optional Docker image TAR source in S3
  --loaded-image IMAGE    Image name expected after docker load
  --push-mode MODE        remote or local. Default: remote
  --remote-root DIR       Default: /opt/nextflow-offline/ecr-e2e
  --out-dir DIR           Local evidence dir
  --keep-repo             Keep temporary ECR repository after proof
  --help

No public registries, AWS Batch, Terraform, network changes, or broad Docker
cleanup are performed.
EOF
}

profile="${AWS_PROFILE:-dev}"
region="${AWS_REGION:-ap-southeast-1}"
instance_id=""
today="$(date +%Y%m%d)"
repo_name="nextflow-offline/e2e-fastqc-$today"
source_image="registry.example.internal/biocontainers/fastqc:0.12.1--hdfd78af_0"
source_tar_s3_uri=""
loaded_image="biocontainers/fastqc:0.12.1--hdfd78af_0"
push_mode="remote"
remote_root="/opt/nextflow-offline/ecr-e2e"
out_dir="$HOME/.AGENTS-temp/offline/dev-ecr-nextflow-e2e-$(date +%Y%m%d-%H%M%S)"
keep_repo="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --instance-id) instance_id="${2:?missing --instance-id value}"; shift 2 ;;
    --repo-name) repo_name="${2:?missing --repo-name value}"; shift 2 ;;
    --source-image) source_image="${2:?missing --source-image value}"; shift 2 ;;
    --source-tar-s3-uri) source_tar_s3_uri="${2:?missing --source-tar-s3-uri value}"; shift 2 ;;
    --loaded-image) loaded_image="${2:?missing --loaded-image value}"; shift 2 ;;
    --push-mode) push_mode="${2:?missing --push-mode value}"; shift 2 ;;
    --remote-root) remote_root="${2:?missing --remote-root value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --keep-repo) keep_repo="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$instance_id" =~ ^i-[a-z0-9]+$ ]]; then
  echo "ERROR: --instance-id is required" >&2
  exit 1
fi

if [[ "$push_mode" != "remote" && "$push_mode" != "local" ]]; then
  echo "ERROR: --push-mode must be remote or local" >&2
  exit 2
fi

mkdir -p "$out_dir"

account_id="$(aws --profile "$profile" --region "$region" sts get-caller-identity --query Account --output text)"
repo_uri="$account_id.dkr.ecr.$region.amazonaws.com/$repo_name"
image_tag="${source_image##*:}"
ecr_image="$repo_uri:$image_tag"
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

repo_created="false"
cleanup_status="not_started"

cleanup_repo() {
  if [[ "$keep_repo" == "true" ]]; then
    cleanup_status="kept_by_request"
    return 0
  fi
  if [[ "$repo_created" == "true" ]]; then
    if aws --profile "$profile" --region "$region" ecr delete-repository \
      --repository-name "$repo_name" \
      --force > "$out_dir/ecr-delete-repository.json" 2> "$out_dir/ecr-delete-repository.stderr"; then
      cleanup_status="deleted"
    else
      cleanup_status="delete_failed"
    fi
  fi
}
trap cleanup_repo EXIT

aws --profile "$profile" --region "$region" ecr create-repository \
  --repository-name "$repo_name" \
  --image-scanning-configuration scanOnPush=false \
  --encryption-configuration encryptionType=AES256 \
  --tags \
    Key=Name,Value=nextflow-offline-ecr-e2e-fastqc-"$today" \
    Key=dev,Value=amit \
    Key=project,Value=nextflow-offline \
    Key=created,Value="$created_date" \
    Key=tools,Value=cdx \
    Key=environment,Value=dev \
    Key=owner,Value=amit \
    Key=version,Value=e2e-"$today" \
    Key=TTL,Value=24-06-26 \
    Key=purpose,Value=temporary-dev-ecr-nextflow-e2e \
    Key=phase,Value=ecr-basic-e2e \
  > "$out_dir/ecr-create-repository.json"
repo_created="true"

if [[ "$push_mode" == "local" ]]; then
  if [[ -z "$instance_profile_arn" ]]; then
    echo "ERROR: instance has no IAM instance profile; cannot grant ECR pull" >&2
    exit 1
  fi
  instance_profile_name="${instance_profile_arn##*/}"
  ec2_role_arn="$(aws --profile "$profile" --region "$region" iam get-instance-profile \
    --instance-profile-name "$instance_profile_name" \
    --query 'InstanceProfile.Roles[0].Arn' \
    --output text)"
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
  aws --profile "$profile" --region "$region" ecr set-repository-policy \
    --repository-name "$repo_name" \
    --policy-text "file://$repo_policy" \
    > "$out_dir/ecr-set-repository-policy.json"

  if [[ -n "$source_tar_s3_uri" ]]; then
    local_tar="$out_dir/source-image.tar"
    aws --profile "$profile" --region "$region" s3 cp "$source_tar_s3_uri" "$local_tar" --no-progress
    docker load -i "$local_tar" > "$out_dir/local-docker-load.txt"
    local_runtime_image="$loaded_image"
  else
    docker pull "$source_image" > "$out_dir/local-docker-pull.txt"
    local_runtime_image="$source_image"
  fi
  aws --profile "$profile" --region "$region" ecr get-login-password \
    | docker login --username AWS --password-stdin "$account_id.dkr.ecr.$region.amazonaws.com" \
    > "$out_dir/local-ecr-login.txt"
  docker tag "$local_runtime_image" "$ecr_image"
  docker push "$ecr_image" > "$out_dir/local-docker-push.txt"
  docker image rm "$ecr_image" > "$out_dir/local-docker-rm-ecr-tag.txt" 2>&1 || true
fi

remote_commands="$out_dir/remote-commands.sh"
parameters_file="$out_dir/ssm-parameters.json"
cat > "$remote_commands" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

region="__REGION__"
account_id="__ACCOUNT_ID__"
source_image="__SOURCE_IMAGE__"
source_tar_s3_uri="__SOURCE_TAR_S3_URI__"
loaded_image="__LOADED_IMAGE__"
push_mode="__PUSH_MODE__"
ecr_image="__ECR_IMAGE__"
remote_root="__REMOTE_ROOT__"

run_id="ecr-nextflow-e2e-$(date +%Y%m%d-%H%M%S)"
run_dir="$remote_root/results/$run_id"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/stdout.txt") 2> >(tee "$run_dir/stderr.txt" >&2)

status="started"
blocker=""
nextflow_status="not_run"

write_result() {
  cat > "$run_dir/RESULT.md" <<RESULT
# RESULT - DEV ECR Nextflow E2E

Date: $(date)

Status: $status

Input:
- region: $region
- account_id: $account_id
- source_image: $source_image
- source_tar_s3_uri: ${source_tar_s3_uri:-none}
- loaded_image: $loaded_image
- push_mode: $push_mode
- ecr_image: $ecr_image
- remote_root: $remote_root

Checks:
- nextflow_status: $nextflow_status

Evidence:
- stdout: $run_dir/stdout.txt
- stderr: $run_dir/stderr.txt
- nextflow_log: $run_dir/nextflow.log
- workflow: $run_dir/main.nf

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

echo "== source manifest =="
runtime_image="$source_image"
if [[ "$push_mode" == "local" ]]; then
  echo "image already pushed by controller; EC2 will pull from ECR"
elif [[ -n "$source_tar_s3_uri" ]]; then
  tar_path="$run_dir/source-image.tar"
  aws s3 cp "$source_tar_s3_uri" "$tar_path" --no-progress
  docker load -i "$tar_path"
  runtime_image="$loaded_image"
else
  docker manifest inspect "$source_image" >/dev/null
  echo "== pull source =="
  docker pull "$source_image"
fi

echo "== ecr login =="
aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$account_id.dkr.ecr.$region.amazonaws.com"

if [[ "$push_mode" == "remote" ]]; then
  echo "== tag and push =="
  docker tag "$runtime_image" "$ecr_image"
  docker push "$ecr_image"
fi

echo "== pull back =="
docker image rm "$ecr_image" >/dev/null 2>&1 || true
docker pull "$ecr_image"

cat > "$run_dir/main.nf" <<NF
nextflow.enable.dsl=2

process FASTQC_VERSION {
  container '$ecr_image'
  output:
  path 'fastqc-version.txt'
  script:
  '''
  fastqc --version > fastqc-version.txt
  '''
}

workflow {
  FASTQC_VERSION()
}
NF

echo "== nextflow run =="
export NXF_OFFLINE=true
export NXF_PLUGIN_AUTOINSTALL=false
set +e
"$nextflow_bin" -log "$run_dir/nextflow.log" run "$run_dir/main.nf" \
  -with-docker "$ecr_image" \
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
  -e "s#__ACCOUNT_ID__#$account_id#g" \
  -e "s#__SOURCE_IMAGE__#$source_image#g" \
  -e "s#__SOURCE_TAR_S3_URI__#$source_tar_s3_uri#g" \
  -e "s#__LOADED_IMAGE__#$loaded_image#g" \
  -e "s#__PUSH_MODE__#$push_mode#g" \
  -e "s#__ECR_IMAGE__#$ecr_image#g" \
  -e "s#__REMOTE_ROOT__#$remote_root#g" \
  "$remote_commands"

jq -n --rawfile script "$remote_commands" '{commands: [$script]}' > "$parameters_file"

command_id="$(aws --profile "$profile" --region "$region" ssm send-command \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "nextflow offline DEV ECR basic e2e" \
  --parameters "file://$parameters_file" \
  --query Command.CommandId \
  --output text)"

echo "$command_id" > "$out_dir/command-id.txt"
aws --profile "$profile" --region "$region" ssm wait command-executed \
  --command-id "$command_id" \
  --instance-id "$instance_id" || true

aws --profile "$profile" --region "$region" ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id "$instance_id" \
  --output json > "$out_dir/invocation.json"

jq -r '.StandardOutputContent' "$out_dir/invocation.json" > "$out_dir/stdout.txt"
jq -r '.StandardErrorContent' "$out_dir/invocation.json" > "$out_dir/stderr.txt"

remote_status="$(jq -r '.Status' "$out_dir/invocation.json")"

cleanup_repo
trap - EXIT

cat > "$out_dir/RESULT.md" <<RESULT
# RESULT - DEV ECR Nextflow E2E

Date: $(date)

Status: $remote_status

Account/profile/region:

- $account_id / $profile / $region

EC2:

- instance_id: $instance_id
- state: $state
- public_ip: $public_ip

ECR:

- repository: $repo_name
- image: $ecr_image
- cleanup: $cleanup_status

Source image:

- $source_image
- source_tar_s3_uri: ${source_tar_s3_uri:-none}
- loaded_image: $loaded_image
- push_mode: $push_mode

Evidence:

- command_id: $command_id
- invocation: $out_dir/invocation.json
- stdout: $out_dir/stdout.txt
- stderr: $out_dir/stderr.txt
- remote_root: $remote_root/results/

Conclusion:

- See SSM status and remote RESULT.md under remote_root.
RESULT

if [[ "$remote_status" != "Success" ]]; then
  exit 1
fi
