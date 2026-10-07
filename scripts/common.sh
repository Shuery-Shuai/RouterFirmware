#!/usr/bin/env bash
#######################################
# 通用日志和工具函数库
#
# 提供标准化的日志输出、文件检查、日期格式化等工具函数。
# 支持多级别日志、彩色输出、文件记录等特性。
#
# 用法:
#   source "${SCRIPT_DIR}/common.sh"
#   log INFO "这是一条信息日志"
#   log WARN "操作" "警告消息"
#   require_file "/path/to/file" "配置文件缺失"
#
# 环境变量:
#   LOG_LEVEL      - 最低日志级别 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL，默认: INFO)
#   LOG_TO_FILE    - 是否写入日志文件 (true|false，默认: false)
#   LOG_FILE_PATH  - 日志文件路径 (默认: /tmp/openwrt_build_YYYYMMDD_HHMMSS.log)
#
# 作者: Shuery-Shuai
# 版本: 1.0.0
#######################################

set -euo pipefail

#######################################
# 运行环境检查
#
# 本项目多处依赖 bash 4.0+ 特性（关联数组 declare -A、${var,,} 小写展开等），
# 在更旧的 bash 上会以难以定位的报错中断（例如 macOS 自带的 bash 3.2 会把
# 关联数组下标当算术表达式求值，报出 "Jan: unbound variable"）。
# 这里提前拦截并给出可操作的提示。
#######################################
if ((${BASH_VERSINFO[0]:-0} < 4)); then
  printf '错误: 本项目脚本需要 bash 4.0 或更高版本，当前为 %s\n' "${BASH_VERSION}" >&2
  printf '  macOS 自带的 bash 为 3.2，请安装新版后重试: brew install bash\n' >&2
  printf '  或改用 Docker / Dev Container 进行构建。\n' >&2
  exit 1
fi

#######################################
# 日志级别常量
#
# 用于设置和比较日志级别，数值越小级别越低。
#
# Globals:
#   LOG_LEVEL_TRACE  - 追踪级别 (0)
#   LOG_LEVEL_DEBUG  - 调试级别 (1)
#   LOG_LEVEL_INFO   - 信息级别 (2)
#   LOG_LEVEL_WARN   - 警告级别 (3)
#   LOG_LEVEL_ERROR  - 错误级别 (4)
#   LOG_LEVEL_FATAL  - 致命级别 (5)
#######################################
# shellcheck disable=SC2034
readonly LOG_LEVEL_TRACE=0 LOG_LEVEL_DEBUG=1 LOG_LEVEL_INFO=2
# shellcheck disable=SC2034
readonly LOG_LEVEL_WARN=3 LOG_LEVEL_ERROR=4 LOG_LEVEL_FATAL=5

#######################################
# ANSI 颜色代码常量
#
# 根据输出目标是否为终端自动启用或禁用颜色。
# 仅当 stderr 连接到 TTY 时启用彩色输出。
#
# Globals:
#   COLOR_RESET  - 重置所有样式
#   COLOR_GRAY   - 灰色（用于 TRACE）
#   COLOR_CYAN   - 青色（用于 DEBUG）
#   COLOR_BLUE   - 蓝色（用于 INFO）
#   COLOR_YELLOW - 黄色（用于 WARN）
#   COLOR_RED    - 红色（用于 ERROR/FATAL）
#   COLOR_GREEN  - 绿色（用于 SUCCESS）
#######################################
if [[ -t 2 ]]; then
  readonly COLOR_RESET='\033[0m'
  readonly COLOR_GRAY='\033[0;37m'
  readonly COLOR_CYAN='\033[0;36m'
  readonly COLOR_BLUE='\033[0;34m'
  readonly COLOR_YELLOW='\033[1;33m'
  readonly COLOR_RED='\033[1;31m'
  readonly COLOR_GREEN='\033[1;32m'
else
  readonly COLOR_RESET='' COLOR_GRAY='' COLOR_CYAN=''
  readonly COLOR_BLUE='' COLOR_YELLOW='' COLOR_RED='' COLOR_GREEN=''
fi

#######################################
# 可配置的全局变量
#
# Globals:
#   LOG_LEVEL      - 当前日志级别，低于此级别的日志将被过滤
#   LOG_TO_FILE    - 是否同时写入日志文件
#   LOG_FILE_PATH  - 日志文件的存储路径
#######################################
: "${LOG_LEVEL:=INFO}"

# 文件日志策略：
#   - 未显式指定时：本地默认开启，CI 默认关闭（GitHub 已提供日志，且 runner 磁盘仅 14GB）
#   - LOG_FILE_PATH 必须由入口脚本解析一次并 export，否则每个子脚本会各自生成一个带新
#     时间戳的路径，同一轮构建的日志会碎成多份
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${LOG_TO_FILE:-}" ]]; then
  if [[ -n "${CI:-}" ]]; then
    LOG_TO_FILE="false"
  else
    LOG_TO_FILE="true"
  fi
