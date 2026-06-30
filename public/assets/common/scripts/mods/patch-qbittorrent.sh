#!/bin/bash
# 文件: common/scripts/mods/patch-qbittorrent.sh
# 用途: 针对 ImmortalWrt 构建，解决第三方 qBittorrent 与自带版本冲突的问题
#       1. 将第三方 luci-app-qbittorrent 重命名为 luci-app-qbittorrent-original
#       2. 修复 qBittorrent Makefile 中的 libtorrent 依赖 (rblibtorrent -> libtorrent-rasterbar)
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若无 common 库，脚本内置了简单的日志后备
# 用法:
#   source common/scripts/mods/patch-qbittorrent.sh
#   patch_qbittorrent [custom_base_dir]
#
# 参数:
#   custom_base_dir : 自定义软件包根目录，默认为 'custom-packages/qbittorrent'
# 返回值:
#   0 成功 (无论目录是否存在都会正常返回)
#   1 当目标路径不存在时仅打印警告，不返回错误码
#######################################

# 如果未定义 log (即未加载 common)，提供后备日志函数
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 应用 ImmortalWrt 专属 qBittorrent 补丁
#
# 功能:
#   1. 检查是否存在 luci-app-qbittorrent 目录，若存在则将其重命名为 luci-app-qbittorrent-original
#   2. 修改 qbittorrent 核心包的 Makefile，确保依赖为 +libtorrent-rasterbar
#      - 如果已有正确的依赖则跳过
#      - 如果存在旧依赖 +rblibtorrent，则替换
#      - 若都不存在，则在 DEPENDS 行末尾追加
#
# Globals:
#   None
#
# Arguments:
#   $1 - (可选) qbittorrent 自定义软件包的基础路径，默认为 'custom-packages/qbittorrent'
#
# Outputs:
#   操作详情到 stderr (通过 log)
#
# Returns:
#   0 - 完成 (即使目录不存在也不会报错退出)
#
# Examples:
#   patch_qbittorrent
#   patch_qbittorrent 'custom-packages/qbittorrent'
#######################################
patch_qbittorrent() {
    local base_path="${1:-custom-packages/qbittorrent}"

    # 检查基础路径是否存在
    if [[ ! -d "${base_path}" ]]; then
        log WARN "qBittorrent directory not found: ${base_path}, skipping ImmortalWrt qBittorrent patch."
        return 0
    fi

    log INFO "Applying ImmortalWrt qBittorrent patch on ${base_path}..."

    # --- 1. 重命名 LuCI 应用以避免与自带的 luci-app-qbittorrent 冲突 ---
    local luci_original="${base_path}/luci-app-qbittorrent"
    local luci_renamed="${base_path}/luci-app-qbittorrent-original"

    if [[ -d "${luci_original}" ]]; then
        log INFO "Renaming ${luci_original} -> ${luci_renamed}"
        mv "${luci_original}" "${luci_renamed}"

        # 修改 Makefile 内部引用，确保名称一致
        local renamed_makefile="${luci_renamed}/Makefile"
        if [[ -f "${renamed_makefile}" ]]; then
            sed -i 's/luci-app-qbittorrent/luci-app-qbittorrent-original/g' "${renamed_makefile}"
            log INFO "Updated Makefile references in ${renamed_makefile}"
        else
            log WARN "Makefile not found in renamed directory, manual check may be needed."
        fi
    else
        log INFO "No luci-app-qbittorrent directory found; either already renamed or using original ImmortalWrt package."
    fi

    # --- 2. 修复 qbittorrent 核心包的依赖 (libtorrent) ---
    local qbit_makefile="${base_path}/qbittorrent/Makefile"

    if [[ ! -f "${qbit_makefile}" ]]; then
        log WARN "qBittorrent core Makefile not found: ${qbit_makefile}, skipping dependency fix."
        return 0
    fi

    if grep -q '+libtorrent-rasterbar' "${qbit_makefile}"; then
        log INFO "Dependency +libtorrent-rasterbar already present, nothing to do."
    elif grep -q '+rblibtorrent' "${qbit_makefile}"; then
        log INFO "Replacing legacy +rblibtorrent with +libtorrent-rasterbar..."
        sed -i 's/+rblibtorrent/+libtorrent-rasterbar/g' "${qbit_makefile}"
        log INFO "Replacement done."
    else
        # 依赖行完全缺失，尝试追加到 DEPENDS 行
        if grep -q 'DEPENDS:=' "${qbit_makefile}"; then
            log INFO "Adding +libtorrent-rasterbar to DEPENDS line..."
            sed -i '/define Package\/qbittorrent/,/^endef/{
                /DEPENDS:=/ s/$/ +libtorrent-rasterbar/
            }' "${qbit_makefile}"
            log INFO "Added +libtorrent-rasterbar to DEPENDS."
        else
            log WARN "Cannot locate DEPENDS line in ${qbit_makefile}; you may need to manually add +libtorrent-rasterbar."
        fi
    fi

    log INFO "ImmortalWrt qBittorrent patch completed."
}

# 若直接运行脚本，则执行默认补丁
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    patch_qbittorrent "$@"
fi
