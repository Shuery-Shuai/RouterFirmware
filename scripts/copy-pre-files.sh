#!/usr/bin/env bash
#######################################
# 复制编译前配置文件
#
# 将固件配置文件、DIY 脚本和额外文件从 public 目录复制到固件源码目录，
# 为后续的固件编译做准备。支持多固件类型、多版本和多设备配置。
#
# 用法:
#   ./copy-pre-files.sh [firmware] [version] [profile]
#   ./copy-pre-files.sh [options]
#   ./copy-pre-files.sh --help
#
# 参数:
#   firmware - 固件类型，默认: immortalwrt
#   version  - 固件版本，默认: snapshots
#   profile  - 设备配置文件名，默认: bananapi_bpi-r4
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 复制的文件包括:
#   - .config            : 主配置文件
#   - diff.config        : 差异配置文件（可选）
#   - diy-part1.sh       : DIY 脚本第一部分
#   - diy-part2.sh       : DIY 脚本第二部分（固件特定）
#   - files/             : 额外文件目录（common + profile 特定）
#
# 示例:
#   ./copy-pre-files.sh immortalwrt snapshots bananapi_bpi-r4
#   ./copy-pre-files.sh --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
#   ./copy-pre-files.sh openwrt 23.05.3
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

#######################################
# 安装 APK 软件包签名密钥
#
# 将 apk 签名私钥还原到源码根目录并导出对应公钥。
# 上游构建系统从 $(TOPDIR)/private-key.pem 取私钥签名，
# 并把 $(TOPDIR)/public-key.pem 安装到镜像的 /etc/apk/keys/。
#
# 私钥来源（按优先级）:
#   1. 环境变量 APK_PRIVATE_KEY_B64 - CI 使用，base64 编码
#   2. keys/private-key.pem         - 本地构建使用
#
# 两者都缺失时本地构建仅告警（构建会生成一次性密钥），
# CI 中则视为错误，避免发布出设备不信任的仓库。
#
# Arguments:
#   $1 - 源码目录（绝对路径）
#
# Returns:
#   0 - 已安装密钥，或本地构建未提供密钥
#   1 - 密钥解码/导出失败，或与仓库内公钥不匹配
#######################################
install_apk_signing_key() {
  local dst_dir="$1"
  local key_dir="${SCRIPT_DIR}/../keys"
  local pub_key_src="${key_dir}/public-key.pem"
  local priv_key_dst="${dst_dir}/private-key.pem"
  local pub_key_dst="${dst_dir}/public-key.pem"

  if [[ -n "${APK_PRIVATE_KEY_B64:-}" ]]; then
    log INFO "从 APK_PRIVATE_KEY_B64 还原 APK 签名私钥"
    if ! (umask 077; printf '%s' "${APK_PRIVATE_KEY_B64}" | base64 -d >"${priv_key_dst}") 2>/dev/null &&
      ! (umask 077; printf '%s' "${APK_PRIVATE_KEY_B64}" | base64 -D >"${priv_key_dst}") 2>/dev/null; then
      log FATAL "APK_PRIVATE_KEY_B64 解码失败"
      return 1
    fi
  elif [[ -f "${key_dir}/private-key.pem" ]]; then
    log INFO "使用本地私钥: ${key_dir}/private-key.pem"
    (umask 077; cp "${key_dir}/private-key.pem" "${priv_key_dst}")
  else
    log WARN "未提供 APK 签名私钥（APK_PRIVATE_KEY_B64 或 keys/private-key.pem）"
    log WARN "构建将生成一次性签名密钥，已刷机设备会因 UNTRUSTED signature 无法安装软件包"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      log FATAL "CI 构建必须提供仓库 secret APK_PRIVATE_KEY_B64"
      return 1
    fi
    return 0
  fi

  chmod 600 "${priv_key_dst}"
  if ! openssl ec -in "${priv_key_dst}" -pubout >"${pub_key_dst}" 2>/dev/null; then
    log FATAL "无法从私钥导出公钥，请确认密钥为 EC 格式"
    return 1
  fi
  if [[ -f "${pub_key_src}" ]] && ! diff -q "${pub_key_dst}" "${pub_key_src}" >/dev/null; then
    log FATAL "私钥与仓库内 keys/public-key.pem 不匹配"
    return 1
  fi

  local fingerprint
  fingerprint="$(openssl ec -in "${priv_key_dst}" -pubout -outform DER 2>/dev/null |
    openssl dgst -sha256 -r | cut -d' ' -f1)"
  log INFO "APK 签名密钥已安装: ${fingerprint}"
  return 0
}

