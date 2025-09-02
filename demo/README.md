# demo — Quick Start (KISS)

- source ~/.env; source ENV
- ./setup.sh -f; cd demo
- just verify_config   # upstream regular file before finalize
- Data prep (optional):
  - just data_input     # samplesheet -> offline/inputs3.csv + S3
  - just check_data
- If you update conf/test.config to S3 URIs: just finalize_config
- Online:  just preview  (or: just stub / just test)
- Offline: just down; just run
- Quay tag (one-time): bash ../../common/quay/select_quay_revision.sh --pipeline demo
