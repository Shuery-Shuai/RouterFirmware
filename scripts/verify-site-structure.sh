#!/usr/bin/env bash
#######################################
# 站点目录结构校验与清理（发布前守门）
#
# 在部署到 GitHub Pages 之前检查 public/ 的目录结构，避免把结构损坏的站点发出去。
#
# 两类问题分开处理：
#   多余 —— 不属于站点声明的内容（嵌套 public/、白名单之外的顶层条目、旧 SPA 资产、
#     被跳过路径里的列表页）：--prune 模式直接删除（优先删除，不让部署失败）；
#     校验模式只告警，提示该跑 --prune。
#   缺失 —— 发布必需的内容（公钥、targets/packages、元数据文件、列表页、落地页）：
#     一律断言失败，绝不"修复"，缺失发出去就是坏站点。
#
# 历史事故：public.zip 打包时带上了顶层 public/，部署流程又解包到 public/，
# 于是线上出现 public/public/** 的整站副本，站点体积凭空翻倍（且这些文件
# 全部可被 HTTP 访问）。这类多余内容现在由 --prune 删除，同时告警。
#
# 断言:
#   1. 不存在嵌套的 public/ 目录                                （多余）
#   2. 顶层条目只允许白名单内的名字（含 site.json 的固件）        （多余）
#   3. {firmware}/snapshots 与 {firmware}/releases/<version> 同时含 targets 与 packages（缺失）
#   4. 每个 targets/<target>/<subtarget> 含 profiles.json、sha256sums、*.buildinfo（缺失）
#   5. 不残留旧 SPA 资产（assets/web、*.index.json、items.json）  （多余）
#   6. 带 --require-listings 时，每个发布目录都要有生成的 index.html（缺失）
#   6b. 被跳过的路径（站点 chrome）里不得出现列表页               （多余）
#   7. 站点发布的公钥与仓库 public-key.pem 一致                  （缺失）
#   8. 站点根与各发行版根必须是落地页（发行版目录不存在时跳过）    （缺失）
#
# 体积只记录，不作为失败条件。
#
# 用法:
#   ./verify-site-structure.sh [options]
#
# 选项:
#   --public-dir=DIR        待校验/清理目录 (默认: public)
#   --config=FILE           站点配置，用于确定固件名单 (默认: config/site.json)
#   --firmwares=a,b         固件目录名（覆盖 site.json 里的清单）
#   --require-listings      要求每个发布目录都存在 index.html
#   --prune                 删除多余内容（只清理，不校验缺失项）
#   -h, --help              显示此帮助信息
#
# 退出状态:
#   0 - 全部断言通过（允许有警告）
#   1 - 至少一条断言失败，或清理目标越出 PUBLIC_DIR 边界
#
# 安全边界：拒绝在 / 与仓库根目录上执行；每次删除前校验目标位于 PUBLIC_DIR 内。
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

readonly DEFAULT_SITE_CONFIG="config/site.json"

# 生成列表页时必须跳过的路径（相对 public 根）——与
# scripts/generate-site-listings.py 的 DEFAULT_SKIP_PATHS 保持一致：
# 站点自身资源（字体/CSS/JS/搜索索引）属于站点 chrome，不作为可下载内容列出。
readonly SKIP_LISTING_PATHS=("assets/site")

# 本脚本的布尔开关：让 parse_args 把它们当标志处理（不消费后一个参数）
BOOLEAN_OPTIONS+=(prune require-listings)

# 校验结果收集（一次跑完所有断言，而不是碰到第一个错就退出）
FAILURES=()
WARNINGS=()

# 清理模式开关与清理记录
PRUNE="false"
PRUNED=()

# PUBLIC_DIR 的物理绝对路径：清理边界校验的基准
PUBLIC_DIR_ABS=""

# 固件目录名单（来自 --firmwares 或 site.json）
FIRMWARES=()

