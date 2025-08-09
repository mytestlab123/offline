#!/bin/bash
export PIPELINE=bamtofastq
export REVISION=2.1.1
export BUNDLE_DIR="pipe"
#wget https://raw.githubusercontent.com/mytestlab123/offline/refs/heads/main/bamtofastq/justfile
wget https://raw.githubusercontent.com/mytestlab123/offline/refs/heads/main/bamtofastq/prepare_bamtofastq_offline_test.sh
nf-core pipelines download "$PIPELINE" --revision "$REVISION" --container-system none --compress none --outdir "$BUNDLE_DIR" --force
# OR
#just pull
mv pipe/2_1_1 bamtofastq
mkdir -p bamtofastq/offline
mv prepare_bamtofastq_offline_test.sh bamtofastq/offline/
