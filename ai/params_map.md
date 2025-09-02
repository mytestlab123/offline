scrnaseq Params Mapping

- input: samplesheet CSV
  - conf: `scrnaseq/scrnaseq/conf/test.config`
  - root: `scrnaseq/test.config`
  - value: `s3://lifebit-user-data-nextflow/offline/scrnaseq/data/inputs3.csv`

- outdir: output directory
  - conf/root: `/tmp/out-scrnaseq`

- fasta: genome fasta (chr19 subset)
  - conf/root: `s3://lifebit-user-data-nextflow/offline/scrnaseq/data/GRCm38.p6.genome.chr19.fa`

- gtf: gene annotation (chr19 subset)
  - conf/root: `s3://lifebit-user-data-nextflow/offline/scrnaseq/data/gencode.vM19.annotation.chr19.gtf`

- aligner: primary aligner
  - conf/root: `star`

- protocol: library protocol
  - conf/root: `10XV2`

- skip_emptydrops: disable emptydrops for small test data
  - conf/root: `true`

- offline toggles
  - genome: `null`
  - igenomes_ignore: `true`
  - pipelines_testdata_base_path: `''`
  - custom_config_base: `''`
  - validate_params: `false`

- resources (bounds)
  - max_cpus: `4`
  - max_memory: `4.GB`
  - max_time: `1.h`
  - process.resourceLimits mirrors above

- containers
  - docker.enabled: `true`
  - docker.registry: `nexus-docker-quay.ship.gov.sg` (DEV uses `quay.io` via justfile override)

Notes
- Optional: add `skip_emptydrops = true` for minimal test parity.
- DEV online runs use `tests/nextflow.config` via `EXTRA` in `scrnaseq/ENV`.
- PROD offline runs use profile `test` (loads `conf/test.config`) with `-offline`.

Quick usage
```
cd scrnaseq/scrnaseq
source ../ENV
just preview              # DEV (online, quay)
just down; just run       # PROD (offline, S3 inputs)
```
