source ENV
echo "Linking..."
SCRIPT_DIR="${HOME}/offline/$PIPELINE"

echo ${SCRIPT_DIR}

[[ -f "${SCRIPT_DIR}/justfile"    ]] && ln -sv "${SCRIPT_DIR}/justfile" "${SCRIPT_DIR}/${PIPELINE}/justfile"
[[ -f "${SCRIPT_DIR}/test.config"    ]] && ln -sv "${SCRIPT_DIR}/test.config" "${SCRIPT_DIR}/${PIPELINE}/conf/test.config"
[[ -f "${SCRIPT_DIR}/ENV"         ]] && ln -sv "${SCRIPT_DIR}/ENV" "${SCRIPT_DIR}/${PIPELINE}/ENV"
