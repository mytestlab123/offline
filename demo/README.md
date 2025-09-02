# demo — Quick Start (KISS)

- source ~/.env; source ENV
- ./setup.sh -f; cd demo
- diff -u ../test.config conf/test.config || echo "OK: symlink"
- just check_data
- Online: just preview  (or: just stub / just test)
- Offline: just down; just run
- Optional data refresh: bash ../../common/data/mirror_testdata.sh --rows 1 --param-name input --conf ./conf/test.config
- Quay tag (one-time): bash ../../common/quay/select_quay_revision.sh --pipeline demo
