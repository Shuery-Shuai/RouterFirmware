#!/usr/bin/env bash
#######################################
# 上游版本 Tag 检查脚本
#
# 为 GitHub Actions 工作流（upstream-tag-checker.yml）提供两项能力:
#   1. plan   - 由 config/site.json 推导需要跟踪的「固件 + 发行线」矩阵
#   2. select - 在指定发行线上挑选需要编译的最新版本 Tag
#
# 发行线取自 config/site.json 中各固件声明的 stable / oldstable
# （取主次版本号，如 25.12.5 → 25.12）。每条发行线优先选择最新正式版 Tag
# （如 v25.12.6）；该发行线尚无正式版时，回退到最新预发布版（rc/beta/alpha）。
#
# 本脚本只负责「挑出版本」，某个版本是否已经编译过由调用方（工作流缓存）
# 判断，因此新增发行线只需在 site.json 中声明，无需额外维护基线。
#
# 用法:
#   ./scripts/upstream-tag.sh plan [--config=PATH]
#   ./scripts/upstream-tag.sh select --firmware=FW --line=LINE
#   ./scripts/upstream-tag.sh --help
#
# 参数:
#   plan
#     --config=PATH           site.json 路径 (默认: config/site.json)
#   select
#     --firmware=FW           固件类型 (openwrt/immortalwrt)
#     --line=LINE             发行线 (如 25.12)
#
# 选项:
#   -h, --help                显示此帮助信息
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 输出:
#   plan   - 单行 JSON 数组（GitHub Actions matrix 的 include 列表）到 stdout
#   select - 需要编译的 Tag（含 v 前缀）到 stdout；该发行线暂无 Tag 时不输出内容
#   日志一律写入 stderr，便于调用方捕获 stdout
#
# 依赖:
#   - common.sh: 提供日志和参数解析函数
#   - jq: 解析 config/site.json
#   - git: 通过 ls-remote 读取上游标签（不下载上游对象）
#
# 退出状态:
#   0 - 成功（select 未找到 Tag 同样返回 0，由调用方按空输出处理）
#   1 - 参数错误、依赖缺失或上游访问失败
#
# 示例:
#   ./scripts/upstream-tag.sh plan
#   ./scripts/upstream-tag.sh select --firmware=openwrt --line=25.12
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

# 默认站点配置路径（相对仓库根目录）
readonly DEFAULT_CONFIG="config/site.json"

# 上游标签查询超时（秒）
readonly REMOTE_TIMEOUT=120

#######################################
# 上游仓库登记表
#
# 键为固件类型（与 config/site.json 的 id 一致），值为上游 Git 仓库地址。
# 新增固件时在此登记；未登记的固件会被 plan 跳过并给出告警。
#######################################
declare -A UPSTREAM_REPOS=(
  [openwrt]="https://github.com/openwrt/openwrt"
  [immortalwrt]="https://github.com/immortalwrt/immortalwrt"
)

#######################################
# 解析发行线（主次版本号，内部函数）
#
# Arguments:
#   $1 - 版本号，如 25.12.5 或 25.12.0-rc2
#
# Outputs:
#   发行线到 stdout，如 25.12
#
# Examples:
#   _parse_release_line "25.12.5"      # 输出: 25.12
#   _parse_release_line "25.12.0-rc2"  # 输出: 25.12
#######################################
_parse_release_line() {
  local version="$1"
  local major minor

  IFS='.' read -r major minor _ <<<"${version}"
  printf '%s.%s\n' "${major}" "${minor}"
}