#######################################
# 记录一条失败断言
#
# Arguments:
#   $1 - 失败描述
#######################################
_fail() {
  FAILURES+=("$1")
  log ERROR "$1"
}

#######################################
# 记录一条警告（不影响退出码）
#
# Arguments:
#   $1 - 警告描述
#######################################
_warn() {
  WARNINGS+=("$1")
  log WARN "$1"
}

#######################################
# 判断某个值是否在给定列表中
#
# Arguments:
#   $1 - 待查找的值
#   $@ - 候选列表
#
# Returns:
#   0 - 命中; 1 - 未命中
#######################################
_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "${needle}" == "${item}" ]] && return 0
  done
  return 1
}

#######################################
# 判断名字能否安全用作路径片段
#
# 固件名会拼进 ${PUBLIC_DIR}/<name> 并参与清理边界判断，因此必须是纯名字。
#
# Arguments:
#   $1 - 待校验的名字
#
# Returns:
#   0 - 安全; 1 - 为空、含路径字符，或为 . / ..
#######################################
_is_safe_name() {
  local name="$1"
  [[ -n "${name}" && "${name}" != "." && "${name}" != ".." ]] || return 1
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]]
}

#######################################
# 读取 site.json 里声明的固件 id
#
# Arguments:
#   $1 - 站点配置路径
#
# Outputs:
#   每行一个固件 id 到 stdout
#
# Returns:
#   0 - 解析成功; 1 - 缺 python3 或配置解析失败
#######################################
_site_config_ids() {
  local config="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    log ERROR "解析站点配置需要 python3，但未找到"
    return 1
  fi
  python3 - "${config}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
for firmware in data.get("firmwares") or []:
    firmware_id = (firmware or {}).get("id")
    if firmware_id:
        print(firmware_id)
PY
}

