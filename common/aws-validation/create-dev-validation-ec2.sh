#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/create-dev-validation-ec2.sh [--apply] [options]

Purpose:
  Create one private EC2 for Nextflow offline validation.

Defaults:
  profile: ${AWS_PROFILE:-default}
  region: ${AWS_REGION:-ap-southeast-1}
  subnet: required via --subnet-id or NEXTFLOW_VALIDATION_SUBNET_ID
  security group: required via --security-group-id or NEXTFLOW_VALIDATION_SECURITY_GROUP_ID
  instance profile: required via --iam-instance-profile or NEXTFLOW_VALIDATION_INSTANCE_PROFILE
  AMI: required via --ami-id or NEXTFLOW_VALIDATION_AMI_ID
  instance type: m6i.xlarge
  root EBS: 200GB gp3
  no public IP

Options:
  --profile NAME
  --region REGION
  --name NAME
  --ami-id AMI
  --instance-type TYPE
  --subnet-id SUBNET
  --security-group-id SG
  --iam-instance-profile PROFILE
  --expected-account ACCOUNT
  --volume-size-gb GB
  --ttl DD-MM-YY
  --out-dir DIR
  --apply
  --help
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
name="dev-nextflow-offline-validation-$(date +%Y%m%d)"
ami_id="${NEXTFLOW_VALIDATION_AMI_ID:-}"
instance_type="m6i.xlarge"
subnet_id="${NEXTFLOW_VALIDATION_SUBNET_ID:-}"
security_group_id="${NEXTFLOW_VALIDATION_SECURITY_GROUP_ID:-}"
iam_instance_profile="${NEXTFLOW_VALIDATION_INSTANCE_PROFILE:-}"
expected_account="${NEXTFLOW_VALIDATION_EXPECTED_ACCOUNT:-}"
volume_size_gb="200"
ttl="30-06-26"
out_dir="$HOME/.AGENTS-temp/offline/dev-ec2-create-$(date +%Y%m%d-%H%M%S)"
mode="plan"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --name) name="${2:?missing --name value}"; shift 2 ;;
    --ami-id) ami_id="${2:?missing --ami-id value}"; shift 2 ;;
    --instance-type) instance_type="${2:?missing --instance-type value}"; shift 2 ;;
    --subnet-id) subnet_id="${2:?missing --subnet-id value}"; shift 2 ;;
    --security-group-id) security_group_id="${2:?missing --security-group-id value}"; shift 2 ;;
    --iam-instance-profile) iam_instance_profile="${2:?missing --iam-instance-profile value}"; shift 2 ;;
    --expected-account) expected_account="${2:?missing --expected-account value}"; shift 2 ;;
    --volume-size-gb) volume_size_gb="${2:?missing --volume-size-gb value}"; shift 2 ;;
    --ttl) ttl="${2:?missing --ttl value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --apply) mode="apply"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$volume_size_gb" =~ ^[0-9]+$ || "$volume_size_gb" -lt 50 ]]; then
  echo "ERROR: --volume-size-gb must be an integer >= 50" >&2
  exit 1
fi

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "ERROR: $name is required" >&2
    exit 2
  fi
}

require_value "--ami-id or NEXTFLOW_VALIDATION_AMI_ID" "$ami_id"
require_value "--subnet-id or NEXTFLOW_VALIDATION_SUBNET_ID" "$subnet_id"
require_value "--security-group-id or NEXTFLOW_VALIDATION_SECURITY_GROUP_ID" "$security_group_id"
require_value "--iam-instance-profile or NEXTFLOW_VALIDATION_INSTANCE_PROFILE" "$iam_instance_profile"

mkdir -p "$out_dir"

aws_cli() {
  AWS_PROFILE="$profile" aws "$@" --region "$region"
}

echo "Output: $out_dir"

aws_cli sts get-caller-identity --output json | tee "$out_dir/sts.json"
account="$(jq -r '.Account' "$out_dir/sts.json")"
if [[ -n "$expected_account" && "$account" != "$expected_account" ]]; then
  echo "ERROR: expected account $expected_account, got $account" >&2
  exit 1
fi

aws_cli ec2 describe-subnets \
  --subnet-ids "$subnet_id" \
  --query 'Subnets[0].{SubnetId:SubnetId,VpcId:VpcId,AvailabilityZone:AvailabilityZone,MapPublicIp:MapPublicIpOnLaunch,CidrBlock:CidrBlock}' \
  --output json | tee "$out_dir/subnet.json"

map_public_ip="$(jq -r '.MapPublicIp' "$out_dir/subnet.json")"
vpc_id="$(jq -r '.VpcId' "$out_dir/subnet.json")"
if [[ "$map_public_ip" != "false" ]]; then
  echo "ERROR: subnet maps public IPs by default: $subnet_id" >&2
  exit 1
fi

aws_cli ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$subnet_id" \
  --query 'RouteTables[].Routes[]' \
  --output json | tee "$out_dir/routes.json"

if jq -e '.[] | select((.GatewayId // "") | startswith("igw-"))' "$out_dir/routes.json" >/dev/null; then
  echo "ERROR: subnet has IGW route; refusing private validation launch" >&2
  exit 1
fi

if jq -e '.[] | select((.NatGatewayId // "") | startswith("nat-"))' "$out_dir/routes.json" >/dev/null; then
  echo "ERROR: subnet has NAT route; refusing private-only validation launch" >&2
  exit 1
fi