fi
export LOG_TO_FILE

: "${LOG_FILE_PATH:=${_COMMON_DIR}/../logs/build-$(date +%Y%m%d_%H%M%S).log}"
export LOG_FILE_PATH

if [[ "${LOG_TO_FILE}" == "true" ]]; then
  mkdir -p "$(dirname "${LOG_FILE_PATH}")" 2>/dev/null || true
fi

# 构建原始输出留存策略：
#   - 未显式指定时：本地默认开启（失败后可复盘 make 的原始输出），CI 默认关闭（runner 磁盘仅 14GB）
#   - 关闭时无任何磁盘占用；开启时由 build.sh 把 make 输出追加写入带时间戳的文件
if [[ -z "${CAPTURE_BUILD_LOG:-}" ]]; then
  if [[ -n "${CI:-}" ]]; then
    CAPTURE_BUILD_LOG="false"
  else
    CAPTURE_BUILD_LOG="true"
  fi
fi
export CAPTURE_BUILD_LOG

#######################################
# 获取日志级别的显示样式（内部函数）
#
# 根据日志级别返回对应的颜色代码和 emoji 图标。
#
# Arguments:
#   $1 - 日志级别名称 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL|SUCCESS)
#
# Outputs:
#   输出格式: "颜色代码|emoji"
#   示例: "\033[0;34m|💡"
#
# Returns:
#   0 - 总是成功
#######################################
_get_log_style() {
  local level="$1"
  case "${level}" in
  TRACE) echo "${COLOR_GRAY}|🔬" ;;
  DEBUG) echo "${COLOR_CYAN}|🐛" ;;
  INFO) echo "${COLOR_BLUE}|💡" ;;
  WARN) echo "${COLOR_YELLOW}|🚨" ;;
  ERROR) echo "${COLOR_RED}|🚫" ;;
  FATAL) echo "${COLOR_RED}|💀" ;;
  SUCCESS) echo "${COLOR_GREEN}|✅" ;;
  *) echo "${COLOR_GRAY}|📌" ;;
  esac
}

#######################################
# 将日志级别名称转换为数值（内部函数）
#
# 用于比较日志级别的优先级。
#
# Arguments:
#   $1 - 日志级别名称
#
# Outputs:
#   日志级别对应的数值 (0-5)，未知级别返回 -1
#
# Returns:
#   0 - 总是成功
#######################################
_normalize_log_level() {
  case "$1" in
  TRACE) echo 0 ;;
  DEBUG) echo 1 ;;
  INFO | SUCCESS) echo 2 ;;
  WARN) echo 3 ;;
  ERROR) echo 4 ;;
  FATAL) echo 5 ;;
  *) echo -1 ;;
  esac
}

# LOG_LEVEL 合法性校验：未知级别会让级别过滤整体失效（所有日志放行或全部丢弃），必须显式纠正
if [[ "$(_normalize_log_level "${LOG_LEVEL}")" == "-1" ]]; then
  printf '[%s] [🚨 WARN] [common] 未知 LOG_LEVEL=%s，已回退为 INFO（可选值: TRACE|DEBUG|INFO|WARN|ERROR|FATAL）\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_LEVEL}" >&2
  LOG_LEVEL="INFO"
fi

#######################################
# 执行命令：输出实时透传，同时留存完整输出供失败诊断
#
# 用法: run_capture [--append] <留存文件> <命令...>
#
# Returns:
#   命令自身的退出码（而非 tee 的退出码）
#######################################
run_capture() {
  local mode="w"
  if [[ "${1:-}" == "--append" ]]; then
    mode="a"
    shift
  fi
  local capture_file="$1"
  local rc=0
  shift
  if [[ "${mode}" == "a" ]]; then
    "$@" 2>&1 | tee -a "${capture_file}" || rc="${PIPESTATUS[0]}"
  else
    "$@" 2>&1 | tee "${capture_file}" || rc="${PIPESTATUS[0]}"
  fi
  return "${rc}"
}

#######################################
# 打印留存的命令输出尾部（FATAL 前的失败现场）
#
# 用法: print_tail <留存文件> [行数，默认 40]
#######################################
print_tail() {
  local capture_file="$1"
  local lines="${2:-40}"
  [[ -s "${capture_file}" ]] || return 0
  tail -n "${lines}" "${capture_file}" 2>/dev/null | sed 's/^/    /' >&2 || true
}

