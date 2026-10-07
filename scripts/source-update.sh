#!/usr/bin/env bash
#######################################
# 上游源码（快照版）更新检查脚本
#
# 为 GitHub Actions 工作流（source-update-checker.yml）提供两项能力:
#   1. plan - 由 config/site.json 推导需要检查的上游仓库矩阵
#   2. head - 读取某个固件上游开发分支上的最新提交
#
# 检查对象取自 config/site.json 的 firmwares[]：声明了 snapshots: true 的固件会被
# 跟踪，仓库地址取自 repo、分支取自 branch——脚本里不写死任何发行版数据，新增固件
# 只需在 site.json 里补齐 repo / branch。声明了 snapshots 却缺 repo 或 branch 属配置
# 错误，脚本直接报错退出（不做静默跳过：否则会出现「看着在检测、其实没检测」的缺口）。
#
# 本脚本只负责「查上游最新提交」，某个提交是否已经触发过编译由调用方（工作流缓存）
# 判断，因此脚本不维护任何基线。
#
# 用法:
#   ./scripts/source-update.sh plan [--config=PATH] [--firmware=FW]
#   ./scripts/source-update.sh head [--config=PATH] --firmware=FW
#   ./scripts/source-update.sh --help
#
# 参数:
#   plan
#     --config=PATH           site.json 路径 (默认: config/site.json)
#     --firmware=FW           只保留指定固件 (可选；缺省输出全部跟踪对象)
#   head
#     --config=PATH           site.json 路径 (默认: config/site.json)
#     --firmware=FW           固件类型 (openwrt/immortalwrt，必填)
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
#   head   - 上游分支最新提交的 SHA 到 stdout
#   日志一律写入 stderr，便于调用方捕获 stdout
#
# 依赖:
#   - common.sh: 提供日志、参数解析与配置读取函数
#   - jq: 解析 config/site.json
#   - git: 通过 ls-remote 读取上游分支（不下载上游对象）
#
# 退出状态:
#   0 - 成功
#   1 - 参数错误、依赖缺失、配置不完整或上游访问失败
#
# 示例:
#   ./scripts/source-update.sh plan
#   ./scripts/source-update.sh plan --firmware=openwrt
#   ./scripts/source-update.sh head --firmware=immortalwrt
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

# 上游提交查询超时（秒）
readonly REMOTE_TIMEOUT=120

#######################################
# 检查 jq 是否可用（内部函数）
#
# Arguments:
#   $1 - 配置文件路径（仅用于报错信息）
#
# Returns:
#   0 - jq 可用
#   1 - 缺少 jq
#######################################
_require_jq() {
  local config="$1"

  if ! command -v jq >/dev/null 2>&1; then
    log ERROR "缺少 jq，无法解析 ${config}"
    return 1
  fi
}

