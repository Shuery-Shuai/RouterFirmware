#!/usr/bin/env bash
#######################################
# prune-releases.py 回归测试
#
# 在临时目录里搭出发布树夹具，逐条验证稳定版保留裁剪的行为：
# 数量策略、固件级覆盖、声明版本钉住、数值比较、snapshots / packages-* / 无数字
# 目录不动、dry-run 不落盘、非法配置报错、步骤摘要生成。
#
# 裁剪会真的删目录，改 prune-releases.py 的删除逻辑后务必先在这里跑通。
#
# 用法:
#   bash scripts/tests/prune-releases-test.sh
#
# 退出状态:
#   0 - 全部断言通过
#   1 - 至少有断言失败
#
# 依赖: bash、python3（仅标准库）
#######################################

# 断言条件是有意用单引号写的：交给 assert() 里的 eval 在断言处求值，
# 因此 shellcheck 看不到这些变量与表达式的使用（SC2016 / SC2034）
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_DIR
readonly PRUNE="${REPO_DIR}/scripts/prune-releases.py"

ROOT="$(mktemp -d)"
readonly ROOT
trap 'rm -rf "${ROOT}"' EXIT

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s  << %s\n' "$1" "$2"; }
assert() { if eval "$2"; then _pass "$1"; else _fail "$1" "$2"; fi; }

#######################################
# 搭夹具：两种固件 + snapshots + 共享包目录 + 无数字目录 + 隐藏目录
#######################################
build_tree() {
  rm -rf "${ROOT}/public"
  mkdir -p "${ROOT}/public/assets/site"
  local version
  for version in 24.10.2 24.10.11 25.12.5; do
    mkdir -p "${ROOT}/public/openwrt/releases/${version}/targets"
  done
  for version in 24.10.3 25.11.0 25.12.2 25.12.5; do
    mkdir -p "${ROOT}/public/immortalwrt/releases/${version}/targets"
  done
  mkdir -p "${ROOT}/public/immortalwrt/releases/packages-x86_64"
  mkdir -p "${ROOT}/public/immortalwrt/releases/nightly"
  mkdir -p "${ROOT}/public/immortalwrt/snapshots/targets"
  mkdir -p "${ROOT}/public/immortalwrt/.hidden"
  echo keep >"${ROOT}/public/immortalwrt/snapshots/targets/marker"
}

# 站点级 2 个 + openwrt 固件级覆盖为 1 个 + immortalwrt 归档声明 24.10.3
config_a() {
  cat >"${ROOT}/site.json" <<'JSON'
{
  "keep_stable": 2,
  "firmwares": [
    {"id": "immortalwrt", "stable": "25.12.5", "oldstable": null,
     "snapshots": true, "archive": ["24.10.3"]},
    {"id": "openwrt", "keep_stable": 1, "stable": "25.12.5",
     "snapshots": true, "archive": []}
  ]
}
JSON
}

run() { python3 "${PRUNE}" --public-dir="${ROOT}/public" --config="${ROOT}/site.json" "$@"; }

echo "### 场景 1: 站点级 keep_stable=2 + 固件级覆盖 + 声明钉住 + 数值比较"
build_tree
config_a
run --quiet
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "openwrt 固件级 keep_stable=1 生效，仅留 25.12.5" \
  '[ "$(ls "${ROOT}/public/openwrt/releases")" = "25.12.5" ]'
assert "24.10.11 被删（数值比较：24.10.11 > 24.10.2）" \
  '[ ! -d "${ROOT}/public/openwrt/releases/24.10.11" ]'
assert "24.10.2 被删" '[ ! -d "${ROOT}/public/openwrt/releases/24.10.2" ]'
assert "25.11.0 超出 N=2 被删" '[ ! -d "${ROOT}/public/immortalwrt/releases/25.11.0" ]'
assert "25.12.5 保留" '[ -d "${ROOT}/public/immortalwrt/releases/25.12.5" ]'
assert "25.12.2 保留" '[ -d "${ROOT}/public/immortalwrt/releases/25.12.2" ]'
assert "archive 声明的 24.10.3 钉住不删（排在 N 名之外）" \
  '[ -d "${ROOT}/public/immortalwrt/releases/24.10.3" ]'
assert "releases/packages-x86_64 共享目录不动" \
  '[ -d "${ROOT}/public/immortalwrt/releases/packages-x86_64" ]'
