#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

out_root="${OUT_ROOT:-out/container-inventory-test}"
evidence_root="${EVIDENCE_ROOT:-${HOME}/.AGENTS-temp/offline/container-inventory-20260622}"
fixture_dir="${evidence_root}/fixtures"
mkdir -p "$fixture_dir"

write_fixture() {
  local pipeline="$1"
  local json="${fixture_dir}/${pipeline}.inspect.json"
  cat > "$json" <<EOF
{
  "processes": [
    {"name": "${pipeline}:QUAY", "container": "quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0"},
    {"name": "${pipeline}:WAVE", "container": "community.wave.seqera.io/library/scanpy:1.10.2--e83da2205b92a538"},
    {"name": "${pipeline}:DOCKER", "container": "docker.io/nfcore/anndatar:20241129"},
    {"name": "${pipeline}:DOCKER_PREFIX", "container": "docker://docker.io/nfcore/anndatar:20241129"},
    {"name": "${pipeline}:GHCR", "container": "ghcr.io/example/${pipeline}:1.0.0"},
    {"name": "${pipeline}:IMPLICIT", "container": "biocontainers/python:3.9--1"},
    {"name": "${pipeline}:DYNAMIC", "container": "quay.io/example/\${params.dynamic_image}"}
  ]
}
EOF
  echo "$json"
}

for pipeline in demo bamtofastq rnaseq sarek scrnaseq; do
  json="$(write_fixture "$pipeline")"
  common/container-inventory/extract-container-hosts.sh \
    --pipeline "$pipeline" \
    --inspect-json "$json" \
    --out-root "$out_root" \
    --force >/dev/null

  out_dir="${out_root}/${pipeline}"
  test -s "${out_dir}/all.txt"
  test -s "${out_dir}/hosts/quay.io.txt"
  test -s "${out_dir}/hosts/community.wave.seqera.io.txt"
  test -s "${out_dir}/hosts/docker.io.txt"
  test -s "${out_dir}/hosts/ghcr.io.txt"
  test -s "${out_dir}/hosts/dynamic.txt"
  test -s "${out_dir}/hosts/implicit.txt"
  test ! -s "${out_dir}/hosts/unknown.txt"
  grep -q '^host	count	file$' "${out_dir}/summary.tsv"
  grep -q '^host	container$' "${out_dir}/containers.tsv"
  grep -q '^quay.io	1	' "${out_dir}/summary.tsv"
  grep -q '^community.wave.seqera.io	1	' "${out_dir}/summary.tsv"
  grep -q '^docker.io	1	' "${out_dir}/summary.tsv"
  grep -q '^ghcr.io	1	' "${out_dir}/summary.tsv"
  grep -q '^dynamic	1	' "${out_dir}/summary.tsv"
  grep -q '^implicit	1	' "${out_dir}/summary.tsv"
done

mkdir -p "$evidence_root"
cp -a "$out_root" "${evidence_root}/"

echo "[ok] container inventory fixture validation passed for demo, bamtofastq, rnaseq, sarek, scrnaseq"
echo "[ok] evidence: ${evidence_root}"
