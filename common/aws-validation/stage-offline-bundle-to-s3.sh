#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/stage-offline-bundle-to-s3.sh --bundle-dir DIR [options]

Purpose:
  Upload a proven nf-core offline bundle to the approved S3 data/artifact path.

Options:
  --profile NAME       Default: ${AWS_PROFILE:-default}
  --region REGION      Default: ${AWS_REGION:-ap-southeast-1}
  --bundle-dir DIR     Required. Example: .../downloads/testpipeline
  --s3-uri URI         Required unless NEXTFLOW_OFFLINE_BUNDLE_S3_URI is set
  --skip-integrity-check
  --validate-only      Run local bundle checks without AWS/S3 access
  --dry-run
  --delete             Remove destination objects not present locally
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
bundle_dir=""
s3_uri="${NEXTFLOW_OFFLINE_BUNDLE_S3_URI:-}"
dry_run="false"
delete_extra="false"
integrity_check="true"
validate_only="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --bundle-dir) bundle_dir="${2:?missing --bundle-dir value}"; shift 2 ;;
    --s3-uri) s3_uri="${2:?missing --s3-uri value}"; shift 2 ;;
    --skip-integrity-check) integrity_check="false"; shift ;;
    --validate-only) validate_only="true"; shift ;;
    --dry-run) dry_run="true"; shift ;;
    --delete) delete_extra="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$bundle_dir" || ! -d "$bundle_dir" ]]; then
  echo "ERROR: --bundle-dir must be an existing directory" >&2
  exit 1
fi

if [[ -z "$s3_uri" && "$validate_only" != "true" ]]; then
  echo "ERROR: --s3-uri or NEXTFLOW_OFFLINE_BUNDLE_S3_URI is required" >&2
  exit 2
fi

if [[ ! -f "$bundle_dir/docker-images/docker-load.sh" ]]; then
  echo "ERROR: expected docker-load.sh missing: $bundle_dir/docker-images/docker-load.sh" >&2
  exit 1
fi

if ! find "$bundle_dir" -maxdepth 1 -type d -name "*_*_*" | grep -q .; then
  echo "ERROR: expected workflow revision directory like 3_2_1 under $bundle_dir" >&2
  exit 1
fi

if [[ "$integrity_check" == "true" ]]; then
  validation_dir="$bundle_dir/.bundle-validation"
  mkdir -p "$validation_dir"
  python3 - "$bundle_dir/docker-images" "$validation_dir" <<'PY'
import hashlib
import json
import os
import sys
import tarfile

docker_dir = sys.argv[1]
validation_dir = sys.argv[2]
errors = []
rows = []
checksums = []

def blob_path_for_digest(digest):
    algo, value = digest.split(":", 1)
    return f"blobs/{algo}/{value}"

tar_paths = sorted(
    os.path.join(docker_dir, name)
    for name in os.listdir(docker_dir)
    if name.endswith(".tar")
)

if not tar_paths:
    errors.append(f"no Docker TAR files found under {docker_dir}")

for path in tar_paths:
    name = os.path.basename(path)
    size = os.path.getsize(path)
    status = "ok"
    with open(path, "rb") as handle:
        checksums.append((hashlib.sha256(handle.read()).hexdigest(), name))
    try:
        with tarfile.open(path, "r:*") as archive:
            members = {member.name for member in archive.getmembers()}

            if "manifest.json" in members:
                manifest = json.load(archive.extractfile("manifest.json"))
                items = manifest if isinstance(manifest, list) else [manifest]
                for item in items:
                    for ref in [item.get("Config"), *item.get("Layers", [])]:
                        if ref and ref not in members:
                            errors.append(f"{name}: manifest reference missing: {ref}")
                            status = "bad"

            if "index.json" in members:
                index = json.load(archive.extractfile("index.json"))
                for item in index.get("manifests", []):
                    digest = item.get("digest", "")
                    if digest.startswith("sha256:"):
                        ref = blob_path_for_digest(digest)
                        if ref not in members:
                            errors.append(f"{name}: index reference missing: {ref}")
                            status = "bad"
                            continue
                        manifest_blob = json.load(archive.extractfile(ref))
                        config_digest = manifest_blob.get("config", {}).get("digest", "")
                        if config_digest.startswith("sha256:"):
                            config_ref = blob_path_for_digest(config_digest)
                            if config_ref not in members:
                                errors.append(f"{name}: config blob missing: {config_ref}")
                                status = "bad"
                        for layer in manifest_blob.get("layers", []):
                            layer_digest = layer.get("digest", "")
                            if layer_digest.startswith("sha256:"):
                                layer_ref = blob_path_for_digest(layer_digest)
                                if layer_ref not in members:
                                    errors.append(f"{name}: layer blob missing: {layer_ref}")
                                    status = "bad"
    except Exception as exc:
        errors.append(f"{name}: unreadable TAR: {exc}")
        status = "bad"
    rows.append((name, str(size), status))

with open(os.path.join(validation_dir, "docker-image-sizes.tsv"), "w", encoding="utf-8") as handle:
    handle.write("file\tsize_bytes\tstatus\n")
    for row in rows:
        handle.write("\t".join(row) + "\n")

with open(os.path.join(validation_dir, "docker-image-sha256sum.txt"), "w", encoding="utf-8") as handle:
    for digest, name in checksums:
        handle.write(f"{digest}  docker-images/{name}\n")

if errors:
    with open(os.path.join(validation_dir, "docker-image-integrity-errors.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(errors) + "\n")
    print("ERROR: Docker TAR integrity validation failed", file=sys.stderr)
    for error in errors[:20]:
        print(error, file=sys.stderr)
    if len(errors) > 20:
        print(f"... {len(errors) - 20} more errors", file=sys.stderr)
    sys.exit(1)

print(f"Validated {len(tar_paths)} Docker TAR files")
PY
fi

if [[ "$validate_only" == "true" ]]; then
  echo "Bundle validation passed: $bundle_dir"
  exit 0
fi

args=(
  s3 sync
  "$bundle_dir/"
  "$s3_uri"
  --region "$region"
  --no-follow-symlinks
)

if [[ "$delete_extra" == "true" ]]; then
  args+=(--delete)
fi

if [[ "$dry_run" == "true" ]]; then
  args+=(--dryrun)
fi

AWS_PROFILE="$profile" aws "${args[@]}"
