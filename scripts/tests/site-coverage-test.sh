#!/usr/bin/env bash
#######################################
# site-coverage.py 回归测试
#
# 全程离线：用夹具伪造「官方版本事实 + 站点声明 + 发布树」，逐条验证比对规则
#   - drift：官方 stable / oldstable 的发行线不在声明里（fail 级）
#   - stale：同线上官方补丁更新（提示级，不失败）
#   - gap：声明了却没有发布（fail 级）
#   - local：本地有、官方列表没有（提示级）
#   - --fail-on 门槛与退出码、--summary 摘要追加、缺上游事实时的行为
#
# 用法:
#   bash scripts/tests/site-coverage-test.sh
#
# 退出状态:
#   0 - 全部断言通过
#   1 - 至少有断言失败
#
# 依赖: bash、python3（仅标准库）；不需要网络
#######################################

# shellcheck disable=SC2016,SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_DIR
readonly COVERAGE="${REPO_DIR}/scripts/site-coverage.py"

ROOT="$(mktemp -d)"
readonly ROOT
trap 'rm -rf "${ROOT}"' EXIT

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s  << %s\n' "$1" "$2"; }
assert() { if eval "$2"; then _pass "$1"; else _fail "$1" "$2"; fi; }

#######################################
# 夹具
#   immortalwrt：声明 stable 25.12.2 / oldstable 24.10.6，两者都已发布；
#                官方 stable 25.12.5（同线 → stale），oldstable 24.10.6（一致）
#   openwrt：声明 stable 25.12.5，官方旧稳定 24.10.8 而未声明任何 24.10 线 → drift；
#            声明的 25.12.5 本地没有 → gap；本地多出 25.11.9 → local
#######################################
build_fixtures() {
  local version
  for version in 25.12.2 25.12.5 24.10.6; do
    mkdir -p "${ROOT}/public/immortalwrt/releases/${version}/targets"
  done
  mkdir -p "${ROOT}/public/openwrt/releases/25.11.9/targets"

  cat >"${ROOT}/site.json" <<'JSON'
{
  "firmwares": [
    {"id": "immortalwrt", "title": "ImmortalWrt", "stable": "25.12.2", "oldstable": "24.10.6"},
    {"id": "openwrt", "title": "OpenWrt", "stable": "25.12.5"}
  ]
}
JSON

  cat >"${ROOT}/upstream.json" <<'JSON'
{
  "schema": 1,
  "fetched_at": "2026-10-07T00:00:00+00:00",
  "firmwares": {
    "immortalwrt": {"state": "fresh", "fetched_at": "2026-10-07T00:00:00+00:00",
                    "stable": "25.12.5", "oldstable": "24.10.6", "upcoming": "",
                    "versions": ["25.12.5", "25.12.2", "24.10.6"]},
    "openwrt": {"state": "fresh", "fetched_at": "2026-10-07T00:00:00+00:00",
                "stable": "25.12.5", "oldstable": "24.10.8", "upcoming": "",
                "versions": ["25.12.5", "24.10.8"]}
  }
}
JSON
}

run() {
  python3 "${COVERAGE}" --config="${ROOT}/site.json" \
    --upstream="${ROOT}/upstream.json" --public-dir="${ROOT}/public" "$@"
}

build_fixtures

echo "### 场景 1: 报告内容与分级"
OUT="$(run 2>&1)"
rc=$?
assert "退出码 0（缺省 --fail-on=none 只报告）" '[ "${rc}" = "0" ]'
assert "报告含 Markdown 标题" 'grep -q "## 站点覆盖率" <<<"${OUT}"'
assert "报告含三方对比表" 'grep -q "| 发行版 | 官方稳定 |" <<<"${OUT}"'
assert "drift：官方旧稳定线未声明" 'grep -q "\*\*drift\*\*（openwrt）" <<<"${OUT}"'
assert "stale：同线上官方补丁更新" 'grep -q "\*\*stale\*\*（immortalwrt）" <<<"${OUT}"'
assert "gap：声明了却没发布" 'grep -q "\*\*gap\*\*（openwrt）" <<<"${OUT}"'
assert "local：本地有、官方没有" 'grep -q "\*\*local\*\*（openwrt）" <<<"${OUT}"'
assert "与官方一致的项不报 drift" '! grep -q "\*\*drift\*\*（immortalwrt）" <<<"${OUT}"'

echo "### 场景 2: --fail-on 门槛"
run --fail-on=drift >/dev/null 2>&1
assert "drift 门槛 → 退出 1" '[ "$?" = "1" ]'
run --fail-on=gap >/dev/null 2>&1
assert "gap 门槛 → 退出 1" '[ "$?" = "1" ]'
run --fail-on=any >/dev/null 2>&1
assert "any 门槛 → 退出 1" '[ "$?" = "1" ]'
run --fail-on=none >/dev/null 2>&1
assert "none 门槛 → 退出 0" '[ "$?" = "0" ]'

echo "### 场景 3: 全部对齐时任意门槛都通过"
cat >"${ROOT}/aligned.json" <<'JSON'
{"firmwares": [{"id": "immortalwrt", "title": "ImmortalWrt",
                "stable": "25.12.5", "oldstable": "24.10.6"}]}
JSON
python3 "${COVERAGE}" --config="${ROOT}/aligned.json" --upstream="${ROOT}/upstream.json" \
  --public-dir="${ROOT}/public" --fail-on=any --quiet >/dev/null 2>&1
assert "对齐后退出 0" '[ "$?" = "0" ]'

echo "### 场景 4: 只做本地检查（无上游事实）"
python3 "${COVERAGE}" --config="${ROOT}/site.json" --public-dir="${ROOT}/public" \
  --fail-on=none >/dev/null 2>&1
assert "缺上游仍退出 0" '[ "$?" = "0" ]'
python3 "${COVERAGE}" --config="${ROOT}/site.json" --public-dir="${ROOT}/public" \
  --fail-on=gap >/dev/null 2>&1
assert "无上游时 gap 仍可判定 → 退出 1" '[ "$?" = "1" ]'
python3 "${COVERAGE}" --config="${ROOT}/site.json" --public-dir="${ROOT}/public" \
  --fail-on=drift >/dev/null 2>&1
assert "无上游却要求判 drift → 用法错误 2" '[ "$?" = "2" ]'

echo "### 场景 5: 摘要追加与参数错误"
printf '## 前置内容\n' >"${ROOT}/summary.md"
run --summary="${ROOT}/summary.md" --quiet >/dev/null 2>&1
assert "退出码 0" '[ "$?" = "0" ]'
assert "摘要保留原有内容" 'grep -q "## 前置内容" "${ROOT}/summary.md"'
assert "摘要追加覆盖率报告" 'grep -q "## 站点覆盖率" "${ROOT}/summary.md"'
if python3 "${COVERAGE}" --config="${ROOT}/nope.json" >/dev/null 2>&1; then
  _fail "配置不存在应退出 2" "退出码 0"
else _pass "配置不存在时退出 2"; fi
if python3 "${COVERAGE}" --config="${ROOT}/site.json" --fail-on=bogus >/dev/null 2>&1; then
  _fail "非法 --fail-on 应被拒绝" "退出码 0"
else _pass "非法 --fail-on 被拒绝"; fi

echo
echo "结果: ${PASS} 通过, ${FAIL} 失败"
[ "${FAIL}" -eq 0 ]
