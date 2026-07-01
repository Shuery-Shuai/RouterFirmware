#!/usr/bin/env bash
#######################################
# Feeds 管理脚本
#
# 负责管理 OpenWrt/ImmortalWrt 的软件包源（feeds）。
# 主要功能包括：
#   - 执行构建前的自定义脚本 (diy-part1.sh)
#   - 更新所有 feeds 源
#   - 执行构建前的第二阶段自定义脚本 (diy-part2.sh)
#   - 安装所有 feeds 软件包
#
# 用法:
#   ./feeds-management.sh <source_dir> <firmware>
#   ./feeds-management.sh [options]
#   ./feeds-management.sh --help
#
# 示例:
#   ./feeds-management.sh ./sources/immortalwrt immortalwrt
#   ./feeds-management.sh --source-dir=./sources/immortalwrt --firmware=immortalwrt
#   ./feeds-management.sh /build/openwrt openwrt
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 依赖:
#   - common.sh: 提供日志和工具函数
#   - 源码目录中的 Makefile 和 scripts/feeds
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
# Feeds 管理主函数
#
# 执行 feeds 的完整管理流程：
#   1. 验证源码目录结构
#   2. 执行 diy-part1.sh（如果存在）
#   3. 更新所有 feeds 源
#   4. 执行 diy-part2.sh（如果存在）
#   5. 安装所有 feeds 软件包
#
# Globals:
#   SCRIPT_DIR - 当前脚本所在目录（只读）
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Outputs:
#   多级别日志输出到 stderr
#   feeds 更新和安装的详细输出
#
# Returns:
#   0 - 成功
#   1 - 源码目录验证失败、feeds 更新或安装失败
#
# Examples:
#   main "./sources/immortalwrt" "immortalwrt"
#   main --source-dir=./sources/immortalwrt --firmware=immortalwrt
#   main --help
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS[help]:-}" ]]; then
    show_help "feeds-management.sh" \
      "管理 OpenWrt/ImmortalWrt 软件包源（feeds）" \
      "[options] [source_dir] [firmware]" \
      "  -h, --help              显示此帮助信息" \
      "  --source-dir=PATH       源码目录路径 (默认: .)" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: immortalwrt)" \
      "" \
      "位置参数:" \
      "  source_dir              源码目录路径 (等同于 --source-dir)" \
      "  firmware                固件类型 (等同于 --firmware)"
    exit 0
  fi

  # 获取参数（优先使用命名参数，其次使用位置参数，最后使用默认值）
  local source_dir="${PARSED_ARGS['source-dir']:-${PARSED_ARGS[_POSITIONAL_0]:-.}}"
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_1]:-immortalwrt}}"

  # 验证源码目录结构
  require_file "${source_dir}/Makefile" "Makefile 不存在于 ${source_dir}"
  require_file "${source_dir}/scripts/feeds" "feeds 脚本不存在于 ${source_dir}/scripts"

  log INFO "Feeds 管理: ${firmware}"
  log DEBUG "源码目录: ${source_dir}"

  # 切换到源码目录，所有后续操作在此目录中进行
  cd "${source_dir}"

  # 在更新前暴力重置所有 feeds 子仓库
  if [ -d feeds ]; then
    find feeds -maxdepth 2 -name .git -type d | while read -r gitdir; do
      repo_dir=$(dirname "$gitdir")
      log 'INFO' "重置 ${repo_dir} ……"
      git -C "$repo_dir" fetch origin
      git -C "$repo_dir" reset --hard origin/master
      git -C "$repo_dir" clean -fdx
    done
  fi

  # 清除可能由之前构建残留的自定义符号链接（这些链接不是 Git 管理的）
  log INFO "清除 feeds 中的符号链接"
  find feeds -type l -delete || log WARN "清除符号链接时出现错误（通常无害）"

  # 执行第一阶段 DIY 脚本（通常用于修改 feeds.conf.default）
  if [[ -f "diy-part1.sh" ]]; then
    log INFO "执行 diy-part1.sh"
    # 允许脚本返回非零退出码（可能只是警告）
    bash diy-part1.sh || log WARN "diy-part1.sh 有警告"
  else
    log DEBUG "diy-part1.sh 不存在，跳过"
  fi

  # 更新所有 feeds 源
  # -a: 更新所有 feeds
  # -f: 强制更新，即使已是最新版本
  log INFO "更新 feeds"
  if ! ./scripts/feeds update -a -f 2>&1; then
    log FATAL "feeds 更新失败"
    log ERROR "工作目录: $(pwd)"
    log ERROR "feeds 脚本: ./scripts/feeds"
    exit 1
  fi

  # 执行第二阶段 DIY 脚本（通常用于修改软件包源码或配置）
  # 注意：必须在 feeds install 之前执行，以便：
  #   1. 创建的符号链接能被构建系统识别
  #   2. 修改已安装的 feeds 内容（如 Makefile、源码补丁等）
  if [[ -f "diy-part2.sh" ]]; then
    log INFO "执行 diy-part2.sh"
    # 允许脚本返回非零退出码（可能只是警告）
    bash diy-part2.sh || log WARN "diy-part2.sh 有警告"
  else
    log DEBUG "diy-part2.sh 不存在，跳过"
  fi

  # 刷新包索引
  ./scripts/feeds update -i
  
  # 安装所有 feeds 软件包到构建系统
  # -a: 安装所有 feeds
  # -f: 强制安装，覆盖已有版本
  log INFO "安装 feeds"
  if ! ./scripts/feeds install -a -f 2>&1; then
    log FATAL "feeds 安装失败"
    log ERROR "工作目录: $(pwd)"
    log ERROR "feeds 脚本: ./scripts/feeds"
    exit 1
  fi

  log INFO "Feeds 管理完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
