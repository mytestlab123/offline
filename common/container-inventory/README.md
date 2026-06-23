# Container Inventory

This directory answers one question:

Can a Nextflow pipeline list its container images clearly enough for GCC/offline
validation?

It has two scripts:

- `extract-container-hosts.sh`
  - creates an inventory from `nextflow inspect`, an existing inspect JSON file,
    an existing image list, or a static local source scan
- `verify-nexus-container-access.sh`
  - sends a read/validation command through SSM to a GCC EC2 and verifies Docker
    can pull inventory images through Nexus Proxy while public registries fail

## Extract Containers

Default live inspect:

```bash
common/container-inventory/extract-container-hosts.sh --pipeline sarek --force
```

Use a specific output root:

```bash
common/container-inventory/extract-container-hosts.sh \
  --pipeline rnaseq \
  --out-root out/container-inventory-live \
  --force
```

Use an existing Nextflow inspect JSON:

```bash
common/container-inventory/extract-container-hosts.sh \
  --pipeline demo \
  --inspect-json /path/to/inspect.json \
  --force
```

Use an existing newline-delimited image list:

```bash
common/container-inventory/extract-container-hosts.sh \
  --pipeline demo \
  --input-list /path/to/images.txt \
  --force
```

Static scan fallback:

```bash
common/container-inventory/extract-container-hosts.sh \
  --pipeline scrnaseq \
  --static \
  --force
```

## Five Pipeline Commands

```bash
for pipeline in demo bamtofastq rnaseq sarek scrnaseq; do
  common/container-inventory/extract-container-hosts.sh \
    --pipeline "$pipeline" \
    --out-root out/container-inventory-live \
    --force
done
```

## Output Files

For `--out-root out/container-inventory-live --pipeline sarek`, output goes to:

```text
out/container-inventory-live/sarek/
```

Files:

- `all.txt`
  - unique normalized container strings
- `containers.tsv`
  - two columns: `host`, `container`
- `summary.tsv`
  - one row per host bucket with count and file path
- `metadata.env`
  - pipeline, revision, profile, source, output path
- `hosts/quay.io.txt`
- `hosts/community.wave.seqera.io.txt`
- `hosts/docker.io.txt`
- `hosts/ghcr.io.txt`
- `hosts/dynamic.txt`
- `hosts/implicit.txt`
- `hosts/unknown.txt`
- `raw/inspect.json`
  - raw `nextflow inspect -format json` when live inspect or JSON input is used

Host buckets:

- `quay.io`: explicit Quay images
- `community.wave.seqera.io`: Wave images; not GCC-ready unless separately
  resolved
- `docker.io`: public Docker Hub images
- `ghcr.io`: public GitHub Container Registry images
- `dynamic`: expressions such as `${params.image}` that cannot be proven from a
  static string alone
- `implicit`: images without an explicit registry, for example
  `biocontainers/python:3.9--1`
- `unknown`: malformed or unsupported references

## GCC Nexus Verification

Use this only after an inventory exists and Amit provides the exact EC2 target.

Dry run first:

```bash
common/container-inventory/verify-nexus-container-access.sh \
  --instance-id i-0123456789abcdef0 \
  --profile project-prod \
  --region ap-southeast-1 \
  --inventory-dir out/container-inventory-live/sarek \
  --dry-run
```

Live SSM verification:

```bash
common/container-inventory/verify-nexus-container-access.sh \
  --instance-id i-0123456789abcdef0 \
  --profile project-prod \
  --region ap-southeast-1 \
  --inventory-dir out/container-inventory-live/sarek
```

Defaults:

- Nexus host: `nexus-docker.ship.gov.sg`
- Runtime: `docker`
- Output root: `out/container-inventory-verify`
- Public registries tested for blocked access:
  - `quay.io`
  - `docker.io`
  - `ghcr.io`
  - `community.wave.seqera.io`

The verifier pulls through Nexus by rewriting:

```text
quay.io/biocontainers/fastqc:tag
```

to:

```text
nexus-docker.ship.gov.sg/biocontainers/fastqc:tag
```

It also checks public pulls directly from public registries. In GCC, those
public pulls should fail. If any public pull succeeds, the verification fails.

## Validation

Local validation:

```bash
bash -n common/container-inventory/*.sh tests/container_inventory.sh
shellcheck common/container-inventory/*.sh tests/container_inventory.sh
just container-inventory-test
just container-inventory-verify-test
```

Live extraction was validated for:

```text
demo       3 containers, all quay.io
bamtofastq 5 containers, all quay.io
rnaseq     26 containers, all quay.io
sarek      22 containers, all quay.io
scrnaseq   7 containers, all quay.io
```

## Limitations

- `nextflow inspect` must be available for best results.
- Static scan is a fallback only.
- Dynamic container expressions require human review.
- The SSM verifier leaves pulled images on the EC2 unless a future cleanup mode
  is explicitly added and approved.
- Do not treat public registry failure as complete proof unless the SSM stdout
  and stderr show the expected GCC/no-Internet behavior.
