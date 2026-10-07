#!/usr/bin/env bash
#######################################
# fetch-upstream-versions.py 回归测试
#
# 全程离线：用 file:// 夹具冒充上游 .versions.json，逐条验证
#   - 归一化：脏条目丢弃、重复去重、前导 v 去掉、字段映射、目录形式补路径
#   - 退路：抓取失败回退缓存（保留原 fetched_at）、无缓存则失败且不写产物
#   - 离线模式、未登记固件跳过、残缺 payload 拒绝、参数与配置错误
# 改本脚本的取数 / 回退逻辑后务必先在这里跑通。
#
# 用法:
#   bash scripts/tests/fetch-upstream-versions-test.sh
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
readonly FETCH="${REPO_DIR}/scripts/fetch-upstream-versions.py"

ROOT="$(mktemp -d)"
readonly ROOT
trap 'rm -rf "${ROOT}"' EXIT

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s  << %s\n' "$1" "$2"; }
assert() { if eval "$2"; then _pass "$1"; else _fail "$1" "$2"; fi; }

# 取产物字段：field <文件> <固件|-> <键>
field() {
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
value = data if sys.argv[2] == "-" else data["firmwares"][sys.argv[2]]
print(value[sys.argv[3]])
' "$1" "$2" "$3"
}

# 取某固件 versions 的逗号连接串
versions() {
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(data["firmwares"][sys.argv[2]]["versions"]))
' "$1" "$2"
}

#######################################
# 夹具：三个上游 payload（含脏数据）+ 站点配置 + 残缺 payload
#######################################
build_fixtures() {
  # 上游地址来自 config 的 downloads 字段；customfw 故意不声明（应被跳过并告警）
  cat >"${ROOT}/site.json" <<JSON
{
  "firmwares": [
    {"id": "immortalwrt", "downloads": "file://${ROOT}/immortalwrt.json"},
    {"id": "openwrt", "downloads": "file://${ROOT}/upstream/openwrt"},
    {"id": "customfw", "stable": "1.0.0"}
  ]
}
JSON
  # 含脏条目：重复项、前导 v、数字、null、空串、非版本字符串
  cat >"${ROOT}/immortalwrt.json" <<'JSON'
{"stable_version": "25.12.2", "oldstable_version": "24.10.6", "upcoming_version": "",
 "versions_list": ["25.12.2", "25.12.1", "25.12.2", "v25.12.0", 42, null, "", "garbage", "24.10.6"]}
JSON
  # openwrt 用「目录 + /.versions.json」形式，覆盖路径补全分支
  mkdir -p "${ROOT}/upstream/openwrt"
  cat >"${ROOT}/upstream/openwrt/.versions.json" <<'JSON'
{"stable_version": "25.12.5", "oldstable_version": "24.10.8", "upcoming_version": "25.12.6-rc1",
 "versions_list": ["25.12.5", "24.10.8"]}
JSON
  printf '%s' '{"versions_list": ["1.0.0"]}' >"${ROOT}/missing-stable.json"
  printf '%s' '{"stable_version": "1.0.0"}' >"${ROOT}/missing-list.json"
  printf '%s' '["not", "an", "object"]' >"${ROOT}/not-object.json"
  printf '%s' '{"stable_version": "9.9.9", "versions_list": ["1.0.0"]}' >"${ROOT}/inconsistent.json"
  # 两个固件都声明了抓不到的地址（模拟断网）
  cat >"${ROOT}/site-broken.json" <<JSON
{"firmwares": [{"id": "immortalwrt", "downloads": "file://${ROOT}/gone.json"},
               {"id": "openwrt", "downloads": "file://${ROOT}/gone.json"}]}
JSON
  printf '%s' '{"firmwares": [{"id": "nosuchfw"}]}' >"${ROOT}/site-unknown.json"
}

run() {
  python3 "${FETCH}" --config="${ROOT}/site.json" "$@"
}

# 模拟断网：两个固件声明的地址都不存在
run_broken() {
  python3 "${FETCH}" --config="${ROOT}/site-broken.json" "$@"
}

build_fixtures

echo "### 场景 1: 正常抓取 + 归一化"
run --output="${ROOT}/art.json" --quiet >/dev/null 2>"${ROOT}/s1.err"
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "schema=1" '[ "$(field "${ROOT}/art.json" - schema)" = "1" ]'
assert "顶层 fetched_at 非空" '[ -n "$(field "${ROOT}/art.json" - fetched_at)" ]'
assert "immortalwrt stable 映射正确" '[ "$(field "${ROOT}/art.json" immortalwrt stable)" = "25.12.2" ]'
assert "immortalwrt oldstable 映射正确" '[ "$(field "${ROOT}/art.json" immortalwrt oldstable)" = "24.10.6" ]'
assert "脏条目丢弃 + 去重 + 前导 v 归一化" \
  '[ "$(versions "${ROOT}/art.json" immortalwrt)" = "25.12.2,25.12.1,25.12.0,24.10.6" ]'
assert "丢弃的脏条目有告警" 'grep -q "不是合法版本号" "${ROOT}/s1.err"'
assert "state=fresh" '[ "$(field "${ROOT}/art.json" immortalwrt state)" = "fresh" ]'
assert "目录形式的 downloads 补上 /.versions.json" \
  '[ "$(field "${ROOT}/art.json" openwrt source)" = "file://${ROOT}/upstream/openwrt/.versions.json" ]'
