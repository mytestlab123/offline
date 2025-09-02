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
3) Verify test config
   - diff -u ../test.config conf/test.config || echo "OK: symlink in place"
4) Check data
   - just check_data
5) Run (online)
   - just preview  or  just stub  or  just test
6) Run (offline)
   - just down; just run

Example 2: rnaseq (complex)
1) Pick quay-only revision (manual, one-time)
   - bash common/quay/select_quay_revision.sh --pipeline rnaseq
2) Set env and stage
   - cd rnaseq; source ~/.env; source ENV
   - ./setup.sh -f; cd rnaseq
3) Verify test config includes S3 inputs
   - rg -n "params\.input|fasta|gtf" conf/test.config
   - diff -u ../test.config conf/test.config || echo "OK: symlink in place"
4) Mirror small test data (optional refresh)
   - bash ../../common/data/mirror_testdata.sh --rows 1 --param-name input --conf ./conf/test.config
5) Check data
   - just check_data
6) Run (online)
   - just preview  or  just stub  or  just test
7) Run (offline)
   - just down; just run

Notes
- Always: source ~/.env; source ENV before running `just` or `setup.sh`.
- S3 sync uses --follow-symlinks and excludes .nextflow/*.
- ARG disables remote config lookups for faster offline runs.
