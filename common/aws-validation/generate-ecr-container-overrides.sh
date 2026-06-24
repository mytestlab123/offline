#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/generate-ecr-container-overrides.sh --inspect-json FILE --account-id ID [options]

Purpose:
  Generate a data-driven ECR image manifest and Nextflow container override
  config from `nextflow inspect -format json` output.

Options:
  --inspect-json FILE       Required. Nextflow inspect JSON with process containers.
  --account-id ID           Required. Target AWS account ID for ECR image URIs.
  --region REGION           Default: ${AWS_REGION:-ap-southeast-1}
  --repo-prefix NAME        Default: nextflow-offline/e2e-generic
  --max-cpus N              Default: 1
  --max-memory SIZE         Default: 2 GB
  --out-dir DIR             Default: out/aws-validation/ecr-container-overrides
  --help

Outputs:
  image-manifest.tsv
  nextflow-ecr-containers.config
  source-images.txt
  RESULT.md
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

region="${AWS_REGION:-ap-southeast-1}"
inspect_json=""
account_id=""
repo_prefix="nextflow-offline/e2e-generic"
max_cpus="1"
max_memory="2 GB"
out_dir="out/aws-validation/ecr-container-overrides"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inspect-json) inspect_json="${2:?missing --inspect-json value}"; shift 2 ;;
    --account-id) account_id="${2:?missing --account-id value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --repo-prefix) repo_prefix="${2:?missing --repo-prefix value}"; shift 2 ;;
    --max-cpus) max_cpus="${2:?missing --max-cpus value}"; shift 2 ;;
    --max-memory) max_memory="${2:?missing --max-memory value}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing --out-dir value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$inspect_json" && -f "$inspect_json" ]] || die "--inspect-json must be an existing file"
[[ "$account_id" =~ ^[0-9]{12}$ ]] || die "--account-id must be a 12 digit AWS account ID"
[[ -n "$repo_prefix" ]] || die "--repo-prefix cannot be empty"

need jq
need python3

mkdir -p "$out_dir"

jq -r '
  .processes[]
  | select(.name and .container)
  | [.name, .container]
  | @tsv
' "$inspect_json" > "$out_dir/process-containers.tsv"

if [[ ! -s "$out_dir/process-containers.tsv" ]]; then
  die "inspect JSON does not contain process/container pairs"
fi

python3 - "$out_dir/process-containers.tsv" "$account_id" "$region" "$repo_prefix" "$max_cpus" "$max_memory" "$out_dir" <<'PY'
import csv
import hashlib
import os
import re
import sys

process_tsv, account_id, region, repo_prefix, max_cpus, max_memory, out_dir = sys.argv[1:]
registry = f"{account_id}.dkr.ecr.{region}.amazonaws.com"

def sanitize_repo_part(value):
    value = value.lower()
    value = re.sub(r"[^a-z0-9._/-]+", "-", value)
    value = re.sub(r"/+", "/", value)
    value = re.sub(r"(^[._/-]+|[._/-]+$)", "", value)
    value = re.sub(r"([._-]){2,}", r"\1", value)
    return value or "image"

def sanitize_tag(value):
    value = re.sub(r"[^A-Za-z0-9_.-]+", "-", value)
    value = value.strip(".-")
    if not value or not re.match(r"^[A-Za-z0-9_]", value):
        value = "tag-" + value
    return value[:128]

def parse_image(image):
    image = re.sub(r"^(docker|podman|singularity|oras)://", "", image)
    if "@" in image:
        image_without_digest, digest = image.split("@", 1)
        tag = sanitize_tag(digest.replace(":", "-"))
    else:
        image_without_digest = image
        last = image_without_digest.rsplit("/", 1)[-1]
        if ":" in last:
            image_without_digest, tag = image_without_digest.rsplit(":", 1)
            tag = sanitize_tag(tag)
        else:
            tag = "latest"

    first = image_without_digest.split("/", 1)[0]
    if "." in first or ":" in first or first == "localhost":
        path = image_without_digest.split("/", 1)[1] if "/" in image_without_digest else first
    else:
        path = image_without_digest
    return sanitize_repo_part(path), tag

process_rows = []
images = {}
with open(process_tsv, encoding="utf-8") as handle:
    reader = csv.reader(handle, delimiter="\t")
    for process_name, source_image in reader:
        repo_path, tag = parse_image(source_image)
        digest = hashlib.sha1(source_image.encode("utf-8")).hexdigest()[:10]
        repo_name = f"{repo_prefix.rstrip('/')}/{repo_path}-{digest}"
        ecr_image = f"{registry}/{repo_name}:{tag}"
        images[source_image] = (repo_name, tag, ecr_image)
        process_rows.append((process_name, source_image, ecr_image))

with open(os.path.join(out_dir, "source-images.txt"), "w", encoding="utf-8") as handle:
    for source_image in sorted(images):
        handle.write(source_image + "\n")

with open(os.path.join(out_dir, "image-manifest.tsv"), "w", encoding="utf-8") as handle:
    handle.write("source_image\trepository_name\ttag\tecr_image\n")
    for source_image, (repo_name, tag, ecr_image) in sorted(images.items()):
        handle.write(f"{source_image}\t{repo_name}\t{tag}\t{ecr_image}\n")

with open(os.path.join(out_dir, "nextflow-ecr-containers.config"), "w", encoding="utf-8") as handle:
    handle.write("process {\n")
    handle.write(f"  cpus = {max_cpus}\n")
    handle.write(f"  memory = '{max_memory}'\n\n")
    for label in ["process_single", "process_low", "process_medium", "process_high"]:
        handle.write(f"  withLabel: '{label}' {{\n")
        handle.write(f"    cpus = {max_cpus}\n")
        handle.write(f"    memory = '{max_memory}'\n")
        handle.write("  }\n")
    for process_name, _source_image, ecr_image in sorted(process_rows):
        safe_process = process_name.replace("\\", "\\\\").replace("'", "\\'")
        handle.write(f"  withName: '{safe_process}' {{\n")
        handle.write(f"    cpus = {max_cpus}\n")
        handle.write(f"    memory = '{max_memory}'\n")
        handle.write(f"    container = '{ecr_image}'\n")
        handle.write("  }\n")
    handle.write("}\n")

with open(os.path.join(out_dir, "RESULT.md"), "w", encoding="utf-8") as handle:
    handle.write("# RESULT - ECR Container Overrides\n\n")
    handle.write(f"Processes: {len(process_rows)}\n")
    handle.write(f"Unique images: {len(images)}\n")
    handle.write(f"Region: `{region}`\n")
    handle.write(f"Repo prefix: `{repo_prefix}`\n\n")
    handle.write("Outputs:\n")
    handle.write(f"- `{os.path.join(out_dir, 'image-manifest.tsv')}`\n")
    handle.write(f"- `{os.path.join(out_dir, 'nextflow-ecr-containers.config')}`\n")
    handle.write(f"- `{os.path.join(out_dir, 'source-images.txt')}`\n")

print(f"Generated {len(images)} image mappings for {len(process_rows)} processes")
print(f"Output: {out_dir}")
PY
