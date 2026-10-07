#!/usr/bin/env bash
#######################################
# source-update.sh 回归测试
#
# 全程离线：用夹具伪造「站点配置 + 上游仓库」，逐条验证检查逻辑
#   - plan：只跟踪 snapshots: true 的固件；--firmware 过滤；矩阵字段完整（含 url /
#     branch / profile）；无跟踪目标时输出 []
#   - plan 的配置守门：声明了 snapshots 却缺 repo / branch、缺 defaults.profile、
#     JSON 损坏、指定了不在跟踪范围内的固件，都必须报错退出（不静默漏检）
#   - head：查询的是配置里的仓库与分支（用 stub git 记录参数），分支不存在 /
#     返回非提交对象 / 固件未声明时都必须报错退出
#   - 分支单一来源：source-management.sh 的 _get_target_ref（编译侧）与
#     source-update.sh 的 plan（检测侧）必须给出同一个分支
#
# 用法:
#   bash scripts/tests/source-update-test.sh
#
# 退出状态:
#   0 - 全部断言通过
#   1 - 至少有断言失败
#
# 依赖: bash、jq、coreutils；不需要网络（git 用 stub 顶替）
#######################################

# shellcheck disable=SC2016  # assert 的条件串交给 eval 展开，此处不展开是刻意的

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_DIR
readonly CHECKER="${REPO_DIR}/scripts/source-update.sh"
readonly SOURCE_MGMT="${REPO_DIR}/scripts/source-management.sh"

ROOT="$(mktemp -d)"
readonly ROOT
trap 'rm -rf "${ROOT}"' EXIT

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s  << %s\n' "$1" "$2"; }
assert() { if eval "$2"; then _pass "$1"; else _fail "$1" "$2"; fi; }
check() {
  if [[ "$2" == "$3" ]]; then
    _pass "$1"
  else
    _fail "$1" "期望 [${2}] / 实际 [${3}]"
  fi
}

#######################################
# 夹具：站点配置
#
# branch 故意取 ow-trunk / iw-trunk 这种"不像 main/master"的名字：一旦脚本里
# 还留着写死的分支映射，断言立刻失败。legacy 固件用来验证 snapshots: false 的
# 固件不会被跟踪。
#######################################
readonly FIXTURE="${ROOT}/site.json"
readonly FIXTURE_NO_BRANCH="${ROOT}/no-branch.json"
readonly FIXTURE_NO_REPO="${ROOT}/no-repo.json"
readonly FIXTURE_NO_PROFILE="${ROOT}/no-profile.json"
readonly FIXTURE_EMPTY="${ROOT}/empty.json"
readonly FIXTURE_BROKEN="${ROOT}/broken.json"

build_fixtures() {
  cat >"${FIXTURE}" <<'JSON'
{
  "defaults": {"firmware": "immortalwrt", "version": "snapshots", "profile": "bananapi_bpi-r4"},
  "firmwares": [
    {"id": "immortalwrt", "title": "ImmortalWrt", "repo": "https://example.invalid/immortalwrt.git",
     "branch": "iw-trunk", "snapshots": true},
    {"id": "openwrt", "title": "OpenWrt", "repo": "https://example.invalid/openwrt.git",
     "branch": "ow-trunk", "snapshots": true},
    {"id": "legacy", "title": "Legacy", "repo": "https://example.invalid/legacy.git",
     "branch": "master", "snapshots": false}
  ]
}
JSON

  cat >"${FIXTURE_NO_BRANCH}" <<'JSON'
{
  "defaults": {"profile": "bananapi_bpi-r4"},
  "firmwares": [
    {"id": "openwrt", "title": "OpenWrt", "repo": "https://example.invalid/openwrt.git", "snapshots": true}
  ]
}
JSON

  cat >"${FIXTURE_NO_REPO}" <<'JSON'
{
  "defaults": {"profile": "bananapi_bpi-r4"},
  "firmwares": [
    {"id": "openwrt", "title": "OpenWrt", "branch": "main", "snapshots": true}
  ]
}
JSON

  cat >"${FIXTURE_NO_PROFILE}" <<'JSON'
{
  "defaults": {"firmware": "openwrt"},
  "firmwares": [
    {"id": "openwrt", "title": "OpenWrt", "repo": "https://example.invalid/openwrt.git",
     "branch": "main", "snapshots": true}
  ]
}
JSON

  cat >"${FIXTURE_EMPTY}" <<'JSON'
{
  "defaults": {"profile": "bananapi_bpi-r4"},
  "firmwares": []
}
JSON

  printf '%s\n' '{"firmwares": [ {"id": "openwrt", "snapshots": true}' >"${FIXTURE_BROKEN}"
}

