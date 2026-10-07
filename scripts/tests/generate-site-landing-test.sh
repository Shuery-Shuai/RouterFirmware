#!/usr/bin/env bash
#######################################
# generate-site-landing.py 回归测试
#
# 全程离线：造一棵假的发布树 + config/site.json + 上游版本事实，逐条验证渲染规则
#   - 声明存在且本地有 → 链接；本地没有 → 纯文本 + 提示（绝不出现死链）
#   - 声明的版本落后于官方 → 提示里给出官方版本，并向 stderr 告警
#   - 快照：目录存在才链接；snapshots: false 不出栏目
#   - 版本归档从发布树派生：排除声明的 stable / oldstable、不含 targets 的半成品
#     目录不进归档、不在官方版本列表里的标「本地构建」
#   - 站点装饰（样式表 / 公钥 / 脚本路径）全部来自配置，未配置就不渲染
#   - --upstream 缺失或损坏时退化为纯声明渲染，不失败
#
# 用法:
#   bash scripts/tests/generate-site-landing-test.sh
#
# 退出状态:
#   0 - 全部断言通过
#   1 - 至少有断言失败
#
# 依赖: bash、python3（仅标准库）；不需要网络
#######################################

# 断言条件是有意用单引号写的：交给 assert() 里的 eval 在断言处求值，
# 因此 shellcheck 看不到这些变量与表达式的使用（SC2016 / SC2034）
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_DIR
readonly LANDING="${REPO_DIR}/scripts/generate-site-landing.py"

ROOT="$(mktemp -d)"
readonly ROOT
trap 'rm -rf "${ROOT}"' EXIT

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s  << %s\n' "$1" "$2"; }
assert() { if eval "$2"; then _pass "$1"; else _fail "$1" "$2"; fi; }

# 断言某个文件里没有某个字符串
refute() { if eval "$2"; then _fail "$1" "$2（不该出现）"; else _pass "$1"; fi; }

# 取站点首页里某个发行版栏目的片段（从标题到下一个 <hr/>）
section() {
  python3 -c '
import sys
text = open(sys.argv[1], encoding="utf-8").read()
rest = text[text.index(sys.argv[2]):]
end = rest.find("<hr/>")
print(rest if end < 0 else rest[:end])
' "$1" "$2"
}

#######################################
# 夹具：发布树 + 配置 + 上游事实
#
# 发布树（本地现实）:
#   immortalwrt 25.12.2 / 24.10.6 有 targets（=声明的 stable / oldstable）
#               24.10.5 / 24.10.4  有 targets（=归档候选）
#               25.11.0            无 targets（半成品，不可链接、不该进归档）
#   immortalwrt snapshots/targets 存在
#   openwrt     25.11.9 有 targets（未被声明 → 归档 + 本地构建）
#               snapshots 不存在；声明的 25.12.4 也不存在（且落后于官方 25.12.5）
#   customfw    目录整体不存在
#######################################
build_fixtures() {
  local version
  for version in 25.12.2 24.10.6 24.10.5 24.10.4; do
    mkdir -p "${ROOT}/public/immortalwrt/releases/${version}/targets"
    printf 'x' >"${ROOT}/public/immortalwrt/releases/${version}/targets/image.bin"
  done
  mkdir -p "${ROOT}/public/immortalwrt/releases/25.11.0"
  mkdir -p "${ROOT}/public/immortalwrt/snapshots/targets"
  mkdir -p "${ROOT}/public/openwrt/releases/25.11.9/targets"

  cat >"${ROOT}/site.json" <<'JSON'
{
  "title": "测试站点",
  "description": "测试用描述",
  "description_en": "Test description",
  "stylesheet": "https://example.invalid/theme.css",
  "package_key": "/assets/common/keys/public-key.pem",
  "scripts_path": "/assets/",
  "firmwares": [
    {"id": "immortalwrt", "title": "ImmortalWrt", "stable": "25.12.2", "oldstable": "24.10.6",
     "snapshots": true, "archive": []},
    {"id": "openwrt", "title": "OpenWrt", "stable": "25.12.4",
     "snapshots": true, "archive": []},
    {"id": "customfw", "title": "CustomFW", "stable": "1.0.0",
     "snapshots": false, "archive": []}
  ]
}
JSON

  # 极简配置：没有站点装饰，用来验证「未配置就不渲染」
  cat >"${ROOT}/bare.json" <<'JSON'
{"firmwares": [{"id": "immortalwrt", "title": "ImmortalWrt", "stable": "25.12.2",
                "oldstable": "24.10.6", "snapshots": true}]}
JSON

  cat >"${ROOT}/upstream.json" <<'JSON'
{
  "schema": 1,
  "fetched_at": "2026-10-07T00:00:00+00:00",
  "firmwares": {
    "immortalwrt": {"source": "https://example.invalid/.versions.json", "state": "fresh",
                    "fetched_at": "2026-10-07T00:00:00+00:00", "stable": "25.12.2",
                    "oldstable": "24.10.6", "upcoming": "",
                    "versions": ["25.12.2", "24.10.6", "24.10.4"]},
    "openwrt": {"source": "https://example.invalid/.versions.json", "state": "fresh",
                "fetched_at": "2026-10-07T00:00:00+00:00", "stable": "25.12.5",
                "oldstable": "24.10.8", "upcoming": "",
                "versions": ["25.12.5", "24.10.8"]}
  }
}
JSON
  printf '%s' '{ this is not json' >"${ROOT}/broken.json"
}

