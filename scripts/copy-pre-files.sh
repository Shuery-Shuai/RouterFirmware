#!/usr/bin/env bash
#######################################
# 复制编译前配置文件
#
# 将固件配置文件、DIY 脚本和额外文件从 public 目录复制到固件源码目录，
# 为后续的固件编译做准备。支持多固件类型、多版本和多设备配置。
#
# 用法:
#   ./copy-pre-files.sh [firmware] [version] [profile]
#   ./copy-pre-files.sh [options]
#   ./copy-pre-files.sh --help
#
# 参数:
#   firmware - 固件类型，默认: immortalwrt
#   version  - 固件版本，默认: snapshots
#   profile  - 设备配置文件名，默认: bananapi_bpi-r4
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 复制的文件包括:
#   - .config            : 主配置文件
#   - diff.config        : 差异配置文件（可选）
#   - diy-part1.sh       : DIY 脚本第一部分
#   - diy-part2.sh       : DIY 脚本第二部分（固件特定）
#   - files/             : 额外文件目录（common + profile 特定）
#
# 示例:
#   ./copy-pre-files.sh immortalwrt snapshots bananapi_bpi-r4
#   ./copy-pre-files.sh --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
#   ./copy-pre-files.sh openwrt 23.05.3
#
# 作者: Shuery-Shuai
# 版本: 1.0.0
#######################################

set -euo pipefail

# 脚本目录路径（绝对路径）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