#######################################
# 主函数
#
# 执行配置文件复制流程：
#   1. 验证源码目录存在
#   2. 复制主配置文件 (.config)
#   3. 复制差异配置文件 (diff.config，可选)
#   4. 复制 DIY 脚本 (diy-part1.sh, diy-part2.sh)
#   5. 同步额外文件 (common 和 profile 特定的 files 目录)
#
# Globals:
#   SCRIPT_DIR - 脚本所在目录的绝对路径
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Outputs:
#   复制过程的详细日志到 stderr
#
# Returns:
#   0 - 复制成功
#   1 - 验证失败或复制过程中出错
#
# Examples:
#   main immortalwrt snapshots bananapi_bpi-r4
#   main --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
#   main --help
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "copy-pre-files.sh" \
      "复制编译前配置文件到源码目录" \
      "[options] [firmware] [version] [profile]" \
      "  -h, --help              显示此帮助信息" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: config/site.json 的 defaults.firmware)" \
      "  --version=VER           版本号 (snapshots|版本号, 默认: config/site.json 的 defaults.version)" \
      "  --profile=PROF          设备 profile (默认: config/site.json 的 defaults.profile)" \
      "" \
      "位置参数:" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)" \
      "  profile                 设备 profile (等同于 --profile)"
    exit 0
  fi

  # 获取参数（优先命名参数，其次位置参数，最后默认值）
  # 缺省值来自 config/site.json 的 defaults.*，改配置即可，无需改脚本
  local default_firmware default_version default_profile
  default_firmware="$(config_value defaults.firmware)"
  default_version="$(config_value defaults.version)"
  default_profile="$(config_value defaults.profile)"
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_0]:-${default_firmware:-immortalwrt}}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_1]:-${default_version:-snapshots}}}"
  local profile="${PARSED_ARGS['profile']:-${PARSED_ARGS[_POSITIONAL_2]:-${default_profile:-bananapi_bpi-r4}}}"

  # 计算源目录和目标目录的绝对路径
  local src_dir="${SCRIPT_DIR}/../public"
  local dst_dir="${SCRIPT_DIR}/../sources/${firmware}"

  log INFO "复制 ${firmware} ${version} [${profile}] 配置文件"
  log DEBUG "源目录: ${src_dir}, 目标目录: ${dst_dir}"

  # 切换到项目根目录
  cd "${SCRIPT_DIR}/.."

  # 验证源码目录存在（必须已通过 source-management.sh 创建）
  require_dir "sources/${firmware}" "源码目录不存在"

  # 提前校验 profile 目录：profile 必须与 public/assets/<profile> 目录名逐字符一致
  # （连字符误写成下划线时，原本只会在后面报“配置文件不存在”，难以定位）
  local profile_dir="${src_dir}/assets/${profile}"
  if [[ ! -d "${profile_dir}" ]]; then
    local available="" d
    for d in "${src_dir}/assets"/*/; do
      [[ -d "${d}" ]] || continue
      available+="$(basename "${d}") "
    done
    log FATAL "profile 目录不存在: ${profile_dir}"
    log ERROR "profile 必须与目录名完全一致（注意连字符 - 与下划线 _ 的区别）"
    log ERROR "可用 profile: ${available:-（无）}"
    return 1
  fi

  #######################################
  # 复制主配置文件
  #######################################
  local config="${src_dir}/assets/${profile}/configs/${firmware}.config"
  log DEBUG "主配置文件: ${config}"
  require_file "${config}" "配置文件不存在: ${config}"
  cp "${config}" "${dst_dir}/.config"
  log INFO "已复制: .config"

  #######################################
  # 复制差异配置文件（可选）
  #
  # diff.config 用于存储与默认配置的差异，
  # 如果不存在则跳过，不影响后续流程。
  #######################################
  local diff_config="${src_dir}/assets/${profile}/configs/${firmware}.${version}.diff.config"
  if [[ -f "${diff_config}" ]]; then
    cp "${diff_config}" "${dst_dir}/diff.config"
    log INFO "已复制: diff.config"
  else
    log DEBUG "diff.config 不存在，跳过"
  fi

  #######################################
  # 复制 DIY 脚本及其依赖
  #
  # diy-part1.sh: 通用脚本，在 feeds update 之前执行
  # diy-part2.sh: 固件特定脚本，在 feeds install 之后执行
  #######################################
  local libs_dir="${src_dir}/assets/common/scripts/libs"
  local mods_dir="${src_dir}/assets/common/scripts/mods"
  local libs_device_dir="${src_dir}/assets/${profile}/scripts/libs"
  local mods_device_dir="${src_dir}/assets/${profile}/scripts/mods"
  local diy1="${src_dir}/assets/${profile}/scripts/diy-part1.${firmware}.sh"
  local diy2="${src_dir}/assets/${profile}/scripts/diy-part2.${firmware}.sh"
  require_dir "${libs_dir}" "libs 目录不存在"
  require_dir "${mods_dir}" "mods 目录不存在"
  require_dir "${libs_device_dir}" "libs-${profile} 目录不存在"
  require_dir "${mods_device_dir}" "mods-${profile} 目录不存在"
  require_file "${diy1}" "diy-part1.${firmware}.sh 不存在"
  require_file "${diy2}" "diy-part2.${firmware}.sh 不存在"

  # 使用 rsync 同步，源路径加 / 表示复制内容，避免目录嵌套
  rsync -a --delete "${libs_dir}/" "${dst_dir}/libs/"
  rsync -a --delete "${mods_dir}/" "${dst_dir}/mods/"
  rsync -a --delete "${libs_device_dir}/" "${dst_dir}/libs-${profile}/"
  rsync -a --delete "${mods_device_dir}/" "${dst_dir}/mods-${profile}/"

  # DIY 脚本直接复制
  cp "${diy1}" "${dst_dir}/diy-part1.sh"
  cp "${diy2}" "${dst_dir}/diy-part2.sh"

  #######################################
  # 同步额外文件
  #
  # 使用 rsync 同步文件目录，排除 index.html 以避免覆盖固件自带的索引页。
  # 先同步 common 目录（所有设备通用），再同步 profile 特定目录（可覆盖通用文件）。
  #
  # 同步顺序很重要:
  #   1. common/files/     - 所有设备的通用文件
  #   2. ${profile}/files/ - 特定设备的文件（优先级更高）
  #######################################
  log INFO "同步额外文件"

  # 同步通用文件
  if [[ -d "${src_dir}/assets/common/files" ]]; then
    local rsync_log
    rsync_log="$(mktemp)"
    if ! run_capture "${rsync_log}" rsync -a --exclude='index.html' "${src_dir}/assets/common/files/" "${dst_dir}/files"; then
      log FATAL "同步 common 文件失败"
      log ERROR "源: ${src_dir}/assets/common/files/"
      log ERROR "目标: ${dst_dir}/files"
      log ERROR "失败输出尾部:"
      print_tail "${rsync_log}"
      rm -f "${rsync_log}"
      exit 1
    fi
    rm -f "${rsync_log}"
  else
    log INFO "未找到 common/files 目录，跳过通用额外文件同步"
  fi

  # 同步设备特定文件
  if [[ -d "${src_dir}/assets/${profile}/files" ]]; then
    rsync_log="$(mktemp)"
    if ! run_capture "${rsync_log}" rsync -a --exclude='index.html' "${src_dir}/assets/${profile}/files/" "${dst_dir}/files"; then
      log FATAL "同步 ${profile} 文件失败"
      log ERROR "源: ${src_dir}/assets/${profile}/files/"
      log ERROR "目标: ${dst_dir}/files"
      log ERROR "失败输出尾部:"
      print_tail "${rsync_log}"
      rm -f "${rsync_log}"
      exit 1
    fi
    rm -f "${rsync_log}"
  else
    log INFO "未找到 ${profile}/files 目录，跳过设备特定额外文件同步"
  fi

  log INFO "已同步: 额外文件"

  #######################################
  # 安装 APK 软件包签名密钥
  #######################################
  if ! install_apk_signing_key "${dst_dir}"; then
    exit 1
  fi

  log INFO "SUCCESS" "配置文件复制完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