#######################################
# 执行 git 命令，在"元数据抖动"时自动重试
#
# 在 Docker Desktop 的 virtiofs/osxfs 共享挂载上，git 会因瞬时元数据异常误报
# "detected dubious ownership" 或 "Operation not permitted"；同一命令立即重跑即可
# 成功（实测重现与恢复）。这里只对这两类抖动重试，其他错误原样返回。
#
# 用法: git_retry <git 参数...>   （在目标仓库 cwd 或配合 -C 使用）
#
# Returns:
#   最后成功/失败的退出码
#######################################
git_retry() {
  local attempts=3
  local attempt=1
  local output=""

  while [[ "${attempt}" -le "${attempts}" ]]; do
    if output="$(git "$@" 2>&1)"; then
      [[ -n "${output}" ]] && printf '%s\n' "${output}"
      return 0
    fi
    if [[ "${attempt}" -lt "${attempts}" ]] &&
      [[ "${output}" == *"dubious ownership"* || "${output}" == *"Operation not permitted"* ]]; then
      log WARN "git 元数据抖动（第 ${attempt}/${attempts} 次重试）: git $*"
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi
    printf '%s\n' "${output}" >&2
    return 1
  done
  return 1
}

#######################################
# 收割本次构建新增的 OpenWrt 失败日志
#
# OpenWrt 只在失败时把现场写进源码树的 logs/ 目录（如
# logs/package/feeds/packages/<pkg>/dump.txt）；本函数只挑出本次构建新增的部分
# 并打印尾部，避免 FATAL 旁边只有硬编码路径。镜像/签名等阶段的失败不会留下
# 这类日志，此时给出明确提示。
#
# 用法: harvest_build_logs <起始时间戳(epoch)> <源码目录>
#######################################
harvest_build_logs() {
  local started_at="$1"
  local source_dir="$2"
  local log_root="${source_dir}/logs"

  if [[ ! -d "${log_root}" ]]; then
    log WARN "OpenWrt 未产生失败日志目录（${log_root} 不存在，失败可能发生在镜像/签名等阶段）"
    return 0
  fi

  # 只收割本次构建新增的文件；find 不支持 -newermt（精简镜像）时退回全量列出并明确告知
  local find_expr=(-type f)
  if find "${log_root}" -maxdepth 0 -newermt "@${started_at}" >/dev/null 2>&1; then
    find_expr+=(-newermt "@${started_at}")
  else
    log WARN "当前 find 不支持 -newermt，改为列出 logs/ 下全部文件（可能包含历史失败）"
  fi

  local found=0
  local harvested
  while IFS= read -r harvested; do
    [[ -z "${harvested}" ]] && continue
    found=$((found + 1))
    log ERROR "OpenWrt 失败现场: ${harvested}"
    print_tail "${harvested}" 40
  done < <(find "${log_root}" "${find_expr[@]}" 2>/dev/null | sort | head -10)

  if [[ "${found}" -eq 0 ]]; then
    log WARN "OpenWrt 日志目录存在，但本次构建未新增失败日志"
  fi
  return 0
}

#######################################
# 交互式是/否询问（三态：非交互 / 回车 / 超时）
#
# 取值规则：
#   - 非 TTY 或 NON_INTERACTIVE=true：不询问，取 non_tty_default
#   - TTY + 回车（空回答）          ：取 prompt_default（即提示语里大写的那个）
#   - TTY + 超时（timeout 秒无输入）：取 prompt_default
#   - TTY + 明确回答                ：解析 y/yes/n/no，非法值按 prompt_default 并告警
#
# 用法: prompt_yes_no <prompt_default: y|n> <non_tty_default: y|n> <timeout 秒> <提示语>
# 输出: y 或 n（stdout；提示语与告警走 stderr）
#######################################
prompt_yes_no() {
  local prompt_default="$1"
  local non_tty_default="$2"
  local timeout_seconds="$3"
  local prompt_text="$4"
  local answer=""

  if [[ ! -t 0 || "${NON_INTERACTIVE:-false}" == "true" ]]; then
    log INFO "非交互环境：按 ${non_tty_default} 处理（${prompt_text% }）"
    printf '%s\n' "${non_tty_default}"
    return 0
  fi

  local read_args=(-r -p "${prompt_text}")
  [[ "${timeout_seconds}" != "0" ]] && read_args+=(-t "${timeout_seconds}")

  # shellcheck disable=SC2162  # -r 已包含在 read_args 中，shellcheck 无法跨数组追踪
  if read "${read_args[@]}" answer; then
    case "${answer,,}" in
    "") printf '%s\n' "${prompt_default}" ;;
    y | yes) printf 'y\n' ;;
    n | no) printf 'n\n' ;;
    *)
      log WARN "无法识别的输入 '${answer}'，按默认 ${prompt_default} 处理"
      printf '%s\n' "${prompt_default}"
      ;;
    esac
  else
    log WARN "未收到输入（${timeout_seconds} 秒超时或输入结束），按默认 ${prompt_default} 处理"
    printf '%s\n' "${prompt_default}"
  fi
}

