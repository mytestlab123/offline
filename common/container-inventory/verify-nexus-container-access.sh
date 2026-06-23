#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  verify-nexus-container-access.sh --instance-id ID --profile PROFILE --region REGION --inventory-dir DIR [options]

Required:
  --instance-id ID         SSM-managed EC2 instance ID
  --profile PROFILE        AWS CLI profile
  --region REGION          AWS region
  --inventory-dir DIR      Container inventory output dir from extract-container-hosts.sh

Options:
  --nexus-host HOST        Nexus Docker proxy host. Default: nexus-docker.ship.gov.sg
  --runtime NAME           Container runtime on EC2. Default: docker
  --out-root DIR           Local output root. Default: out/container-inventory-verify
  --max-nexus-pulls N      Limit Nexus pulls. Default: 0 means all inventory images
  --ssm-timeout-seconds N  SSM command timeout. Default: 3600
  --pull-timeout-seconds N Per-image Nexus pull timeout. Default: 300
  --public-timeout-seconds N Per-public-registry pull timeout. Default: 90
  --dry-run                Write payload/parameter files but do not call AWS
  -h, --help               Show help

Behavior:
  - Pulls inventory containers through Nexus on the EC2.
  - Tests public registries directly and expects them to fail in GCC.
  - Does not push images.
  - Does not edit Docker daemon config.
  - Does not install packages.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

instance_id=""
aws_profile=""
aws_region=""
inventory_dir=""
nexus_host="nexus-docker.ship.gov.sg"
runtime="docker"
out_root="out/container-inventory-verify"
max_nexus_pulls=0
ssm_timeout_seconds=3600
pull_timeout_seconds=300
public_timeout_seconds=90
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) instance_id="$2"; shift 2 ;;
    --profile) aws_profile="$2"; shift 2 ;;
    --region) aws_region="$2"; shift 2 ;;
    --inventory-dir) inventory_dir="$2"; shift 2 ;;
    --nexus-host) nexus_host="$2"; shift 2 ;;
    --runtime) runtime="$2"; shift 2 ;;
    --out-root) out_root="$2"; shift 2 ;;
    --max-nexus-pulls) max_nexus_pulls="$2"; shift 2 ;;
    --ssm-timeout-seconds) ssm_timeout_seconds="$2"; shift 2 ;;
    --pull-timeout-seconds) pull_timeout_seconds="$2"; shift 2 ;;
    --public-timeout-seconds) public_timeout_seconds="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$instance_id" ]] || { usage >&2; exit 2; }
