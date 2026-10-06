#!/usr/bin/env bash
#######################################
# 编译脚本
#
# 负责执行 OpenWrt/ImmortalWrt 的实际编译过程。
# 主要功能包括：
#   - 验证构建环境
#   - 多线程下载源码包
#   - 多线程编译固件
#   - 编译失败时自动降级为单线程重试
#
# 用法:
#   ./build.sh <source_dir>
#   ./build.sh --source-dir=<path>
#   ./build.sh --help
#
# 示例:
#   ./build.sh ./sources/immortalwrt
#   ./build.sh --source-dir=./sources/immortalwrt
#   ./build.sh /build/openwrt
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 依赖:
#   - common.sh: 提供日志和工具函数
#   - 源码目录中的 Makefile 和 .config
#   - nproc: 用于获取系统处理器数量
#
# 注意事项:
#   - 编译过程需要大量磁盘空间（至少 15GB）
#   - 首次编译可能需要数小时完成
#   - 多线程编译失败后会自动切换到单线程详细模式
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
# 编译主函数
#
# 执行完整的编译流程：
#   1. 验证源码目录和配置文件
#   2. 多线程下载所有依赖源码包
#   3. 尝试多线程编译
#   4. 如果编译失败，降级为单线程详细模式重试
#
# Globals:
#   SCRIPT_DIR - 当前脚本所在目录（只读）
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Outputs:
#   多级别日志输出到 stderr
#   编译过程的详细输出
#   单线程模式下输出详细的编译日志 (V=sc)
#
# Returns:
#   0 - 编译成功
#   1 - 验证失败、下载失败或编译失败
#
# Examples:
#   main "./sources/immortalwrt"
#   main --source-dir=./sources/immortalwrt
#   main --help
#
# Notes:
#   V=sc 表示详细输出：
#     s - 显示命令行参数
#     c - 显示编译命令
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS[help]:-}" ]]; then
    show_help "build.sh" \
      "编译 OpenWrt/ImmortalWrt 固件" \
      "[options] [source_dir]" \
      "  -h, --help              显示此帮助信息" \
      "  --source-dir=PATH       源码目录路径 (默认: .)" \
      "" \
      "位置参数:" \
      "  source_dir              源码目录路径 (等同于 --source-dir)"
    exit 0
  fi

  # 获取源码目录参数（优先使用命名参数，其次使用位置参数）
  local source_dir="${PARSED_ARGS['source-dir']:-${PARSED_ARGS[_POSITIONAL_0]:-.}}"
  local nproc

  # 验证源码目录结构
  require_file "${source_dir}/Makefile" "Makefile 不存在于 ${source_dir}"
  require_file "${source_dir}/.config" ".config 不存在于 ${source_dir}"

  log INFO "编译: 开始"
  log DEBUG "源码目录: ${source_dir}"

  # 切换到源码目录，所有后续操作在此目录中进行
  cd "${source_dir}"

  # 并行度：--jobs 优先（资源竞争或内存受限时降并行），否则取系统核数
  if [[ -n "${JOBS:-}" ]]; then
    if [[ ! "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
      log ERROR "--jobs 必须是正整数，当前值: '${JOBS}'"
      exit 1
    fi
    nproc="${JOBS}"
    log INFO "并行度由 --jobs 指定: ${nproc}（系统 $(nproc) 核）"
  else
    nproc=$(nproc)
    log DEBUG "系统处理器数: ${nproc}"
  fi

  # 执行位自检：共享挂载（virtiofs/osxfs）上的 chmod 抖动会让已安装的二进制丢掉执行位，
  # 而 make 的安装戳记仍标记为完成 —— 不修的话重试永远失败（实测：host 的 ninja、
  # 交叉工具链的 cc1，后者表现为内核报 "unknown C compiler"）。开局与每次重试前都跑。
  repair_exec_bits() {
    local files=()
    local f
    while IFS= read -r f; do
      [[ -n "${f}" ]] && files+=("${f}")
    done < <(find "${source_dir}/staging_dir" -type f \
      \( -path '*/bin/*' -o -path '*/libexec/*' -o -path '*/sbin/*' \) ! -perm -u+x 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
      return 0
    fi
    for f in "${files[@]}"; do
      chmod u+x "${f}" 2>/dev/null || true
    done
    log WARN "执行位自检：修复 ${#files[@]} 个缺失执行位的文件（示例：$(printf '%s ' "${files[@]:0:3}")）"
    return 0
  }

  repair_exec_bits

  # 本次构建起始时间：用于收割 OpenWrt 在失败时新增的 logs/ 现场
  local build_started_at
  build_started_at=$(date +%s)

  # 构建原始输出留存（下载 + 并行编译 + 单线程重试写同一文件）
  # 开关默认由 common.sh 按环境决定：本地开启、CI 关闭
  local capture_enabled="${CAPTURE_BUILD_LOG:-false}"
  local build_output_log="${CAPTURE_BUILD_LOG_PATH:-${LOG_FILE_PATH%.log}.make.log}"
  local retry_count="${RETRY_COUNT:-}"
  if [[ -z "${retry_count}" ]]; then
    # 以**构建树**所在文件系统判定：脚本目录可能还在共享挂载上（如 macOS 的仓库绑定挂载），
    # 但构建树若已放到 Docker 卷（ext4）上，就不会再有元数据抖动，无需提高重试次数。
    if _detect_shared_mount "${source_dir}" quiet; then
      retry_count=6
      log INFO "构建树位于共享挂载：并行重试次数默认提高到 ${retry_count}（每个 host tool 首建都可能抖动一次）"
    else
      retry_count=2
    fi
  fi
  local serial_retry_count="${SERIAL_RETRY_COUNT:-1}"
  if [[ ! "${retry_count}" =~ ^[1-9][0-9]*$ ]]; then
    log ERROR "RETRY_COUNT 必须是正整数，当前值: '${retry_count}'"
    exit 1
  fi
  if [[ ! "${serial_retry_count}" =~ ^[0-9]+$ ]]; then
    log ERROR "SERIAL_RETRY_COUNT 必须是非负整数，当前值: '${serial_retry_count}'"
    exit 1
  fi
  if [[ "${capture_enabled}" == "true" ]]; then
    log INFO "构建原始输出留存: ${build_output_log}"
  fi

  # 构建命令统一入口：开启留存时"实时透传 + 落盘"，否则仅实时透传
  run_build_cmd() {
    if [[ "${capture_enabled}" == "true" ]]; then
      run_capture --append "${build_output_log}" "$@"
    else
      "$@"
    fi
  }

  # 失败时统一输出：运行日志位置、原始输出尾部、OpenWrt 自己的失败日志
  report_build_failure() {
    log ERROR "本轮运行日志: ${LOG_FILE_PATH}"
    if [[ -f "${build_output_log}" ]]; then
      log ERROR "构建原始输出: ${build_output_log}（尾部 40 行）"
      print_tail "${build_output_log}" 40
    else
      log ERROR "构建原始输出未留存（CAPTURE_BUILD_LOG=${capture_enabled}），失败现场仅在本条日志上方的终端输出中"
    fi
    harvest_build_logs "${build_started_at}" "${source_dir}"
  }

  # 下载所有依赖的源码包
  # download 目标会根据 .config 下载所需的软件包源码
  # 使用多线程可以显著提高下载速度
  log INFO "下载源码包 (${nproc} 线程)"
  if ! run_build_cmd make download "-j${nproc}"; then
    log ERROR "并行下载失败（失败现场见上方输出），尝试单线程下载 (-j1 V=s)"
    if ! run_build_cmd make download -j1 V=s; then
      log FATAL "下载失败"
      log ERROR "工作目录: $(pwd)"
      report_build_failure
      exit 1
    fi
  fi

  # 编译固件
  # 先尝试多线程编译以提高速度
  log INFO "开始编译 (${nproc} 线程)"
  if ! run_build_cmd make "-j${nproc}"; then
    # 多线程编译失败，可能是由于：
    #   - 并发竞争导致的构建错误
    #   - 实际的代码或配置问题
    # 降级为单线程详细模式重试，便于定位问题
    log ERROR "并行编译失败（失败现场在本条日志上方的输出中），开始单线程重试 (-j1 V=sc)"

    # 单线程编译参数说明：
    #   -j1: 单线程编译，避免并发问题
    #   V=sc: 详细输出模式
    #     s - 显示完整的命令行参数
    #     c - 显示实际执行的编译命令
    local parallel_ok="false"
    local serial_ok="false"
    local attempt=1

    # 阶梯 1：并行重试。共享挂载（virtiofs/osxfs）上的失败多为"首次元数据操作抖动"，
    # 重试即成功（此时相关文件已存在），因此优先用并行重试保速度。
    while [[ "${attempt}" -le "${retry_count}" ]]; do
      repair_exec_bits
      log ERROR "并行编译失败（失败现场在上方输出中），第 ${attempt}/${retry_count} 次并行重试 (-j${nproc})"
      if run_build_cmd make "-j${nproc}"; then
        parallel_ok="true"
        break
      fi
      attempt=$((attempt + 1))
    done

    # 阶梯 2：单线程重试。用于并发竞争类问题，并给出可读日志。
    if [[ "${parallel_ok}" != "true" ]]; then
      attempt=1
      while [[ "${attempt}" -le "${serial_retry_count}" ]]; do
        repair_exec_bits
        log ERROR "并行重试未成功，第 ${attempt}/${serial_retry_count} 次单线程重试 (-j1 V=sc)"
        if run_build_cmd make -j1 V=sc; then
          serial_ok="true"
          break
        fi
        attempt=$((attempt + 1))
      done
    fi

    if [[ "${parallel_ok}" != "true" && "${serial_ok}" != "true" ]]; then
      log FATAL "并行重试 ${retry_count} 次 + 单线程重试 ${serial_retry_count} 次后仍然失败"
      log ERROR "工作目录: $(pwd)"
      if [[ "${SHARED_MOUNT:-false}" == "true" ]]; then
        log ERROR "提示：共享挂载（virtiofs/osxfs）上存在'首次元数据操作必失败、重试即成功'的抖动，可加大 --retry-count"
      fi
      report_build_failure
      exit 1
    fi
  fi

  log INFO "编译完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