#######################################
# 主函数
#
# 执行配置文件复制流程：
#   1. 验证源码目录存在
#   2. 复制主配置文件 (.config)
#   3. 复制差异配置文件 (diff.config，可选)
#   4. 复制 DIY 脚本 (diy-part1.sh, diy-part2.sh)
#   5. 同步额外文件 (common 和 profile 特定的 files 目录)
#
# Globals:
#   SCRIPT_DIR - 脚本所在目录的绝对路径
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Outputs:
#   复制过程的详细日志到 stderr
#
# Returns:
#   0 - 复制成功
#   1 - 验证失败或复制过程中出错
#
# Examples:
#   main immortalwrt snapshots bananapi_bpi-r4
#   main --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
#   main --help
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "copy-pre-files.sh" \
      "复制编译前配置文件到源码目录" \
      "[options] [firmware] [version] [profile]" \
      "  -h, --help              显示此帮助信息" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: immortalwrt)" \
      "  --version=VER           版本号 (snapshots|版本号, 默认: snapshots)" \
      "  --profile=PROF          设备 profile (默认: bananapi_bpi-r4)" \
      "" \
      "位置参数:" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)" \
      "  profile                 设备 profile (等同于 --profile)"
    exit 0
  fi

  # 获取参数（优先使用命名参数，其次使用位置参数，最后使用默认值）
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_0]:-immortalwrt}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_1]:-snapshots}}"
  local profile="${PARSED_ARGS['profile']:-${PARSED_ARGS[_POSITIONAL_2]:-bananapi_bpi-r4}}"

  # 计算源目录和目标目录的绝对路径
  local src_dir="${SCRIPT_DIR}/../public"
  local dst_dir="${SCRIPT_DIR}/../sources/${firmware}"

  log INFO "复制 ${firmware} ${version} [${profile}] 配置文件"
  log DEBUG "源目录: ${src_dir}, 目标目录: ${dst_dir}"

  # 切换到项目根目录
  cd "${SCRIPT_DIR}/.."

  # 验证源码目录存在（必须已通过 source-management.sh 创建）
  require_dir "sources/${firmware}" "源码目录不存在"

  #######################################
  # 复制主配置文件
  #######################################
  local config="${src_dir}/assets/${profile}/${firmware}.${version}.config"
  log DEBUG "主配置文件: ${config}"
  require_file "${config}" "配置文件不存在: ${config}"
  cp "${config}" "${dst_dir}/.config"
  log INFO "已复制: .config"

  #######################################
  # 复制差异配置文件（可选）
  #
  # diff.config 用于存储与默认配置的差异，
  # 如果不存在则跳过，不影响后续流程。
  #######################################
  local diff_config="${src_dir}/assets/${profile}/${firmware}.${version}.diff.config"
  if [[ -f "${diff_config}" ]]; then
    cp "${diff_config}" "${dst_dir}/diff.config"
    log INFO "已复制: diff.config"
  else
    log DEBUG "diff.config 不存在，跳过"
  fi

  #######################################
  # 复制 DIY 脚本及其依赖
  #
  # diy-part1.sh: 通用脚本，在 feeds update 之前执行
  # diy-part2.sh: 固件特定脚本，在 feeds install 之后执行
  #######################################
  local libs_dir="${src_dir}/assets/common/scripts/libs"
  local mods_dir="${src_dir}/assets/common/scripts/mods"
  local libs_device_dir="${src_dir}/assets/${profile}/scripts/libs-${profile}"
  local mods_device_dir="${src_dir}/assets/${profile}/scripts/mods-${profile}"
  local diy1="${src_dir}/assets/${profile}/diy-part1.${firmware}.sh"
  local diy2="${src_dir}/assets/${profile}/diy-part2.${firmware}.sh"
  require_dir "${libs_dir}" "libs 目录不存在"
  require_dir "${mods_dir}" "mods 目录不存在"
  require_dir "${libs_device_dir}" "libs-${profile} 目录不存在"
  require_dir "${mods_device_dir}" "mods-${profile} 目录不存在"
  require_file "${diy1}" "diy-part1.${firmware}.sh 不存在"
  require_file "${diy2}" "diy-part2.${firmware}.sh 不存在"

  cp -r "${libs_dir}"/*.sh "${dst_dir}/scripts/libs/"
  cp -r "${mods_dir}"/*.sh "${dst_dir}/scripts/mods/"
  cp -r "${libs_device_dir}"/*.sh "${dst_dir}/scripts/libs-${profile}/"
  cp -r "${mods_device_dir}"/*.sh "${dst_dir}/scripts/mods-${profile}/"
  cp "${diy1}" "${dst_dir}/diy-part1.sh"
  cp "${diy2}" "${dst_dir}/diy-part2.sh"
  log INFO "已复制: DIY 脚本"

  #######################################
  # 同步额外文件
  #
  # 使用 rsync 同步文件目录，排除 index.html 以避免覆盖固件自带的索引页。
  # 先同步 common 目录（所有设备通用），再同步 profile 特定目录（可覆盖通用文件）。
  #
  # 同步顺序很重要:
  #   1. common/files/     - 所有设备的通用文件
  #   2. ${profile}/files/ - 特定设备的文件（优先级更高）
  #######################################
  log INFO "同步额外文件"

  # 同步通用文件
  if [[ -d "${src_dir}/assets/common/files" ]]; then
    if ! rsync -a --exclude='index.html' "${src_dir}/assets/common/files/" "${dst_dir}/files" 2>&1; then
      log FATAL "同步 common 文件失败"
      log ERROR "源: ${src_dir}/assets/common/files/"
      log ERROR "目标: ${dst_dir}/files"
      exit 1
    fi
  else
    log INFO "未找到 common/files 目录，跳过通用额外文件同步"
  fi

  # 同步设备特定文件
  if [[ -d "${src_dir}/assets/${profile}/files" ]]; then
    if ! rsync -a --exclude='index.html' "${src_dir}/assets/${profile}/files/" "${dst_dir}/files" 2>&1; then
      log FATAL "同步 ${profile} 文件失败"
      log ERROR "源: ${src_dir}/assets/${profile}/files/"
      log ERROR "目标: ${dst_dir}/files"
      exit 1
    fi
  else
    log INFO "未找到 ${profile}/files 目录，跳过设备特定额外文件同步"
  fi

  log INFO "已同步: 额外文件"

  log INFO "SUCCESS" "配置文件复制完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
