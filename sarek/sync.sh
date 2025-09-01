
echo "syncing..."
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo ${SCRIPT_DIR}

export OLD=rnaseq
echo OLD: ${OLD}
echo NEW: ${PIPELINE}
#set -x
#sed -i "s/${OLD}/${PIPELINE}/g" ${SCRIPT_DIR}/test.config | grep $PIPELINE
#sed "s/${OLD}/${PIPELINE}/g" "${SCRIPT_DIR}/test.config" | grep $PIPELINE
#set -x
[[ -f "${SCRIPT_DIR}/justfile"    ]] && rsync -a "${SCRIPT_DIR}/justfile" .
[[ -f "${SCRIPT_DIR}/ENV"         ]] && rsync -a "${SCRIPT_DIR}/ENV" ENV
[[ -f "${SCRIPT_DIR}/test.config" ]] && rsync -a "${SCRIPT_DIR}/test.config" conf/
#set +x


