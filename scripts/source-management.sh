#!/usr/bin/env bash
#######################################
# 固件源码管理脚本
#
# 负责克隆、更新和切换固件源码版本。支持 OpenWrt 和 ImmortalWrt 两种固件类型，
# 自动处理分支和标签的切换，智能识别当前版本状态。
#
# 用法:
#   ./source-management.sh [source_dir] [firmware] [version]
#   ./source-management.sh [options]
#   ./source-management.sh --help
#
# 参数:
#   source_dir - 源码父目录，脚本将在其中创建 {firmware} 子目录，默认: .
#   firmware   - 固件类型 (openwrt/immortalwrt)，默认: immortalwrt
#   version    - 版本号 (snapshots/版本号)，默认: snapshots
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 版本规则:
#   - snapshots       → openwrt: main 分支, immortalwrt: master 分支
#   - 具体版本号     → v{version} 标签 (如 v23.05.3)
#
# 工作流程:
#   1. 检查源码目录是否存在
#   2. 如果存在：切换到目标版本，分支则 git pull，标签则跳过
#   3. 如果不存在：克隆指定版本的源码 (--depth=1 浅克隆)
#
# 示例:
#   ./source-management.sh ./source immortalwrt snapshots
#   ./source-management.sh --source-dir=./source --firmware=openwrt --version=23.05.3
#   ./source-management.sh ./source openwrt 23.05.3
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

readonly GIT_QUICK_TIMEOUT=10
readonly GIT_NETWORK_TIMEOUT=180
readonly GIT_CLEAN_TIMEOUT=300

#######################################
# 获取目标分支/标签（内部函数）
#
# 根据固件类型和版本号，计算出应该克隆或切换的 Git 引用。
#
# 版本映射规则:
#   - snapshots + openwrt     → main
#   - snapshots + immortalwrt → master
#   - 具体版本号              → v{version} (标签)
#
# Arguments:
#   $1 - firmware 类型 (openwrt/immortalwrt)
#   $2 - 版本号 (snapshots/版本号)
#
# Outputs:
#   分支名或标签名到 stdout
#
# Returns:
#   0 - 成功
#
# Examples:
#   _get_target_ref "openwrt" "snapshots"      # 输出: main
#   _get_target_ref "immortalwrt" "snapshots"  # 输出: master
#   _get_target_ref "openwrt" "23.05.3"        # 输出: v23.05.3
#######################################
_get_target_ref() {
  local firmware="$1"
  local version="$2"

  if [[ "${version}" == "snapshots" ]]; then
    # snapshots 版本使用主分支
    [[ "${firmware}" == "openwrt" ]] && echo "main" || echo "master"
  else
    # 具体版本使用标签
    echo "v${version}"
  fi
}

#######################################
# 获取当前 Git 引用（内部函数）
#
# Outputs:
#   当前分支名、标签名或空字符串
#######################################
_get_current_ref() {
  timeout 3 git symbolic-ref --short HEAD 2>/dev/null ||
    timeout 3 git describe --tags --exact-match HEAD 2>/dev/null || echo ""
}

#######################################
# 拉取指定分支引用（内部函数）
#
# Arguments:
#   $1 - 分支名
#######################################
_fetch_branch_ref() {
  local target="$1"

  timeout "${GIT_NETWORK_TIMEOUT}" git fetch --prune origin \
    "+refs/heads/${target}:refs/remotes/origin/${target}" >/dev/null 2>&1
}

#######################################
# 拉取指定标签引用（内部函数）
#
# Arguments:
#   $1 - 标签名
#######################################
_fetch_tag_ref() {
  local target="$1"

  timeout "${GIT_NETWORK_TIMEOUT}" git fetch --force origin \
    "refs/tags/${target}:refs/tags/${target}" >/dev/null 2>&1
}

#######################################
# 更新目标引用（内部函数）
#
# 浅克隆或单分支克隆通常只配置了 master/main 的 fetch 规则。
# 切换 release 标签前必须显式拉取目标标签，否则本地 checkout 会找不到该标签。
#
# Arguments:
#   $1 - 目标引用（分支名或标签名）
#######################################
_fetch_target_ref() {
  local target="$1"

  log INFO "更新目标引用: ${target}"

  if [[ "${target}" == v* ]]; then
    if _fetch_tag_ref "${target}"; then
      log DEBUG "已获取标签 ${target}"
      return 0
    fi
    if _fetch_branch_ref "${target}"; then
      log DEBUG "已获取远端分支 origin/${target}"
      return 0
    fi
  else
    if _fetch_branch_ref "${target}"; then
      log DEBUG "已获取远端分支 origin/${target}"
      return 0
    fi
    if _fetch_tag_ref "${target}"; then
      log DEBUG "已获取标签 ${target}"
      return 0
    fi
  fi

  log WARN "精确获取 ${target} 失败，尝试获取全部标签"
  if timeout "${GIT_NETWORK_TIMEOUT}" git fetch --tags origin >/dev/null 2>&1; then
    return 0
  fi

  log ERROR "无法从 origin 获取 ${target}"
  return 1
}

