#!/usr/bin/env bash
#######################################
# OpenWrt 编译协调脚本
#
# 这是整个构建流程的主入口脚本，负责协调各个子脚本完成完整的固件构建。
# 主要功能包括：
#   - 协调调用各个子脚本，按正确顺序执行构建流程
#   - 管理源码目录的准备和清理
#   - 复制配置文件和编译产物
#
# 完整构建流程：
#   1. 源码管理 (source-management.sh): 克隆或更新源码
#   2. 清理旧构建产物 (bin 目录)
#   3. 复制配置 (copy-pre-files.sh): 复制 DIY 脚本和配置文件
#   4. Feeds 管理 (feeds-management.sh): 更新和安装软件包源
#   5. 配置管理 (config-management.sh): 生成和应用配置
#   6. 编译 (build.sh): 下载源码包并编译
#   7. 复制产物 (copy-bin-files.sh): 复制生成的固件文件
#
# 用法:
#   ./make.sh [firmware] [version] [profile] [ask-menuconfig]
#   ./make.sh [options]
#   ./make.sh --help
#
# 示例:
#   ./make.sh immortalwrt snapshots bananapi_bpi-r4 false
#   ./make.sh --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
#   ./make.sh openwrt 23.05 x86_64 true
#   ./make.sh  # 使用所有默认值
#
# 默认值:
#   firmware       - immortalwrt
#   version        - snapshots
#   profile        - bananapi_bpi-r4
#   ask-menuconfig - false
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 依赖:
#   - common.sh: 提供日志和工具函数
#   - source-management.sh: 源码管理
#   - copy-pre-files.sh: 配置文件复制
#   - feeds-management.sh: Feeds 管理
#   - config-management.sh: 配置管理
#   - build.sh: 编译执行
#   - copy-bin-files.sh: 产物复制
#
# 目录结构:
#   scripts/           - 脚本目录
#   sources/{firmware}/ - 源码目录
#   bin/               - 编译产物输出目录
#
# 作者: Shuery-Shuai
# 版本: 1.0.0
#######################################

set -euo pipefail

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载通用函数库
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

#######################################
# 构建协调主函数
#
# 按正确顺序调用各个子脚本，完成完整的固件构建流程。
# 任何步骤失败都会导致整个构建失败（set -e）。
#
# Globals:
#   SCRIPT_DIR - 当前脚本所在目录（只读）
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Outputs:
#   多级别日志输出到 stderr
#   各个子脚本的输出
#   最终生成的固件文件位于 bin/ 目录
#
# Returns:
#   0 - 构建成功
#   1 - 任何步骤失败
#
# Examples:
#   main "immortalwrt" "snapshots" "bananapi_bpi-r4" "false"
#   main --firmware=openwrt --version=23.05 --profile=x86_64
#   main --help
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "make.sh" \
      "OpenWrt/ImmortalWrt 固件构建协调脚本" \
      "[options] [firmware] [version] [profile] [ask-menuconfig]" \
      "  -h, --help              显示此帮助信息" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: immortalwrt)" \
      "  --version=VER           版本号 (snapshots|23.05|..., 默认: snapshots)" \
      "  --profile=PROF          设备 profile (默认: bananapi_bpi-r4)" \
      "  --ask-menuconfig=BOOL   是否询问运行 menuconfig (true|false, 默认: false)" \
      "" \
      "位置参数:" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)" \
      "  profile                 设备 profile (等同于 --profile)" \
      "  ask-menuconfig          是否询问运行 menuconfig (等同于 --ask-menuconfig)"
    exit 0
  fi

  # 获取参数（优先使用命名参数，其次使用位置参数，最后使用默认值）
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_0]:-immortalwrt}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_1]:-snapshots}}"
  local profile="${PARSED_ARGS['profile']:-${PARSED_ARGS[_POSITIONAL_2]:-bananapi_bpi-r4}}"
  local ask_menuconfig="${PARSED_ARGS['ask-menuconfig']:-${PARSED_ARGS[_POSITIONAL_3]:-false}}"
  local source_parent
  local source_dir

  # 验证参数值
  validate_enum "firmware" "${firmware}" "openwrt" "immortalwrt"
  validate_enum "ask-menuconfig" "${ask_menuconfig}" "true" "false"

  log INFO "开始构建 ${firmware} ${version} [${profile}]"
  log DEBUG "参数: firmware=${firmware}, version=${version}, profile=${profile}, menuconfig=${ask_menuconfig}"

  # 准备源码目录结构
  source_parent="${SCRIPT_DIR}/../sources"
  source_dir="${source_parent}/${firmware}"
  mkdir -p "${source_parent}"
  log DEBUG "源码父目录: ${source_parent}"

  # 步骤 1: 源码管理
  # 克隆或更新指定 firmware 和版本的源码
  "${SCRIPT_DIR}/source-management.sh" "${source_parent}" "${firmware}" "${version}"

  # 步骤 2: 清理旧构建产物
  # 删除上次构建生成的 bin 目录，确保本次构建的产物是全新的
  if [[ -d "${source_dir:?}/bin" ]]; then
    log INFO "清理旧构建产物"
    # 使用 :? 确保变量不为空，防止误删除根目录
    rm -rf "${source_dir:?}/bin"
  fi

  # 步骤 3: 复制配置和脚本
  # 将用户的配置文件、DIY 脚本等复制到源码目录
  log INFO "复制配置文件"
  "${SCRIPT_DIR}/copy-pre-files.sh" "${firmware}" "${version}" "${profile}"

  # 步骤 4: Feeds 管理
  # 更新和安装所有软件包源
  "${SCRIPT_DIR}/feeds-management.sh" "${source_dir}" "${firmware}"

  # 步骤 5: 配置管理
  # 生成默认配置，应用差异配置，可选地运行 menuconfig
  "${SCRIPT_DIR}/config-management.sh" "${source_dir}" "${firmware}" "${version}" "${profile}" "${ask_menuconfig}"

  # 步骤 6: 编译
  # 下载源码包并执行实际的编译过程
  "${SCRIPT_DIR}/build.sh" "${source_dir}"

  # 步骤 7: 复制产物
  # 将编译生成的固件文件复制到输出目录
  log INFO "复制编译产物"
  "${SCRIPT_DIR}/copy-bin-files.sh" "${firmware}" "${version}"

  log INFO "SUCCESS" "构建完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
