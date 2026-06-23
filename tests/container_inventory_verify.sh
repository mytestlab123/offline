#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fixture_root="out/container-inventory-verify-fixture"
verify_root="out/container-inventory-verify-test"
rm -rf "$fixture_root" "$verify_root"

mkdir -p "$fixture_root/demo/hosts" "$fixture_root/demo/raw"
cat > "$fixture_root/demo/containers.tsv" <<'EOF'
host	container
quay.io	quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0
implicit	biocontainers/python:3.9--1
dynamic	quay.io/example/${params.dynamic_image}
EOF

common/container-inventory/verify-nexus-container-access.sh \
  --instance-id i-0123456789abcdef0 \
  --profile dryrun \
  --region ap-southeast-1 \
  --inventory-dir "$fixture_root/demo" \
  --out-root "$verify_root" \
  --dry-run >/dev/null

out_dir="$verify_root/i-0123456789abcdef0"
test -s "$out_dir/nexus-images.txt"
test -s "$out_dir/public-images.txt"
test -s "$out_dir/remote-command.sh"
test -s "$out_dir/send-command-parameters.json"
test -s "$out_dir/summary.env"

grep -q '^nexus-docker.ship.gov.sg/biocontainers/fastqc:' "$out_dir/nexus-images.txt"
grep -q '^nexus-docker.ship.gov.sg/biocontainers/python:' "$out_dir/nexus-images.txt"
if grep -q 'params.dynamic_image' "$out_dir/nexus-images.txt"; then
  echo "dynamic image should not be added to Nexus pull list" >&2
  exit 1
fi
grep -q '^quay.io/' "$out_dir/public-images.txt"
grep -q '^docker.io/' "$out_dir/public-images.txt"
grep -q '^ghcr.io/' "$out_dir/public-images.txt"
grep -q '^community.wave.seqera.io/' "$out_dir/public-images.txt"

python3 -m json.tool "$out_dir/send-command-parameters.json" >/dev/null

echo "[ok] container inventory Nexus verifier dry-run validation passed"