#######################################
# 切换到已存在的目标引用（内部函数）
#
# Arguments:
#   $1 - 目标引用（分支名或标签名）
#######################################
_checkout_target_ref() {
  local target="$1"

  if timeout 3 git show-ref --verify --quiet "refs/tags/${target}"; then
    timeout "${GIT_QUICK_TIMEOUT}" git checkout "${target}"
    return
  fi

  if timeout 3 git show-ref --verify --quiet "refs/heads/${target}"; then
    timeout "${GIT_QUICK_TIMEOUT}" git checkout "${target}"
    return
  fi

  if timeout 3 git show-ref --verify --quiet "refs/remotes/origin/${target}"; then
    timeout "${GIT_QUICK_TIMEOUT}" git checkout -B "${target}" "origin/${target}"
    return
  fi

  timeout "${GIT_QUICK_TIMEOUT}" git checkout "${target}"
}

#######################################
# 更新当前分支（内部函数）
#
# 标签不可变，不执行 pull；分支使用 ff-only 避免意外创建 merge commit。
#######################################
_pull_current_branch() {
  local branch

  branch=$(timeout 3 git symbolic-ref --short HEAD 2>/dev/null || echo "")
  [[ -z "${branch}" ]] && return 0

  log INFO "更新分支 ${branch}"
  timeout "${GIT_NETWORK_TIMEOUT}" git pull --ff-only || log WARN "git pull --ff-only 失败"
}

#######################################
# 输出引用诊断信息（内部函数）
#
# Arguments:
#   $1 - 目标引用（分支名或标签名）
#######################################
_log_ref_diagnostics() {
  local target="$1"

  log ERROR "当前位置: $(pwd)"
  log ERROR "当前提交: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  log ERROR "fetch 规则: $(git config --get-all remote.origin.fetch 2>/dev/null || echo unknown)"
  log ERROR "本地分支: $(git branch -a 2>/dev/null | sed -n '1,20p')"
  log ERROR "本地匹配标签: $(git tag -l "${target}*" 2>/dev/null | sed -n '1,20p')"
  log ERROR "远端匹配标签: $(timeout 30 git ls-remote --tags origin "refs/tags/${target}*" 2>/dev/null | sed -n '1,20p' || echo "查询失败")"
}

#######################################
# 切换到目标版本（内部函数）
#
# 智能切换 Git 版本，处理以下场景:
#   1. 已在目标分支：执行 git pull 更新
#   2. 已在目标标签：无需操作（标签不变）
#   3. 在其他版本：切换到目标版本
#   4. 本地缺少目标引用：从 origin 精确拉取后重试
#   5. 工作区阻塞切换：清理工作区后兜底重试
#
# 使用 timeout 命令防止 Git 操作挂起（网络问题或仓库损坏）。
#
# Arguments:
#   $1 - 目标引用（分支名或标签名）
#
# Outputs:
#   切换过程的详细日志到 stderr
#
# Returns:
#   0 - 切换成功
#   1 - 切换失败（记录错误日志后退出脚本）
#
# Examples:
#   _switch_to_target "main"
#   _switch_to_target "v23.05.3"
#######################################
_switch_to_target() {
  local target="$1"
  local current_ref

  #######################################
  # 检查 Git 仓库可用性
  #
  # 使用 timeout 防止 Git 操作挂起。
  # 如果仓库不可用（损坏、网络问题），记录警告并跳过版本检查。
  #######################################
  if ! timeout 3 git rev-parse --git-dir >/dev/null 2>&1; then
    log WARN "Git 仓库不可用，跳过版本检查"
    return 0
  fi

  #######################################
  # 获取当前 Git 引用
  #
  # 尝试按以下顺序识别:
  #   1. 分支名 (git symbolic-ref)
  #   2. 标签名 (git describe --tags --exact-match)
  #   3. 未知状态（分离头指针或其他）
  #######################################
  current_ref=$(_get_current_ref)

  log DEBUG "当前引用: ${current_ref:-未知}, 目标: ${target}"

  #######################################
  # 场景 1: 已在目标版本
  #
  # 如果在分支上，执行 git pull 更新最新代码。
  # 如果在标签上，无需操作（标签不可变）。
  #######################################
  if [[ "${current_ref}" == "${target}" ]]; then
    if timeout 3 git symbolic-ref --short HEAD >/dev/null 2>&1; then
      # 在分支上，更新代码
      log INFO "在分支 ${target}"
      _pull_current_branch
    else
      # 在标签上，无需更新
      log INFO "在标签 ${target}，无需更新"
    fi
    return 0
  fi

  #######################################
  # 场景 2: 需要切换版本
  #
  # 尝试直接切换；如果失败，先拉取目标引用后重试。
  # 只有仍然失败时，才清理工作区做兜底重试。
  #######################################
  log INFO "切换: ${current_ref:-unknown} → ${target}"

  if ! _checkout_target_ref "${target}" >/dev/null 2>&1; then
    log WARN "本地无法直接切换到 ${target}，尝试从 origin 更新引用"
    _fetch_target_ref "${target}" || log ERROR "目标引用更新失败"

    if ! _checkout_target_ref "${target}" 2>&1; then
      # 仍然失败，可能是工作区文件冲突，最后才清理。
      log WARN "切换仍失败，清理工作区后重试"
      timeout "${GIT_CLEAN_TIMEOUT}" git clean -xfd || log ERROR "git clean 失败"
      timeout "${GIT_QUICK_TIMEOUT}" git restore . || log ERROR "git restore 失败"
      _fetch_target_ref "${target}" || log ERROR "目标引用更新失败"

      if ! _checkout_target_ref "${target}" 2>&1; then
        log FATAL "无法切换到 ${target}"
        _log_ref_diagnostics "${target}"
        exit 1
      fi
    fi
  fi

  _pull_current_branch
  log INFO "成功切换到 ${target}"
}

