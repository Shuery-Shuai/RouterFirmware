#!/usr/bin/env bash
#######################################
# OpenWrt/ImmortalWrt 编译产物复制脚本
#
# 将编译完成的固件文件从源码目录复制到发布目录，支持两种版本布局:
#   1. snapshots 版本: 直接复制 targets 和 packages
#   2. releases 版本: targets 按版本号隔离，packages 按主次版本共享
#
# 目录结构示例:
#   snapshots:
#     public/immortalwrt/snapshots/targets/...
#     public/immortalwrt/snapshots/packages/...
#
#   releases:
#     public/immortalwrt/releases/25.12.0/targets/...
#     public/immortalwrt/releases/packages-25.12/...  (多个修订版共享)
#     public/immortalwrt/releases/25.12.0/packages -> ../packages-25.12 (符号链接)
#
# 用法:
#   ./copy-bin-files.sh [FIRMWARE] [VERSION]
#   ./copy-bin-files.sh [options]
#   ./copy-bin-files.sh --help
#
# Arguments:
#   $1 - 固件类型 (immortalwrt|openwrt，默认: immortalwrt)
#   $2 - 版本号 (snapshots|MAJOR.MINOR.PATCH，默认: snapshots)
#
# 环境变量:
#   无特殊要求，脚本使用相对路径自动定位目录
#
# Examples:
#   ./copy-bin-files.sh immortalwrt snapshots
#   ./copy-bin-files.sh --firmware=immortalwrt --version=snapshots
#   ./copy-bin-files.sh openwrt 23.05.2
#   ./copy-bin-files.sh  # 使用默认值 immortalwrt snapshots
#
# 作者: Shuery-Shuai
# 版本: 1.0.0
#######################################

set -euo pipefail

# 脚本所在目录（绝对路径）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载通用函数库（日志、文件检查等）
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

#######################################
# 从完整版本号提取主次版本
#
# 将三段式版本号 (MAJOR.MINOR.PATCH) 截断为两段 (MAJOR.MINOR)，
# 用于确定 packages 的共享目录名称。
#
# Arguments:
#   $1 - 完整版本号 (格式: MAJOR.MINOR.PATCH)
#
# Outputs:
#   主次版本号 (MAJOR.MINOR) 到 stdout
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   _get_major_minor_version "25.12.0"  # 输出: 25.12
#   _get_major_minor_version "24.10.6"  # 输出: 24.10
#######################################
_get_major_minor_version() {
  local version="$1"
  # 使用参数扩展移除最后一个 . 及其后的内容
  echo "${version%.*}"
}

