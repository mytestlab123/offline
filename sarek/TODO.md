Sarek TODO (KISS)

- [ ] Verify ENV has PIPELINE, REVISION, S3_ROOT, ROOT_DIR, NXF_* set
- [ ] Online smoke: `just preview` (quay override)
- [ ] Upload code: `just up`
- [ ] Download code: `just down`
- [ ] Offline run: `just run`
- [ ] Optional: `just stub` / `just stub2` for quick checks

Notes
- Single ENV file: this folder’s `ENV`. Optionally: `source ~/.env; source ENV` before runs.
- `ARG` disables remote config lookups to speed up offline runs.