assert "无数字目录 nightly 保守保留" '[ -d "${ROOT}/public/immortalwrt/releases/nightly" ]'
assert "snapshots 及其内容不动" '[ -f "${ROOT}/public/immortalwrt/snapshots/targets/marker" ]'
assert "隐藏目录 .hidden 不动" '[ -d "${ROOT}/public/immortalwrt/.hidden" ]'
assert "顶层 assets 不动" '[ -d "${ROOT}/public/assets/site" ]'

echo "### 场景 2: --dry-run 只报告不删除"
build_tree
config_a
OUT="$(run --dry-run)"
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "报告了待删除目录" 'grep -q "dry-run" <<<"${OUT}"'
assert "25.11.0 仍在" '[ -d "${ROOT}/public/immortalwrt/releases/25.11.0" ]'
assert "openwrt 三个版本都在" '[ "$(ls "${ROOT}/public/openwrt/releases" | wc -l)" = "3" ]'

echo "### 场景 3: keep_stable=0 表示不裁剪"
build_tree
cat >"${ROOT}/site.json" <<'JSON'
{"keep_stable": 0, "firmwares": [{"id": "immortalwrt", "stable": "25.12.5"},
                                 {"id": "openwrt", "stable": "25.12.5"}]}
JSON
run --quiet
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "immortalwrt 六个条目全留" '[ "$(ls "${ROOT}/public/immortalwrt/releases" | wc -l)" = "6" ]'

echo "### 场景 4: --protect 钉住本次构建的版本"
build_tree
config_a
run --quiet --protect=25.11.0,24.10.2
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "--protect 的 25.11.0 保留" '[ -d "${ROOT}/public/immortalwrt/releases/25.11.0" ]'
assert "--protect 的 24.10.2 保留" '[ -d "${ROOT}/public/openwrt/releases/24.10.2" ]'
assert "未钉住的 24.10.11 仍被删" '[ ! -d "${ROOT}/public/openwrt/releases/24.10.11" ]'

echo "### 场景 5: 配置非法时明确报错"
build_tree
for bad_json in '{"keep_stable": "two", "firmwares": [{"id": "openwrt"}]}' \
                '{"keep_stable": -1, "firmwares": [{"id": "openwrt"}]}' \
                '{"keep_stable": true, "firmwares": [{"id": "openwrt"}]}' \
                '{"firmwares": [{"stable": "25.12.5"}]}'; do
  printf '%s' "${bad_json}" >"${ROOT}/site.json"
  if run --quiet >/dev/null 2>"${ROOT}/err"; then
    _fail "非法配置被接受: ${bad_json}" "应退出非 0"
  else
    assert "非法配置被拒绝并给出原因: $(head -c 50 "${ROOT}/err")" 'grep -q "错误" "${ROOT}/err"'
  fi
done

echo "### 场景 6: 边界（目录缺失 / 参数非法 / 空清单）"
mkdir -p "${ROOT}/public/emptyfw"
printf '%s' '{"firmwares": [{"id": "nosuchfw"}]}' >"${ROOT}/site.json"
if run --quiet >/dev/null 2>&1; then _pass "缺失 releases/ 的固件优雅跳过"; else _fail "缺失 releases/ 不应失败" "退出码非 0"; fi
printf '%s' '{"firmwares": []}' >"${ROOT}/site.json"
if run --quiet >/dev/null 2>&1; then _pass "空固件清单返回 0"; else _fail "空固件清单不应失败" "退出码非 0"; fi
if run --keep=-3 >/dev/null 2>&1; then _fail "--keep=-3 应被拒绝" "退出码 0"; else _pass "--keep=-3 被拒绝"; fi
if python3 "${PRUNE}" --public-dir="${ROOT}/nope" --config="${ROOT}/site.json" >/dev/null 2>&1; then
  _fail "发布目录不存在应失败" "退出码 0"
else _pass "发布目录不存在时退出 1"; fi
if python3 "${PRUNE}" --public-dir="${ROOT}/public" --config="${ROOT}/nope.json" >/dev/null 2>&1; then
  _fail "配置不存在应失败" "退出码 0"
else _pass "配置不存在时退出 1"; fi

echo "### 场景 7: GITHUB_STEP_SUMMARY 步骤摘要"
build_tree
config_a
GITHUB_STEP_SUMMARY="${ROOT}/summary.md" python3 "${PRUNE}" \
  --public-dir="${ROOT}/public" --config="${ROOT}/site.json" --quiet >/dev/null
rc=$?
assert "退出码 0" '[ "${rc}" = "0" ]'
assert "摘要写入了保留与删除明细" 'grep -q "已删除" "${ROOT}/summary.md"'

echo
echo "结果: ${PASS} 通过, ${FAIL} 失败"
[ "${FAIL}" -eq 0 ]
