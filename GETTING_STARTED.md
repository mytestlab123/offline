# Getting Started (KISS)

Prereqs
- Tools: nextflow, nf-core, docker, awscli v2, just, rg
- Online Dev has internet; Offline Prod has S3 + Nexus Proxy only

Example 1: demo (basic)
1) Pick quay-only revision (manual, one-time)
   - bash common/quay/select_quay_revision.sh --pipeline demo
   - Note selected tag in /tmp/out/demo/selected_tag.txt
2) Set env and stage
   - cd demo; source ~/.env; source ENV
   - ./setup.sh -f; cd demo
3) Verify test config (upstream)
   - rg -n "params\.(input|contrasts|fasta|gtf)" conf/test.config
4) Check data
   - just check_data
5) Run (online)
   - just preview  or  just stub  or  just test
6) Run (offline)
   - just down; just run
7) Verify environment
   - just verify_env

Example 2: rnaseq (complex)
1) Pick quay-only revision (manual, one-time)
   - bash common/quay/select_quay_revision.sh --pipeline rnaseq
2) Set env and stage
   - cd rnaseq; source ~/.env; source ENV
   - ./setup.sh -f; cd rnaseq
3) Verify test config includes S3 inputs (upstream file)
   - rg -n "params\.(input|fasta|gtf)" conf/test.config
4) Mirror small test data (verified)
   - bash ../../common/data/mirror_testdata.sh --rows 1 --param-name input --conf ./conf/test.config
   - or: `just mirror` then `just check_data` and `just verify_offline`
5) Check data
   - just check_data
6) Run (online)
   - just preview  or  just stub  or  just test
7) Run (offline)
   - just down; just run
7) Verify environment
- just verify_env

Example 3: scrnaseq (scRNA-seq)
1) Pick quay-only revision (manual, one-time)
   - bash common/quay/select_quay_revision.sh --pipeline scrnaseq
2) Set env and stage
   - cd scrnaseq; source ~/.env; source ENV
   - ./setup.sh -f; cd scrnaseq
3) Verify test config includes S3 inputs + refs (upstream file)
   - rg -n "params\.(input|fasta|gtf|aligner|protocol)" conf/test.config
4) Mirror small test data (explicit; verified)
   - just data_input      # samplesheet -> offline/inputs3.csv + S3 upload
   - just data_refs       # fasta + gtf -> S3 upload
   - just mirror          # runs both mirroring steps and uploads contrasts
   - Optional: just verify_offline  # ensure S3 URIs present
5) Edit conf/test.config directly to point to S3 URIs (input/contrasts/fasta/gtf) and set offline toggles
7) Run (online)
   - just preview  or  just stub  or  just test
8) Run (offline)
   - just down; just run
9) Verify environment
   - just verify_env

 Notes
 - Always: source ~/.env; source ENV before running `just` or `setup.sh`.
 - S3 sync uses --follow-symlinks and excludes .nextflow/*.
 - ARG disables remote config lookups for faster offline runs.
 - Data prep: keep it explicit. Do not run mirroring on every `just online`.
 - test.config flow: setup never modifies `<pipeline>/<pipeline>/conf/test.config`; it also writes a one-time backup at `conf/original.test.config`. Edit `conf/test.config` directly.