#######################################
# 输出格式化的日志消息
#
# 支持多种调用方式：
#   - log LEVEL MESSAGE
#   - log LEVEL CATEGORY MESSAGE
#   - log LEVEL CATEGORY MESSAGE TO_FILE
#
# 日志格式: [时间戳] [级别] [脚本名][分类] 消息
#
# Arguments:
#   $1 - 日志级别 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL|SUCCESS)
#   $2 - 消息内容 或 分类名称
#   $3 - 消息内容（当 $2 是分类时）
#   $4 - 是否写入文件 (true|false，覆盖 LOG_TO_FILE 变量)
#
# Outputs:
#   格式化的日志输出到 stderr
#   如果启用文件记录，同时追加到 LOG_FILE_PATH
#
# Returns:
#   0 - 成功
#   1 - 参数错误
#
# Examples:
#   log INFO "服务已启动"
#   log WARN "网络" "连接超时，正在重试..."
#   log ERROR "数据库" "连接失败" true
#######################################
log() {
  local level="$1"
  local category=""
  local message=""
  local to_file="${LOG_TO_FILE}"

  case $# in
  2) message="$2" ;;
  3)
    category="$2"
    message="$3"
    ;;
  4)
    category="$2"
    message="$3"
    to_file="$4"
    ;;
  *)
    printf 'Usage: log LEVEL [CATEGORY] MESSAGE [TO_FILE]\n' >&2
    return 1
    ;;
  esac

  # 级别过滤：如果当前消息级别低于设定级别，直接返回
  local level_num current_level_num
  level_num=$(_normalize_log_level "${level}")
  current_level_num=$(_normalize_log_level "${LOG_LEVEL}")
  [[ ${level_num} -lt ${current_level_num} ]] && return 0

  # 获取样式
  local style color emoji
  style=$(_get_log_style "${level}")
  color="${style%|*}"
  emoji="${style#*|}"

  # 获取调用脚本名称（去除路径和扩展名）
  local script_name
  script_name=$(basename "${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-unknown}}" .sh)

  # 构建分类标签
  local cat_tag=""
  [[ -n "${category}" ]] && cat_tag=" [${category}]"

  # 输出到 stderr（带颜色）
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%b\n' "[${timestamp}] ${color}[${emoji} ${level}]${COLOR_RESET} [${script_name}]${cat_tag} ${message}" >&2

  # 输出到文件（不带颜色代码）
  if [[ "${to_file}" == "true" ]]; then
    echo "[${timestamp}] [${emoji} ${level}] [${script_name}]${cat_tag} ${message}" >>"${LOG_FILE_PATH}"
  fi
}

#######################################
# 将英文月份缩写转换为中文月份
#
# 用于将英文日期格式转换为中文日期格式。
# 这里刻意不使用关联数组，以免在旧版 bash 上因下标求值而报出
# 难以理解的错误。
#
# Arguments:
#   $1 - 英文月份缩写 (Jan..Dec)
#
# Outputs:
#   中文月份到 stdout；无法识别时输出 "00月"
#
# Returns:
#   0 - 总是成功
#######################################
month_to_cn() {
  case "$1" in
  Jan) printf '01月' ;;
  Feb) printf '02月' ;;
  Mar) printf '03月' ;;
  Apr) printf '04月' ;;
  May) printf '05月' ;;
  Jun) printf '06月' ;;
  Jul) printf '07月' ;;
  Aug) printf '08月' ;;
  Sep) printf '09月' ;;
  Oct) printf '10月' ;;
  Nov) printf '11月' ;;
  Dec) printf '12月' ;;
  *) printf '00月' ;;
  esac
}

#######################################
# HTML 特殊字符转义
#
# 将输入中的 HTML 特殊字符转换为对应的实体编码，
# 防止 XSS 攻击和 HTML 显示错误。
#
# Arguments:
#   None (从 stdin 读取)
#
# Outputs:
#   转义后的文本到 stdout
#
# Returns:
#   0 - 成功
#
# Examples:
#   echo '<script>alert("xss")</script>' | html_escape
#   # 输出: &lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;
#######################################
html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

#######################################
# 格式化文件的修改时间为中文日期
#
# 将文件的最后修改时间转换为友好的中文格式。
#
# Arguments:
#   $1 - 文件路径
#
# Outputs:
#   中文格式的日期时间，格式: "YYYY年 MM月 DD日 HH:MM:SS"
#   文件不存在时输出 "-"
#
# Returns:
#   0 - 成功
#   1 - 文件不存在
#
# Examples:
#   format_file_date "/etc/config"
#   # 输出示例: "2025年 06月 16日 14:30:45"
#######################################
format_file_date() {
  local filepath="$1"
  [[ ! -e "${filepath}" ]] && echo "-" && return 1

  local en_date month day time year
  en_date=$(LC_TIME=C date -r "${filepath}" '+%b %d %H:%M:%S %Y')
  read -r month day time year <<<"${en_date}"
  echo "${year}年 $(month_to_cn "${month}") ${day}日 ${time}"
}

