#!/bin/bash
# 文件: bananapi_bpi-r4/scripts/diy-part2.immortalwrt.sh
# 用途: ImmortalWrt 构建第二阶段 - 在 feeds install 后执行
#       1. 修改系统默认配置
#       2. 创建符号链接
#       3. 修补 LuCI 集合
#       4. 修补 easyupdate.sh (ImmortalWrt 版，替换固件名称)
#       5. 修改 Rust 构建配置
#       6. 添加执行权限
#       7. 固定 dae 版本
#       8. 重命名 qBittorrent 并修复依赖（ImmortalWrt 专用）
#       9. 固定 fan2go 版本
#      10. 修复 libnl-tiny 编译错误
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

set_default_ip
set_default_shell

create_symlinks 'custom-packages'

apply_luci_collection_patches

# ImmortalWrt 版 easyupdate 补丁
patch_easyupdate_immortalwrt

modify_rust_build_config

ensure_exec_permission 'files/usr/bin/restore-packages.sh'

# 固定 dae 版本
set_dae_version "1.1.0rc1" "726a049813a4d5b800c441ea76ff0ce1846596c180fba0e8ec920a129b3b6e0a"

# ImmortalWrt 专用：重命名 qBittorrent 并修复依赖
patch_qbittorrent_immortalwrt

# 固定 fan2go 版本
set_fan2go_version "0.13.0" "d693bc3ed4c43c8f120433ff17cecca9b98def829e031759373e6ff1ed8def61"

# 修复 libnl-tiny 编译警告
fix_libnl_tiny_compile

log INFO "Part 2 for ImmortalWrt completed."
