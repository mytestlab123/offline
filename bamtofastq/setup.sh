#!/bin/bash
export PIPELINE=bamtofastq
export REVISION=2.1.1
export BUNDLE_DIR="pipe"
nf-core pipelines download "$PIPELINE" --revision "$REVISION" --container-system none --compress none --outdir "$BUNDLE_DIR" --force
mv pipe/2_1_1 bamtofastq
mkdir -p bamtofastq/offline
cp -v justfile bamtofastq
cp -v prepare_bamtofastq_offline_test.sh bamtofastq/offline/
cp -v ENV bamtofastq/.env
