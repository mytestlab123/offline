#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id i-... [options]

Purpose:
  Run deterministic staged validation probes against an existing DEV EC2 host through SSM.

Options:
  --profile NAME              Default: ${AWS_PROFILE:-default}
  --region REGION             Default: ${AWS_REGION:-ap-southeast-1}
  --instance-id ID            Required
  --workspace DIR             Default: /mnt/data5/nfcore-offline-smoke
  --out-dir DIR               Local evidence directory
  --repo-s3-uri URI           Required for host-tool-s3
  --tools-s3-uri URI          Required for host-tool-s3
  --bundle-s3-uri URI         Required for s3-bundle-* stages
  --remote-repo-dir DIR        Default: /opt/nextflow-offline
  --smoke-script PATH         Optional smoke script path on host
  --nexus-host HOST           Required for docker-nexus or network-probe
  --probe-image IMAGE         Default: quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0
  --stages STAGE[,STAGE...]   Comma-separated stages. Default:
                               host-tool-s3,network-probe,docker-nexus,nextflow-inspect
  --run-full-smoke            Alias for: --stages full-smoke
  --help

Stages:
  host-tool-s3     restore tools from S3 (if missing), sync repo, capture host/tool evidence
  network-probe    quay.io reachability + nexus reachability checks
  docker-nexus    1-image Docker pull validation (public pull should fail, nexus pull should succeed)
  nextflow-inspect inspect-only probe via local script stage
  s3-bundle-sync  sync prebuilt workflow and docker TAR bundle from S3
  s3-docker-load  load prebuilt Docker TARs from synced S3 bundle
  s3-offline-run  run Nextflow offline from synced S3 bundle and loaded images
  full-smoke      runs host-tool-s3, network-probe, docker-nexus, nextflow-inspect, full-smoke

Notes:
  Full-smoke is explicit only. Default behavior stops before heavy runtime smoke.
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
workspace="/mnt/data5/nfcore-offline-smoke"
out_dir="$HOME/.AGENTS-temp/offline/dev-ec2-smoke-$(date +%Y%m%d-%H%M%S)"
repo_s3_uri="${NEXTFLOW_OFFLINE_REPO_S3_URI:-}"
tools_s3_uri="${NEXTFLOW_OFFLINE_TOOLS_S3_URI:-}"
bundle_s3_uri="${NEXTFLOW_OFFLINE_BUNDLE_S3_URI:-}"
remote_repo_dir="/opt/nextflow-offline"
smoke_script=""
nexus_host="${NEXTFLOW_OFFLINE_NEXUS_HOST:-}"
probe_image="quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0"
stages_csv="host-tool-s3,network-probe,docker-nexus,nextflow-inspect"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --instance-id) instance_id="${2:?missing --instance-id value}"; shift 2 ;;
    --workspace) workspace="${2:?missing --workspace value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --repo-s3-uri) repo_s3_uri="${2:?missing --repo-s3-uri value}"; shift 2 ;;
    --tools-s3-uri) tools_s3_uri="${2:?missing --tools-s3-uri value}"; shift 2 ;;
    --bundle-s3-uri) bundle_s3_uri="${2:?missing --bundle-s3-uri value}"; shift 2 ;;
    --remote-repo-dir) remote_repo_dir="${2:?missing --remote-repo-dir value}"; shift 2 ;;
    --smoke-script) smoke_script="${2:?missing --smoke-script value}"; shift 2 ;;
    --nexus-host) nexus_host="${2:?missing --nexus-host value}"; shift 2 ;;
    --probe-image) probe_image="${2:?missing --probe-image value}"; shift 2 ;;
    --stages) stages_csv="${2:?missing --stages value}"; shift 2 ;;
    --run-full-smoke) stages_csv="full-smoke"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$instance_id" =~ ^i-[a-z0-9]+$ ]]; then
  echo "ERROR: --instance-id is required" >&2
  exit 1
fi