run() {
  python3 "${LANDING}" --public-dir="${ROOT}/public" --config="${ROOT}/site.json" "$@"
}

build_fixtures

echo "### 场景 1: 声明 + 本地现实 + 上游事实（带 --upstream）"
run --upstream="${ROOT}/upstream.json" --quiet >/dev/null 2>"${ROOT}/s1.err"
rc=$?
IDX="${ROOT}/public/immortalwrt/index.html"
OWT="${ROOT}/public/openwrt/index.html"
ROOT_IDX="${ROOT}/public/index.html"
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "站点首页已生成" '[ -f "${ROOT_IDX}" ]'
assert "发行版首页已生成" '[ -f "${IDX}" ] && [ -f "${OWT}" ]'
assert "本地无目录的发行版不写首页" '[ ! -e "${ROOT}/public/customfw/index.html" ]'

assert "本地存在的稳定版给链接" 'grep -q "href=\"/immortalwrt/releases/25.12.2/targets/\"" "${IDX}"'
assert "本地存在的旧稳定版给链接" 'grep -q "href=\"/immortalwrt/releases/24.10.6/targets/\"" "${IDX}"'
assert "快照目录存在 → 给链接" 'grep -q "href=\"/immortalwrt/snapshots/targets/\"" "${IDX}"'

assert "声明的版本本地不存在 → 不给链接（无死链）" \
  '! grep -q "href=\"/openwrt/releases/25.12.4/targets/\"" "${OWT}"'
assert "落后于官方时提示里给出官方版本" 'grep -q "官方已发布 25.12.5" "${OWT}"'
assert "声明落后于官方 → stderr 告警" 'grep -q "落后于官方 25.12.5" "${ROOT}/s1.err"'
assert "快照目录不存在 → 不给链接" '! grep -q "href=\"/openwrt/snapshots/targets/\"" "${OWT}"'

assert "归档来自发布树（本地独有的版本）" 'grep -q "href=\"/immortalwrt/releases/24.10.5/targets/\"" "${IDX}"'
assert "归档不包含声明的 stable / oldstable" \
  '[ "$(grep -c "releases/25.12.2/targets/\|releases/24.10.6/targets/" <<<"$(sed -n "/版本归档/,\$p" "${IDX}")" || true)" = "0" ]'
assert "没有 targets 的半成品目录不进归档" '! grep -q "25.11.0" "${IDX}"'
assert "不在官方列表里的版本标「本地构建」" \
  '[ "$(grep -c "本地构建" "${IDX}")" = "1" ]'