[[ -n "$aws_profile" ]] || { usage >&2; exit 2; }
[[ -n "$aws_region" ]] || { usage >&2; exit 2; }
[[ -n "$inventory_dir" ]] || { usage >&2; exit 2; }
[[ "$runtime" == "docker" ]] || die "only docker runtime is supported today"
[[ "$out_root" == out/* || "$out_root" == /tmp/* || "$out_root" == /mnt/* || "$out_root" == "$HOME"/.AGENTS-temp/* ]] \
  || die "--out-root must be a generated output path"

case "$max_nexus_pulls" in (*[!0-9]*|"") die "--max-nexus-pulls must be a non-negative integer" ;; esac
case "$ssm_timeout_seconds" in (*[!0-9]*|"") die "--ssm-timeout-seconds must be a positive integer" ;; esac
case "$pull_timeout_seconds" in (*[!0-9]*|"") die "--pull-timeout-seconds must be a positive integer" ;; esac
case "$public_timeout_seconds" in (*[!0-9]*|"") die "--public-timeout-seconds must be a positive integer" ;; esac
[[ "$ssm_timeout_seconds" -gt 0 ]] || die "--ssm-timeout-seconds must be positive"
[[ "$pull_timeout_seconds" -gt 0 ]] || die "--pull-timeout-seconds must be positive"
[[ "$public_timeout_seconds" -gt 0 ]] || die "--public-timeout-seconds must be positive"

if [[ "$inventory_dir" != /* ]]; then
  inventory_dir="${repo_root}/${inventory_dir}"
fi
[[ -d "$inventory_dir" ]] || die "inventory dir not found: $inventory_dir"
[[ -f "${inventory_dir}/containers.tsv" ]] || die "missing containers.tsv in inventory dir: $inventory_dir"

need awk
need base64
need python3
if [[ "$dry_run" != "1" ]]; then
  need aws
fi

out_dir="${repo_root}/${out_root}/${instance_id}"
mkdir -p "$out_dir"

nexus_images_file="${out_dir}/nexus-images.txt"
public_images_file="${out_dir}/public-images.txt"
remote_script="${out_dir}/remote-command.sh"
parameters_json="${out_dir}/send-command-parameters.json"
command_json="${out_dir}/send-command.json"
invocation_json="${out_dir}/get-command-invocation.json"
stdout_file="${out_dir}/stdout.txt"
stderr_file="${out_dir}/stderr.txt"
summary_file="${out_dir}/summary.env"

normalize_image() {
  sed -E 's#^(docker|podman|singularity|oras)://##'
}

to_nexus_image() {
  local image="$1"
  local first rest
  image="$(printf '%s' "$image" | normalize_image)"
  first="${image%%/*}"
  if [[ "$image" == *'$'* || "$image" == *'{'* || "$image" == *'}'* ]]; then
    return 1
  fi
  if [[ "$image" != */* ]]; then
    return 1
  fi
  if [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    rest="${image#*/}"
  else
    rest="$image"
  fi
  printf '%s/%s\n' "$nexus_host" "$rest"
}

: > "$nexus_images_file"
awk -F '\t' 'NR > 1 {print $2}' "${inventory_dir}/containers.tsv" | while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  to_nexus_image "$image" || true
done | sort -u > "$nexus_images_file"

if [[ "$max_nexus_pulls" -gt 0 ]]; then
  tmp_file="${nexus_images_file}.tmp"
  head -n "$max_nexus_pulls" "$nexus_images_file" > "$tmp_file"
  mv "$tmp_file" "$nexus_images_file"
fi

[[ -s "$nexus_images_file" ]] || die "no Nexus-verifiable images found in ${inventory_dir}/containers.tsv"

cat > "$public_images_file" <<'EOF'
quay.io/prometheus/busybox:latest
docker.io/library/hello-world:latest
ghcr.io/fluxcd/flux-cli:v2.2.3
community.wave.seqera.io/library/scanpy:1.10.2--e83da2205b92a538
EOF

cat > "$remote_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

runtime="${runtime}"
nexus_host="${nexus_host}"
pull_timeout_seconds="${pull_timeout_seconds}"
public_timeout_seconds="${public_timeout_seconds}"
work_dir="/tmp/container-inventory-verify-\$(date +%Y%m%d-%H%M%S)-\$\$"
mkdir -p "\$work_dir"

cat > "\$work_dir/nexus-images.txt" <<'NEXUS_IMAGES'
$(cat "$nexus_images_file")
NEXUS_IMAGES

cat > "\$work_dir/public-images.txt" <<'PUBLIC_IMAGES'
$(cat "$public_images_file")
PUBLIC_IMAGES

pass=0
fail=0

log() {
  printf '%s %s\n' "\$(date -Is)" "\$*"
}

record_pass() {
  pass=\$((pass + 1))
  log "PASS: \$*"
}

record_fail() {
  fail=\$((fail + 1))
  log "FAIL: \$*"
}

log "runtime=\$runtime"
log "nexus_host=\$nexus_host"
log "work_dir=\$work_dir"

if ! command -v "\$runtime" >/dev/null 2>&1; then
  record_fail "container runtime not found: \$runtime"
  exit 1
fi
record_pass "container runtime found: \$runtime"

if "\$runtime" info >/dev/null 2>&1; then
  record_pass "docker daemon reachable"
