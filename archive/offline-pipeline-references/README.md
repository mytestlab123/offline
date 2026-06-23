# Offline Pipeline References

These pipeline directories are customized working references for Amit's offline
Nextflow work:

- `demo`
- `bamtofastq`
- `rnaseq`
- `sarek`
- `scrnaseq`

They are not clean upstream nf-core checkouts.

They may contain offline-specific changes such as:

- local `ENV` files
- custom `test.config` files
- private/offline profile assumptions
- S3 input paths
- Nexus/offline container assumptions
- setup or sync behavior needed for AWS/offline execution

Use them as reference material when extracting reusable logic into `common/`.

Before deleting, moving, or replacing any of these directories:

1. compare the directory against the matching upstream pipeline/revision
2. record the offline-specific delta
3. preserve any working input-data and config pattern
4. get Amit approval

Long-term target:

- keep reusable code in `common/`
- keep tiny examples or fixtures in this repo
- move bulky pipeline workspaces only after their offline deltas are documented
