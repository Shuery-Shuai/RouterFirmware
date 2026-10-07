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
# 流程：
#   1. make defconfig → 产生默认 .config
#   2. 备份为 .config.defconfig（基线）
#   3. 生成 customfeeds.list
#   4. 如果 diff.config 存在 → 合并至 .config → yes '' | make oldconfig 更新
#   5. 如果 ask_menuconfig == true → 运行 make menuconfig
#   6. 基于 .config.defconfig 基线生成完整差异文件 diff.config
#   7. 清理临时文件
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
      "  --firmware=TYPE         固件类型 (openwrt|immortalwrt, 默认: config/site.json 的 defaults.firmware)" \
      "  --version=VER           版本号 (snapshots|版本号, 默认: config/site.json 的 defaults.version)" \
      "  --profile=PROF          设备 profile (默认: config/site.json 的 defaults.profile)" \
      "  --ask-menuconfig=BOOL   是否询问运行 menuconfig (true|false, 默认: false)" \
      "  --prompt-timeout=SEC    交互提示超时秒数 (0=永不超时, 默认: 60)" \
      "  --non-interactive       强制非交互：提示一律取默认值" \
      "" \
      "位置参数:" \
      "  source_dir              源码目录路径 (等同于 --source-dir)" \
      "  firmware                固件类型 (等同于 --firmware)" \
      "  version                 版本号 (等同于 --version)" \
      "  profile                 设备 profile (等同于 --profile)" \
      "  ask_menuconfig          是否询问运行 menuconfig (等同于 --ask-menuconfig)"
    exit 0
  fi

  # 获取参数（优先命名参数，其次位置参数，最后默认值）
  # 缺省值来自 config/site.json 的 defaults.*，改配置即可，无需改脚本
  local default_firmware default_version default_profile
  default_firmware="$(config_value defaults.firmware)"
  default_version="$(config_value defaults.version)"
  default_profile="$(config_value defaults.profile)"
  local source_dir="${PARSED_ARGS['source-dir']:-${PARSED_ARGS[_POSITIONAL_0]:-.}}"
  local firmware="${PARSED_ARGS['firmware']:-${PARSED_ARGS[_POSITIONAL_1]:-${default_firmware:-immortalwrt}}}"
  local version="${PARSED_ARGS['version']:-${PARSED_ARGS[_POSITIONAL_2]:-${default_version:-snapshots}}}"
  local profile="${PARSED_ARGS['profile']:-${PARSED_ARGS[_POSITIONAL_3]:-${default_profile:-bananapi_bpi-r4}}}"
  local ask_menuconfig="${PARSED_ARGS['ask-menuconfig']:-${PARSED_ARGS[_POSITIONAL_4]:-false}}"
  local prompt_timeout="${PARSED_ARGS['prompt-timeout']:-${PROMPT_TIMEOUT:-60}}"
  local board
  local subtarget
  local arch

  # 非交互标志：本脚本直接运行或由 make.sh 通过环境变量继承
  if [[ "${PARSED_ARGS['non-interactive']:-}" == "true" ]]; then
    NON_INTERACTIVE="true"
    export NON_INTERACTIVE
  fi

  if [[ ! "${prompt_timeout}" =~ ^[0-9]+$ ]]; then
    log ERROR "--prompt-timeout 必须是非负整数（秒），当前值: '${prompt_timeout}'"
    exit 1
  fi

  # 验证源码目录结构
  require_file "${source_dir}/Makefile" "Makefile 不存在于 ${source_dir}"

  log INFO "配置管理: ${firmware} ${version} [${profile}]"
  log DEBUG "源码目录: ${source_dir}"

  # 切换到源码目录，所有后续操作在此目录中进行
  cd "${source_dir}"

  # 重新扫描软件包索引
  # diy-part2.sh 可能通过符号链接添加了新包，需要先扫描包目录
  # 注意：必须同时删除扫描戳记，否则 feeds install 刚生成的戳记会让 make 认为
  # "扫描已是最新"而跳过重建，导致 prepare-tmpinfo 因缺少 tmp/.packageinfo 失败
  log INFO "重新扫描软件包索引"
  rm -f tmp/.packageinfo tmp/.config-package.in tmp/info/.scan-packageinfo.stamp ||
    log WARN "清理 packageinfo 缓存失败，但继续"

  # 生成默认配置文件
  # defconfig 会根据 .config 中的 CONFIG_TARGET_* 生成完整配置
  log INFO "生成默认配置"
  make defconfig

  # 备份 config 为基线（.config.defconfig）
  cp .config .config.defconfig
  log INFO "已保存 defconfig 基线到 .config.defconfig"

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
    #
    # 注意站点上的版本目录名：快照版是 snapshots/，发行版是 releases/<版本>/
    # （与 copy-bin-files.sh 的落盘路径一致；此前发行版会写成 /<版本>/ 导致 404）
    local version_path
    if [[ "${version}" == "snapshots" ]]; then
      version_path="snapshots"
    else
      version_path="releases/${version}"
    fi
    cat >files/etc/apk/repositories.d/customfeeds.list <<EOF
