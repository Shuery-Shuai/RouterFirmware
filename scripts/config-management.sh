#!/usr/bin/env bash
#######################################
# 配置管理脚本
#
# 负责生成和管理 OpenWrt/ImmortalWrt 的构建配置。
# 主要功能包括：
#   - 生成默认配置文件 (.config)
#   - 生成自定义软件包源列表 (customfeeds.list)
#   - 应用差异配置文件 (diff.config)
#   - 可选地运行交互式配置工具 (menuconfig)
#
# 用法:
#   ./config-management.sh <source_dir> <firmware> <version> <profile> [ask-menuconfig]
#   ./config-management.sh [options]
#   ./config-management.sh --help
#
# 示例:
#   ./config-management.sh ./sources/immortalwrt immortalwrt snapshots bananapi_bpi-r4 false
#   ./config-management.sh --source-dir=./sources/immortalwrt --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
#   ./config-management.sh /build/openwrt openwrt 23.05 x86_64 true
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 依赖:
#   - common.sh: 提供日志和工具函数
#   - 源码目录中的 Makefile
#   - diff.config: 可选的差异配置文件
#
# 作者: Shuery-Shuai
# 版本: 1.0.0
#######################################

set -euo pipefail

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载通用函数库
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

#######################################
# 配置管理主函数
#
# 执行完整的配置管理流程：
#   1. 验证源码目录
#   2. 生成默认配置
#   3. 从 .config 中提取架构信息
#   4. 生成自定义软件包源列表
#   5. 应用差异配置（如果存在）
#   6. 可选地运行 menuconfig 进行交互式配置
#
# Globals:
#   SCRIPT_DIR - 当前脚本所在目录（只读）
#
# Arguments:
#   $@ - 命令行参数（支持位置参数或命名参数）
#
# Outputs:
#   多级别日志输出到 stderr
#   生成的配置文件: .config, customfeeds.list
#
# Returns:
#   0 - 成功
#   1 - 源码目录验证失败或 make defconfig 失败
#
# Examples:
#   main "./sources/immortalwrt" "immortalwrt" "snapshots" "bananapi_bpi-r4" "false"
#   main --source-dir=./sources/immortalwrt --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
#   main --help
#######################################
main() {
  # 解析命令行参数
  declare -A PARSED_ARGS
  parse_args "$@"

  # 处理帮助选项
  if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
    show_help "config-management.sh" \
      "管理 OpenWrt/ImmortalWrt 构建配置" \
      "[options] [source_dir] [firmware] [version] [profile] [ask-menuconfig]" \
      "  -h, --help              显示此帮助信息" \
      "  --source-dir=PATH       源码目录路径 (默认: .)" \
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: immortalwrt)" \
      "  --version=VER           版本号 (snapshots|版本号, 默认: snapshots)" \
      "  --profile=PROF          设备 profile (默认: bananapi_bpi-r4)" \
      "  --ask-menuconfig=BOOL   是否询问运行 menuconfig (true|false, 默认: false)" \
      "" \
      "位置参数:" \
      "  source_dir              源码目录路径 (等同于 --source-dir)" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)" \
      "  profile                 设备 profile (等同于 --profile)" \
      "  ask_menuconfig          是否询问运行 menuconfig (等同于 --ask-menuconfig)"
    exit 0
  fi

  # 获取参数（优先使用命名参数，其次使用位置参数，最后使用默认值）
  local source_dir="${PARSED_ARGS['source-dir']:-${PARSED_ARGS[_POSITIONAL_0]:-.}}"
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_1]:-immortalwrt}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_2]:-snapshots}}"
  local profile="${PARSED_ARGS['profile']:-${PARSED_ARGS[_POSITIONAL_3]:-bananapi_bpi-r4}}"
  local ask_menuconfig="${PARSED_ARGS['ask-menuconfig']:-${PARSED_ARGS[_POSITIONAL_4]:-false}}"
  local board
  local subtarget
  local arch

  # 验证源码目录结构
  require_file "${source_dir}/Makefile" "Makefile 不存在于 ${source_dir}"

  log INFO "配置管理: ${firmware} ${version} [${profile}]"
  log DEBUG "源码目录: ${source_dir}"

  # 切换到源码目录，所有后续操作在此目录中进行
  cd "${source_dir}"

  # 重新扫描软件包索引
  # diy-part2.sh 可能通过符号链接添加了新包，需要先扫描包目录
  # 使用 make tmp/.packageinfo 来触发包索引重建，但不改动 .config
  log INFO "重新扫描软件包索引"
  if ! rm -f tmp/.packageinfo 2>&1; then
    log WARN "清理 packageinfo 缓存失败，但继续"
  fi

  # 生成默认配置文件
  # defconfig 会根据 .config 中的 CONFIG_TARGET_* 生成完整配置
  log INFO "生成默认配置"
  make defconfig

  # 从生成的 .config 中提取架构信息
  # 这些信息用于构建自定义软件包源的 URL
  log INFO "生成 customfeeds.list"
  board=$(grep '^CONFIG_TARGET_BOARD=' .config 2>/dev/null | cut -d'"' -f2)
  subtarget=$(grep '^CONFIG_TARGET_SUBTARGET=' .config 2>/dev/null | cut -d'"' -f2)
  arch=$(grep '^CONFIG_TARGET_ARCH_PACKAGES=' .config 2>/dev/null | cut -d'"' -f2)

  # 如果成功提取架构信息，生成自定义软件包源列表
  if [[ -n "${board}" && -n "${subtarget}" && -n "${arch}" ]]; then
    log DEBUG "board=${board}, subtarget=${subtarget}, arch=${arch}"

    # 创建 APK 仓库配置目录（OpenWrt 23.05+ 使用 APK 替代 opkg）
    mkdir -p files/etc/apk/repositories.d

    # 生成自定义软件包源配置文件
    # 包含四个软件包源：
    #   1. 目标平台特定软件包
    #   2. 架构基础软件包
    #   3. LuCI Web 界面软件包
    #   4. 通用软件包
    cat >files/etc/apk/repositories.d/customfeeds.list <<EOF
