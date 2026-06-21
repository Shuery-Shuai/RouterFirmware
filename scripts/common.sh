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
: "${LOG_TO_FILE:=false}"
: "${LOG_FILE_PATH:=/tmp/openwrt_build_$(date +%Y%m%d_%H%M%S).log}"

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
  INFO) echo 2 ;;
  WARN) echo 3 ;;
  ERROR) echo 4 ;;
  FATAL) echo 5 ;;
  *) echo -1 ;;
  esac
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
# 月份英文缩写到中文的映射表
#
# 用于将英文日期格式转换为中文日期格式。
#
# Globals:
#   MONTHS - 关联数组，键为英文月份缩写，值为中文月份
#######################################
declare -r -A MONTHS=(
  [Jan]="01月" [Feb]="02月" [Mar]="03月" [Apr]="04月"
  [May]="05月" [Jun]="06月" [Jul]="07月" [Aug]="08月"
  [Sep]="09月" [Oct]="10月" [Nov]="11月" [Dec]="12月"
)

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
  echo "${year}年 ${MONTHS[${month}]:-00月} ${day}日 ${time}"
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
  echo "${year}年 ${MONTHS[${month}]:-00月} ${day}日 ${time}"
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
      if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
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