assert "官方列表里的归档版本不标「本地构建」" 'grep -q "href=\"/immortalwrt/releases/24.10.4/targets/\"" "${IDX}"'
assert "未被声明的本地版本进归档并标「本地构建」" \
  'grep -q "href=\"/openwrt/releases/25.11.9/targets/\"" "${OWT}" && grep -q "本地构建" "${OWT}"'

assert "配置了样式表 → 站点首页引用它" 'grep -q "https://example.invalid/theme.css" "${ROOT_IDX}"'
assert "配置了公钥路径 → 渲染公钥行" 'grep -q "/assets/common/keys/public-key.pem" "${IDX}"'
assert "配置了脚本路径 → 渲染构建脚本栏目" 'grep -q "构建脚本与配置" "${ROOT_IDX}"'
assert "无目录的发行版不给「浏览全部文件」链接" '! grep -q "href=\"/customfw/\"" "${ROOT_IDX}"'
assert "snapshots: false → 该栏目不出快照链接" \
  '! grep -q "snapshots/targets" <<<"$(section "${ROOT_IDX}" "CustomFW")"'
assert "其他发行版的快照链接不受影响" \
  'grep -q "snapshots/targets" <<<"$(section "${ROOT_IDX}" "ImmortalWrt")"'
assert "无上游事实的发行版用通用提示" 'grep -q "本镜像尚未构建" "${ROOT_IDX}"'

echo "### 场景 2: 不带 --upstream（纯声明 + 本地现实）"
run --quiet >/dev/null 2>"${ROOT}/s2.err"
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "本地存在仍给链接" 'grep -q "href=\"/immortalwrt/releases/25.12.2/targets/\"" "${IDX}"'
assert "本地不存在仍不给链接" '! grep -q "href=\"/openwrt/releases/25.12.4/targets/\"" "${OWT}"'
assert "无上游时不标「本地构建」" '! grep -q "本地构建" "${IDX}"'
assert "无上游时不产生残缺提示" 'grep -q "本镜像尚未构建" "${OWT}"'

echo "### 场景 3: 极简配置（无站点装饰）"
python3 "${LANDING}" --public-dir="${ROOT}/public" --config="${ROOT}/bare.json" \
  --upstream="${ROOT}/upstream.json" --quiet >/dev/null 2>&1
rc=$?
BARE="${ROOT}/public/index.html"
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "未配置样式表 → 不渲染官方样式表" '! grep -q "theme.css" "${BARE}"'
assert "未配置公钥路径 → 不渲染公钥行" '! grep -q "public-key.pem" "${BARE}"'
assert "未配置脚本路径 → 不渲染构建脚本栏目" '! grep -q "构建脚本与配置" "${BARE}"'
assert "未配置的双语文案回退中文" 'grep -q "本页由构建流程自动生成" "${BARE}"'

echo "### 场景 4: 上游事实缺失 / 损坏"
run --upstream="${ROOT}/gone.json" --quiet >/dev/null 2>"${ROOT}/s4.err"
assert "缺失时退出码 0" '[ "$?" = "0" ]'
assert "缺失时告警并退化渲染" 'grep -q "退化为纯声明渲染" "${ROOT}/s4.err"'
run --upstream="${ROOT}/broken.json" --quiet >/dev/null 2>"${ROOT}/s5.err"
assert "损坏时退出码 0" '[ "$?" = "0" ]'
assert "损坏时告警" 'grep -q "无法解析" "${ROOT}/s5.err"'

echo "### 场景 5: 缓存来源的上游事实会提示可能不新鲜"
python3 - <<PY >"${ROOT}/cached.json"
import json
data = json.load(open("${ROOT}/upstream.json", encoding="utf-8"))
data["firmwares"]["openwrt"]["state"] = "cache"
json.dump(data, open("${ROOT}/cached.json", "w", encoding="utf-8"))
PY
run --upstream="${ROOT}/cached.json" --quiet >/dev/null 2>"${ROOT}/s6.err"
assert "退出码 0" '[ "$?" = "0" ]'
assert "缓存来源会告警" 'grep -q "来自缓存" "${ROOT}/s6.err"'

echo
echo "结果: ${PASS} 通过, ${FAIL} 失败"
[ "${FAIL}" -eq 0 ]