normalize_stages() {
  local raw="$1"
  local item
  local -a normalized=()
  local -a expanded=()

  IFS=',' read -r -a expanded <<< "${raw:-$stages_csv}"
  for item in "${expanded[@]}"; do
    item="${item//[[:space:]]/}"
    case "$item" in
      host-tool-s3|host-tool|hostprobe|host-tools)
        normalized+=("host-tool-s3")
        ;;
      network-probe|network|networkcheck|network-check)
        normalized+=("network-probe")
        ;;
      docker-nexus|docker|nexus)
        normalized+=("docker-nexus")
        ;;
      nextflow-inspect|inspect|inspect-only)
        normalized+=("nextflow-inspect")
        ;;
      s3-bundle-sync|bundle-sync|bundle)
        normalized+=("s3-bundle-sync")
        ;;
      s3-docker-load|bundle-docker-load|bundle-load)
        normalized+=("s3-docker-load")
        ;;
      s3-offline-run|bundle-offline-run|bundle-run)
        normalized+=("s3-offline-run")
        ;;
      full-smoke|full|smoke)
        normalized+=("host-tool-s3" "network-probe" "docker-nexus" "nextflow-inspect" "full-smoke")
        ;;
      *)
        echo "ERROR: unknown stage in --stages: $item" >&2
        exit 2
        ;;
    esac
  done

  if [[ "${#normalized[@]}" -eq 0 ]]; then
    normalized=("host-tool-s3" "network-probe" "docker-nexus" "nextflow-inspect")
  fi

  STAGES=()
  for item in "${normalized[@]}"; do
    [[ " ${STAGES[*]} " == *" $item "* ]] || STAGES+=("$item")
  done
}

normalize_stages "$stages_csv"

has_stage() {
  local wanted="$1"
  local item
  for item in "${STAGES[@]}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

stage_csv="$(printf '%s,' "${STAGES[@]}")"
stage_csv="${stage_csv%,}"

run_host_tool_s3="$(has_stage host-tool-s3 && echo 1 || echo 0)"
run_network_probe="$(has_stage network-probe && echo 1 || echo 0)"
run_docker_nexus="$(has_stage docker-nexus && echo 1 || echo 0)"
run_nextflow_inspect="$(has_stage nextflow-inspect && echo 1 || echo 0)"
run_s3_bundle_sync="$(has_stage s3-bundle-sync && echo 1 || echo 0)"
run_s3_docker_load="$(has_stage s3-docker-load && echo 1 || echo 0)"
run_s3_offline_run="$(has_stage s3-offline-run && echo 1 || echo 0)"
run_full_smoke="$(has_stage full-smoke && echo 1 || echo 0)"

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "ERROR: $name is required for selected stages" >&2
    exit 2
  fi
}

if has_stage host-tool-s3; then
  require_value "--repo-s3-uri or NEXTFLOW_OFFLINE_REPO_S3_URI" "$repo_s3_uri"
  require_value "--tools-s3-uri or NEXTFLOW_OFFLINE_TOOLS_S3_URI" "$tools_s3_uri"
fi

if has_stage network-probe || has_stage docker-nexus; then
  require_value "--nexus-host or NEXTFLOW_OFFLINE_NEXUS_HOST" "$nexus_host"
fi

if has_stage s3-bundle-sync || has_stage s3-docker-load || has_stage s3-offline-run; then
  require_value "--bundle-s3-uri or NEXTFLOW_OFFLINE_BUNDLE_S3_URI" "$bundle_s3_uri"
fi

mkdir -p "$out_dir"

commands_file="$out_dir/remote-commands.sh"
cat > "$commands_file" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

workspace="__WORKSPACE__"
repo_s3_uri="__REPO_S3_URI__"
tools_s3_uri="__TOOLS_S3_URI__"
bundle_s3_uri="__BUNDLE_S3_URI__"
remote_repo_dir="__REMOTE_REPO_DIR__"
smoke_script="__SMOKE_SCRIPT__"
nexus_host="__NEXUS_HOST__"
probe_image="__PROBE_IMAGE__"

run_host_tool_s3="__RUN_HOST_TOOL_S3__"
run_network_probe="__RUN_NETWORK_PROBE__"
run_docker_nexus="__RUN_DOCKER_NEXUS__"
run_nextflow_inspect="__RUN_NEXTFLOW_INSPECT__"
run_s3_bundle_sync="__RUN_S3_BUNDLE_SYNC__"
run_s3_docker_load="__RUN_S3_DOCKER_LOAD__"
run_s3_offline_run="__RUN_S3_OFFLINE_RUN__"
run_full_smoke="__RUN_FULL_SMOKE__"