#######################################
# 主函数
#
# 执行源码管理流程：
#   1. 计算目标版本（分支或标签）
#   2. 如果源码目录存在，切换到目标版本
#   3. 如果源码目录不存在，克隆指定版本的源码
#
# Globals:
#   SCRIPT_DIR - 脚本所在目录的绝对路径
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Outputs:
#   多级别日志输出到 stderr
#   git 克隆/更新的详细输出
#
# Returns:
#   0 - 成功
#   1 - 克隆或切换失败
#
# Examples:
#   main "." "immortalwrt" "snapshots"
#   main --source-dir=. --firmware=openwrt --version=23.05.3
#   main --help
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS[help]:-}" ]]; then
    show_help "source-management.sh" \
      "管理 OpenWrt/ImmortalWrt 源码（克隆、更新、切换版本）" \
      "[options] [source_dir] [firmware] [version]" \
      "  -h, --help              显示此帮助信息" \
      "  --source-dir=PATH       源码父目录 (默认: .)" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: immortalwrt)" \
      "  --version=VER           版本号 (snapshots|版本号, 默认: snapshots)" \
      "" \
      "位置参数:" \
      "  source_dir              源码父目录 (等同于 --source-dir)" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)"
    exit 0
  fi

  # 获取参数（优先使用命名参数，其次使用位置参数，最后使用默认值）
  local source_dir="${PARSED_ARGS['source-dir']:-${PARSED_ARGS[_POSITIONAL_0]:-.}}"
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_1]:-immortalwrt}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_2]:-snapshots}}"
  local source_parent="${source_dir}"
  local target

  source_dir="${source_parent}/${firmware}"

  # 确保源码父目录存在
  if [[ ! -d "${source_parent}" ]]; then
    mkdir -p "${source_parent}"
  fi

  # 计算源码目录的完整路径
  source_dir="${source_parent}/${firmware}"

  # 获取目标 Git 引用（分支或标签）
  target=$(_get_target_ref "${firmware}" "${version}")

  log INFO "源码管理: ${firmware} ${version} [${target}]"
  log DEBUG "源码目录: ${source_dir}"

  #######################################
  # 场景 1: 源码目录已存在
  #
  # 进入目录，切换到目标版本。
  # 如果已在目标版本且为分支，执行 git pull 更新。
  #######################################
  if [[ -d "${source_dir}" ]]; then
    log INFO "进入现有源码目录"
    cd "${source_dir}"
    _switch_to_target "${target}"
  #######################################
  # 场景 2: 源码目录不存在
  #
  # 克隆指定版本的源码。
  # 使用 --depth=1 浅克隆以节省空间和时间。
  # 使用 timeout 防止克隆操作挂起（默认 10 分钟超时）。
  #######################################
  else
    log INFO "克隆 ${firmware} ${target}"
    log DEBUG "仓库地址: https://github.com/${firmware}/${firmware}.git"

    if ! timeout 600 git clone --depth=1 --branch "${target}" \
      "https://github.com/${firmware}/${firmware}.git" "${source_dir}" 2>&1; then
      # 克隆失败，记录详细错误信息
      log FATAL "克隆失败"
      log ERROR "仓库: https://github.com/${firmware}/${firmware}.git"
      log ERROR "分支/标签: ${target}"
      log ERROR "目标目录: ${source_dir}"
      exit 1
    fi

    log INFO "克隆完成"
  fi

  log INFO "源码已就位: ${source_dir}"
}

# 执行主函数，传递所有命令行参数
main "$@"
