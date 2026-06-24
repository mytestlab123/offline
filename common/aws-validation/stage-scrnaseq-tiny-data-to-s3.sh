#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  common/aws-validation/stage-scrnaseq-tiny-data-to-s3.sh --s3-uri URI [options]

Purpose:
  Create and stage a tiny deterministic nf-core/scrnaseq input dataset for
  private ECR smoke validation.

Options:
  --profile NAME       Default: ${AWS_PROFILE:-default}
  --region REGION      Default: ${AWS_REGION:-ap-southeast-1}
  --work-dir DIR       Default: ~/.AGENTS-temp/offline/scrnaseq-tiny-data-<timestamp>
  --s3-uri URI         Required unless NEXTFLOW_OFFLINE_SCRNASEQ_TINY_DATA_S3_URI is set.
  --dry-run            Show planned sync only.
  --help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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
work_dir="$HOME/.AGENTS-temp/offline/scrnaseq-tiny-data-$(date +%Y%m%d-%H%M%S)"
s3_uri="${NEXTFLOW_OFFLINE_SCRNASEQ_TINY_DATA_S3_URI:-}"
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?missing --profile value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --work-dir) work_dir="${2:?missing --work-dir value}"; shift 2 ;;
    --s3-uri) s3_uri="${2:?missing --s3-uri value}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$s3_uri" && "$s3_uri" == s3://* ]] || die "--s3-uri must be an s3:// URI"

data_dir="$work_dir/data"
mkdir -p "$data_dir"

cat > "$data_dir/genome.fasta" <<'EOF'
>chrTiny
GATTACAGCTAGTCGATCGGATCCTAGGCTAACCGTTAAGCTGATCGATGCACTGACCGTATCGATGCTAGCTAGGATCGTACCGATGACCTAGTACGATCGTAGCTACGATGCTAGCTAGCTGACTA
EOF

cat > "$data_dir/genes.gtf" <<'EOF'
chrTiny	tiny	gene	1	128	.	+	.	gene_id "gene1"; gene_name "gene1"; gene_biotype "protein_coding";
chrTiny	tiny	transcript	1	128	.	+	.	gene_id "gene1"; transcript_id "tx1"; gene_name "gene1"; gene_biotype "protein_coding";
chrTiny	tiny	exon	1	128	.	+	.	gene_id "gene1"; transcript_id "tx1"; exon_number "1"; gene_name "gene1"; gene_biotype "protein_coding";
EOF

make_fastq() {
  local path="$1"
  local sequence="$2"
  local quality="$3"
  {
    for i in $(seq 1 20); do
      printf '@tiny_%02d\n%s\n+\n%s\n' "$i" "$sequence" "$quality"
    done
  } | gzip -c > "$path"
}

make_r1_fastq() {
  local path="$1"
  local barcode="AAACCTGAGAAACCAT"
  local quality="IIIIIIIIIIIIIIIIIIIIIIIIII"
  local -a umis=(
    ACGTACGTAC TGCATGCATG GATCGATCGA CTAGCTAGCT AGTCAGTCAG
    TCAGTCAGTC CGTACGTACG TACGTACGTA GCTAGCTAGC ATCGATCGAT
    CAGTCAGTCA GTACGTACGT TCGATCGATC AGCTAGCTAG CATGCATGCA
    GCATGCATGC ATGCTAGCTA TAGCTAGCTA CGATCGATCG GTCAGTCAGT
  )

  {
    local i umi
    for i in "${!umis[@]}"; do
      umi="${umis[$i]}"
      printf '@tiny_%02d\n%s%s\n+\n%s\n' "$((i + 1))" "$barcode" "$umi" "$quality"
    done
  } | gzip -c > "$path"
}

# R1 is 10xV2 cell barcode plus UMI: 16 bp whitelist barcode + 10 bp UMI.
make_r1_fastq "$data_dir/tiny_R1.fastq.gz"
make_fastq "$data_dir/tiny_R2.fastq.gz" "GATTACAGCTAGTCGATCGGATCCTAGGCTAACCGTTAAGCTGATCGA" "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII"

cat > "$data_dir/README.md" <<'EOF'
# Tiny scrnaseq validation dataset

Purpose: deterministic private ECR smoke validation, not scientific analysis.

Files:
- `tiny_R1.fastq.gz`
- `tiny_R2.fastq.gz`
- `genome.fasta`
- `genes.gtf`

The EC2 runner writes the final samplesheet with local EC2 paths after syncing
this directory from S3.
EOF

args=(s3 cp "$data_dir/" "$s3_uri" --recursive --region "$region" --no-follow-symlinks)
if [[ "$dry_run" == "true" ]]; then
  args+=(--dryrun)
fi

AWS_PROFILE="$profile" aws "${args[@]}"

cat > "$work_dir/RESULT.md" <<RESULT
# RESULT - scrnaseq Tiny Data Staging

Status: staged

Profile/region:
- $profile / $region

S3:
- $s3_uri

Local data:
- $data_dir

Files:
- tiny_R1.fastq.gz
- tiny_R2.fastq.gz
- genome.fasta
- genes.gtf
RESULT

cat "$work_dir/RESULT.md"