#######################################
# 校验跟踪配置是否完整（内部函数）
#
# 声明了 snapshots 的固件就是要检测上游更新的固件，必须给出 repo 与 branch；
# 触发编译还要带上设备 profile。缺项直接报错，避免静默漏检。
#
# Arguments:
#   $1 - site.json 路径
#
# Returns:
#   0 - 配置完整
#   1 - 配置缺失或 JSON 解析失败
#######################################
_validate_tracking() {
  local config="$1"
  local incomplete profile

  if ! jq -e '.firmwares' "${config}" >/dev/null 2>&1; then
    log ERROR "解析 ${config} 失败（不是合法 JSON 或缺少 firmwares）"
    return 1
  fi

  incomplete="$(jq -r '
    .firmwares[]?
    | select(.snapshots == true)
    | select((.repo // "") == "" or (.branch // "") == "")
    | (.id // "（缺 id）")
  ' "${config}")"
  if [[ -n "${incomplete}" ]]; then
    log ERROR "${config} 中以下固件声明了 snapshots，却缺少 repo 或 branch:"
    while IFS= read -r id; do
      log ERROR "  - ${id}"
    done <<<"${incomplete}"
    return 1
  fi

  profile="$(jq -r '.defaults.profile // ""' "${config}")"
  if [[ -z "${profile}" ]]; then
    log ERROR "${config} 未声明 defaults.profile（触发编译时的设备 profile）"
    return 1
  fi
}

#######################################
# 生成检查矩阵（内部函数）
#
# 逐个取出声明了 snapshots 的固件，输出 GitHub Actions matrix.include 列表。
# 矩阵元素带上 url / branch，作业日志里就能直接看出这次检测的是哪个上游分支。
#
# Arguments:
#   $1 - site.json 路径
#   $2 - 只保留的固件 id（可选，空字符串表示全部）
#
# Outputs:
#   单行 JSON 数组到 stdout，元素形如:
#   {"firmware":"openwrt","title":"OpenWrt","url":"...","branch":"main","profile":"..."}
#
# Returns:
#   0 - 成功
#   1 - 配置缺失、jq 不可用或 JSON 解析失败
#
# Examples:
#   _plan_matrix "config/site.json" ""
#######################################
_plan_matrix() {
  local config="$1"
  local only="$2"
  local matrix profile

  require_file "${config}" "站点配置不存在: ${config}"
  _require_jq "${config}" || return 1
  _validate_tracking "${config}" || return 1

  # 手动指定固件时，名字必须是跟踪范围内的，避免"选了一个不会跑的名字"却静默通过
  if [[ -n "${only}" ]] && ! jq -e --arg id "${only}" \
    '.firmwares[]? | select(.snapshots == true) | select(.id == $id)' "${config}" >/dev/null; then
    log ERROR "固件 ${only} 不在跟踪范围内（需在 ${config} 声明 snapshots: true）"
    return 1
  fi

  profile="$(jq -r '.defaults.profile' "${config}")"
  if ! matrix="$(jq -c --arg only "${only}" --arg profile "${profile}" '
    [ .firmwares[]?
      | select(.snapshots == true)
      | select($only == "" or .id == $only)
      | {
          firmware: .id,
          title: (.title // .id),
          url: .repo,
          branch: .branch,
          profile: $profile
        }
    ]' "${config}")"; then
    log ERROR "解析 ${config} 失败"
    return 1
  fi

  log INFO "跟踪 $(jq 'length' <<<"${matrix}") 个上游仓库"
  printf '%s\n' "${matrix}"
}

#######################################
# 读取上游分支最新提交（内部函数）
#
# 只读取分支引用（不下载上游对象），拿到分支 tip 的 SHA 即可判断"有没有新提交"。
# 分支不存在时 ls-remote 会返回空输出，这里按错误处理——分支写错必须被看见，
# 而不是默默当成"没有更新"。
#
# Arguments:
#   $1 - site.json 路径
#   $2 - 固件类型（id）
#
# Outputs:
#   分支最新提交的 SHA 到 stdout
#
# Returns:
#   0 - 成功
#   1 - 固件未声明、分支不存在、上游访问失败或返回非预期对象
#
# Examples:
#   _upstream_head "config/site.json" "openwrt"
#######################################
_upstream_head() {
  local config="$1"
  local firmware="$2"
  local url branch remote_output head_sha

  require_file "${config}" "站点配置不存在: ${config}"
  _require_jq "${config}" || return 1

  # 只服务跟踪范围内的固件：未声明、未开 snapshots、缺 repo / branch 都要报错，
  # 避免"查了一个根本不会编译的分支"，或退回兜底分支后悄悄查错地方
  if ! jq -e --arg id "${firmware}" '
    .firmwares[]?
    | select(.id == $id)
    | select(.snapshots == true)
    | select((.repo // "") != "" and (.branch // "") != "")
  ' "${config}" >/dev/null; then
    log ERROR "固件 ${firmware} 不在跟踪范围内（需在 ${config} 声明 snapshots: true 并给出 repo / branch）"
    return 1
  fi

  # 仓库地址与分支都取自配置（与 source-management.sh 同一个出口）
  url="$(firmware_repo_url "${firmware}" "${config}")"
  branch="$(firmware_snapshot_branch "${firmware}" "${config}")"

  if ! remote_output="$(timeout "${REMOTE_TIMEOUT}" git ls-remote --heads "${url}" "refs/heads/${branch}")"; then
    log ERROR "读取上游分支失败（网络或仓库地址异常）: ${url} refs/heads/${branch}"
    return 1
  fi

  head_sha="$(awk 'NR == 1 { print $1 }' <<<"${remote_output}")"
  if [[ -z "${head_sha}" ]]; then
    log ERROR "上游分支不存在或为空: ${url} refs/heads/${branch}"
    return 1
  fi
  if [[ ! "${head_sha}" =~ ^[0-9a-f]{40,64}$ ]]; then
    log ERROR "上游返回了非预期的提交对象: ${head_sha}"
    return 1
  fi

  log INFO "上游 ${firmware} 分支 ${branch} 最新提交: ${head_sha}"
  printf '%s\n' "${head_sha}"
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
#   main head --firmware=openwrt
#######################################
main() {
  declare -A PARSED_ARGS
  parse_args "$@"

  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "source-update.sh" \
      "检查上游源码（快照版）是否有新提交，供工作流判断是否触发编译" \
      "<plan|head> [options]" \
      "  plan                    输出检查矩阵 (JSON 数组)" \
      "  head                    输出固件上游开发分支的最新提交 (SHA)" \
      "  --config=PATH           site.json 路径 (默认: config/site.json)" \
      "  --firmware=FW           固件类型 (plan 为过滤项，head 为必填)" \
      "  -h, --help              显示此帮助信息"
    exit 0
  fi

  local command="${PARSED_ARGS[_POSITIONAL_0]:-}"
  local config="${PARSED_ARGS['config']:-${SITE_CONFIG_DEFAULT}}"
  local firmware="${PARSED_ARGS['firmware']:-}"

  case "${command}" in
  plan)
    _plan_matrix "${config}" "${firmware}"
    ;;
  head)
    if [[ -z "${firmware}" ]]; then
      log ERROR "head 需要 --firmware 参数"
      log ERROR "使用 --help 查看完整用法"
      exit 1
    fi
    _upstream_head "${config}" "${firmware}"
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
