#!/usr/bin/env bash
#######################################
# 生成「本地预览用」的假发布树
#
# 目的：在没有真实编译产物的情况下，也能在本地看到站点生成器（目录列表页 /
# 落地页 / 覆盖率报告 / 守门脚本）的真实效果。
#
# 模拟的现状（可改参数复现别的场景）:
#   immortalwrt  有 snapshots + 三个稳定版目录（25.12.2 已声明为稳定版，
#                25.12.1 / 24.10.6 / 24.10.9 未声明 → 进归档；24.10.9 不在官方
#                版本列表里 → 页面标「本地构建」）
#   openwrt      完全为空（目录不存在），复现线上「整条线未构建」的状态
#
# 生成的目录都在 .gitignore 忽略范围内（public/<固件>/、public/**/index.html），
# 不会污染 git 工作区。重复执行会先清掉这两个固件目录再重建。
#
# 用法:
#   bash scripts/tests/make-preview-tree.sh [--public-dir=public]
#
# 依赖: bash、coreutils（sha256sum）；不需要网络
#######################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_DIR

PUBLIC_DIR="${REPO_DIR}/public"
for arg in "$@"; do
  case "${arg}" in
  --public-dir=*) PUBLIC_DIR="${arg#*=}" ;;
  -h | --help)
    sed -n '2,25p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "未知参数: ${arg}" >&2
    exit 1
    ;;
  esac
done
readonly PUBLIC_DIR

readonly TARGET_DIR="mediatek/filogic"
readonly DEVICE="bananapi_bpi-r4"

# 造一个 target/subtarget 目录：镜像、profiles.json、sha256sums、buildinfo
# Arguments:
#   $1 - 目录
#   $2 - 版本号（写进 buildinfo / profiles.json）
make_target_dir() {
  local dir="$1"
  local version="$2"
  mkdir -p "${dir}"

  local image="immortalwrt-${TARGET_DIR//\//-}-${DEVICE}-squashfs-sysupgrade.itb"
  local factory="immortalwrt-${TARGET_DIR//\//-}-${DEVICE}-squashfs-factory.bin"
  # 造出有区分度的体积（列表页会显示 KB）
  head -c 2621440 /dev/zero >"${dir}/${image}"
  head -c 4194304 /dev/zero >"${dir}/${factory}"
  head -c 51200 /dev/zero >"${dir}/immortalwrt-imagebuilder-${TARGET_DIR//\//-}.Linux-x86_64.tar.zst"

  # 官方 profiles.json 是「profiles.<profile-id>.images[]」的嵌套形状；
  # 生成器据此把目录拆成 Image Files / Supplementary Files 两张表
  cat >"${dir}/profiles.json" <<JSON
{
  "version_number": "${version}",
  "version_code": "r0-preview",
  "target": "${TARGET_DIR}",
  "profiles": {
    "${DEVICE}": {
      "device_packages": [],
      "images": [
        {"filesystem": "squashfs", "name": "${image}", "type": "sysupgrade"},
        {"filesystem": "squashfs", "name": "${factory}", "type": "factory"}
      ]
    }
  }
}
JSON

  (cd "${dir}" && sha256sum *.itb *.bin *.tar.zst >sha256sums)

  printf 'CONFIG_TARGET_%s=y\n' "${TARGET_DIR//\//_}" >"${dir}/config.buildinfo"
  printf 'src-git packages https://git.openwrt.org/feed/packages.git\n' >"${dir}/feeds.buildinfo"
  printf '%s\n' "${version}" >"${dir}/version.buildinfo"
}

# 一个版本的完整树（releases/<版本> 或 snapshots）
# Arguments:
#   $1 - 固件目录（public/immortalwrt）
#   $2 - 版本号或 snapshots
make_version_tree() {
  local base="$1"
  local version="$2"
  local root

  if [[ "${version}" == "snapshots" ]]; then
    root="${base}/snapshots"
  else
    root="${base}/releases/${version}"
  fi

  make_target_dir "${root}/targets/${TARGET_DIR}" "${version}"
  mkdir -p "${root}/packages"
  head -c 8192 /dev/zero >"${root}/packages/index.json"
  printf 'x' >"${root}/packages/packages.adb"
}

echo "构建本地预览树: ${PUBLIC_DIR}"
rm -rf "${PUBLIC_DIR}/immortalwrt" "${PUBLIC_DIR}/openwrt"

# openwrt 故意留空：目录不创建，复现「整条线未构建」的线上现状

for version in snapshots 25.12.2 25.12.1 24.10.6 24.10.9; do
  make_version_tree "${PUBLIC_DIR}/immortalwrt" "${version}"
  echo "  immortalwrt/${version} ✓"
done

echo "完成（openwrt 保持为空）"
