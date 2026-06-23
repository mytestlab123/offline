scrnaseq Progress (Agent-managed)

DONE
- [x] Stage nf-core/scrnaseq@2.7.1 via setup.sh
- [x] Online preview OK with HTTP test data (tests/nextflow.config)
- [x] Remove docs/TASKS.md (use ai/* only)
- [x] Add scrnaseq/data to .gitignore
 - [x] Define scrnaseq/data folder structure and data checklist (ai/data_checklist.md)
 - [x] Online full test (pull images; end-to-end)
 - [x] Review scrnaseq/scrnaseq/conf/test.config and map required params to root test.config (ai/params_map.md)
 - [x] Prepare offline S3 inputs/refs under ${S3_ROOT}/scrnaseq/data/
 - [x] Patch setup.sh to safe-link conf/test.config (OVERWRITE_TEST_CONFIG opt-in)
 - [x] Update GETTING_STARTED with test.config ownership and overwrite behavior

DOING (single current task mirrors ai/current.md)
- [ ] Offline preview/run using private registry

TODO

Notes
- Common justfile updated previously: `-stub-run` fixed and `$EXTRA` added.
- Set `EXTRA` in scrnaseq/ENV for DEV runs as needed.
- Smoke test lives at tests/smoke.sh.
 - Mapped params in ai/params_map.md; added `skip_emptydrops=true` to root test.config.
 - S3 data present: s3://lifebit-user-data-nextflow/offline/scrnaseq/data/ (inputs3.csv, fasta, gtf, fastqs).
 - Smoke test green: `just test` OK; online full test outputs at /tmp/out-scrnaseq; NXF logs at /tmp/runs.log.