aws_cli ec2 describe-security-groups \
  --group-ids "$security_group_id" \
  --query 'SecurityGroups[0].{GroupId:GroupId,GroupName:GroupName,VpcId:VpcId}' \
  --output json | tee "$out_dir/security-group.json"

sg_vpc_id="$(jq -r '.VpcId' "$out_dir/security-group.json")"
if [[ "$sg_vpc_id" != "$vpc_id" ]]; then
  echo "ERROR: security group VPC $sg_vpc_id does not match subnet VPC $vpc_id" >&2
  exit 1
fi

aws_cli ec2 describe-images \
  --image-ids "$ami_id" \
  --query 'Images[0].{ImageId:ImageId,Name:Name,State:State,RootDeviceName:RootDeviceName}' \
  --output json | tee "$out_dir/ami.json"

if [[ "$(jq -r '.State' "$out_dir/ami.json")" != "available" ]]; then
  echo "ERROR: AMI is not available: $ami_id" >&2
  exit 1
fi

AWS_PROFILE="$profile" aws iam get-instance-profile \
  --instance-profile-name "$iam_instance_profile" \
  --output json | tee "$out_dir/instance-profile.json" >/dev/null

run_args=(
  ec2 run-instances
  --region "$region"
  --image-id "$ami_id"
  --instance-type "$instance_type"
  --iam-instance-profile "Name=$iam_instance_profile"
  --network-interfaces "DeviceIndex=0,SubnetId=$subnet_id,Groups=$security_group_id,AssociatePublicIpAddress=false"
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"DeleteOnTermination\":true,\"VolumeType\":\"gp3\",\"VolumeSize\":$volume_size_gb,\"Iops\":3000,\"Throughput\":125}}]"
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2"
  --tag-specifications
  "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=dev,Value=amit},{Key=project,Value=nextflow-offline},{Key=created,Value=$(date +%F)},{Key=tools,Value=cdx},{Key=environment,Value=dev},{Key=owner,Value=amit},{Key=version,Value=$(date +%Y%m%d)},{Key=TTL,Value=$ttl},{Key=purpose,Value=nextflow-offline-validation},{Key=phase,Value=ami-factory-dev-validation},{Key=Repo,Value=offline},{Key=ProvisionedBy,Value=codex}]"
  "ResourceType=volume,Tags=[{Key=Name,Value=$name-root},{Key=dev,Value=amit},{Key=project,Value=nextflow-offline},{Key=created,Value=$(date +%F)},{Key=tools,Value=cdx},{Key=environment,Value=dev},{Key=owner,Value=amit},{Key=version,Value=$(date +%Y%m%d)},{Key=TTL,Value=$ttl},{Key=purpose,Value=nextflow-offline-validation},{Key=phase,Value=ami-factory-dev-validation},{Key=Repo,Value=offline},{Key=ProvisionedBy,Value=codex}]"
  --output json
)

printf 'AWS_PROFILE=%q aws ' "$profile" > "$out_dir/run-command.txt"
printf '%q ' "${run_args[@]}" >> "$out_dir/run-command.txt"
printf '\n' >> "$out_dir/run-command.txt"

if [[ "$mode" != "apply" ]]; then
  echo "Plan only. Reviewed private launch inputs; command written to $out_dir/run-command.txt"
  exit 0
fi

AWS_PROFILE="$profile" aws "${run_args[@]}" | tee "$out_dir/run-instances.json"
instance_id="$(jq -r '.Instances[0].InstanceId' "$out_dir/run-instances.json")"
printf '%s\n' "$instance_id" | tee "$out_dir/instance-id.txt"

aws_cli ec2 wait instance-running --instance-ids "$instance_id"

aws_cli ec2 describe-instances \
  --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,State:State.Name,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress,SubnetId:SubnetId,VpcId:VpcId,InstanceType:InstanceType,ImageId:ImageId,Name:Tags[?Key==`Name`]|[0].Value,TTL:Tags[?Key==`TTL`]|[0].Value}' \
  --output json | tee "$out_dir/instance.json"

aws_cli ec2 describe-volumes \
  --filters "Name=attachment.instance-id,Values=$instance_id" \
  --query 'Volumes[].{VolumeId:VolumeId,Size:Size,VolumeType:VolumeType,Encrypted:Encrypted,State:State,Device:Attachments[0].Device,DeleteOnTermination:Attachments[0].DeleteOnTermination,Name:Tags[?Key==`Name`]|[0].Value,TTL:Tags[?Key==`TTL`]|[0].Value}' \
  --output json | tee "$out_dir/volumes.json"

cat > "$out_dir/RESULT.md" <<EOF
# DEV EC2 Create Result

Instance: \`$instance_id\`
Name: \`$name\`
Profile: \`$profile\`
Account: \`$account\`
Region: \`$region\`
VPC: \`$vpc_id\`
Subnet: \`$subnet_id\`
Security group: \`$security_group_id\`
AMI: \`$ami_id\`
Instance type: \`$instance_type\`
Root EBS: \`${volume_size_gb}GB gp3\`
TTL: \`$ttl\`
Public IP: none expected; verify in \`$out_dir/instance.json\`

Evidence:
- \`$out_dir/sts.json\`
- \`$out_dir/subnet.json\`
- \`$out_dir/routes.json\`
- \`$out_dir/security-group.json\`
- \`$out_dir/ami.json\`
- \`$out_dir/run-instances.json\`
- \`$out_dir/instance.json\`
- \`$out_dir/volumes.json\`
EOF

echo "OK: $out_dir/RESULT.md"