assert "upcoming 透传" '[ "$(field "${ROOT}/art.json" openwrt upcoming)" = "25.12.6-rc1" ]'
assert "未声明 downloads 的固件不出现在产物里" '! grep -q "customfw" "${ROOT}/art.json"'
assert "未声明 downloads 的固件给出告警" 'grep -q "customfw: config 未声明 downloads" "${ROOT}/s1.err"'
assert "无 .tmp 残留" '[ -z "$(find "${ROOT}" -maxdepth 1 -name "*.tmp" -print -quit)" ]'

echo "### 场景 2: 未声明 downloads 的固件只告警、不阻塞其他固件"
run --output="${ROOT}/art2.json" >/dev/null 2>"${ROOT}/s2.err"
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "已声明固件仍写入产物" '[ "$(field "${ROOT}/art2.json" openwrt stable)" = "25.12.5" ]'
assert "stderr 告警提到 customfw" 'grep -q "customfw" "${ROOT}/s2.err"'

echo "### 场景 2b: --source 覆盖 config 里声明的地址"
run --source=immortalwrt="file://${ROOT}/inconsistent.json" \
  --output="${ROOT}/override.json" --quiet >/dev/null 2>&1
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "覆盖生效（9.9.9 来自被覆盖的夹具）" \
  '[ "$(field "${ROOT}/override.json" immortalwrt stable)" = "9.9.9" ]'
assert "未覆盖的固件仍用 config 地址" \
  '[ "$(field "${ROOT}/override.json" openwrt stable)" = "25.12.5" ]'

echo "### 场景 3: 抓取失败且无缓存 → 退出 1，不写产物"
run_broken --output="${ROOT}/none.json" --cache="${ROOT}/no-cache.json" >/dev/null 2>&1
rc=$?
assert "退出码 1" '[ "${rc}" = "1" ]'
assert "未写出残缺产物" '[ ! -e "${ROOT}/none.json" ]'

echo "### 场景 4: 抓取失败 → 回退缓存（保留原抓取时间）"
BEFORE="$(field "${ROOT}/art.json" openwrt fetched_at)"
run_broken --output="${ROOT}/fallback.json" --cache="${ROOT}/art.json" \
  >/dev/null 2>"${ROOT}/s4.err"
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "两个固件都标记为 cache" \
  '[ "$(field "${ROOT}/fallback.json" immortalwrt state),$(field "${ROOT}/fallback.json" openwrt state)" = "cache,cache" ]'
assert "fetched_at 保留缓存里的原值" \
  '[ "$(field "${ROOT}/fallback.json" openwrt fetched_at)" = "${BEFORE}" ]'
assert "缓存内容未被改写" '[ "$(field "${ROOT}/fallback.json" openwrt stable)" = "25.12.5" ]'
assert "回退有显式告警" 'grep -q "回退到缓存" "${ROOT}/s4.err"'

echo "### 场景 5: --offline 只用缓存"
run_broken --offline --quiet --output="${ROOT}/off.json" --cache="${ROOT}/art.json"
rc=$?
assert "有缓存退出码 0" '[ "${rc}" = "0" ]'
assert "离线产物标记 cache" '[ "$(field "${ROOT}/off.json" immortalwrt state)" = "cache" ]'
run_broken --offline --quiet --output="${ROOT}/off2.json" --cache="${ROOT}/no-cache.json" \
  >/dev/null 2>&1
rc=$?
assert "无缓存退出码 1" '[ "${rc}" = "1" ]'
assert "无缓存时不写产物" '[ ! -e "${ROOT}/off2.json" ]'

echo "### 场景 6: 残缺 / 非法 payload 一律拒绝"
for fixture in missing-stable missing-list not-object; do
  python3 "${FETCH}" --config="${ROOT}/site.json" --output="${ROOT}/bad.json" \
    --cache="${ROOT}/no-cache.json" \
    --source=immortalwrt="file://${ROOT}/${fixture}.json" \
    --source=openwrt="file://${ROOT}/gone.json" >/dev/null 2>&1
  rc=$?
  assert "${fixture}.json 被拒绝（退出 1）" '[ "${rc}" = "1" ]'
  assert "${fixture}.json 不写出产物" '[ ! -e "${ROOT}/bad.json" ]'
done

echo "### 场景 7: stable 不在 versions_list 里 → 告警但成功"
python3 "${FETCH}" --config="${ROOT}/site.json" --output="${ROOT}/inconsistent.json" \
  --cache="${ROOT}/no-cache.json" \
  --source=immortalwrt="file://${ROOT}/inconsistent.json" \
  --source=openwrt="file://${ROOT}/upstream/openwrt" >/dev/null 2>"${ROOT}/s7.err"
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "给出上游数据不一致告警" 'grep -q "不在 versions_list 里" "${ROOT}/s7.err"'

echo "### 场景 8: 参数与配置错误"
if python3 "${FETCH}" --config="${ROOT}/site.json" --source=broken >/dev/null 2>&1; then
  _fail "--source 非法取值应被拒绝" "退出码 0"
else _pass "--source 非法取值被拒绝"; fi
if python3 "${FETCH}" --config="${ROOT}/nope.json" >/dev/null 2>&1; then
  _fail "配置不存在应失败" "退出码 0"
else _pass "配置不存在时退出 1"; fi
if python3 "${FETCH}" --config="${ROOT}/site-unknown.json" \
  --output="${ROOT}/unknown-out.json" >/dev/null 2>&1; then
  _fail "没有任何可抓取固件应失败" "退出码 0"
else _pass "没有可抓取固件时退出 1"; fi

echo
echo "结果: ${PASS} 通过, ${FAIL} 失败"
[ "${FAIL}" -eq 0 ]
