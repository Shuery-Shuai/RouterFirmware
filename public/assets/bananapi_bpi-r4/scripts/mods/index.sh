#!/bin/bash
# 文件: bananapi_bpi-r4/scripts/mods/index.sh
# 用途: 加载 bananapi_bpi-r4/scripts/mods/ 下的设备专用修改脚本
# 用法: source bananapi_bpi-r4/scripts/mods/index.sh
#       在 diy-part 脚本中调用该目录下的任意修改函数

_COMMON_MODS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for script in "${_COMMON_MODS_DIR}"/*.sh; do
    if [[ "$(basename "${script}")" == "index.sh" ]]; then
        continue
    fi

    if [[ -f "${script}" ]]; then
        # shellcheck source=/dev/null
        if ! source "${script}"; then
            log "WARN" "Failed to source ${script}" >&2
            exit 1
        fi
    fi
done

unset _COMMON_MODS_DIR
