# scrnaseq — Quick Start (KISS)

- source ~/.env; source ENV
- (Optional pin) export NXF_VER=24.04.4
- ./setup.sh -f; cd scrnaseq
- rg -n "params\.input|fasta|gtf|aligner|protocol" conf/test.config
- just verify_config   # upstream regular file before finalize
- Data prep (explicit):
  - just data_input      # samplesheet -> offline/inputs3.csv + S3
  - just data_refs       # fasta + gtf -> S3
  - just check_data      # or: just mirror
- Update conf/test.config with S3 URIs for input/fasta/gtf and set offline toggles
- just verify_offline   # optional sanity check for s3:// URIs
- just finalize_config  # promote to ../test.config and link back
- Online:  just preview  (or: just stub / just test)
- Offline: just down; just run
- Quay tag (one-time): bash ../../common/quay/select_quay_revision.sh --pipeline scrnaseq
