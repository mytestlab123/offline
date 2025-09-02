# rnasplice — Quick Start (KISS)

- source ~/.env; source ENV
- ./setup.sh -f; cd rnasplice
- rg -n "params\.(input|contrasts|fasta|gtf)" conf/test.config
- just verify_config   # upstream regular file before finalize
- Data prep (explicit):
  - just data_input           # samplesheet -> offline/inputs3.csv + S3
  - just data_param contrasts # contrasts CSV -> S3
  - just data_refs            # fasta + gtf -> S3
  - just check_data           # or: just mirror
- Update conf/test.config with S3 URIs for input/contrasts/fasta/gtf and set offline toggles
- just verify_offline   # optional sanity check for s3:// URIs (input/fasta/gtf)
- just finalize_config  # promote to ../test.config and link back
- Online:  just preview  (or: just stub / just test)
- Offline: just down; just run
- Quay tag (one-time): bash ../../common/quay/select_quay_revision.sh --pipeline rnasplice