#######################################
# 格式化当前时间为中文日期
#
# 将当前系统时间转换为友好的中文格式。
#
# Arguments:
#   None
#
# Outputs:
#   中文格式的当前日期时间
#
# Returns:
#   0 - 成功
#
# Examples:
#   format_current_date
#   # 输出示例: "2025年 06月 16日 14:30:45"
#######################################
format_current_date() {
  local en_date month day time year
  en_date=$(LC_TIME=C date '+%b %d %H:%M:%S %Y')
  read -r month day time year <<<"${en_date}"
  echo "${year}年 $(month_to_cn "${month}") ${day}日 ${time}"
}

#######################################
# 计算文件的 SHA256 哈希值
#
# Arguments:
#   $1 - 文件路径
#
# Outputs:
#   64 位十六进制 SHA256 哈希值
#   文件不存在时输出 "-"
#
# Returns:
#   0 - 成功（包括文件不存在的情况）
#
# Examples:
#   calculate_sha256 "firmware.bin"
#   # 输出: "a1b2c3d4e5f6..."
#######################################
calculate_sha256() {
  [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || echo "-"
}

#######################################
# 截取哈希值的前 8 位
#
# 用于显示简短的哈希值，方便阅读和比较。
#
# Arguments:
#   $1 - 完整的哈希值字符串
#
# Outputs:
#   前 8 位哈希值，如果输入是 "-" 或长度不足则原样返回
#
# Returns:
#   0 - 成功
#
# Examples:
#   truncate_hash "a1b2c3d4e5f6789012345678"
#   # 输出: "a1b2c3d4"
#######################################
truncate_hash() {
  local hash="$1"
  [[ "${hash}" != "-" && ${#hash} -ge 8 ]] && echo "${hash:0:8}" || echo "${hash}"
}

#######################################
# 格式化文件大小为人类可读格式
#
# 将字节数转换为 B/K/M/G 单位。
#
# Arguments:
#   $1 - 文件大小（字节）
#
# Outputs:
#   格式化后的大小字符串 (如 "1.5M", "256K")
#
# Returns:
#   0 - 成功
#
# Examples:
#   format_file_size 1048576
#   # 输出: "1M"
#######################################
format_file_size() {
  local size=$1
  if ((size < 1024)); then
    echo "${size}B"
  elif ((size < 1048576)); then
    echo "$((size / 1024))K"
  elif ((size < 1073741824)); then
    echo "$((size / 1048576))M"
  else
    echo "$((size / 1073741824))G"
  fi
}

#######################################
# 检查文件是否存在，不存在则退出脚本
#
# 用于在脚本开始时验证必需文件，失败时输出详细错误信息并退出。
#
# Arguments:
#   $1 - 文件路径
#   $2 - 自定义错误消息（可选，默认: "文件不存在"）
#
# Outputs:
#   如果文件不存在，输出 FATAL 级别日志和调试信息到 stderr
#
# Returns:
#   不返回（文件不存在时直接 exit 1）
#
# Examples:
#   require_file "/etc/config/network" "网络配置文件缺失"
#   require_file "$CONFIG_FILE"
#######################################
require_file() {
  local file="$1"
  local msg="${2:-文件不存在}"
  if [[ ! -f "${file}" ]]; then
    log FATAL "${msg}"
    log ERROR "文件路径: ${file}"
    log ERROR "当前目录: $(pwd)"
    [[ -n "${BASH_SOURCE[1]:-}" ]] && log ERROR "调用位置: ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
    exit 1
  fi
}

# 实例配置的默认路径（仓库内的 config/site.json，含 defaults 段）。
# 用 common.sh 自身位置推导成绝对路径，脚本从任意目录调用都能读到。
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly _REPO_ROOT
readonly SITE_CONFIG_DEFAULT="${_REPO_ROOT}/config/site.json"

#######################################
# 读取实例配置值（config/site.json 的点分键路径）
#
# 设备 profile、上游地址、发行线等实例数据都写在 config/site.json 里，脚本只读取、
# 不写死。取值优先用 python3，其次 jq；两者都不可用、配置缺失或键不存在时输出空，
# 由调用方用 ${VAR:-字面缺省值} 兜底（缺省值仍是可改的：改配置即可覆盖）。
#
# Arguments:
#   $1 - 点分键路径（如 defaults.profile）
#   $2 - 配置文件（可选，默认: ${SITE_CONFIG_DEFAULT}）
#
# Outputs:
#   取到的字符串到 stdout（未取到则输出空行）
#
# Returns:
#   0 - 无论取没取到都返回 0（由调用方判断空值）
#
# Examples:
#   profile="$(config_value defaults.profile)"
#   profile="${profile:-bananapi_bpi-r4}"
#######################################
config_value() {
  local key="$1"
  local config="${2:-${SITE_CONFIG_DEFAULT}}"

  [[ -f "${config}" ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(0)
for part in sys.argv[2].split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(0)
    value = value[part]
print(value if isinstance(value, str) else "")
' "${config}" "${key}" 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    jq -r --arg path "${key}" 'getpath($path | split(".")) // ""' "${config}" 2>/dev/null |
      grep -v '^null$'
  fi
}

#######################################
# 读取某个固件条目里的配置值（config/site.json 的 firmwares[]）
#
# Arguments:
#   $1 - 固件 id（匹配 firmwares[].id）
#   $2 - 条目内的键（如 downloads / repo）
#   $3 - 配置文件（可选，默认: ${SITE_CONFIG_DEFAULT}）
#
# Outputs:
#   取到的字符串到 stdout（未取到则输出空行）
#
# Examples:
#   url="$(config_firmware_value openwrt downloads)"
#######################################
config_firmware_value() {
  local firmware="$1"
  local key="$2"
  local config="${3:-${SITE_CONFIG_DEFAULT}}"

  [[ -f "${config}" ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(0)
entry = next((item for item in data.get("firmwares") or []
              if isinstance(item, dict) and item.get("id") == sys.argv[2]), None)
value = (entry or {}).get(sys.argv[3])
print(value if isinstance(value, str) else "")
' "${config}" "${firmware}" "${key}" 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    jq -r --arg id "${firmware}" --arg key "${key}" \
      'first(.firmwares[]? | select(.id == $id) | .[$key] // "") // ""' "${config}" 2>/dev/null |
      grep -v '^null$'
  fi
}

#######################################
# 读取固件的上游仓库地址（config/site.json 的 firmwares[].repo）
#
# 「检测哪个上游、编译哪个上游」都走这一个出口：更新检测（source-update.sh）与
# 源码克隆（source-management.sh）读的是同一份配置，不会出现"检测的分支和编译的
# 分支不是一回事"。配置缺项（或读取工具不可用）时按 GitHub 约定地址兜底，保持
# 历史行为不变。
#
# Arguments:
#   $1 - 固件 id（如 openwrt / immortalwrt）
#   $2 - 配置文件（可选，默认: ${SITE_CONFIG_DEFAULT}）
#
# Outputs:
#   仓库地址到 stdout（永远非空）
#
# Examples:
#   url="$(firmware_repo_url openwrt)"
#######################################
firmware_repo_url() {
  local firmware="$1"
  local config="${2:-${SITE_CONFIG_DEFAULT}}"
  local url

  url="$(config_firmware_value "${firmware}" repo "${config}")"
  printf '%s\n' "${url:-https://github.com/${firmware}/${firmware}.git}"
}

#######################################
# 读取固件的上游开发分支（config/site.json 的 firmwares[].branch）
#
# 快照版编译与快照版更新检测都以该分支为准：source-management.sh 用它挑
# 克隆/切分支的引用，source-update.sh 用它查最新提交。配置缺项（或读取工具
# 不可用）时退回历史映射（openwrt → main，其余 → master），行为与从前一致。
#
# Arguments:
#   $1 - 固件 id（如 openwrt / immortalwrt）
#   $2 - 配置文件（可选，默认: ${SITE_CONFIG_DEFAULT}）
#
# Outputs:
#   分支名到 stdout（永远非空）
#
# Examples:
#   branch="$(firmware_snapshot_branch openwrt)"   # 输出: main
#######################################
firmware_snapshot_branch() {
  local firmware="$1"
  local config="${2:-${SITE_CONFIG_DEFAULT}}"
  local branch

  branch="$(config_firmware_value "${firmware}" branch "${config}")"
  if [[ -z "${branch}" ]]; then
    [[ "${firmware}" == "openwrt" ]] && branch="main" || branch="master"
  fi
  printf '%s\n' "${branch}"
}

#######################################
# 检查目录是否存在，不存在则退出脚本
#
# 用于在脚本开始时验证必需目录，失败时输出详细错误信息并退出。
#
# Arguments:
#   $1 - 目录路径
#   $2 - 自定义错误消息（可选，默认: "目录不存在"）
#
# Outputs:
#   如果目录不存在，输出 FATAL 级别日志和调试信息到 stderr
#
# Returns:
#   不返回（目录不存在时直接 exit 1）
#
# Examples:
#   require_dir "/build/output" "构建输出目录缺失"
#   require_dir "$WORK_DIR"
#######################################
require_dir() {
  local dir="$1"
  local msg="${2:-目录不存在}"
  if [[ ! -d "${dir}" ]]; then
    log FATAL "${msg}"
    log ERROR "目录路径: ${dir}"
    log ERROR "当前目录: $(pwd)"
    [[ -n "${BASH_SOURCE[1]:-}" ]] && log ERROR "调用位置: ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
    exit 1
  fi
}

#######################################
# 显示脚本帮助信息
#
# 输出格式化的帮助文档，包括脚本描述、用法、参数、示例等。
# 帮助信息从调用脚本的顶部注释中自动提取，或由调用者传入。
#
# Arguments:
#   $1 - 脚本名称
#   $2 - 脚本描述（简短说明）
#   $3 - 用法示例（如：[options] <source_dir>）
#   $@ (从 $4 开始) - 参数说明行，格式: "  --param=VALUE    说明文字"
#
# Outputs:
#   格式化的帮助文档到 stdout
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   show_help "build.sh" \
#     "编译 OpenWrt/ImmortalWrt 固件" \
#     "[options] [source_dir]" \
#     "  -h, --help              显示此帮助信息" \
#     "  --source-dir=PATH       源码目录路径 (默认: .)" \
#     "  --log-level=LEVEL       日志级别 (默认: INFO)"
#######################################
show_help() {
  local script_name="$1"
  local description="$2"
  local usage="$3"
  shift 3

  cat <<EOF
${description}

用法: ${script_name} ${usage}

选项:
EOF

  # 打印所有参数说明
  for line in "$@"; do
    echo "${line}"
  done

  cat <<EOF

环境变量:
  LOG_LEVEL       设置日志级别 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL)
  LOG_TO_FILE     启用日志文件输出 (true|false)
  LOG_FILE_PATH   指定日志文件路径

示例:
  ${script_name} --help
  查看完整的用法说明（位于脚本顶部注释）

作者: Shuery-Shuai
EOF
}

#######################################
# 解析命令行参数
#
# 统一的参数解析函数，支持以下格式：
#   - 位置参数: script.sh value1 value2
#   - 长选项: --param=value 或 --param value
#   - 短选项: -h
#   - 混合模式: script.sh --param=value positional_arg
#
# 解析后的参数存储在关联数组中，调用者需要声明 declare -A PARSED_ARGS
#
# Arguments:
#   $@ - 所有命令行参数
#
# Outputs:
#   填充 PARSED_ARGS 关联数组
#   位置参数存储在 PARSED_ARGS[_POSITIONAL_0], [_POSITIONAL_1] 等
#
# Returns:
#   0 - 解析成功
#   1 - 遇到无效参数
#
# Examples:
#   declare -A PARSED_ARGS
#   parse_args "$@"
#   source_dir="${PARSED_ARGS[source-dir]:-${PARSED_ARGS[_POSITIONAL_0]:-.}}"
#
# Note:
#   PARSED_ARGS 由调用者在外部声明并在函数返回后读取，
#   Shell Check 无法跨函数边界追踪此用法，故在函数内禁用 SC2034。
#######################################
# shellcheck disable=SC2034  # PARSED_ARGS 由调用者声明和使用
# 无值布尔选项：写 `--flag` 等价于 `--flag=true`，且永不吞掉后面的位置参数
BOOLEAN_OPTIONS=(h help ask-menuconfig non-interactive no-retry-serial allow-diy-failure no-log-file capture-build-log no-capture-build-log)

parse_args() {
  local positional_index=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --*=*)
      # 格式: --key=value
      local key="${1#--}"
      key="${key%%=*}"
      local value="${1#*=}"
      PARSED_ARGS["${key}"]="${value}"
      log DEBUG "解析参数: --${key}='${value}'"
      shift
      ;;
    --*)
      # 格式: --key value 或 --flag
      local key="${1#--}"
      local is_boolean="false"
      local bool_option
      for bool_option in "${BOOLEAN_OPTIONS[@]}"; do
        if [[ "${key}" == "${bool_option}" ]]; then
          is_boolean="true"
          break
        fi
      done
      if [[ "${is_boolean}" == "true" ]]; then
        # 布尔选项：恒为 true，不消费下一个参数
        PARSED_ARGS["${key}"]="true"
        log DEBUG "解析参数: --${key}=true (布尔选项)"
        shift
      elif [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
        # 下一个参数不是选项，视为此选项的值
        PARSED_ARGS["${key}"]="$2"
        log DEBUG "解析参数: --${key}='$2'"
        shift 2
      else
        # 布尔标志
        PARSED_ARGS["${key}"]="true"
        log DEBUG "解析参数: --${key}=true (标志)"
        shift
      fi
      ;;
    -*)
      # 短选项 (如 -h)
      local key="${1#-}"
      PARSED_ARGS["${key}"]="true"
      log DEBUG "解析参数: -${key}=true (短选项)"
      shift
      ;;
    *)
      # 位置参数
      PARSED_ARGS["_POSITIONAL_${positional_index}"]="$1"
      log DEBUG "解析参数: 位置参数[${positional_index}]='$1'"
      positional_index=$((positional_index + 1))
      shift
      ;;
    esac
  done

  # 保存位置参数数量
  PARSED_ARGS["_POSITIONAL_COUNT"]="${positional_index}"
  log DEBUG "参数解析完成: ${positional_index} 个位置参数, $((${#PARSED_ARGS[@]} - positional_index - 1)) 个命名参数"
}

#######################################
# 验证必需参数
#
# 检查关联数组中的必需参数是否存在，如果不存在则报错退出。
#
# Arguments:
#   $1 - 必需参数名（支持多个，用空格分隔）
#
# Globals:
#   PARSED_ARGS - 参数关联数组
#
# Returns:
#   0 - 所有必需参数都存在
#   1 - 有参数缺失（记录错误日志后退出）
#
# Examples:
#   validate_required_args "source-dir firmware version"
#   validate_required_args "profile"
#######################################
validate_required_args() {
  local missing_args=()

  for arg in "$@"; do
    # 检查命名参数是否存在
    if [[ -z "${PARSED_ARGS[$arg]:-}" ]]; then
      missing_args+=("--${arg}")
    fi
  done

  if [[ ${#missing_args[@]} -gt 0 ]]; then
    log ERROR "缺少必需参数: ${missing_args[*]}"
    log ERROR "使用 --help 查看完整用法"
    exit 1
  fi
}

#######################################
# 验证参数值是否在允许列表中
#
# 检查参数值是否为允许的值之一。
#
# Arguments:
#   $1 - 参数名
#   $2 - 参数值
#   $3+ - 允许的值列表
#
# Returns:
#   0 - 参数值有效
#   1 - 参数值无效（记录错误日志后退出）
#
# Examples:
#   validate_enum "firmware" "${firmware}" "openwrt" "immortalwrt"
#   validate_enum "ask-menuconfig" "${ask_menuconfig}" "true" "false"
#######################################
validate_enum() {
  local param_name="$1"
  local param_value="$2"
  shift 2
  local allowed_values=("$@")

  for allowed in "${allowed_values[@]}"; do
    if [[ "${param_value}" == "${allowed}" ]]; then
      return 0
    fi
  done

  log ERROR "参数 --${param_name} 的值 '${param_value}' 无效"
  log ERROR "允许的值: ${allowed_values[*]}"
  exit 1
}

#######################################
# 共享挂载适配（内部函数）
#
# Docker Desktop 在 macOS 上通过 virtiofs/osxfs 暴露宿主目录，元数据操作会偶发
# 失败，导致 git 误报 "detected dubious ownership in repository"（实测：同一条命令
# 立即重跑即成功）。项目内所有仓库都归同一构建用户所有，因此在该类挂载上显式关闭
# 该检查；CI 的 ext4 上不做任何改动。
#
# Arguments:
#   $1 - 用于判定挂载类型的路径
#   $2 - 可选: quiet（命中时不打印日志，由调用方决定如何提示）
#
# Returns:
#   0 - 命中共享挂载（并已设置 git 环境变量）
#   1 - 普通文件系统
#######################################
_detect_shared_mount() {
  local target="$1"
  local quiet="${2:-}"
  local mount_point fstype
  local best=""
  local best_type=""

  while read -r _ mount_point fstype _; do
    case "${target}" in
    "${mount_point}" | "${mount_point%/}"/*)
      if [[ ${#mount_point} -gt ${#best} ]]; then
        best="${mount_point}"
        best_type="${fstype}"
      fi
      ;;
    esac
  done < <(awk '{print $1, $2, $3}' /proc/mounts 2>/dev/null)

  case "${best_type}" in
  virtiofs | osxfs | fuse.osxfs | 9p)
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0=safe.directory
    export GIT_CONFIG_VALUE_0='*'
    export SHARED_MOUNT=true
    if [[ "${quiet}" != "quiet" ]]; then
      log INFO "检测到共享挂载（${best_type}）：已关闭 git dubious-ownership 检查，并提高构建重试次数默认值"
    fi
    return 0
    ;;
  *) return 1 ;;
  esac
}

if [[ -z "${GIT_CONFIG_COUNT:-}" ]]; then
  _detect_shared_mount "${_COMMON_DIR}" || true
fi