#######################################
# 生成跟踪矩阵（内部函数）
#
# 从 config/site.json 读取每个固件声明的 stable / oldstable，
# 按「固件 + 发行线」去重后输出 GitHub Actions matrix.include 列表。
# 同一发行线上同时声明了 stable 与 oldstable 时只保留一条（声明靠前者）。
#
# Arguments:
#   $1 - site.json 路径
#
# Outputs:
#   单行 JSON 数组到 stdout，元素形如:
#   {"firmware":"openwrt","repo":"https://github.com/openwrt/openwrt","line":"25.12","title":"OpenWrt"}
#
# Returns:
#   0 - 成功（无跟踪目标时输出 []）
#   1 - 配置缺失、jq 不可用或 JSON 解析失败
#
# Examples:
#   _plan_matrix "config/site.json"
#######################################
_plan_matrix() {
  local config="$1"

  require_file "${config}" "站点配置不存在: ${config}"
  if ! command -v jq >/dev/null 2>&1; then
    log ERROR "缺少 jq，无法解析 ${config}"
    return 1
  fi

  local entries=""
  local entry_count=0
  declare -A seen_lines=()
  local firmware title declared line key repo

  # jq: 逐固件输出 "固件ID \t 展示名 \t 已声明版本"，stable 在前、oldstable 在后
  while IFS=$'\t' read -r firmware title declared; do
    [[ -z "${firmware}" || -z "${declared}" ]] && continue

    line="$(_parse_release_line "${declared}")"
    key="${firmware}/${line}"
    if [[ -n "${seen_lines[${key}]:-}" ]]; then
      log DEBUG "发行线 ${key} 已登记，跳过 ${declared}"
      continue
    fi

    repo="${UPSTREAM_REPOS[${firmware}]:-}"
    if [[ -z "${repo}" ]]; then
      log WARN "固件 ${firmware} 未登记上游仓库，跳过 ${declared}"
      continue
    fi

    seen_lines["${key}"]=1
    entries+="${entries:+,}{\"firmware\":\"${firmware}\",\"repo\":\"${repo}\",\"line\":\"${line}\",\"title\":\"${title}\"}"
    entry_count=$((entry_count + 1))
  done < <(jq -r '
    .firmwares[]
    | .id as $id
    | .title as $title
    | .stable, .oldstable
    | select(. != null and . != "")
    | "\($id)\t\($title)\t\(.)"
  ' "${config}")

  log INFO "跟踪 ${entry_count} 条发行线"
  printf '[%s]\n' "${entries}"
}

#######################################
# 拉取上游标签名列表（内部函数）
#
# 仅读取标签引用（--refs 过滤掉 peeled 的 ^{} 行），不下载上游对象。
#
# Arguments:
#   $1 - 上游仓库地址
#
# Outputs:
#   标签名列表到 stdout，每行一个（如 v25.12.6）
#
# Returns:
#   0 - 成功
#   1 - git 命令失败或超时
#
# Examples:
#   _fetch_remote_tags "https://github.com/openwrt/openwrt"
#######################################
_fetch_remote_tags() {
  local repo_url="$1"
  local remote_output

  if ! remote_output="$(timeout "${REMOTE_TIMEOUT}" git ls-remote --tags --refs "${repo_url}")"; then
    log ERROR "读取上游标签失败（网络或仓库地址异常）: ${repo_url}"
    return 1
  fi

  awk -F'refs/tags/' 'NF > 1 { print $2 }' <<<"${remote_output}"
}

#######################################
# 挑选发行线上最新的 Tag（内部函数）
#
# 先取该发行线上最新的正式版 Tag；若该发行线尚无正式版，则回退到
# 最新的预发布版（rc/beta/alpha）。
#
# Arguments:
#   $1 - 固件类型 (openwrt/immortalwrt)
#   $2 - 发行线 (如 25.12)
#
# Outputs:
#   最新的 Tag（含 v 前缀）到 stdout；该发行线无 Tag 时不输出内容
#
# Returns:
#   0 - 成功
#   1 - 固件未登记或上游访问失败
#
# Examples:
#   _select_latest_tag "openwrt" "25.12"
#######################################
_select_latest_tag() {
  local firmware="$1"
  local line="$2"
  local repo_url="${UPSTREAM_REPOS[${firmware}]:-}"

  if [[ -z "${repo_url}" ]]; then
    log ERROR "固件 ${firmware} 未登记上游仓库"
    return 1
  fi

  local tags escaped_line tag
  tags="$(_fetch_remote_tags "${repo_url}")" || return 1
  escaped_line="${line//./\\.}"

  # sort -V 按版本号排序（注意：同补丁号的 rc 会排在正式版之后，
  # 因此正式版与预发布版必须分开比较）
  tag="$(grep -E "^v${escaped_line}\.[0-9]+$" <<<"${tags}" | sort -V | tail -n1 || true)"
  if [[ -z "${tag}" ]]; then
    tag="$(grep -E "^v${escaped_line}\.[0-9]+-(rc|beta|alpha)[0-9]+$" <<<"${tags}" | sort -V | tail -n1 || true)"
  fi

  if [[ -z "${tag}" ]]; then
    log INFO "发行线 ${line} 暂无版本标签，跳过"
    return 0
  fi

  log INFO "发行线 ${line} 最新标签: ${tag}"
  printf '%s\n' "${tag}"
}

#######################################
# 主函数
#
# 解析子命令并分发到对应实现。
#
# Globals:
#   PARSED_ARGS - parse_args 填充的参数关联数组
#
# Arguments:
#   $@ - 命令行参数
#
# Returns:
#   0 - 成功
#   1 - 参数错误或执行失败
#
# Examples:
#   main plan
#   main select --firmware=openwrt --line=25.12
#######################################
main() {
  declare -A PARSED_ARGS
  parse_args "$@"

  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "upstream-tag.sh" \
      "检查上游是否发布新的版本 Tag，并输出需要编译的版本" \
      "<plan|select> [options]" \
      "  plan                    输出跟踪矩阵 (JSON 数组)" \
      "  select                  输出发行线上最新的版本 Tag" \
      "  --config=PATH           site.json 路径 (默认: config/site.json，仅 plan)" \
      "  --firmware=FW           固件类型 (仅 select)" \
      "  --line=LINE             发行线，如 25.12 (仅 select)" \
      "  -h, --help              显示此帮助信息"
    exit 0
  fi

  local command="${PARSED_ARGS[_POSITIONAL_0]:-}"
  case "${command}" in
  plan)
    _plan_matrix "${PARSED_ARGS['config']:-${DEFAULT_CONFIG}}"
    ;;
  select)
    local firmware="${PARSED_ARGS['firmware']:-}"
    local line="${PARSED_ARGS['line']:-}"
    if [[ -z "${firmware}" || -z "${line}" ]]; then
      log ERROR "select 需要 --firmware 与 --line 参数"
      log ERROR "使用 --help 查看完整用法"
      exit 1
    fi
    _select_latest_tag "${firmware}" "${line}"
    ;;
  *)
    log ERROR "未知命令: ${command:-（空）}"
    log ERROR "使用 --help 查看完整用法"
    exit 1
    ;;
  esac
}

# 执行主函数
main "$@"
