Progress (Agent-managed)

DONE
- [x] Stage nf-core/scrnaseq@2.7.1 via setup.sh
- [x] Online preview OK with HTTP test data (tests/nextflow.config)
- [x] Remove docs/TASKS.md (use ai/* only)
- [x] Add scrnaseq/data to .gitignore
- [x] Define scrnaseq/data folder structure and data checklist (ai/data_checklist.md)
- [x] Online full test (pull images; end-to-end)
- [x] Review scrnaseq/scrnaseq/conf/test.config and map required params to root test.config (ai/params_map.md)
- [x] Prepare offline S3 inputs/refs under ${S3_ROOT}/scrnaseq/data/
- [x] Update setup.sh to never modify conf/test.config; create one-time backup at conf/original.test.config
- [x] rnasplice: conf/test.config switched to ENV S3; inputs under samplesheet/, refs under reference/
- [x] rnasplice: mirror scripts enhanced (TMPDIR, --dest-subdir); one-command mirroring works
- [x] rnasplice: removed legacy offline/offline_test.conf; setup.sh preserves conf/test.config
- [x] rnasplice: validation — `just mirror` + `just check_data` green
- [x] sarek: validation — `just mirror` + `just check_data` green (refs skipped)
- [x] rnaseq: validation — `just mirror` + `just check_data` green
 - [x] Data mirror verified by Amit on 2025‑09‑03 (PR #14)
 - [x] rnaseq: conf/test.config uses data/samplesheet/inputs3.csv; refs kept at data/* for DEV (no write to public S3)

DOING (single current task mirrors ai/current.md)
- [ ] Document rnasplice + rnaseq in ai/data_checklist.md and ai/params_map.md

TODO
- [ ] Switch rnaseq to `${pipelines_testdata_base_path}/reference/*` in private PROD S3 (requires write access)
- [ ] Optional: add DRY_RUN to mirror scripts; add strict S3 object presence check target

Links
- PR #14: https://github.com/mytestlab123/offline/pull/14

Notes
- Common justfile previously updated: `-stub-run` fixed and `$EXTRA` added
- Smoke test lives at tests/smoke.sh
- TMPDIR honored by mirroring to avoid /tmp issues
- Legacy flat files in S3 may remain; safe to ignore or clean later
