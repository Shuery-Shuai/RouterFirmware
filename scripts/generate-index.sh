#!/usr/bin/env bash
#######################################
# 生成文件目录索引 JSON
#
# 递归扫描 public 目录，生成包含文件和目录信息的 JSON 索引文件。
# 索引包括文件名、路径、大小、修改时间、SHA256 哈希值等元数据。
#
# 用法:
#   ./generate-index.sh
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 输出文件:
#   public/assets/web/data/index.json
#
# JSON 结构:
#   {
#     "generated": <unix_timestamp>,
#     "version": "1.0",
#     "items": [
#       {
#         "type": "file|dir",
#         "name": "文件名",
#         "path": "相对路径",
#         "size": 文件大小(字节),
#         "mtime": 修改时间(unix时间戳),
#         "sha256": "SHA256哈希值"
#       },
#       ...
#     ]
#   }
#
# 跳过的内容:
#   - assets/web 目录（避免包含索引文件本身）
#   - source, scripts 目录（源码和脚本不对外提供）
#   - index.html, 404.html, search.html（特殊页面）
#   - 隐藏文件和目录（以 . 开头）
#   - node_modules 目录
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

# 常量定义
readonly PUBLIC_DIR="${SCRIPT_DIR}/../public"
readonly OUTPUT_FILE="${PUBLIC_DIR}/assets/web/data/index.json"