#######################################
# 确定固件目录名单
#
# 站点发布哪些固件由 --firmwares 或 config/site.json 决定：site.json 是站点内容的
# 唯一声明来源，顶层白名单与"多余内容"清理都基于这份名单。
#
# Arguments:
#   $1 - --firmwares 的原始取值（可为空）
#   $2 - 站点配置路径
#
# Globals:
#   FIRMWARES
#######################################
_load_firmwares() {
  local explicit="$1" config="$2"
  local -a names=()
  local ids line

  if [[ -n "${explicit}" ]]; then
    IFS=',' read -r -a names <<<"${explicit// /}"
    log INFO "固件名单来自 --firmwares: ${names[*]}"
  else
    require_file "${config}" "站点配置不存在，无法确定固件名单（可用 --firmwares 覆盖）"
    if ! ids="$(_site_config_ids "${config}")"; then
      log FATAL "站点配置解析失败: ${config}"
      exit 1
    fi
    while IFS= read -r line; do
      [[ -n "${line}" ]] && names+=("${line}")
    done <<<"${ids}"
    if ((${#names[@]} == 0)); then
      log FATAL "${config} 里没有声明任何 firmwares[].id"
      exit 1
    fi
    log INFO "固件名单来自 ${config}: ${names[*]}"
  fi

  for line in "${names[@]}"; do
    if ! _is_safe_name "${line}"; then
      log FATAL "固件名不能作为目录名使用: '${line}'（只允许字母、数字、. _ -）"
      exit 1
    fi
  done
  FIRMWARES=("${names[@]}")
}

#######################################
# 处理一条"多余内容"
#
# --prune 模式删除该路径；校验模式只告警。删除前校验目标必须位于 PUBLIC_DIR 内，
# 越界一律记为失败并拒绝删除。
#
# Arguments:
#   $1 - 目标路径（绝对路径）
#   $2 - 原因描述
#
# Globals:
#   PUBLIC_DIR_ABS
#   PRUNE
#   PRUNED
#######################################
_prune() {
  local target="$1" reason="$2"

  # 用 -e 或 -L 判定：断掉的符号链接也属于多余内容，必须能删掉
  [[ -e "${target}" || -L "${target}" ]] || return 0

  if [[ "${target}" != "${PUBLIC_DIR_ABS}/"* ]]; then
    _fail "拒绝处理 PUBLIC_DIR 之外的路径: ${target}（${reason}）"
    return 1
  fi

  if [[ "${PRUNE}" != "true" ]]; then
    _warn "存在多余内容（--prune 会删除）: ${target}（${reason}）"
    return 0
  fi

  rm -rf -- "${target}"
  PRUNED+=("${target}（${reason}）")
  log WARN "已清理多余内容: ${target}（${reason}）"
}

#######################################
# 处理四类多余内容
#
# 与"缺失"类断言分开：这里的问题都能靠删除解决，删不掉才算失败。
#
# Globals:
#   PUBLIC_DIR_ABS
#######################################
_prune_extras() {
  _prune "${PUBLIC_DIR_ABS}/public" "嵌套 public/——压缩包层级错误，会造成整站副本"
  _prune_top_level
  _prune_legacy_spa
  _prune_skipped_listings
}

#######################################
# 断言 2: 顶层条目白名单（白名单之外的条目属于多余内容）
#
# Globals:
#   PUBLIC_DIR
#   PUBLIC_DIR_ABS
#   FIRMWARES
#######################################
_prune_top_level() {
  shopt -s nullglob
  # favicon.ico / favicon.svg / apple-touch-icon.png 由 scripts/build-site-icon.py 生成并随仓库提交：
  # 浏览器对 /favicon.ico 是"无 link 也请求"，所以三个文件必须待在站点根，不能挪进 assets/。
  local allowed=("assets" "index.html" "404.html" "CNAME" ".nojekyll"
                 "favicon.ico" "favicon.svg" "apple-touch-icon.png" "${FIRMWARES[@]}")
  local entry name
  for entry in "${PUBLIC_DIR}"/* "${PUBLIC_DIR}"/.[!.]*; do
    name="$(basename "${entry}")"
    if ! _in_list "${name}" "${allowed[@]}"; then
      _prune "${PUBLIC_DIR_ABS}/${name}" "顶层白名单之外的条目"
    fi
  done
  shopt -u nullglob
}

#######################################
# 断言 3: 版本树必须同时含 targets 与 packages
#
# Arguments:
#   $1 - 固件目录名
#
# Globals:
#   PUBLIC_DIR
#######################################
_check_version_trees() {
  local firmware="$1"
  local base="${PUBLIC_DIR}/${firmware}"

  if [[ ! -d "${base}" ]]; then
    _warn "固件目录不存在，跳过: ${base}"
    return 0
  fi

  local sub
  if [[ -d "${base}/snapshots" ]]; then
    for sub in targets packages; do
      [[ -d "${base}/snapshots/${sub}" ]] ||
        _fail "${base}/snapshots 缺少 ${sub}/ 目录"
    done
  fi

  if [[ -d "${base}/releases" ]]; then
    shopt -s nullglob
    local version_dirs=("${base}/releases"/*/)
    shopt -u nullglob
    local vdir vname found=false
    for vdir in "${version_dirs[@]}"; do
      vname="$(basename "${vdir}")"
      # 官方布局中 releases/packages-<major.minor> 是共享包目录，不含 targets
      [[ "${vname}" == packages-* ]] && continue
      found=true
      for sub in targets packages; do
        [[ -d "${vdir}${sub}" ]] ||
          _fail "${vdir%/} 缺少 ${sub}/ 目录"
      done
    done
    [[ "${found}" == "true" ]] || _warn "${base}/releases 下没有任何版本目录"
  fi

  if [[ ! -d "${base}/snapshots" && ! -d "${base}/releases" ]]; then
    _warn "${base} 下既没有 snapshots/ 也没有 releases/"
  fi
}

#######################################
# 断言 4: 每个 target/subtarget 必须含官方元数据文件
#
# Arguments:
#   $1 - 固件目录名
#
# Globals:
#   PUBLIC_DIR
#######################################
_check_target_metadata() {
  local firmware="$1"
  local roots=()

  [[ -d "${PUBLIC_DIR}/${firmware}/snapshots" ]] &&
    roots+=("${PUBLIC_DIR}/${firmware}/snapshots")

  if [[ -d "${PUBLIC_DIR}/${firmware}/releases" ]]; then
    shopt -s nullglob
    local version_dirs=("${PUBLIC_DIR}/${firmware}/releases"/*/)
    shopt -u nullglob
    local vdir vname
    for vdir in "${version_dirs[@]}"; do
      vname="$(basename "${vdir}")"
      [[ "${vname}" == packages-* ]] && continue
      roots+=("${vdir%/}")
    done
  fi

  local root td
  for root in "${roots[@]}"; do
    shopt -s nullglob
    local target_dirs=("${root}/targets"/*/*/)
    shopt -u nullglob
    for td in "${target_dirs[@]}"; do
      [[ -f "${td}profiles.json" ]] || _fail "${td}缺少 profiles.json"
      [[ -f "${td}sha256sums" ]] || _fail "${td}缺少 sha256sums"
      shopt -s nullglob
      local buildinfo=("${td}"*.buildinfo)
      shopt -u nullglob
      ((${#buildinfo[@]} > 0)) || _fail "${td}缺少 *.buildinfo（config/feeds/version）"
    done
  done
}

#######################################
# 断言 5: 旧 SPA 资产属于多余内容（assets/web、*.index.json、items.json）
#
# Globals:
#   PUBLIC_DIR_ABS
#######################################
_prune_legacy_spa() {
  _prune "${PUBLIC_DIR_ABS}/assets/web" "旧 SPA 资产目录"

  local leftovers=() path
  while IFS= read -r path; do
    [[ -n "${path}" ]] && leftovers+=("${path}")
  done < <(find "${PUBLIC_DIR_ABS}" \( -name '.index.json' -o -name 'items.json' \) 2>/dev/null)

  ((${#leftovers[@]} == 0)) && return 0
  for path in "${leftovers[@]}"; do
    _prune "${path}" "旧索引文件"
  done
}

#######################################
# 断言 6: 每个发布目录都要有生成的 index.html
#
# Arguments:
#   $1 - 固件目录名
#
# Globals:
#   PUBLIC_DIR
#######################################
_check_listings() {
  local firmware="$1"
  local base="${PUBLIC_DIR}/${firmware}"
  [[ -d "${base}" ]] || return 0

  local total=0 missing=0 dir rel p skip
  while IFS= read -r dir; do
    rel="${dir#"${base}"/}"
    # 与生成器共用同一份跳过契约：站点 chrome 子树与隐藏目录都不生成列表页
    skip=false
    for p in "${SKIP_LISTING_PATHS[@]}"; do
      [[ "${rel}" == "${p}" || "${rel}" == "${p}/"* ]] && skip=true
    done
    case "$(basename "${dir}")" in .*) skip=true ;; esac
    [[ "${skip}" == "true" ]] && continue

    total=$((total + 1))
    if [[ ! -f "${dir}/index.html" ]]; then
      missing=$((missing + 1))
      ((missing <= 5)) && _fail "缺少目录列表页: ${dir}/index.html"
    fi
  done < <(find "${base}" -type d 2>/dev/null)

  if ((missing > 5)); then
    _fail "另有 $((missing - 5)) 个目录缺少 index.html（共 ${total} 个目录，缺 ${missing} 个）"
  else
    log INFO "[${firmware}] 目录列表页覆盖: $((total - missing))/${total}"
  fi
}

#######################################
# 断言 6b: 被跳过的路径里出现列表页说明生成器跳过规则失效——列表页属于多余内容
#
# 站点 chrome（如 assets/site/**）不应被当成可下载内容：生成器必须跳过它。
#
# Globals:
#   PUBLIC_DIR_ABS
#   SKIP_LISTING_PATHS
#######################################
_prune_skipped_listings() {
  local rel found
  for rel in "${SKIP_LISTING_PATHS[@]}"; do
    [[ -d "${PUBLIC_DIR_ABS}/${rel}" ]] || continue
    while IFS= read -r found; do
      [[ -n "${found}" ]] || continue
      _prune "${found}" "被跳过路径（站点 chrome）里的列表页——生成器跳过规则失效"
    done < <(find "${PUBLIC_DIR_ABS}/${rel}" -name 'index.html' 2>/dev/null)
  done
}

#######################################
# 断言 7: 站点发布的公钥必须与仓库公钥一致
#
# 设备信任锚就是这把公钥（镜像 /etc/apk/keys/ 与站点 /{fw}/public-key.pem
# 来自同一次导出）：站点发错公钥会让用户导入错误的钥匙。
#
# Globals:
#   PUBLIC_DIR
#   FIRMWARES
#######################################
_check_signing_key() {
  local repo_key="keys/public-key.pem"
  if [[ ! -f "${repo_key}" ]]; then
    _warn "仓库公钥不存在，跳过公钥一致性校验: ${repo_key}"
    return 0
  fi

  # 公钥只发布一份（assets/common/keys/）：所有固件共用同一密钥对，
  # 按固件各存一份曾实际分叉（站点上出现过两个不同指纹）。
  local published="${PUBLIC_DIR}/assets/common/keys/public-key.pem"
  if [[ ! -f "${published}" ]]; then
    _fail "${published} 不存在（站点应发布 apk 仓库签名公钥）"
    return 1
  fi
  if ! cmp -s "${repo_key}" "${published}"; then
    _fail "${published} 与 ${repo_key} 不一致（签名密钥与设备信任锚不匹配）"
  fi
}

#######################################
# 断言 8: 站点根与各发行版根必须是落地页
#
# 两个生成器都能写 index.html：落地页归 generate-site-landing.py，目录列表页归
# generate-site-listings.py。若只跑了列表生成器、或执行顺序颠倒，落地页会被
# 目录列表页覆盖（本次就发生过一次）。
#
# 只判"已存在目录的格式"：发行版目录不存在时跳过（site.json 允许先于构建更新，
# 与断言 3 对缺失固件目录的口径一致），目录在却不是落地页仍然失败。
#
# Globals:
#   PUBLIC_DIR
#   FIRMWARES
#######################################
_check_landing_pages() {
  local dirs=("${PUBLIC_DIR}") fw
  for fw in "${FIRMWARES[@]}"; do
    if [[ ! -d "${PUBLIC_DIR}/${fw}" ]]; then
      _warn "发行版目录不存在，跳过落地页校验: ${PUBLIC_DIR}/${fw}"
      continue
    fi
    dirs+=("${PUBLIC_DIR}/${fw}")
  done

  local dir idx
  for dir in "${dirs[@]}"; do
    idx="${dir}/index.html"
    if [[ ! -f "${idx}" ]]; then
      _fail "缺少落地页: ${idx}"
      continue
    fi
    if grep -q 'This directory index page is auto-generated' "${idx}" 2>/dev/null; then
      _fail "${idx} 是目录列表页而非落地页（落地页生成器未运行，或执行顺序颠倒）"
    fi
  done
}

#######################################
# 记录站点体积与清理结果（仅信息，不作为失败条件）
#
# Globals:
#   PUBLIC_DIR
#   PRUNED
#######################################
_report_volume() {
  local kb mb
  kb="$(du -sk "${PUBLIC_DIR}" 2>/dev/null | awk '{print $1}')"
  mb=$((kb / 1024))
  log INFO "站点体积: ${mb} MB（GitHub Pages 上限 1024 MB，仅记录不判定）"
  log INFO "清理条目: ${#PRUNED[@]}"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 站点结构校验"
      echo ""
      echo "- 站点体积: ${mb} MB / 1024 MB"
      echo "- 清理条目: ${#PRUNED[@]}"
      echo "- 失败断言: ${#FAILURES[@]}"
      echo "- 警告: ${#WARNINGS[@]}"
      if ((${#PRUNED[@]} > 0)); then
        echo ""
        echo "已清理："
        printf -- '- %s\n' "${PRUNED[@]:0:20}"
      fi
    } >>"${GITHUB_STEP_SUMMARY}"
  fi
}

#######################################
# 主函数
#
# Arguments:
#   $@ - 命令行参数
#######################################
main() {
  declare -A PARSED_ARGS
  parse_args "$@"

  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "verify-site-structure.sh" \
      "校验站点目录结构并清理多余内容（发布前守门）" \
      "[options]" \
      "  -h, --help              显示此帮助信息" \
      "  --public-dir=DIR        待校验/清理目录 (默认: public)" \
      "  --config=FILE           站点配置，用于确定固件名单 (默认: config/site.json)" \
      "  --firmwares=a,b         固件目录名（覆盖 site.json 里的清单）" \
      "  --require-listings      要求每个发布目录都存在 index.html" \
      "  --prune                 删除多余内容（只清理，不校验缺失项）"
    exit 0
  fi

  PUBLIC_DIR="${PARSED_ARGS['public-dir']:-public}"
  readonly PUBLIC_DIR
  local require_listings="${PARSED_ARGS['require-listings']:-false}"
  local config="${PARSED_ARGS['config']:-${DEFAULT_SITE_CONFIG}}"
  PRUNE="${PARSED_ARGS['prune']:-false}"

  cd "${SCRIPT_DIR}/.."
  require_dir "${PUBLIC_DIR}" "待校验目录不存在"

  PUBLIC_DIR_ABS="$(cd "${PUBLIC_DIR}" && pwd -P)"

  # 清理安全边界：绝不在 / 或仓库根目录上动手（--public-dir=. 会把仓库文件当多余内容删掉）
  local repo_root
  repo_root="$(pwd -P)"
  if [[ "${PUBLIC_DIR_ABS}" == "/" || "${PUBLIC_DIR_ABS}" == "${repo_root}" ]]; then
    log FATAL "拒绝在 ${PUBLIC_DIR_ABS} 上执行（根目录或仓库根目录）"
    exit 1
  fi

  _load_firmwares "${PARSED_ARGS['firmwares']:-}" "${config}"

  if [[ "${PRUNE}" == "true" ]]; then
    log INFO "开始清理站点多余内容: ${PUBLIC_DIR} （固件: ${FIRMWARES[*]}）"
  else
    log INFO "开始校验站点结构: ${PUBLIC_DIR} （固件: ${FIRMWARES[*]}）"
  fi

  # 多余内容：--prune 删除，校验模式只告警
  _prune_extras

  if [[ "${PRUNE}" == "true" ]]; then
    _report_volume
    if ((${#FAILURES[@]} > 0)); then
      log FATAL "多余内容清理失败: ${#FAILURES[@]} 条错误"
      exit 1
    fi
    log SUCCESS "多余内容清理完成（删除 ${#PRUNED[@]} 项）"
    exit 0
  fi

  # 缺失内容：一律失败（删不出来，也不该"修复"）
  _check_signing_key
  _check_landing_pages

  local firmware
  for firmware in "${FIRMWARES[@]}"; do
    _check_version_trees "${firmware}"
    _check_target_metadata "${firmware}"
    if [[ "${require_listings}" == "true" ]]; then
      _check_listings "${firmware}"
    fi
  done

  _report_volume

  if ((${#FAILURES[@]} > 0)); then
    log FATAL "站点结构校验失败: ${#FAILURES[@]} 条断言不通过"
    exit 1
  fi

  log SUCCESS "站点结构校验通过（警告 ${#WARNINGS[@]} 条）"
}

main "$@"
