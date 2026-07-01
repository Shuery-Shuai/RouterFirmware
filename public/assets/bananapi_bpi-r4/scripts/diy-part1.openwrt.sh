#!/bin/bash
# 文件: bananapi_bpi-r4/scripts/diy-part1.openwrt.sh
# 用途: OpenWrt 构建第一阶段 - 在 feeds update 前执行
#       1. 修改 BPI‑R4 分区布局
#       2. 添加 XDP sockets 内核模块支持
#       3. 克隆第三方软件包仓库（OpenWrt 特有列表）
# 依赖: 通用库 common/scripts/libs/functions.sh
#       设备库 bananapi_bpi-r4/scripts/libs/functions.sh
#       通用修改索引 common/scripts/mods/index.sh
#       设备修改索引 bananapi_bpi-r4/scripts/mods/index.sh

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载通用函数库（提供 log、clone_repo 等）
# shellcheck source=../../common/scripts/libs/functions.sh
source "${SCRIPT_DIR}/libs/functions.sh"
# 加载通用修改索引（目前可能为空，预留给后续统一入口）
# shellcheck source=../../common/scripts/mods/index.sh
source "${SCRIPT_DIR}/mods/index.sh"

# 加载 BPI‑R4 专用函数库（提供 modify_bpi_r4_partition）
# shellcheck source=libs/functions.sh
source "${SCRIPT_DIR}/libs-bananapi_bpi-r4/functions.sh"
# 加载 BPI‑R4 专用修改索引（目前可能为空）
# shellcheck source=mods/index.sh
source "${SCRIPT_DIR}/mods-bananapi_bpi-r4/index.sh"

# ===== 执行第一阶段修改 =====

# 1. 扩展固件分区（+50MB）
# modify_bpi_r4_partition 50

# 2. 添加 XDP sockets 内核模块支持（通用功能，位于 common/scripts/mods/ 下）
add_xdp_sockets_diag

# 3. 克隆 OpenWrt 专属的第三方软件包仓库
#    这里直接使用 clone_repo，列出所有必需的仓库（与原始脚本一致）
log INFO "Cloning third-party packages for OpenWrt..."

# BPI-R4 PWM 风扇控制
clone_repo 'https://github.com/anoixa/bpi-r4-pwm-fan' \
    'main' \
    '--depth=1' \
    'custom-packages/bpi-r4-pwm-fan'

# ImmortalWrt LuCI 仓库（稀疏克隆：dae/daed）
clone_repo 'https://github.com/immortalwrt/luci' \
    'master' \
    '--filter=blob:none --sparse --depth=1' \
    'custom-packages/luci'
(
    cd 'custom-packages/luci' || exit 1
    git sparse-checkout set applications/luci-app-dae applications/luci-app-daed
)

# Argon 主题配置应用
clone_repo 'https://github.com/jerrykuku/luci-app-argon-config' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-argon-config'

# DDNS-Go 动态域名解析
clone_repo 'https://github.com/sirpdboy/luci-app-ddns-go' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-ddns-go'

# 磁盘管理工具
clone_repo 'https://github.com/lisaac/luci-app-diskman' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-diskman'

# 风扇控制应用
clone_repo 'https://github.com/rockjake/luci-app-fancontrol' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-fancontrol'

# FanXpert 风扇控制应用
clone_repo 'https://github.com/Shuery-Shuai/LuciFanXpert' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-fanxpert'

# Lucky 网络工具
clone_repo 'https://github.com/gdy666/luci-app-lucky' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-lucky'

# Nginx 管理应用
clone_repo 'https://github.com/zhanghua000/luci-app-nginx' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-nginx'

# ZeroTier 虚拟局域网
clone_repo 'https://github.com/zhengmz/luci-app-zerotier' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-zerotier'

# Argon 主题
clone_repo 'https://github.com/jerrykuku/luci-theme-argon' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-theme-argon'

# OpenClash 代理管理工具
clone_repo 'https://github.com/vernesong/OpenClash' \
    'dev' \
    '--depth=1' \
    'custom-packages/openclash'

# ImmortalWrt 软件包仓库（稀疏克隆：golang、dae、daed）
clone_repo 'https://github.com/immortalwrt/packages' \
    'master' \
    '--filter=blob:none --sparse --depth=1' \
    'custom-packages/packages'
(
    cd 'custom-packages/packages' || exit 1
    git sparse-checkout set lang/golang net/dae net/daed
)

# qBittorrent BT 下载工具
clone_repo 'https://github.com/sbwml/openwrt-qBittorrent' \
    'master' \
    '--depth=1' \
    'custom-packages/qbittorrent'

# SunDaqiang的软件包备份仓库
clone_repo 'https://github.com/sundaqiang/openwrt-packages-backup' \
    'main' \
    '--depth=1' \
    'custom-packages/sundaqiang'

log INFO "Part 1 for OpenWrt completed."