probe_dir="$workspace/results/dev-ec2-staged-probes"
mkdir -p "$probe_dir"

run_host_tool_stage() {
  echo "== identity ==" > "$probe_dir/host-tool-s3.log"
  hostname >> "$probe_dir/host-tool-s3.log"
  date >> "$probe_dir/host-tool-s3.log"

  {
    echo "== os =="
    cat /etc/os-release || true
    echo
    echo "== disk =="
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    df -hT
    findmnt -no SOURCE,FSTYPE,SIZE,USED,AVAIL /
    echo
    echo "== docker =="
    command -v docker || true
    command -v docker >/dev/null 2>&1 && { docker --version || true; }
    echo
    echo "== tools =="
    command -v java || true
    java -version 2>&1 || true
    command -v nextflow || true
    nextflow -version 2>&1 || true
    command -v nf-core || true
    nf-core --version 2>&1 || true
    command -v aws || true
    aws --version 2>&1 || true
  } >> "$probe_dir/host-tool-s3.log"

  if ! command -v nextflow >/dev/null 2>&1 || ! command -v nf-core >/dev/null 2>&1; then
    if command -v aws >/dev/null 2>&1; then
      sudo mkdir -p /mnt/data5 /usr/local/bin
      sudo chown "$(id -u):$(id -g)" /mnt/data5
      aws s3 cp "$tools_s3_uri" /tmp/nextflow-tools.tar.gz --only-show-errors
      tar -C /mnt/data5 -xzf /tmp/nextflow-tools.tar.gz
      sudo ln -sf /mnt/data5/nextflow-tools/bin/nextflow /usr/local/bin/nextflow
      sudo ln -sf /mnt/data5/nextflow-tools/bin/nextflow-25.04 /usr/local/bin/nextflow-25.04
      sudo ln -sf /mnt/data5/nextflow-tools/bin/nf-core /usr/local/bin/nf-core
      echo "tool_restore=restored" >> "$probe_dir/host-tool-s3.log"
    else
      echo "tool_restore=blocked_aws_cli_missing" >> "$probe_dir/host-tool-s3.log"
    fi
  else
    echo "tool_restore=already_present" >> "$probe_dir/host-tool-s3.log"
  fi

  if [[ -x /mnt/data5/nextflow-tools/venvs/nf-core/bin/nf-core ]]; then
    if ! command -v python3.12 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
      if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3.12 git || true
      fi
    fi
    if command -v python3.12 >/dev/null 2>&1; then
      sudo ln -sf "$(command -v python3.12)" /mnt/data5/nextflow-tools/venvs/nf-core/bin/python
      sudo ln -sf python /mnt/data5/nextflow-tools/venvs/nf-core/bin/python3
      sudo ln -sf python /mnt/data5/nextflow-tools/venvs/nf-core/bin/python3.12
    fi
  fi

  {
    echo "== tools after restore =="
    command -v java || true
    java -version 2>&1 || true
    command -v nextflow || true
    nextflow -version 2>&1 || true
    command -v nf-core || true
    nf-core --version 2>&1 || true
    command -v python3.12 || true
    python3.12 --version 2>&1 || true
    command -v git || true
    git --version 2>&1 || true
  } >> "$probe_dir/host-tool-s3.log"

  if [[ -n "$repo_s3_uri" ]]; then
    if command -v aws >/dev/null 2>&1; then
      sudo mkdir -p "$remote_repo_dir"
      sudo chown "$(id -u):$(id -g)" "$remote_repo_dir"
      aws s3 sync "$repo_s3_uri" "$remote_repo_dir" --only-show-errors
      chmod +x "$remote_repo_dir"/common/**/*.sh 2>/dev/null || true
      echo "repo_sync=ok" >> "$probe_dir/host-tool-s3.log"
    else
      echo "repo_sync=blocked_aws_cli_missing" >> "$probe_dir/host-tool-s3.log"
    fi
  else
    echo "repo_sync=skipped_no_repo_uri" >> "$probe_dir/host-tool-s3.log"
  fi
}