#######################################
# stub git：记录调用参数，按环境变量返回固定输出 / 退出码
#   STUB_GIT_LOG     - 参数记录文件
#   STUB_GIT_OUTPUT  - 模拟的 stdout
#   STUB_GIT_EXIT    - 模拟的退出码
#######################################
readonly STUB_BIN="${ROOT}/bin"
readonly STUB_LOG="${ROOT}/git-args.log"
readonly STUB_SHA="0123456789abcdef0123456789abcdef01234567"

build_stub_git() {
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_GIT_LOG}"
if [[ -n "${STUB_GIT_OUTPUT:-}" ]]; then
  printf '%s\n' "${STUB_GIT_OUTPUT}"
fi
exit "${STUB_GIT_EXIT:-0}"
STUB
  chmod +x "${STUB_BIN}/git"
  : >"${STUB_LOG}"
}

# 运行被测试脚本：设置 RC（退出码）与 OUT（stdout）
# Arguments:
#   $1 - 配置文件
#   $@ - 其余参数
run_script() {
  local config="$1"
  shift
  OUT="$(bash "${CHECKER}" "$@" --config="${config}" 2>"${ROOT}/stderr.log")" && RC=0 || RC=$?
}

main() {
  build_fixtures
  build_stub_git
  export STUB_GIT_LOG="${STUB_LOG}"
  export STUB_GIT_OUTPUT=""
  export STUB_GIT_EXIT=0

  printf '\n【plan】检查矩阵\n'
  run_script "${FIXTURE}" plan
  check "plan 成功退出" "0" "${RC}"
  check "plan 输出单行 JSON" "1" "$(printf '%s\n' "${OUT}" | wc -l | tr -d ' ')"
  check "只跟踪 snapshots 为 true 的固件" "immortalwrt,openwrt" "$(jq -r '[.[].firmware] | join(",")' <<<"${OUT}")"
  check "矩阵带上固件展示名" "ImmortalWrt" "$(jq -r '.[0].title' <<<"${OUT}")"
  check "矩阵带上配置里的 url" "https://example.invalid/openwrt.git" "$(jq -r '.[] | select(.firmware == "openwrt") | .url' <<<"${OUT}")"
  check "矩阵带上配置里的 branch" "ow-trunk" "$(jq -r '.[] | select(.firmware == "openwrt") | .branch' <<<"${OUT}")"
  check "矩阵带上缺省 profile" "bananapi_bpi-r4" "$(jq -r '.[0].profile' <<<"${OUT}")"

  run_script "${FIXTURE}" plan --firmware=openwrt
  check "--firmware 过滤成功" "0" "${RC}"
  check "--firmware 只留指定固件" "openwrt" "$(jq -r '[.[].firmware] | join(",")' <<<"${OUT}")"

  run_script "${FIXTURE_EMPTY}" plan
  check "无跟踪固件时成功退出" "0" "${RC}"
  check "无跟踪固件时输出空矩阵" "[]" "${OUT}"

  printf '\n【plan】配置守门（缺口必须报错，不静默漏检）\n'
  run_script "${FIXTURE}" plan --firmware=nosuch
  check "指定未跟踪的固件时报错退出" "1" "${RC}"
  assert "报错点名该固件" 'grep -q "nosuch" "${ROOT}/stderr.log"'

  run_script "${FIXTURE_NO_BRANCH}" plan
  check "声明 snapshots 却缺 branch 时报错退出" "1" "${RC}"
  assert "报错点名缺 branch 的固件" 'grep -q "openwrt" "${ROOT}/stderr.log"'

  run_script "${FIXTURE_NO_REPO}" plan
  check "声明 snapshots 却缺 repo 时报错退出" "1" "${RC}"

  run_script "${FIXTURE_NO_PROFILE}" plan
  check "缺 defaults.profile 时报错退出" "1" "${RC}"
  assert "报错说明缺 profile" 'grep -q "profile" "${ROOT}/stderr.log"'

  run_script "${FIXTURE_BROKEN}" plan
  check "JSON 损坏时报错退出" "1" "${RC}"

  run_script "${ROOT}/not-exist.json" plan
  check "配置文件不存在时报错退出" "1" "${RC}"

  printf '\n【head】上游分支最新提交\n'
  export PATH="${STUB_BIN}:${PATH}"
  export STUB_GIT_OUTPUT="${STUB_SHA}"
  : >"${STUB_LOG}"
  run_script "${FIXTURE}" head --firmware=openwrt
  check "head 输出上游提交" "${STUB_SHA}" "${OUT}"
  assert "查询的是配置里的仓库" 'grep -q "https://example.invalid/openwrt.git" "${STUB_LOG}"'
  assert "查询的是配置里的分支" 'grep -q "refs/heads/ow-trunk" "${STUB_LOG}"'
  assert "没有拉取上游对象（只用 ls-remote）" 'grep -q "ls-remote" "${STUB_LOG}"'

  export STUB_GIT_OUTPUT=""
  run_script "${FIXTURE}" head --firmware=immortalwrt
  check "分支不存在时报错退出" "1" "${RC}"
  assert "报错说明分支不存在" 'grep -q "分支不存在" "${ROOT}/stderr.log"'

  export STUB_GIT_OUTPUT="not-a-commit"
  run_script "${FIXTURE}" head --firmware=openwrt
  check "上游返回非提交对象时报错退出" "1" "${RC}"

  export STUB_GIT_OUTPUT="${STUB_SHA}"
  export STUB_GIT_EXIT=128
  run_script "${FIXTURE}" head --firmware=openwrt
  check "上游访问失败时报错退出" "1" "${RC}"
  export STUB_GIT_EXIT=0

  run_script "${FIXTURE}" head
  check "head 缺 --firmware 时报错退出" "1" "${RC}"

  run_script "${FIXTURE}" head --firmware=legacy
  check "head 未跟踪的固件（snapshots: false）时报错退出" "1" "${RC}"
  assert "报错说明不在跟踪范围" 'grep -q "不在跟踪范围" "${ROOT}/stderr.log"'

  run_script "${FIXTURE}" head --firmware=nosuch
  check "head 未声明的固件时报错退出" "1" "${RC}"

  run_script "${FIXTURE}" unknown-command
  check "未知命令时报错退出" "1" "${RC}"

  run_script "${FIXTURE}" --help
  check "--help 正常退出" "0" "${RC}"
  assert "--help 打印用法" 'grep -q "用法" <<<"${OUT}"'

  printf '\n【单一来源】检测分支 = 编译分支\n'
  # 编译侧（source-management.sh）与检测侧（source-update.sh）读同一份配置：
  # 夹具里的 ow-trunk / iw-trunk 必须原样出现在两边
  local build_ref
  build_ref="$(bash -c "source '${SOURCE_MGMT}'; _get_target_ref openwrt snapshots '${FIXTURE}'")"
  check "夹具：编译侧读到配置分支" "ow-trunk" "${build_ref}"
  run_script "${FIXTURE}" plan --firmware=openwrt
  check "夹具：检测侧读到配置分支" "${build_ref}" "$(jq -r '.[0].branch' <<<"${OUT}")"

  build_ref="$(bash -c "source '${SOURCE_MGMT}'; _get_target_ref immortalwrt snapshots '${FIXTURE}'")"
  check "夹具：另一个固件也读配置分支" "iw-trunk" "${build_ref}"

  build_ref="$(bash -c "source '${SOURCE_MGMT}'; _get_target_ref openwrt 25.12.5 '${FIXTURE}'")"
  check "具体版本仍用标签" "v25.12.5" "${build_ref}"

  # 真实配置：两个固件的检测分支必须与编译分支逐字相同
  local real_plan real_branch build_branch
  real_plan="$(bash "${CHECKER}" plan 2>/dev/null)"
  for firmware in openwrt immortalwrt; do
    real_branch="$(jq -r --arg fw "${firmware}" '.[] | select(.firmware == $fw) | .branch' <<<"${real_plan}")"
    build_branch="$(bash -c "source '${SOURCE_MGMT}'; _get_target_ref '${firmware}' snapshots")"
    check "真实配置：${firmware} 检测分支 = 编译分支" "${build_branch}" "${real_branch}"
    assert "真实配置：${firmware} 分支非空" '[[ -n "${real_branch}" ]]'
  done

  printf '\n----------------------------------------\n'
  printf '通过: %d  失败: %d\n\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]]
}

main "$@"
