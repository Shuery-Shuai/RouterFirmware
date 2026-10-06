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
      "  --non-interactive       强制非交互：所有提示取默认值（CI 无 TTY 时自动生效）" \
      "  --prompt-timeout=SEC    交互提示超时秒数 (0=永不超时, 默认: 60)" \
      "  --no-log-file           关闭文件日志 (默认: 本地开启 logs/build-<时间戳>.log, CI 关闭)" \
      "  --capture-build-log[=PATH] 留存 make 原始输出 (默认: 本地开启 logs/build-<时间戳>.make.log, CI 关闭)" \
      "  --no-capture-build-log  关闭原始输出留存 (磁盘紧张时使用)" \
      "  --allow-diy-failure     允许 diy-part1/2.sh 失败后继续 (默认: 失败即终止构建)" \
      "  --retry-count=N         编译失败后并行重试次数 (默认: 2；共享挂载上的抖动重试即成功)" \
      "  --serial-retry-count=N  并行重试仍失败后的单线程重试次数 (默认: 1，0=不做单线程重试)" \
      "  --jobs=N                编译并行度 (默认: 系统核数；资源竞争或内存受限时调低)" \
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

  # 交互控制：子脚本通过环境变量继承（由 config-management.sh 消费）
  if [[ "${PARSED_ARGS['non-interactive']:-}" == "true" ]]; then
    NON_INTERACTIVE="true"
    export NON_INTERACTIVE
  fi
  PROMPT_TIMEOUT="${PARSED_ARGS['prompt-timeout']:-60}"
  export PROMPT_TIMEOUT

  # 文件日志：common.sh 已按环境取默认（本地开启 / CI 关闭），这里只处理显式关闭
  if [[ "${PARSED_ARGS['no-log-file']:-}" == "true" ]]; then
    LOG_TO_FILE="false"
    export LOG_TO_FILE
  fi
  if [[ "${LOG_TO_FILE}" == "true" ]]; then
    log INFO "日志文件: ${LOG_FILE_PATH}"
  fi

  # 构建原始输出留存：默认由 common.sh 按环境决定（本地开 / CI 关）
  if [[ -n "${PARSED_ARGS['capture-build-log']:-}" ]]; then
    CAPTURE_BUILD_LOG="true"
    export CAPTURE_BUILD_LOG
    if [[ "${PARSED_ARGS['capture-build-log']}" != "true" ]]; then
      CAPTURE_BUILD_LOG_PATH="${PARSED_ARGS['capture-build-log']}"
      export CAPTURE_BUILD_LOG_PATH
    fi
  fi
  if [[ "${PARSED_ARGS['no-capture-build-log']:-}" == "true" ]]; then
    CAPTURE_BUILD_LOG="false"
    export CAPTURE_BUILD_LOG
  fi

  # DIY 脚本失败语义（由 feeds-management.sh 消费）
  if [[ "${PARSED_ARGS['allow-diy-failure']:-}" == "true" ]]; then
    ALLOW_DIY_FAILURE="true"
    export ALLOW_DIY_FAILURE
  fi

  # 编译失败后的重试策略（由 build.sh 消费）：先并行重试，再单线程重试
  RETRY_COUNT="${PARSED_ARGS['retry-count']:-2}"
  export RETRY_COUNT
  SERIAL_RETRY_COUNT="${PARSED_ARGS['serial-retry-count']:-1}"
  export SERIAL_RETRY_COUNT

  # 编译并行度（由 build.sh 消费）
  if [[ -n "${PARSED_ARGS['jobs']:-}" ]]; then
    JOBS="${PARSED_ARGS['jobs']}"
    export JOBS
  fi

  # 步骤包装：子脚本可能因 set -e 直接退出而不打 FATAL，这里统一补上"失败的是哪一步"
  run_step() {
    local step_name="$1"
    shift
    if ! "$@"; then
      log FATAL "步骤失败: ${step_name}"
      log ERROR "命令: $*"
      log ERROR "本轮运行日志: ${LOG_FILE_PATH}"
      log ERROR "失败现场：本日志上方该步骤的原始输出；编译阶段另见 ${LOG_FILE_PATH%.log}.make.log"
      exit 1
    fi
  }

  # 准备源码目录结构
  source_parent="${SCRIPT_DIR}/../sources"
  source_dir="${source_parent}/${firmware}"
  mkdir -p "${source_parent}"
  log DEBUG "源码父目录: ${source_parent}"

  # ---------- 前置守卫：能快速失败就快速失败，否则明确告警 ----------
  # 1) 运行环境断言（仅提示，不阻断）：项目只在 Debian Linux/amd64 上验证过
  local os_name arch_name
  os_name="$(uname -s)"
  arch_name="$(uname -m)"
  if [[ "${os_name}" != "Linux" || ("${arch_name}" != "x86_64" && "${arch_name}" != "amd64") ]]; then
    log WARN "当前环境 ${os_name}/${arch_name} 未经验证（仅支持 Debian Linux/amd64），异常时请优先排查环境差异"
  fi

  # 2) profile 前置校验：拼错时立即失败，避免先付出一整次克隆的代价
  local profile_dir="${SCRIPT_DIR}/../public/assets/${profile}"
  if [[ ! -d "${profile_dir}" ]]; then
    local available_profiles=()
    local candidate
    for candidate in "$(dirname "${profile_dir}")"/*/; do
      [[ -d "${candidate}" ]] && available_profiles+=("$(basename "${candidate}")")
    done
    log FATAL "profile 不存在: ${profile_dir}"
    log ERROR "可用 profile: ${available_profiles[*]}"
    log ERROR "注意连字符 - 与下划线 _ 的区别"
    exit 1
  fi

  # 3) 磁盘空间：只告警不阻断（GitHub runner 仅 14GB，硬门槛会把 CI 直接拦死）
  local avail_gb
  avail_gb="$(df -Pk "${source_parent}" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}')"
  if [[ -n "${avail_gb}" ]]; then
    log INFO "可用磁盘空间: ${avail_gb} GB（源码父目录所在文件系统）"
    if [[ "${avail_gb}" -lt "${MIN_FREE_DISK_GB:-3}" ]]; then
      log WARN "可用空间不足 ${MIN_FREE_DISK_GB:-3} GB，构建可能中途因空间耗尽失败"
    fi
  fi

  # 步骤 1: 源码管理
  # 克隆或更新指定 firmware 和版本的源码
  run_step "步骤 1/7 源码管理" "${SCRIPT_DIR}/source-management.sh" "${source_parent}" "${firmware}" "${version}"

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
  run_step "步骤 3/7 复制配置文件" "${SCRIPT_DIR}/copy-pre-files.sh" "${firmware}" "${version}" "${profile}"

  # 步骤 4: Feeds 管理
  # 更新和安装所有软件包源
  run_step "步骤 4/7 Feeds 管理" "${SCRIPT_DIR}/feeds-management.sh" "${source_dir}" "${firmware}"

  # 步骤 5: 配置管理
  # 生成默认配置，应用差异配置，可选地运行 menuconfig
  run_step "步骤 5/7 配置管理" "${SCRIPT_DIR}/config-management.sh" "${source_dir}" "${firmware}" "${version}" "${profile}" "${ask_menuconfig}"

  # 步骤 6: 编译
  # 下载源码包并执行实际的编译过程
  run_step "步骤 6/7 编译" "${SCRIPT_DIR}/build.sh" "${source_dir}"

  # 步骤 7: 复制产物
  # 将编译生成的固件文件复制到输出目录
  run_step "步骤 7/7 复制编译产物" "${SCRIPT_DIR}/copy-bin-files.sh" "${firmware}" "${version}"

  log INFO "SUCCESS" "构建完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
