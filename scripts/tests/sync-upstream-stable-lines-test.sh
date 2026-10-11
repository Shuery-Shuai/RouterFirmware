#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_DIR
readonly SYNC="${REPO_DIR}/scripts/sync-upstream-stable-lines.py"

ROOT="$(mktemp -d)"
readonly ROOT
trap 'rm -rf "${ROOT}"' EXIT

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s  << %s\n' "$1" "$2"; }
assert() { if eval "$2"; then _pass "$1"; else _fail "$1" "$2"; fi; }

cat >"${ROOT}/site.json" <<'JSON'
{
  "keep_stable": 3,
  "firmwares": [
    {"id": "openwrt", "title": "OpenWrt", "repo": "https://example.invalid",
     "downloads": "https://example.invalid",
     "stable": "25.12.5", "oldstable": null}
  ]
}
JSON
cat >"${ROOT}/upstream.json" <<'JSON'
{
  "firmwares": {
    "openwrt": {
      "state": "fresh",
      "stable": "26.04.1",
      "oldstable": "25.12.5",
      "versions": [
        "26.04.1", "26.04.0-rc1", "25.12.5", "24.10.8", "23.05.7"
      ]
    }
  }
}
JSON

run() {
  python3 "${SYNC}" --config="${ROOT}/site.json" --upstream="${ROOT}/upstream.json" "$@"
}
field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["firmwares"][0][sys.argv[2]])' \
    "${ROOT}/site.json" "$1"
}

echo "### 同步最近 N 条稳定发行线"
run >/dev/null
rc=$?
assert "同步成功" '[ "${rc}" = "0" ]'
assert "stable 更新为最新稳定版本" '[ "$(field stable)" = "26.04.1" ]'
assert "oldstable 更新为第二条稳定线" '[ "$(field oldstable)" = "25.12.5" ]'
assert "tracked_lines 包含最近 3 条稳定线" \
  '[ "$(field tracked_lines)" = "['\''26.04'\'', '\''25.12'\'', '\''24.10'\'']" ]'
assert "RC 不被选为稳定版本" '[ "$(field oldstable)" != "26.04.0-rc1" ]'
PLAN="$(bash "${REPO_DIR}/scripts/upstream-tag.sh" plan --config="${ROOT}/site.json" 2>/dev/null)"
assert "标签计划包含所有自动跟踪发行线" \
  '[ "$(python3 -c '\''import json,sys; print(len(json.loads(sys.argv[1])))'\'' "${PLAN}")" = "3" ]'

echo "### 拒绝缓存数据并保留官方 stable / oldstable 的 0 值行为"
python3 - "${ROOT}/upstream.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["firmwares"]["openwrt"]["state"] = "cache"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
cp "${ROOT}/site.json" "${ROOT}/before.json"
if run >/dev/null 2>"${ROOT}/error"; then
  _fail "缓存数据应被拒绝" "脚本返回 0"
else
  _pass "缓存数据被拒绝"
fi
assert "拒绝缓存时配置不变" 'cmp -s "${ROOT}/before.json" "${ROOT}/site.json"'
assert "错误说明数据非 fresh" 'grep -q "不是本次新抓取" "${ROOT}/error"'

cat >"${ROOT}/site.json" <<'JSON'
{"keep_stable": 0, "firmwares": [
{"id": "openwrt", "repo": "https://example.invalid",
 "downloads": "https://example.invalid"}
]}
JSON
python3 - "${ROOT}/upstream.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["firmwares"]["openwrt"]["state"] = "fresh"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
run >/dev/null
rc=$?
assert "keep_stable=0 同步成功" '[ "${rc}" = "0" ]'
assert "keep_stable=0 只用官方 stable / oldstable 两条线" \
  '[ "$(field tracked_lines)" = "['\''26.04'\'', '\''25.12'\'']" ]'

echo
echo "结果: ${PASS} 通过, ${FAIL} 失败"
[ "${FAIL}" -eq 0 ]
