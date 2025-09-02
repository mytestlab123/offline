scrnaseq Data Checklist (DEV/PROD)

Required files (minimal test set)
- inputs3.csv: Samplesheet (1–N rows) for test run
- GRCm38.p6.genome.chr19.fa: FASTA (chr19 subset)
- gencode.vM19.annotation.chr19.gtf: GTF (chr19 subset)

Local layout (ignored by git)
- scrnaseq/data/inputs/inputs3.csv
- scrnaseq/data/refs/GRCm38.p6.genome.chr19.fa
- scrnaseq/data/refs/gencode.vM19.annotation.chr19.gtf

DEV (online) — populate local data
```
mkdir -p ~/offline/scrnaseq/data/{inputs,refs}
curl -fsSL -o ~/offline/scrnaseq/data/inputs/inputs3.csv \
  https://raw.githubusercontent.com/nf-core/test-datasets/scrnaseq/samplesheet-2-0.csv
curl -fsSL -o ~/offline/scrnaseq/data/refs/GRCm38.p6.genome.chr19.fa \
  https://raw.githubusercontent.com/nf-core/test-datasets/scrnaseq/reference/GRCm38.p6.genome.chr19.fa
curl -fsSL -o ~/offline/scrnaseq/data/refs/gencode.vM19.annotation.chr19.gtf \
  https://raw.githubusercontent.com/nf-core/test-datasets/scrnaseq/reference/gencode.vM19.annotation.chr19.gtf
```

Mirror to S3 for PROD (offline-first)
```
# Set once per env
export S3_ROOT=s3://<your-bucket>/offline

cd ~/offline/scrnaseq/scrnaseq
ROWS=1 S3_ROOT="$S3_ROOT" PIPELINE=scrnaseq \
  bash ../../common/data/mirror_testdata.sh --rows 1 --param-name input --conf tests/nextflow.config

# Optional: copy mirrored objects locally (if desired)
aws s3 cp "$S3_ROOT/scrnaseq/data/inputs3.csv"       ~/offline/scrnaseq/data/inputs/inputs3.csv
aws s3 cp "$S3_ROOT/scrnaseq/data/GRCm38.p6.genome.chr19.fa" \
         ~/offline/scrnaseq/data/refs/GRCm38.p6.genome.chr19.fa
aws s3 cp "$S3_ROOT/scrnaseq/data/gencode.vM19.annotation.chr19.gtf" \
         ~/offline/scrnaseq/data/refs/gencode.vM19.annotation.chr19.gtf
```

Quick check
```
ls -lh ~/offline/scrnaseq/data/inputs/inputs3.csv \
       ~/offline/scrnaseq/data/refs/GRCm38.p6.genome.chr19.fa \
       ~/offline/scrnaseq/data/refs/gencode.vM19.annotation.chr19.gtf
```

Notes
- Offline runs should point params.input/fasta/gtf to private S3 or local paths.
- Registry should be Nexus/Quay per ENV; no Docker Hub.