#######################################
# 扫描目录生成 JSON（已弃用，保留供参考）
#
# 注意: 此函数已被 generate_index() 替代，保留是为了兼容性。
#       新代码应使用 generate_index()。
#
# 扫描指定目录的直接子项（非递归），为每个文件和子目录生成 JSON 对象。
# 跳过特定目录和文件以避免包含不必要的内容。
#
# Arguments:
#   $1 - 目录的绝对路径
#   $2 - 目录的相对路径（用于生成 JSON 中的 path 字段），默认: .
#
# Outputs:
#   逗号分隔的 JSON 对象序列到 stdout（不含外层数组括号）
#
# Returns:
#   0 - 成功（即使目录为空）
#
# Examples:
#   scan_directory "/path/to/public" "."
#   scan_directory "/path/to/public/assets" "assets"
#######################################
scan_directory() {
  local dir="$1"
  local rel_path="${2:-.}"
  local -a entries=()

  # 跳过不需要索引的目录
  [[ "${rel_path}" =~ ^\./(assets/web|source|scripts)(/|$) ]] && return

  # 使用 find 扫描目录内容，-print0 处理包含空格的文件名
  while IFS= read -r -d '' item; do
    local name
    name=$(basename "${item}")

    # 跳过特殊文件和隐藏文件
    [[ "${name}" =~ ^(index\.html|404\.html|search\.html|\.git.*|\..*|node_modules)$ ]] && continue

    # 构建相对路径
    local item_path="${rel_path}/${name}"
    [[ "${rel_path}" == "." ]] && item_path="${name}"

    if [[ -d "${item}" ]]; then
      # 目录条目
      local entry
      entry=$(printf '{"type":"dir","name":"%s","path":"%s"}' \
        "${name//\"/\\\"}" \
        "${item_path//\"/\\\"}")
      entries+=("${entry}")
    elif [[ -f "${item}" ]]; then
      # 文件条目：收集大小、修改时间、SHA256
      local size mtime sha256
      size=$(stat -c%s "${item}" 2>/dev/null || echo "0")
      mtime=$(stat -c%Y "${item}" 2>/dev/null || echo "0")
      sha256=$(sha256sum "${item}" 2>/dev/null | awk '{print $1}' || echo "")

      local entry
      entry=$(printf '{"type":"file","name":"%s","path":"%s","size":%s,"mtime":%s,"sha256":"%s"}' \
        "${name//\"/\\\"}" \
        "${item_path//\"/\\\"}" \
        "${size}" "${mtime}" "${sha256}")
      entries+=("${entry}")
    fi
  done < <(find "${dir}" -maxdepth 1 -mindepth 1 -print0 | sort -z)

  # 输出 JSON 数组元素（不含外层括号，由调用者组装）
  if [[ ${#entries[@]} -gt 0 ]]; then
    local first=true
    for entry in "${entries[@]}"; do
      [[ "${first}" == "true" ]] || echo ","
      echo -n "${entry}"
      first=false
    done
  fi
}

#######################################
# 递归扫描生成完整索引
#
# 递归遍历目录树，为每个文件和目录生成一行 JSON 对象。
# 输出的每一行都是完整的 JSON 对象，由主函数组装成最终的 JSON 数组。
#
# 跳过规则:
#   - 文件名为 index.html, 404.html, search.html
#   - 以 . 开头的文件和目录（隐藏文件）
#   - node_modules 目录
#   - source, scripts 目录
#   - assets/web 目录（避免索引文件索引自己）
#
# Arguments:
#   $1 - 目录的绝对路径
#   $2 - 目录的相对路径（用于生成 JSON 中的 path 字段），默认: .
#
# Outputs:
#   每行一个 JSON 对象到 stdout
#   格式: {"type":"...","name":"...","path":"...",...}
#
# Returns:
#   0 - 成功
#
# Examples:
#   generate_index "/path/to/public" "."
#######################################
generate_index() {
  local dir="$1"
  local rel_path="${2:-.}"

  log INFO "扫描: ${rel_path}"

  # 使用 find 扫描当前目录的直接子项
  while IFS= read -r -d '' item; do
    local name
    name=$(basename "${item}")

    #######################################
    # 应用跳过规则
    #######################################
    # 跳过特殊文件
    [[ "${name}" =~ ^(index\.html|404\.html|search\.html|\.git.*|\..*|node_modules|source|scripts)$ ]] && continue

    # 特殊处理 assets 目录：需要递归，但要跳过其下的 web 子目录
    if [[ "${rel_path}" == "." && "${name}" == "assets" ]]; then
      # assets 目录本身需要处理，跳过逻辑在递归时应用
      :
    elif [[ "${rel_path}" == "assets" && "${name}" == "web" ]]; then
      # 跳过 assets/web 目录
      continue
    fi

    # 构建相对路径
    local item_path="${rel_path}/${name}"
    [[ "${rel_path}" == "." ]] && item_path="${name}"

    if [[ -d "${item}" ]]; then
      #######################################
      # 处理目录
      #
      # 输出目录本身的信息，然后递归扫描子目录。
      #######################################
      local mtime
      mtime=$(stat -c%Y "${item}" 2>/dev/null || echo "0")

      # 输出目录的 JSON 对象
      printf '{"type":"dir","name":"%s","path":"%s","mtime":%s}\n' \
        "${name//\"/\\\"}" \
        "${item_path//\"/\\\"}" \
        "${mtime}"

      # 递归扫描子目录
      generate_index "${item}" "${item_path}"

    elif [[ -f "${item}" ]]; then
      #######################################
      # 处理文件
      #
      # 收集文件的元数据：大小、修改时间、SHA256 哈希。
      # SHA256 用于文件完整性验证和去重检测。
      #######################################
      local size mtime sha256
      size=$(stat -c%s "${item}" 2>/dev/null || echo "0")
      mtime=$(stat -c%Y "${item}" 2>/dev/null || echo "0")
      sha256=$(sha256sum "${item}" 2>/dev/null | awk '{print $1}' || echo "")

      # 输出文件的 JSON 对象
      printf '{"type":"file","name":"%s","path":"%s","size":%s,"mtime":%s,"sha256":"%s"}\n' \
        "${name//\"/\\\"}" \
        "${item_path//\"/\\\"}" \
        "${size}" "${mtime}" "${sha256}"
    fi
  done < <(find "${dir}" -maxdepth 1 -mindepth 1 -print0 | sort -z)
}

#######################################
# 主函数
#
# 执行索引生成流程：
#   1. 切换到 public 目录
#   2. 创建输出目录
#   3. 调用 generate_index() 递归扫描生成条目
#   4. 将扫描结果组装成完整的 JSON 文件
#   5. 记录索引项数量
#
# JSON 文件结构:
#   - generated: 生成时间（Unix 时间戳）
#   - version: 索引格式版本号
#   - items: 文件和目录条目数组
#
# Globals:
#   PUBLIC_DIR  - public 目录的绝对路径
#   OUTPUT_FILE - 输出 JSON 文件的绝对路径
#
# Outputs:
#   生成过程的日志到 stderr
#   索引 JSON 文件写入 OUTPUT_FILE
#
# Returns:
#   0 - 成功
#
# Examples:
#   main
#######################################
main() {
  log INFO "开始生成索引"

  # 切换到 public 目录，确保相对路径计算正确
  cd "${PUBLIC_DIR}"

  # 创建输出目录（如果不存在）
  mkdir -p assets/web/data

  #######################################
  # 步骤 1: 扫描目录生成条目
  #
  # 将所有条目输出到临时文件，每行一个 JSON 对象。
  #######################################
  log INFO "扫描 public 目录"
  local tmpfile
  tmpfile=$(mktemp)
  generate_index "." "." >"${tmpfile}"

  #######################################
  # 步骤 2: 组装最终 JSON 文件
  #
  # 结构:
  #   {
  #     "generated": <timestamp>,
  #     "version": "1.0",
  #     "items": [
  #       <条目1>,
  #       <条目2>,
  #       ...
  #     ]
  #   }
  #######################################
  log INFO "生成 JSON 文件"
  {
    echo "{"
    echo "  \"generated\": $(date +%s),"
    echo "  \"version\": \"1.0\","
    echo "  \"items\": ["

    # 读取临时文件中的每个 JSON 对象，用逗号分隔
    local first=true
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      [[ "${first}" == "true" ]] || echo ","
      echo -n "    ${line}"
      first=false
    done <"${tmpfile}"

    echo ""
    echo "  ]"
    echo "}"
  } >"${OUTPUT_FILE}"

  #######################################
  # 统计索引项数量
  #######################################
  local count
  count=$(grep -c '^{' "${tmpfile}" 2>/dev/null || echo "0")
  rm -f "${tmpfile}"

  log INFO "SUCCESS" "索引生成完成: ${OUTPUT_FILE} (${count} 项)"
}

# 执行主函数，传递所有命令行参数
main "$@"