# Custom package feeds - Auto-generated
https://rtfw.shuery.lssa.fun/${firmware}/${version}/targets/${board}/${subtarget}/packages/packages.adb
https://rtfw.shuery.lssa.fun/${firmware}/${version}/packages/${arch}/base/packages.adb
https://rtfw.shuery.lssa.fun/${firmware}/${version}/packages/${arch}/luci/packages.adb
https://rtfw.shuery.lssa.fun/${firmware}/${version}/packages/${arch}/packages/packages.adb
EOF
    log INFO "已生成 customfeeds.list"
  else
    log WARN "无法提取 board/arch 信息，跳过 customfeeds.list"
  fi

  # 应用差异配置文件（如果存在）
  # diff.config 通常只包含修改的配置项，而非完整配置
  if [[ -f "diff.config" ]]; then
    log INFO "应用 diff.config"
    log DEBUG "合并差异配置到 .config"

    # 使用 awk 智能合并配置：
    #   - 读取 diff.config 中的新配置项
    #   - 遍历 .config，替换已存在的项
    #   - 在末尾追加 diff.config 中的新项
    awk '
      # 第一遍：读取 diff.config，构建新配置映射表
      NR==FNR {
        if (/^# CONFIG_.* is not set/) {
          # 处理禁用的配置项 (# CONFIG_XXX is not set)
          split($0, a, " "); newconf[a[2]] = $0;
        } else if (/^CONFIG_/) {
          # 处理启用的配置项 (CONFIG_XXX=y/m/...)
          split($0, a, "="); newconf[a[1]] = $0;
        }
        next;
      }
      # 第二遍：处理 .config
      {
        if (/^CONFIG_/) {
          split($0, a, "="); key = a[1];
        } else if (/^# CONFIG_.* is not set/) {
          split($0, a, " "); key = a[2];
        } else {
          # 非配置行（注释、空行等）直接输出
          print; next;
        }
        # 如果该配置项在 diff.config 中有新值，使用新值
        if (key in newconf) {
          print newconf[key]; delete newconf[key];
        } else {
          print;
        }
      }
      # 处理完后，追加 diff.config 中剩余的新配置项
      END {
        for (key in newconf) print newconf[key];
      }
    ' diff.config .config >.config.new && mv .config.new .config
    log INFO "差异配置应用完成"
  else
    log DEBUG "diff.config 不存在，跳过"
  fi

  # 可选的交互式配置
  # 允许用户通过 menuconfig 手动调整配置
  if [[ "${ask_menuconfig}" == "true" ]]; then
    read -rp "运行 make menuconfig? [Y/n] " answer
    case "${answer,,}" in
    y | yes | "")
      # 备份当前配置
      cp .config .config.old
      log INFO "已备份当前配置到 .config.old"

      # 运行 menuconfig
      make menuconfig

      # 比较配置变化并生成差异文件
      if [[ -f .config.old ]]; then
        # 计算项目根目录的绝对路径
        local project_root
        project_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
        local diff_output="${project_root}/public/assets/${profile}/${firmware}.${version}.diff.config"

        log INFO "比较配置变化"

        # 使用 scripts/diffconfig.sh 生成差异配置
        if [[ -f scripts/diffconfig.sh ]]; then
          # 确保目标目录存在
          mkdir -p "$(dirname "${diff_output}")"

          # 生成临时差异文件
          local temp_diff="${diff_output}.tmp"
          ./scripts/diffconfig.sh .config.old .config >"${temp_diff}"

          # 检查是否有变化
          local changes_count
          changes_count=$(grep -c '^CONFIG_' "${temp_diff}" 2>/dev/null || echo "0")

          if [[ ${changes_count} -eq 0 ]]; then
            log INFO "配置无变化"
            rm -f "${temp_diff}"
          else
            log INFO "配置变化数量: ${changes_count}"

            # 检查是否已存在 diff 文件
            if [[ -f "${diff_output}" ]]; then
              log WARN "差异配置文件已存在"
              log INFO "显示对比（左：现有 | 右：新生成）："
              echo "========================================"

              # 使用 diff -y 进行并排对比，如果可用则使用 colordiff
              if command -v colordiff &>/dev/null; then
                diff -y --width=160 --suppress-common-lines "${diff_output}" "${temp_diff}" | colordiff || true
              else
                diff -y --width=160 --suppress-common-lines "${diff_output}" "${temp_diff}" || true
              fi

              echo "========================================"

              # 询问是否替换
              read -rp "是否替换现有差异配置文件? [y/N] " replace_answer
              case "${replace_answer,,}" in
              y | yes)
                mv "${temp_diff}" "${diff_output}"
                log INFO "已替换差异配置文件: ${diff_output}"
                ;;
              *)
                rm -f "${temp_diff}"
                log INFO "保留现有差异配置文件"
                ;;
              esac
            else
              # 文件不存在，显示新配置变化并直接保存
              log INFO "配置变化详情："
              cat "${temp_diff}"

              mv "${temp_diff}" "${diff_output}"
              log INFO "已生成差异配置: ${diff_output}"
            fi
          fi
        else
          log WARN "未找到 scripts/diffconfig.sh，跳过差异生成"
        fi

        # 清理备份文件
        rm -f .config.old
      fi
      ;;
    n | no) log INFO "跳过 menuconfig" ;;
    *) log WARN "无效输入，跳过" ;;
    esac
  fi

  log INFO "配置管理完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
