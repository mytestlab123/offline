
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo ${SCRIPT_DIR}

#set -x
[[ -f "${SCRIPT_DIR}/justfile"    ]] && rsync -a "${SCRIPT_DIR}/justfile" .
[[ -f "${SCRIPT_DIR}/ENV"         ]] && rsync -a "${SCRIPT_DIR}/ENV" ENV
[[ -f "${SCRIPT_DIR}/test.config" ]] && rsync -a "${SCRIPT_DIR}/test.config" conf/
#set +x


