set shell := ["bash","-cu"]

env:
    @echo "NXF_VER=${NXF_VER:-}"; nextflow -version || true

test:
    tests/smoke.sh

scrna-preview:
    cd scrnaseq/scrnaseq && just preview

scrna-test:
    cd scrnaseq/scrnaseq && just test

scrna-run-offline:
    cd scrnaseq/scrnaseq && just run

