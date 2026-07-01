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

  # 获取系统处理器数量，用于并行编译
  nproc=$(nproc)
  log DEBUG "系统处理器数: ${nproc}"

  # 下载所有依赖的源码包
  # download 目标会根据 .config 下载所需的软件包源码
  # 使用多线程可以显著提高下载速度
  log INFO "下载源码包 (${nproc} 线程)"
  if ! make download "-j${nproc}"; then
    log ERROR "下载失败，尝试单线程下载"
    if ! make download -j1 V=s; then
      log FATAL "下载失败"
      log ERROR "工作目录: $(pwd)"
      log ERROR "请查看详细日志检查下载输出"
      exit 1
    fi
  fi

  # 编译固件
  # 先尝试多线程编译以提高速度
  log INFO "开始编译 (${nproc} 线程)"
  if ! make "-j${nproc}"; then
    # 多线程编译失败，可能是由于：
    #   - 并发竞争导致的构建错误
    #   - 实际的代码或配置问题
    # 降级为单线程详细模式重试，便于定位问题
    log ERROR "编译失败，尝试单线程编译"

    # 单线程编译参数说明：
    #   -j1: 单线程编译，避免并发问题
    #   V=sc: 详细输出模式
    #     s - 显示完整的命令行参数
    #     c - 显示实际执行的编译命令
    if ! make -j1 V=sc 2>&1; then
      log FATAL "编译失败"
      log ERROR "工作目录: $(pwd)"
      log ERROR "请查看详细日志检查编译输出"
      exit 1
    fi
  fi

  log INFO "编译完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
