#!/usr/bin/env bash
#######################################
# 站点目录结构校验（发布前守门）
#
# 在部署到 GitHub Pages 之前检查 public/ 的目录结构，任何一条断言失败都以
# 非零码退出，避免把结构损坏的站点发出去。
#
# 历史事故：public.zip 打包时带上了顶层 public/，部署流程又解包到 public/，
# 于是线上出现 public/public/** 的整站副本，站点体积凭空翻倍（且这些文件
# 全部可被 HTTP 访问）。
#
# 断言:
#   1. 不存在嵌套的 public/ 目录
#   2. 顶层条目只允许白名单内的名字
#   3. {firmware}/snapshots 与 {firmware}/releases/<version> 同时含 targets 与 packages
#   4. 每个 targets/<target>/<subtarget> 含 profiles.json、sha256sums、*.buildinfo
#   5. 不残留旧 SPA 资产（assets/web、*.index.json、items.json）
#   6. 带 --require-listings 时，每个发布目录都要有生成的 index.html
#   6b. 被跳过的路径（站点 chrome）里不得出现列表页
#   7. 站点发布的公钥与仓库 public-key.pem 一致
#   8. 站点根与各发行版根必须是落地页（发行版目录不存在时跳过）
#
# 体积只记录，不作为失败条件。
#
# 用法:
#   ./verify-site-structure.sh [options]
#
# 选项:
#   --public-dir=DIR        待校验目录 (默认: public)
#   --firmwares=a,b         固件目录名 (默认: immortalwrt,openwrt)
#   --require-listings      要求每个发布目录都存在 index.html
#   -h, --help              显示此帮助信息
#
# 退出状态:
#   0 - 全部断言通过（允许有警告）
#   1 - 至少一条断言失败
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

readonly DEFAULT_FIRMWARES="immortalwrt,openwrt"

# 生成列表页时必须跳过的路径（相对 public 根）——与
# scripts/generate-site-listings.py 的 DEFAULT_SKIP_PATHS 保持一致：
# 站点自身资源（字体/CSS/JS/搜索索引）属于站点 chrome，不作为可下载内容列出。
readonly SKIP_LISTING_PATHS=("assets/site")

# 校验结果收集（一次跑完所有断言，而不是碰到第一个错就退出）
FAILURES=()
WARNINGS=()

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
# 断言 1: 不得存在嵌套的 public/ 目录
#
# Globals:
#   PUBLIC_DIR
#######################################
_check_no_nested_public() {
  if [[ -d "${PUBLIC_DIR}/public" ]]; then
    _fail "存在嵌套目录 ${PUBLIC_DIR}/public —— 压缩包层级错误，会造成整站副本"
  fi
}

#######################################
# 断言 2: 顶层条目白名单
#
# Globals:
#   PUBLIC_DIR
#   FIRMWARES
#######################################
_check_top_level() {
  shopt -s nullglob
  # favicon.ico / favicon.svg / apple-touch-icon.png 由 scripts/build-site-icon.py 生成并随仓库提交：
  # 浏览器对 /favicon.ico 是"无 link 也请求"，所以三个文件必须待在站点根，不能挪进 assets/。
  local allowed=("assets" "index.html" "404.html" "CNAME" ".nojekyll"
                 "favicon.ico" "favicon.svg" "apple-touch-icon.png" "${FIRMWARES[@]}")
  local entry name
  for entry in "${PUBLIC_DIR}"/* "${PUBLIC_DIR}"/.[!.]*; do
    name="$(basename "${entry}")"
    if ! _in_list "${name}" "${allowed[@]}"; then
      _fail "顶层出现白名单之外的条目: ${name}"
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
# 断言 5: 不得残留旧 SPA 资产
#
# Globals:
#   PUBLIC_DIR
#######################################
_check_no_legacy_spa() {
  if [[ -d "${PUBLIC_DIR}/assets/web" ]]; then
    _fail "残留旧 SPA 目录 ${PUBLIC_DIR}/assets/web"
  fi

  local leftovers
  leftovers="$(find "${PUBLIC_DIR}" \( -name '.index.json' -o -name 'items.json' \) 2>/dev/null | head -5)"
  if [[ -n "${leftovers}" ]]; then
    _fail "残留旧索引文件: $(echo "${leftovers}" | tr '\n' ' ')"
  fi
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
# 断言 6b: 被跳过的路径里不得出现列表页
#
# 站点 chrome（如 assets/site/**）不应被当成可下载内容：生成器必须跳过它。
# 这里反向断言——一旦发现其中存在 index.html，说明跳过规则失效。
#
# Globals:
#   PUBLIC_DIR
#   SKIP_LISTING_PATHS
#######################################
_check_skipped_paths() {
  local rel found
  for rel in "${SKIP_LISTING_PATHS[@]}"; do
    [[ -d "${PUBLIC_DIR}/${rel}" ]] || continue
    found="$(find "${PUBLIC_DIR}/${rel}" -name 'index.html' 2>/dev/null | head -3)"
    if [[ -n "${found}" ]]; then
      _fail "被跳过的路径 ${rel}/ 中出现了列表页（生成器跳过规则失效）: $(echo "${found}" | tr '\n' ' ')"
    fi
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
# 记录站点体积（仅信息，不作为失败条件）
#
# Globals:
#   PUBLIC_DIR
#######################################
_report_volume() {
  local kb mb
  kb="$(du -sk "${PUBLIC_DIR}" 2>/dev/null | awk '{print $1}')"
  mb=$((kb / 1024))
  log INFO "站点体积: ${mb} MB（GitHub Pages 上限 1024 MB，仅记录不判定）"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 站点结构校验"
      echo ""
      echo "- 站点体积: ${mb} MB / 1024 MB"
      echo "- 失败断言: ${#FAILURES[@]}"
      echo "- 警告: ${#WARNINGS[@]}"
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
      "校验站点目录结构（发布前守门）" \
      "[options]" \
      "  -h, --help              显示此帮助信息" \
      "  --public-dir=DIR        待校验目录 (默认: public)" \
      "  --firmwares=a,b         固件目录名 (默认: immortalwrt,openwrt)" \
      "  --require-listings      要求每个发布目录都存在 index.html"
    exit 0
  fi

  PUBLIC_DIR="${PARSED_ARGS['public-dir']:-public}"
  readonly PUBLIC_DIR
  local require_listings="${PARSED_ARGS['require-listings']:-false}"

  IFS=',' read -r -a FIRMWARES <<<"${PARSED_ARGS['firmwares']:-${DEFAULT_FIRMWARES}}"

  cd "${SCRIPT_DIR}/.."
  require_dir "${PUBLIC_DIR}" "待校验目录不存在"

  log INFO "开始校验站点结构: ${PUBLIC_DIR} （固件: ${FIRMWARES[*]}）"

  _check_no_nested_public
  _check_top_level
  _check_no_legacy_spa
  _check_skipped_paths
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
