set shell := ["bash","-cu"]

env:
    @echo "NXF_VER=${NXF_VER:-}"; nextflow -version || true

test:
    tests/smoke.sh

container-inventory-test:
    tests/container_inventory.sh

container-inventory-verify-test:
    tests/container_inventory_verify.sh

nfcore-download-smoke:
    common/offline-smoke/nf-core-download-smoke.sh

offline-host-probe:
    common/offline-smoke/nf-core-download-smoke.sh --stages host-probe

offline-inspect-probe:
    common/offline-smoke/nf-core-download-smoke.sh --stages nextflow-inspect

offline-download-probe:
    common/offline-smoke/nf-core-download-smoke.sh --stages download

offline-docker-load-probe:
    common/offline-smoke/nf-core-download-smoke.sh --stages docker-load

offline-run-smoke:
    common/offline-smoke/nf-core-download-smoke.sh --run-smoke

dev-ec2-plan:
    common/aws-validation/create-dev-validation-ec2.sh

dev-sync-repo:
    common/aws-validation/sync-repo-to-s3.sh

dev-stage-tools:
    common/aws-validation/stage-nextflow-tools-to-s3.sh

dev-stage-bundle BUNDLE_DIR:
    common/aws-validation/stage-offline-bundle-to-s3.sh --bundle-dir {{BUNDLE_DIR}}

dev-ec2-smoke INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}}

dev-ec2-host-probe INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages host-tool-s3

dev-ec2-network-probe INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages network-probe

dev-ec2-docker-nexus-probe INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages docker-nexus

dev-ec2-nextflow-inspect-probe INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages nextflow-inspect

dev-ec2-s3-bundle-sync INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages host-tool-s3,s3-bundle-sync

dev-ec2-s3-docker-load INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages host-tool-s3,s3-docker-load

dev-ec2-s3-offline-run INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages host-tool-s3,s3-offline-run

dev-ec2-s3-e2e INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --stages host-tool-s3,s3-bundle-sync,s3-docker-load,s3-offline-run

dev-ec2-full-smoke INSTANCE:
    common/aws-validation/run-dev-ec2-smoke-via-ssm.sh --instance-id {{INSTANCE}} --run-full-smoke

scrna-preview:
    cd scrnaseq/scrnaseq && just preview

scrna-test:
    cd scrnaseq/scrnaseq && just test

scrna-run-offline:
    cd scrnaseq/scrnaseq && just run