# Custom package feeds - Auto-generated
https://rtfw.shuery.lssa.fun/${firmware}/${version_path}/targets/${board}/${subtarget}/packages/packages.adb
https://rtfw.shuery.lssa.fun/${firmware}/${version_path}/packages/${arch}/base/packages.adb
https://rtfw.shuery.lssa.fun/${firmware}/${version_path}/packages/${arch}/luci/packages.adb
https://rtfw.shuery.lssa.fun/${firmware}/${version_path}/packages/${arch}/packages/packages.adb
EOF
    log INFO "已生成 customfeeds.list"
  else
    log WARN "无法提取 board/arch 信息，跳过 customfeeds.list"
  fi

  #######################################
  # 应用差异配置文件（diff.config）
  #
  # 如果当前目录下存在 diff.config，则将其与 .config 合并，
  # 并使用非交互方式更新配置，使其与当前源码树一致。
  #
  # 合并逻辑：
  #   1. 使用 awk 读取 diff.config，构建新配置项的映射表。
  #   2. 逐行处理 .config，若某配置项在 diff.config 中有定义，则替换为新值；
  #      否则保留原值。
  #   3. 追加 diff.config 中独有的新配置项（例如新增包的选项）。
  #
  # 更新配置（解决依赖和过时问题）：
  #   - 优先使用 `scripts/config/conf --olddefconfig` 完全无交互更新。
  #   - 若不可用，降级为 `yes '' | make oldconfig`（空行选择默认值，可能有风险）。
  #
  # Globals:
  #   None
  #
  # Arguments:
  #   None
  #
  # Outputs:
  #   日志信息到 stderr
  #
  # Returns:
  #   0 - 成功应用（即使 diff.config 不存在也返回 0）
  #   非0 - 合并或更新过程中出现严重错误
  #######################################
  if [[ -f "diff.config" ]]; then
    log INFO "应用 diff.config"

    # 使用 awk 将 diff.config 合并到当前 .config
    # 注意：OpenWrt 没有独立的 scripts/config 脚本（它是一个目录），
    # 因此直接使用 awk 进行文本级合并，再通过 conf 工具同步依赖。
    awk '
      # 第一遍：读取 diff.config，构建新配置映射表
      NR==FNR {
        if (/^# CONFIG_.* is not set/) {
          # 处理禁用的配置项，格式：# CONFIG_XXX is not set
          split($0, a, " "); newconf[a[2]] = $0;
        } else if (/^CONFIG_/) {
          # 处理启用的配置项，格式：CONFIG_XXX=value
          split($0, a, "="); newconf[a[1]] = $0;
        }
        next;
      }
      # 第二遍：处理原有的 .config
      {
        if (/^CONFIG_/) {
          split($0, a, "="); key = a[1];
        } else if (/^# CONFIG_.* is not set/) {
          split($0, a, " "); key = a[2];
        } else {
          # 非配置行（注释、空行等）直接输出
          print; next;
        }
        # 若该键在 diff.config 中有新值，则使用新值
        if (key in newconf) {
          print newconf[key]; delete newconf[key];
        } else {
          print;
        }
      }
      # 追加 diff.config 中剩余的新配置项（.config 中没有的）
      END {
        for (key in newconf) print newconf[key];
      }
    ' diff.config .config >.config.new && mv .config.new .config

    # 非交互更新配置：stdin 指向 /dev/null，oldconfig 对所有新符号取默认值
    # （此前用 `yes '' |` 配合 pipefail，会把 yes 的 SIGPIPE 141 误当成失败）
    log INFO "同步配置 (oldconfig)..."
    make oldconfig </dev/null >/dev/null 2>&1 || {
      log WARN "make oldconfig 退出码 $?（配置可能未完全同步）"
    }

    log INFO "差异配置应用完成，已同步至当前源码"
  else
    log DEBUG "diff.config 不存在，跳过差异应用"
  fi

  # 编译缓存：由脚本统一开启 ccache，不要求用户写进 config（便于仓库移植；
  # CI 与本地走同一套脚本，因此两条路径同时生效）。
  # 环境需有 ccache 命令（构建镜像已内置）；缺失时仅告警，不影响构建。
  if command -v ccache >/dev/null 2>&1; then
    if grep -q '^CONFIG_CCACHE=y$' .config; then
      log DEBUG "ccache 已在配置中启用"
    else
      sed -i '/^CONFIG_CCACHE=/d' .config
      printf 'CONFIG_CCACHE=y\n' >>.config
      log INFO "已启用编译缓存 ccache（CONFIG_CCACHE=y，由脚本统一开启）"
      make oldconfig </dev/null >/dev/null 2>&1 || log WARN "oldconfig 返回非零，ccache 配置可能未生效"
    fi
  else
    log WARN "未检测到 ccache 命令，跳过编译缓存启用（安装 ccache 后自动生效）"
  fi

  # 可选的交互式配置
  # TTY 下回车/超时都取提示语默认值（Y）；非 TTY 一律不运行
  if [[ "${ask_menuconfig}" == "true" ]]; then
    if [[ "$(prompt_yes_no y n "${prompt_timeout}" "运行 make menuconfig? [Y/n] ")" == "y" ]]; then
      make menuconfig
      log INFO "menuconfig 完成"
    else
      log INFO "跳过 menuconfig"
    fi
  fi

  # 基于基线生成完整差异文件（自包含的定制快照）
  if [[ -f .config.defconfig ]]; then
    # 计算项目根目录的绝对路径
    local project_root
    project_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local diff_output="${project_root}/public/assets/${profile}/configs/${firmware}.${version}.diff.config"

    log INFO "比较配置变化"

    # 使用 scripts/diffconfig.sh 生成差异配置
    if [[ -f scripts/diffconfig.sh ]]; then
      # 确保目标目录存在
      mkdir -p "$(dirname "${diff_output}")"

      # 生成临时差异文件
      local temp_diff="${diff_output}.tmp"
      ./scripts/diffconfig.sh .config.defconfig .config >"${temp_diff}"

      # 检查是否有变化
      local changes_count
      changes_count=$(grep -c '^CONFIG_' "${temp_diff}" 2>/dev/null || true)

      if [[ ${changes_count} -eq 0 ]]; then
        log INFO "配置与默认一致，无差异"
        rm -f "${temp_diff}" "${diff_output}"
      else
        log INFO "生成完整差异文件 (${changes_count} 行)"
        # 如果已存在旧 diff，询问是否替换
        if [[ -f "${diff_output}" ]]; then
          log WARN "差异文件已存在：${diff_output}"
          echo "差异对比（左：现有 | 右：新生成）："
          echo "========================================"

          # 使用 diff -y 进行并排对比，如果可用则使用 colordiff
          if command -v colordiff &>/dev/null; then
            diff -y --width=160 --suppress-common-lines "${diff_output}" "${temp_diff}" | colordiff || true
          else
            diff -y --width=160 --suppress-common-lines "${diff_output}" "${temp_diff}" || true
          fi

          echo "========================================"

          # 是否替换：TTY 下回车/超时都取提示语默认值（N，保留现有文件）；非 TTY 同样保留
          local replace_answer
          replace_answer="$(prompt_yes_no n n "${prompt_timeout}" "是否替换现有差异配置文件? [y/N] ")"
          if [[ "${replace_answer}" == "y" ]]; then
            mv "${temp_diff}" "${diff_output}"
            log INFO "已替换差异配置文件: ${diff_output}"
          else
            rm -f "${temp_diff}"
            log INFO "保留现有差异配置文件"
          fi
        else
          # 文件不存在，显示新配置变化并直接保存
          log INFO "配置变化详情："
          cat "${temp_diff}"

          mv "${temp_diff}" "${diff_output}"
          log INFO "已生成差异配置: ${diff_output}（新建文件，需人工确认后纳入版本控制）"
        fi

      fi
    else
      log WARN "未找到 scripts/diffconfig.sh，跳过差异生成"
    fi

    # 清理备份文件
    rm -f .config.defconfig
  else
    log WARN "未找到 .config.defconfig，无法生成差异配置"
  fi

  # 清理临时文件
  rm -f .config.defconfig .config.old

  log INFO "配置管理完成"
}

# 执行主函数，传递所有命令行参数
main "$@"