run_network_stage() {
  {
    echo "== network checks =="
    timeout 5 bash -lc 'cat < /dev/null > /dev/tcp/quay.io/443' && echo "quay_tcp_443=reachable" || echo "quay_tcp_443=not_reachable_or_blocked"
    timeout 5 bash -lc "cat < /dev/null > /dev/tcp/${nexus_host}/443" && echo "nexus_tcp_443=reachable" || echo "nexus_tcp_443=not_reachable_or_blocked"
  } > "$probe_dir/network-probe.log"
}

run_docker_nexus_stage() {
  local public_image="$probe_image"
  local image_without_registry="${probe_image#quay.io/}"
  local nexus_image="${nexus_host}/${image_without_registry}"

  if ! command -v docker >/dev/null 2>&1; then
    echo "docker_not_found" > "$probe_dir/docker-nexus.log"
    return 1
  fi

  {
    docker --version || true
    echo "public_image=$public_image"
    echo "nexus_image=$nexus_image"
    docker pull "$public_image" >/tmp/nextflow-public-probe.out 2>/tmp/nextflow-public-probe.err || true
    if [[ -s /tmp/nextflow-public-probe.out ]]; then
      echo "public_pull=unexpected_success"
    else
      echo "public_pull=expected_blocked_or_unavailable"
    fi
    if [[ -s /tmp/nextflow-public-probe.err ]]; then
      echo "public_pull_err=present"
    fi
    if docker pull "$nexus_image" >/tmp/nextflow-nexus-probe.out 2>/tmp/nextflow-nexus-probe.err; then
      echo "nexus_pull=success"
    else
      echo "nexus_pull=failed"
      echo "--- nexus pull stderr ---"
      cat /tmp/nextflow-nexus-probe.err
      exit 1
    fi
  } > "$probe_dir/docker-nexus.log" 2>&1

  docker rmi -f "$public_image" "$nexus_image" >/dev/null 2>&1 || true
}

run_nextflow_inspect_stage() {
  local smoke_cmd=""
  if [[ -n "$smoke_script" && -x "$smoke_script" ]]; then
    smoke_cmd="$smoke_script"
  elif [[ -x "$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh" ]]; then
    smoke_cmd="$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh"
  else
    echo "smoke_script_missing" > "$probe_dir/nextflow-inspect.log"
    echo "expected=$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh" >> "$probe_dir/nextflow-inspect.log"
    return 1
  fi

  mkdir -p "$workspace"
  "$smoke_cmd" --workspace "$workspace" --stages nextflow-inspect > "$probe_dir/nextflow-inspect.log" 2>&1
}

run_s3_bundle_sync_stage() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "aws_cli_missing" > "$probe_dir/s3-bundle-sync.log"
    return 1
  fi
  mkdir -p "$workspace/downloads/testpipeline"
  aws s3 sync "$bundle_s3_uri" "$workspace/downloads/testpipeline" --only-show-errors
  {
    echo "bundle_s3_uri=$bundle_s3_uri"
    echo "target=$workspace/downloads/testpipeline"
    find "$workspace/downloads/testpipeline" -maxdepth 2 -type f -printf '%p %s bytes\n' | sort
  } > "$probe_dir/s3-bundle-sync.log"
}

run_s3_docker_load_stage() {
  local smoke_cmd=""
  if [[ -n "$smoke_script" && -x "$smoke_script" ]]; then
    smoke_cmd="$smoke_script"
  elif [[ -x "$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh" ]]; then
    smoke_cmd="$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh"
  else
    echo "smoke_script_missing" > "$probe_dir/s3-docker-load.log"
    return 1
  fi
  "$smoke_cmd" --workspace "$workspace" --stages docker-load > "$probe_dir/s3-docker-load.log" 2>&1
}

run_s3_offline_run_stage() {
  local smoke_cmd=""
  if [[ -n "$smoke_script" && -x "$smoke_script" ]]; then
    smoke_cmd="$smoke_script"
  elif [[ -x "$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh" ]]; then
    smoke_cmd="$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh"
  else
    echo "smoke_script_missing" > "$probe_dir/s3-offline-run.log"
    return 1
  fi
  "$smoke_cmd" --workspace "$workspace" --stages offline-run > "$probe_dir/s3-offline-run.log" 2>&1
}

