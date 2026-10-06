#!/usr/bin/env bash
#######################################
# 本地发布树 vs 官方 downloads 站 —— 差异比对
#
# 用途：本地构建产物要"完全参考官方发布页"时，用来核对产物树的
# 结构、元数据文件、镜像文件名与 sha256sums 递归性是否与官方一致。
#
# 官方侧数据来源（无需抓 HTML）：dir-index.cgi 的 JSON 接口
#   GET <official>/releases/<ver>/targets/?json
#   → ["<target>/<subtarget>/<file>", ...]
# 注意：该接口只对 targets/ 这一层有效，子目录返回的是 HTML。
#
# 用法:
#   ./compare-with-official.sh [options]
#
# 选项:
#   --firmware=NAME       固件名 (immortalwrt|openwrt, 默认: openwrt)
#   --version=VER          版本号或 snapshots (默认: snapshots)
#   --target=TARGET/SUB    target/subtarget (默认: mediatek/filogic)
#   --device=NAME          只比对本设备镜像 (默认: bananapi_bpi-r4)
#   --local-dir=DIR        本地目录 (默认: public/<firmware>/<version>/targets/<target>)
#   --official-url=URL     官方站根 (默认按固件选择)
#   --json                 以 JSON 输出汇总
#   -h, --help             显示帮助
#
# 退出状态:
#   0 - 比对完成（是否存在差异请读报告结论）
#   1 - 前提不满足（本地目录不存在、官方接口取不到等）
#
# 作者: Shuery-Shuai
# 版本: 1.0.0
#######################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# 官方要求每个 target/subtarget 必须具备的元数据文件
readonly REQUIRED_METADATA=(
  "profiles.json"
  "sha256sums"
  "config.buildinfo"
  "feeds.buildinfo"
  "version.buildinfo"
)

#######################################
# 根据固件名给出官方站根地址
#
# Arguments:
#   $1 - 固件名
#
# Outputs:
#   官方站根 URL 到 stdout
#######################################
_default_official_url() {
  case "$1" in
  openwrt) echo "https://downloads.openwrt.org" ;;
  immortalwrt) echo "https://downloads.immortalwrt.org" ;;
  *) echo "https://downloads.openwrt.org" ;;
  esac
}

#######################################
# 本地版本目录名（releases/<ver> 或 snapshots）
#
# Arguments:
#   $1 - 版本号
#
# Outputs:
#   版本目录名到 stdout
#######################################
_version_dir() {
  local version="$1"
  if [[ "${version}" == "snapshots" ]]; then
    echo "snapshots"
  else
    echo "releases/${version}"
  fi
}

#######################################
# 拉取官方文件清单
#
# Arguments:
#   $1 - 官方站根 URL
#   $2 - 版本目录名（releases/x.y.z 或 snapshots）
#   $3 - target/subtarget
#   $4 - 输出文件路径
#
# Returns:
#   0 - 成功; 1 - 接口不可用
#######################################
_fetch_official_list() {
  local official_url="$1" version_dir="$2" target="$3" out="$4"
  local api="${official_url}/${version_dir}/targets/?json"

  # 首选 dir-index.cgi 的 JSON 接口（发行版镜像支持；部分快照站返回 501）
  if curl -fsSL --max-time 60 "${api}" -o "${out}.raw" 2>/dev/null &&
    python3 - "${out}.raw" "${target}/" "${out}" <<'PY'
import json, sys
raw, prefix, out = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(raw))
if not isinstance(data, list):
    sys.exit(3)
with open(out, "w") as fh:
    for item in data:
        if isinstance(item, str) and item.startswith(prefix):
            fh.write(item[len(prefix):] + "\n")
PY
  then
    rm -f "${out}.raw"
    return 0
  fi

  # 回退：抓该目录的 HTML 列表，抽取文件名（跳过以 / 结尾的目录项）
  local page="${official_url}/${version_dir}/targets/${target}/"
  log WARN "JSON 接口不可用，改用 HTML 列表回退: ${page}"
  if ! curl -fsSL --max-time 60 "${page}" -o "${out}.html"; then
    log ERROR "官方目录页也取不到: ${page}"
    return 1
  fi
  python3 - "${out}.html" "${out}" <<'PY'
import html, re, sys
page, out = sys.argv[1], sys.argv[2]
content = open(page, encoding="utf-8", errors="replace").read()
names = re.findall(r'<td class="n"><a href="([^"]+)">', content)
files = sorted({html.unescape(n) for n in names if not n.endswith("/")})
with open(out, "w") as fh:
    fh.write("".join(name + "\n" for name in files))
