#!/usr/bin/env bash
#######################################
# OpenWrt/ImmortalWrt 编译产物复制脚本
#
# 将编译完成的固件文件从源码目录复制到发布目录：
#   snapshots 版本 → public/<firmware>/snapshots/{targets,packages}/...
#   releases  版本 → public/<firmware>/releases/<版本>/{targets,packages}/...
#
# 说明：站点托管在 GitHub Pages 上——没有服务端软链，且 upload-pages-artifact
# 使用 tar --dereference 会把软链展开成实体副本。因此这里不再创建
# releases/packages-<主次版本> 共享目录与符号链接，packages 直接与 targets
# 同级落盘（与镜像内 apk 源 URL 的 releases/<版本>/packages/... 对应）。
#
# 用法:
#   ./copy-bin-files.sh [FIRMWARE] [VERSION]
#   ./copy-bin-files.sh [options]
#   ./copy-bin-files.sh --help
#
# Arguments:
#   $1 - 固件类型 (immortalwrt|openwrt，默认: immortalwrt)
#   $2 - 版本号 (snapshots|MAJOR.MINOR.PATCH，默认: snapshots)
#
# 环境变量:
#   无特殊要求，脚本使用相对路径自动定位目录
#
# Examples:
#   ./copy-bin-files.sh immortalwrt snapshots
#   ./copy-bin-files.sh --firmware=immortalwrt --version=snapshots
#   ./copy-bin-files.sh openwrt 23.05.2
#   ./copy-bin-files.sh  # 使用默认值 immortalwrt snapshots
#
# 作者: Shuery-Shuai
# 版本: 1.0.0
#######################################

set -euo pipefail

# 脚本所在目录（绝对路径）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载通用函数库（日志、文件检查等）
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

#######################################
# 主函数 - 复制编译产物到发布目录
#
# 两种版本类型的落盘位置：
#   - snapshots: public/<firmware>/snapshots/{targets,packages}
#   - releases:  public/<firmware>/releases/<版本>/{targets,packages}
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Globals:
#   SCRIPT_DIR - 脚本所在目录
#
# Outputs:
#   操作进度和结果日志到 stderr (通过 log 函数)
#
# Returns:
#   0 - 复制成功
#   1 - 源目录不存在或其他错误 (通过 require_dir 退出)
#
# Examples:
#   main immortalwrt snapshots
#   main --firmware=openwrt --version=23.05.2
#   main --help
#
# Files Modified:
#   public/${firmware}/${version}/targets/     - 固件镜像文件
#   public/${firmware}/${version}/packages/    - 软件包文件（与 targets 同级）
#   public/assets/common/keys/public-key.pem  - 签名公钥（只此一份，所有固件共用）
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "copy-bin-files.sh" \
      "复制编译产物到发布目录" \
      "[options] [firmware] [version]" \
      "  -h, --help              显示此帮助信息" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: immortalwrt)" \
      "  --version=VER           版本号 (snapshots|版本号, 默认: snapshots)" \
      "" \
      "位置参数:" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)"
    exit 0
  fi

  # 获取参数（优先使用命名参数，其次使用位置参数，最后使用默认值）
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_0]:-immortalwrt}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_1]:-snapshots}}"
  local src_dir="${SCRIPT_DIR}/../sources/${firmware}"
  local dst_base="${SCRIPT_DIR}/../public/${firmware}"
  local dst_dir
  local is_snapshot

  # 判断版本类型：snapshots 或 releases
  if [[ "${version}" == "snapshots" ]]; then
    is_snapshot=true
    dst_dir="${dst_base}/snapshots"
  else
    is_snapshot=false
    dst_dir="${dst_base}/releases/${version}"
  fi

  log INFO "复制 ${firmware} ${version} 编译产物"
  log DEBUG "源目录: ${src_dir}"
  log DEBUG "目标基目录: ${dst_dir}"

  # 切换到项目根目录（确保相对路径正确）
  cd "${SCRIPT_DIR}/.."

  # 验证源目录和必需子目录存在
  require_dir "${src_dir}" "源码目录不存在"
  require_dir "${src_dir}/bin/targets" "targets 目录不存在"
  require_dir "${src_dir}/bin/packages" "packages 目录不存在"

  # 清理目标目录中的旧产物（避免混合不同构建的文件）
  if [[ -d "${dst_dir}/targets" || -d "${dst_dir}/packages" ]]; then
    log INFO "清理旧产物"
    rm -rf "${dst_dir}/targets" "${dst_dir}/packages"
  fi

  # 根据版本类型执行不同的复制策略
  if [[ "${is_snapshot}" == "true" ]]; then
    #######################################
    # Snapshots 版本处理
    #
    # 直接复制整个 targets 和 packages 目录，
    # 每次构建的产物完全独立，便于追踪最新开发版本。
    #######################################
    log DEBUG "处理 snapshots 版本"
    mkdir -p "${dst_dir}"

    log DEBUG "复制 targets 目录"
    cp -r "${src_dir}/bin/targets" "${dst_dir}/"

    log DEBUG "复制 packages 目录"
    cp -r "${src_dir}/bin/packages" "${dst_dir}/"

    log INFO "已复制: targets 和 packages"
  else
    #######################################
    # Releases 版本处理
    #
    # targets 与 packages 都按完整版本号隔离存放：
    #   releases/<版本>/targets/...
    #   releases/<版本>/packages/...
    #
    # 不再创建 releases/packages-<主次版本> 共享目录与符号链接（Pages 无服务端
    # 软链，artifact 打包会把软链展开成实体副本，共享只会白占一份体积）。
    #######################################
    log DEBUG "处理 releases 版本"

    mkdir -p "${dst_dir}"
    log DEBUG "复制 targets 与 packages 到 ${dst_dir}/"
    cp -r "${src_dir}/bin/targets" "${dst_dir}/"
    if [[ -d "${src_dir}/bin/packages" ]]; then
      cp -r "${src_dir}/bin/packages" "${dst_dir}/"
      log INFO "已复制: targets 和 packages（版本目录内）"
    else
      log WARN "源码树中不存在 bin/packages，跳过 packages 复制"
    fi
  fi

  #######################################
  # 复制签名公钥（可选）
  #
  # 如果源码目录中存在 public-key.pem，则复制到发布根目录。
  # 该公钥由 copy-pre-files.sh 从 keys/ 安装而来，是 **apk 仓库签名**公钥
  # （EC P-256，与 OpenWrt 的 BUILD_KEY_APK_PUB 对应，构建时写入镜像
  # /etc/apk/keys/ 作为信任锚），发布到站点后供已刷机设备手动导入。
  # 注意：它不用于 usign/opkg 体系——那套需要 ed25519 密钥，算法不同。
  #######################################
  if [[ -f "${src_dir}/public-key.pem" ]]; then
    # 公钥只发布一份：所有固件共用同一密钥对，按固件各存一份曾导致分叉
    # （站点上实测出现过两个不同指纹）。旧路径残留必须显式清除，否则 CI 会把
    # 上一轮产物 rsync 合并回来，废弃公钥会永久留在站点上。
    mkdir -p "public/assets/common/keys"
    cp "${src_dir}/public-key.pem" "public/assets/common/keys/public-key.pem"
    log INFO "已复制: assets/common/keys/public-key.pem"
    local stale_key
    for stale_key in public/*/public-key.pem; do
      [[ -e "${stale_key}" ]] || continue
      rm -f "${stale_key}" && log INFO "已移除旧路径公钥: ${stale_key}"
    done
  else
    log DEBUG "public-key.pem 不存在，跳过"
  fi

  log SUCCESS "编译产物复制完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