else
  record_fail "docker daemon not reachable"
  exit 1
fi

if getent hosts "\$nexus_host" >/dev/null 2>&1; then
  record_pass "nexus DNS resolves: \$nexus_host"
else
  record_fail "nexus DNS does not resolve: \$nexus_host"
fi

while IFS= read -r image; do
  [[ -n "\$image" ]] || continue
  log "NEXUS_PULL_START \$image"
  if timeout "\$pull_timeout_seconds" "\$runtime" pull "\$image"; then
    record_pass "nexus pull succeeded: \$image"
  else
    record_fail "nexus pull failed: \$image"
  fi
done < "\$work_dir/nexus-images.txt"

while IFS= read -r image; do
  [[ -n "\$image" ]] || continue
  log "PUBLIC_BLOCK_TEST_START \$image"
  if timeout "\$public_timeout_seconds" "\$runtime" pull "\$image"; then
    record_fail "public registry pull unexpectedly succeeded: \$image"
  else
    record_pass "public registry pull blocked or failed as expected: \$image"
  fi
done < "\$work_dir/public-images.txt"

log "SUMMARY pass=\$pass fail=\$fail"
if [[ "\$fail" -gt 0 ]]; then
  exit 1
fi
EOF
chmod +x "$remote_script"

payload="$(base64 < "$remote_script" | tr -d '\n')"
python3 - "$parameters_json" "$payload" <<'PY'
import json
import sys

path = sys.argv[1]
payload = sys.argv[2]
command = "cat <<'REMOTE_PAYLOAD' | base64 -d | bash\n" + payload + "\nREMOTE_PAYLOAD"
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"commands": [command]}, handle, indent=2)
    handle.write("\n")
PY

{
  echo "instance_id=${instance_id}"
  echo "profile=${aws_profile}"
  echo "region=${aws_region}"
  echo "inventory_dir=${inventory_dir}"
  echo "nexus_host=${nexus_host}"
  echo "runtime=${runtime}"
  echo "nexus_image_count=$(wc -l < "$nexus_images_file" | awk '{print $1}')"
  echo "public_image_count=$(wc -l < "$public_images_file" | awk '{print $1}')"
  echo "dry_run=${dry_run}"
} > "$summary_file"

if [[ "$dry_run" == "1" ]]; then
  echo "[ok] dry-run wrote: $out_dir"
  echo "[ok] remote payload: $remote_script"
  echo "[ok] ssm parameters: $parameters_json"
  exit 0
fi

aws --profile "$aws_profile" --region "$aws_region" ssm send-command \
  --instance-ids "$instance_id" \
  --document-name "AWS-RunShellScript" \
  --comment "container inventory Nexus/public registry verification" \
  --timeout-seconds "$ssm_timeout_seconds" \
  --parameters "file://${parameters_json}" \
  --output json > "$command_json"

command_id="$(python3 - "$command_json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["Command"]["CommandId"])
PY
)"
echo "command_id=${command_id}" >> "$summary_file"
echo "[ok] sent SSM command: ${command_id}"

deadline=$((SECONDS + ssm_timeout_seconds))
status="Pending"
while [[ "$SECONDS" -lt "$deadline" ]]; do
  if aws --profile "$aws_profile" --region "$aws_region" ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --output json > "$invocation_json" 2>"${out_dir}/get-command-invocation.err"; then
    status="$(python3 - "$invocation_json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("Status", "Unknown"))
PY
)"
    case "$status" in
      Success|Cancelled|TimedOut|Failed|Cancelling)
        break
        ;;
    esac
  fi
  sleep 10
done

python3 - "$invocation_json" "$stdout_file" "$stderr_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(data.get("StandardOutputContent", ""))
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    handle.write(data.get("StandardErrorContent", ""))
PY

echo "status=${status}" >> "$summary_file"
echo "[ok] status: ${status}"
echo "[ok] output: ${out_dir}"
[[ "$status" == "Success" ]]
