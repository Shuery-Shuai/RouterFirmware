#!/bin/bash
# 文件: bananapi_bpi-r4/scripts/diy-part2.openwrt.sh
# 用途: OpenWrt 构建第二阶段 - 在 feeds install 前执行
#       1. 修改系统默认配置（IP、Shell）
#       2. 创建自定义软件包符号链接
#       3. 修补 LuCI 集合
#       4. 修补 easyupdate.sh (OpenWrt 版)
#       5. 修改 Rust 构建配置
#       6. 添加脚本执行权限
#       7. 固定 dae 版本
#       8. 修复 qBittorrent 依赖（无需重命名）
# 依赖: 通用库 + 各 mods 脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../../common/scripts/libs/functions.sh
source "${SCRIPT_DIR}/libs/functions.sh"
# shellcheck source=../../common/scripts/mods/index.sh
source "${SCRIPT_DIR}/mods/index.sh"

# shellcheck source=libs/functions.sh
source "${SCRIPT_DIR}/libs-bananapi_bpi-r4/functions.sh"
# shellcheck source=mods/index.sh
source "${SCRIPT_DIR}/mods-bananapi_bpi-r4/index.sh"

# ===== 执行第二阶段修改 =====

# 1. 创建符号链接（将 custom-packages 整合进 feeds）
create_symlinks 'custom-packages'

# 2. 系统默认配置
set_default_ip
set_default_shell

# 3. 修改 LuCI 集合（移除多余包、替换主题）
apply_luci_collection_patches

# 4. 修补 easyupdate.sh（OpenWrt 版，不替换固件名称）
patch_easyupdate 'openwrt'

# 5. 修改 Rust 构建配置
modify_rust_build_config

# 6. 添加脚本执行权限
ensure_exec_permission 'files/usr/bin/restore-packages.sh'

# 7. 固定 dae 版本（1.1.0）
set_dae_version "1.1.0" "e2e4207dc110ef21b07d9150272bcedb466ec93b435a6090fea3a946485f2328"

# 8. 修复 qBittorrent 依赖
fix_qbittorrent_deps

log INFO "Part 2 for OpenWrt completed."