run_full_smoke_stage() {
  local smoke_cmd=""
  if [[ -n "$smoke_script" && -x "$smoke_script" ]]; then
    smoke_cmd="$smoke_script"
  elif [[ -x "$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh" ]]; then
    smoke_cmd="$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh"
  else
    echo "smoke_script_missing" > "$probe_dir/full-smoke.log"
    echo "expected=$remote_repo_dir/common/offline-smoke/nf-core-download-smoke.sh" >> "$probe_dir/full-smoke.log"
    return 1
  fi

  mkdir -p "$workspace"
  "$smoke_cmd" --workspace "$workspace" --stages full-smoke > "$probe_dir/full-smoke.log" 2>&1
}

if [[ "$run_host_tool_s3" == "1" ]]; then
  run_host_tool_stage
fi

if [[ "$run_network_probe" == "1" ]]; then
  run_network_stage
fi

if [[ "$run_docker_nexus" == "1" ]]; then
  run_docker_nexus_stage
fi

if [[ "$run_nextflow_inspect" == "1" ]]; then
  run_nextflow_inspect_stage
fi

if [[ "$run_s3_bundle_sync" == "1" ]]; then
  run_s3_bundle_sync_stage
fi

if [[ "$run_s3_docker_load" == "1" ]]; then
  run_s3_docker_load_stage
fi

if [[ "$run_s3_offline_run" == "1" ]]; then
  run_s3_offline_run_stage
fi

if [[ "$run_full_smoke" == "1" ]]; then
  run_full_smoke_stage
fi

{
  echo "stages: ${run_host_tool_s3} ${run_network_probe} ${run_docker_nexus} ${run_nextflow_inspect} ${run_s3_bundle_sync} ${run_s3_docker_load} ${run_s3_offline_run} ${run_full_smoke}"
  echo "workspace: $workspace"
  echo "remote_repo_dir: $remote_repo_dir"
  printf 'evidence:'
  find "$probe_dir" -maxdepth 1 -type f -print
} > "$probe_dir/probe-summary.log"
REMOTE

sed -i \
  -e "s#__WORKSPACE__#${workspace}#g" \
  -e "s#__REPO_S3_URI__#${repo_s3_uri}#g" \
  -e "s#__TOOLS_S3_URI__#${tools_s3_uri}#g" \
  -e "s#__BUNDLE_S3_URI__#${bundle_s3_uri}#g" \
  -e "s#__REMOTE_REPO_DIR__#${remote_repo_dir}#g" \
  -e "s#__SMOKE_SCRIPT__#${smoke_script}#g" \
  -e "s#__NEXUS_HOST__#${nexus_host}#g" \
  -e "s#__PROBE_IMAGE__#${probe_image}#g" \
  -e "s#__RUN_HOST_TOOL_S3__#${run_host_tool_s3}#g" \
  -e "s#__RUN_NETWORK_PROBE__#${run_network_probe}#g" \
  -e "s#__RUN_DOCKER_NEXUS__#${run_docker_nexus}#g" \
  -e "s#__RUN_NEXTFLOW_INSPECT__#${run_nextflow_inspect}#g" \
  -e "s#__RUN_S3_BUNDLE_SYNC__#${run_s3_bundle_sync}#g" \
  -e "s#__RUN_S3_DOCKER_LOAD__#${run_s3_docker_load}#g" \
  -e "s#__RUN_S3_OFFLINE_RUN__#${run_s3_offline_run}#g" \
  -e "s#__RUN_FULL_SMOKE__#${run_full_smoke}#g" \
  "$commands_file"
chmod +x "$commands_file"

params_file="$out_dir/parameters.json"
jq -n --rawfile commands "$commands_file" '{commands:[$commands]}' > "$params_file"

AWS_PROFILE="$profile" aws ssm send-command \
  --region "$region" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "nextflow offline validation staged probe" \
  --parameters "file://$params_file" \
  --output json | tee "$out_dir/send-command.json"

command_id="$(jq -r '.Command.CommandId' "$out_dir/send-command.json")"
printf '%s\n' "$command_id" > "$out_dir/command-id.txt"

for _ in $(seq 1 90); do
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
# DEV EC2 SSM Staged Validation Result

Instance: \`$instance_id\`
Profile: \`$profile\`
Region: \`$region\`
CommandId: \`$command_id\`
Status: \`$status\`
Stages: \`$stage_csv\`

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