PY
  rm -f "${out}.html"
  return 0
}

#######################################
# 统计 sha256sums 的递归性
#
# Arguments:
#   $1 - sha256sums 文件路径
#
# Outputs:
#   "<总行数> <含子目录的行数> <顶层行数>" 到 stdout（文件不存在时输出 "- - -"）
#######################################
_sha256sums_stats() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "- - -"
    return 0
  fi
  awk '
    { total++; if ($2 ~ /\//) nested++; else top++ }
    END { printf "%d %d %d\n", total, nested + 0, top + 0 }
  ' "${file}"
}

#######################################
# 打印两个文件清单的差异
#
# Arguments:
#   $1 - 本地清单文件
#   $2 - 官方清单文件
#   $3 - 差异标题
#   $4 - 是否详细列出（true/false）
#######################################
_diff_lists() {
  local local_list="$1" official_list="$2" title="$3" verbose="$4"
  local only_official only_local
  only_official="$(comm -13 <(sort "${local_list}") <(sort "${official_list}") || true)"
  only_local="$(comm -23 <(sort "${local_list}") <(sort "${official_list}") || true)"

  local n_official n_local
  n_official="$(grep -c . <<<"${only_official}" || true)"
  n_local="$(grep -c . <<<"${only_local}" || true)"

  log INFO "${title}: 仅官方有 ${n_official} 个, 仅本地有 ${n_local} 个"
  if [[ "${verbose}" == "true" ]]; then
    if [[ -n "${only_official}" ]]; then
      echo "${only_official}" | head -10 | sed 's/^/    [仅官方] /'
    fi
    if [[ -n "${only_local}" ]]; then
      echo "${only_local}" | head -10 | sed 's/^/    [仅本地] /'
    fi
  fi
}

#######################################
# 主函数
#######################################
main() {
  declare -A PARSED_ARGS
  parse_args "$@"

  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "compare-with-official.sh" \
      "对比本地发布树与官方 downloads 站的差异" \
      "[options]" \
      "  --firmware=NAME       固件名 (默认: openwrt)" \
      "  --version=VER          版本号或 snapshots (默认: snapshots)" \
      "  --target=TARGET/SUB    target/subtarget (默认: mediatek/filogic)" \
      "  --device=NAME          只比对本设备镜像 (默认: bananapi_bpi-r4)" \
      "  --local-dir=DIR        本地目录（默认按固件/版本推导）" \
      "  --official-url=URL     官方站根" \
      "  --json                 以 JSON 输出汇总"
    exit 0
  fi

  local firmware="${PARSED_ARGS['firmware']:-openwrt}"
  local version="${PARSED_ARGS['version']:-snapshots}"
  local target="${PARSED_ARGS['target']:-mediatek/filogic}"
  local device="${PARSED_ARGS['device']:-bananapi_bpi-r4}"
  local official_url="${PARSED_ARGS['official-url']:-$(_default_official_url "${firmware}")}"
  local version_dir
  version_dir="$(_version_dir "${version}")"

  cd "${SCRIPT_DIR}/.."

  local local_dir="${PARSED_ARGS['local-dir']:-public/${firmware}/${version_dir}/targets/${target}}"
  if [[ ! -d "${local_dir}" ]]; then
    log FATAL "本地目录不存在: ${local_dir}"
    log ERROR "提示：先完成一次本地构建，或用 --local-dir 指定目录"
    exit 1
  fi

  log INFO "本地: ${local_dir}"
  log INFO "官方: ${official_url}/${version_dir}/targets/${target}/"

  WORK_DIR="$(mktemp -d)"
  work="${WORK_DIR}"
  trap 'rm -rf "${WORK_DIR:-}"' EXIT

  # ---------- 官方文件清单 ----------
  if ! _fetch_official_list "${official_url}" "${version_dir}" "${target}" "${work}/official.txt"; then
    exit 1
  fi
  log INFO "官方清单条目数: $(wc -l <"${work}/official.txt" | tr -d ' ')"

  # ---------- 本地文件清单 ----------
  # 只取该目录“直下一层”的文件，才能与官方列表（targets/?json 或目录页）逐项对齐；
  # 子目录（kmods/、packages/）的文件数在下面第 3 节单独统计。
  (cd "${local_dir}" && find . -mindepth 1 -maxdepth 1 -type f | sed 's|^\./||' | sort) >"${work}/local.txt"
  log INFO "本地清单条目数: $(wc -l <"${work}/local.txt" | tr -d ' ')"

  echo
  log INFO "===== 1. 官方必备元数据文件 ====="
  local missing_meta=0 f
  for f in "${REQUIRED_METADATA[@]}"; do
    if [[ -f "${local_dir}/${f}" ]]; then
      log INFO "  ✓ ${f}"
    else
      log ERROR "  ✗ 缺少 ${f}"
      missing_meta=$((missing_meta + 1))
    fi
  done

  echo
  log INFO "===== 2. 本设备镜像（${device}）====="
  grep -E "/${device}[.-]|^${device}[.-]|${device}" "${work}/official.txt" >"${work}/official_device.txt" || true
  grep "${device}" "${work}/local.txt" >"${work}/local_device.txt" || true
  _diff_lists "${work}/local_device.txt" "${work}/official_device.txt" "设备镜像差异" "true"

  echo
  log INFO "===== 3. 子目录文件数（kmods / packages）====="
  # 注意：官方 targets/?json 只覆盖 <target>/<subtarget>/ 直下一层，
  # 子目录条目只能从官方 sha256sums 里统计。
  local official_sha="${work}/official.sha256sums"
  if curl -fsSL --max-time 90 "${official_url}/${version_dir}/targets/${target}/sha256sums" -o "${official_sha}" 2>/dev/null; then
    log INFO "  官方 sha256sums: $(wc -l <"${official_sha}" | tr -d ' ') 行"
  else
    official_sha=""
    log WARN "  取不到官方 sha256sums，跳过子目录与递归性比对"
  fi
  local d
  for d in kmods packages; do
    local n_local n_official
    # 目录可能不存在（如本地无 kmods/）：find 会返回 1，用 || true 兜住，
    # 否则 set -euo pipefail 会让整个脚本静默退出（曾发生：报告停在“官方 sha256sums: N 行”）
    n_local="$({ find "${local_dir}/${d}" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')"
    if [[ -n "${official_sha}" ]]; then
      n_official="$(grep -cE "\*${d}/" "${official_sha}" || true)"
    else
      n_official="-"
    fi
    log INFO "  ${d}/: 本地 ${n_local} 个文件, 官方 ${n_official} 个文件"
  done

  echo
  log INFO "===== 4. sha256sums 递归性 ====="
  local local_stats official_stats
  local_stats="$(_sha256sums_stats "${local_dir}/sha256sums")"
  if [[ -n "${official_sha}" ]]; then
    official_stats="$(_sha256sums_stats "${official_sha}")"
  else
    official_stats="- - -"
  fi
  log INFO "  本地 (总行/含子目录/仅顶层): ${local_stats}"
  log INFO "  官方 (总行/含子目录/仅顶层): ${official_stats}"
  if [[ "${local_stats}" != "- - -" && "${official_stats}" != "- - -" ]]; then
    local l_sub o_sub
    l_sub="$(echo "${local_stats}" | awk '{print $2}')"
    o_sub="$(echo "${official_stats}" | awk '{print $2}')"
    if [[ "${o_sub}" -gt 0 && "${l_sub}" -eq 0 ]]; then
      log ERROR "  ✗ 官方是递归校验和，本地只有顶层条目（检查 CONFIG_BUILDBOT）"
    fi
  fi

  echo
  log INFO "===== 5. 结论 ====="
  log INFO "  缺失元数据文件: ${missing_meta}"
  log INFO "  本地独有文件: $(comm -23 <(sort "${work}/local.txt") <(sort "${work}/official.txt") | wc -l | tr -d ' ')"
  log INFO "  官方独有文件（含该 subtarget 下其它设备，属正常）: $(comm -13 <(sort "${work}/local.txt") <(sort "${work}/official.txt") | wc -l | tr -d ' ')"

  if [[ -n "${PARSED_ARGS['json']:-}" ]]; then
    python3 - "$local_dir" "$official_url" "$version_dir" "$target" "$missing_meta" "${work}/local.txt" "${work}/official.txt" <<'PY'
import json, sys
local_dir, official_url, version_dir, target, missing, lf, of = sys.argv[1:8]
L = set(open(lf).read().split())
O = set(open(of).read().split())
print(json.dumps({
    "local_dir": local_dir,
    "official_url": f"{official_url}/{version_dir}/targets/{target}/",
    "missing_metadata": int(missing),
    "local_files": len(L),
    "official_files": len(O),
    "only_local": sorted(L - O)[:50],
    "only_official": sorted(O - L)[:50],
}, ensure_ascii=False, indent=2))
PY
  fi
}

main "$@"