#######################################
# 主函数 - 复制编译产物到发布目录
#
# 根据版本类型选择不同的复制策略:
#   - snapshots: 完全独立的 targets 和 packages
#   - releases: targets 独立，packages 按主次版本共享（节省空间）
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Globals:
#   SCRIPT_DIR - 脚本所在目录
#
# Outputs:
#   操作进度和结果日志到 stderr (通过 log 函数)
#
# Returns:
#   0 - 复制成功
#   1 - 源目录不存在或其他错误 (通过 require_dir 退出)
#
# Examples:
#   main immortalwrt snapshots
#   main --firmware=openwrt --version=23.05.2
#   main --help
#
# Files Modified:
#   public/${firmware}/${version}/targets/     - 固件镜像文件
#   public/${firmware}/${version}/packages/    - 软件包文件 (snapshots) 或符号链接 (releases)
#   public/${firmware}/releases/packages-X.Y/  - 共享软件包目录 (仅 releases)
#   public/${firmware}/public-key.pem          - 签名公钥 (如果存在)
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "copy-bin-files.sh" \
      "复制编译产物到发布目录" \
      "[options] [firmware] [version]" \
      "  -h, --help              显示此帮助信息" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: immortalwrt)" \
      "  --version=VER           版本号 (snapshots|版本号, 默认: snapshots)" \
      "" \
      "位置参数:" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)"
    exit 0
  fi

  # 获取参数（优先使用命名参数，其次使用位置参数，最后使用默认值）
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_0]:-immortalwrt}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_1]:-snapshots}}"
  local src_dir="${SCRIPT_DIR}/../sources/${firmware}"
  local dst_base="${SCRIPT_DIR}/../public/${firmware}"
  local dst_dir
  local is_snapshot

  # 判断版本类型：snapshots 或 releases
  if [[ "${version}" == "snapshots" ]]; then
    is_snapshot=true
    dst_dir="${dst_base}/snapshots"
  else
    is_snapshot=false
    dst_dir="${dst_base}/releases/${version}"
  fi

  log INFO "复制 ${firmware} ${version} 编译产物"
  log DEBUG "源目录: ${src_dir}"
  log DEBUG "目标基目录: ${dst_dir}"

  # 切换到项目根目录（确保相对路径正确）
  cd "${SCRIPT_DIR}/.."

  # 验证源目录和必需子目录存在
  require_dir "${src_dir}" "源码目录不存在"
  require_dir "${src_dir}/bin/targets" "targets 目录不存在"
  require_dir "${src_dir}/bin/packages" "packages 目录不存在"

  # 清理目标目录中的旧产物（避免混合不同构建的文件）
  if [[ -d "${dst_dir}/targets" || -d "${dst_dir}/packages" ]]; then
    log INFO "清理旧产物"
    rm -rf "${dst_dir}/targets" "${dst_dir}/packages"
  fi

  # 根据版本类型执行不同的复制策略
  if [[ "${is_snapshot}" == "true" ]]; then
    #######################################
    # Snapshots 版本处理
    #
    # 直接复制整个 targets 和 packages 目录，
    # 每次构建的产物完全独立，便于追踪最新开发版本。
    #######################################
    log DEBUG "处理 snapshots 版本"
    mkdir -p "${dst_dir}"

    log DEBUG "复制 targets 目录"
    cp -r "${src_dir}/bin/targets" "${dst_dir}/"

    log DEBUG "复制 packages 目录"
    cp -r "${src_dir}/bin/packages" "${dst_dir}/"

    log INFO "已复制: targets 和 packages"
  else
    #######################################
    # Releases 版本处理
    #
    # 策略:
    #   1. targets 按完整版本号隔离 (每个版本独立目录)
    #   2. packages 按主次版本共享 (同一大版本的修订版共用)
    #   3. 在版本目录中创建符号链接指向共享 packages
    #
    # 优势:
    #   - 节省磁盘空间 (25.12.0/1/2 共享 packages-25.12)
    #   - 保持版本目录结构清晰
    #######################################
    log DEBUG "处理 releases 版本"

    # 提取主次版本号 (如 25.12.0 -> 25.12)
    local major_minor_version
    major_minor_version=$(_get_major_minor_version "${version}")
    local packages_shared="${dst_base}/releases/packages-${major_minor_version}"

    # 复制 targets 到版本特定目录
    mkdir -p "${dst_dir}"
    log DEBUG "复制 targets 目录到 ${dst_dir}/targets"
    cp -r "${src_dir}/bin/targets" "${dst_dir}/"

    # 处理共享 packages 目录
    # 仅在首次遇到该主次版本时复制，后续修订版跳过
    if [[ ! -d "${packages_shared}" ]]; then
      log DEBUG "首次该主次版本，复制 packages 到 ${packages_shared}"
      mkdir -p "$(dirname "${packages_shared}")"
      cp -r "${src_dir}/bin/packages" "${packages_shared}"
      log INFO "已创建共享 packages 目录: packages-${major_minor_version}"
    else
      log DEBUG "共享 packages 目录已存在，跳过复制"
    fi

    # 在版本目录中创建相对符号链接指向共享 packages
    # 链接路径: releases/25.12.0/packages -> ../packages-25.12
    log DEBUG "创建 packages 符号链接: ${dst_dir}/packages → packages-${major_minor_version}"
    mkdir -p "${dst_dir}"
    ln -sf "../packages-${major_minor_version}" "${dst_dir}/packages"
    log INFO "已创建符号链接: ${version}/packages → packages-${major_minor_version}"
  fi

  #######################################
  # 复制签名公钥（可选）
  #
  # 如果源码目录中存在 public-key.pem，则复制到发布根目录。
  # 用于固件签名验证 (usign)。
  #######################################
  if [[ -f "${src_dir}/public-key.pem" ]]; then
    cp "${src_dir}/public-key.pem" "public/${firmware}/public-key.pem"
    log INFO "已复制: public-key.pem"
  else
    log DEBUG "public-key.pem 不存在，跳过"
  fi

  log SUCCESS "编译产物复制完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
