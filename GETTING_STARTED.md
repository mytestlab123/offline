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
   - just verify_config   # should report a regular file before finalize
4) Check data
   - just check_data
5) Run (online)
   - just preview  or  just stub  or  just test
6) Run (offline)
   - just down; just run
8) Verify environment
   - just verify_env; just verify_config
7) Verify environment
   - just verify_env; just verify_config

Example 2: rnaseq (complex)
1) Pick quay-only revision (manual, one-time)
   - bash common/quay/select_quay_revision.sh --pipeline rnaseq
2) Set env and stage
   - cd rnaseq; source ~/.env; source ENV
   - ./setup.sh -f; cd rnaseq
3) Verify test config includes S3 inputs (upstream file)
   - rg -n "params\.input|fasta|gtf" conf/test.config
   - just verify_config
4) Mirror small test data (optional refresh)
   - bash ../../common/data/mirror_testdata.sh --rows 1 --param-name input --conf ./conf/test.config
5) Check data
   - just check_data
6) Run (online)
   - just preview  or  just stub  or  just test
7) Run (offline)
   - just down; just run
7) Verify environment
- just verify_env; just verify_config

Example 3: scrnaseq (scRNA-seq)
1) Pick quay-only revision (manual, one-time)
   - bash common/quay/select_quay_revision.sh --pipeline scrnaseq
2) Set env and stage
   - cd scrnaseq; source ~/.env; source ENV
   - ./setup.sh -f; cd scrnaseq
3) Verify test config includes S3 inputs + refs (upstream file)
   - rg -n "params\.input|fasta|gtf|aligner|protocol" conf/test.config
   - just verify_config
4) Mirror small test data (explicit, one-time per change)
   - just data_input      # samplesheet -> offline/inputs3.csv + S3 upload
   - just data_refs       # fasta + gtf -> S3 upload
   - just check_data
   - Optional: just verify_offline  # ensure S3 URIs present (after you update conf/test.config)
5) Update conf/test.config to point to S3 URIs (input/fasta/gtf) and set offline toggles
6) Finalize test.config (after data is 100% ready)
   - just finalize_config
   - just verify_config   # should report a symlink post-finalize
7) Run (online)
   - just preview  or  just stub  or  just test
8) Run (offline)
   - just down; just run
9) Verify environment
   - just verify_env; just verify_config

 Notes
 - Always: source ~/.env; source ENV before running `just` or `setup.sh`.
 - S3 sync uses --follow-symlinks and excludes .nextflow/*.
 - ARG disables remote config lookups for faster offline runs.
 - Data prep: keep it explicit. Do not run mirroring on every `just online`.
 - test.config flow: setup never modifies `<pipeline>/<pipeline>/conf/test.config` (upstream stays intact for mirroring).
   - After data prep and manual S3 URI updates, run `just finalize_config` to promote conf/test.config to `<pipeline>/test.config` and link back.
   - Verify with `just verify_config` (regular file before finalize, symlink after).
