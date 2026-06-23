#!/bin/bash
#######################################
# OpenWrt 构建自定义脚本 - 第一阶段
#
# 在 feeds 更新之前执行的自定义脚本，用于克隆第三方仓库和修改源码配置。
# 主要功能包括:
#   - 克隆第三方软件包仓库
#   - 修改 MediaTek Filogic 分区布局
#   - 添加 XDP sockets 内核模块支持
#   - 可选添加无线监管数据库补丁
#
# 执行时机:
#   在 ./scripts/feeds update -a 之前执行
#   适用于需要修改源码树结构和准备第三方软件包的操作
#
# 用法:
#   bash diy-part1.openwrt.sh
#
# 环境变量:
#   无特殊要求，脚本会自动检测所需文件
#
# 依赖:
#   - git (用于克隆软件包仓库)
#   - 网络连接 (下载第三方仓库)
#
# 作者: Shuery-Shuai
# 版本: 2.0.0
# 适用固件: OpenWrt (官方版本)
# 适用设备: BananaPi BPI-R4 (MediaTek MT7988)
#######################################

#######################################
# 修改 MediaTek Filogic 分区布局
#
# 扩展 BPI-R4 的固件分区大小，以容纳更多软件包和功能。
# 修改包括:
#   - 调整 recovery、install、production 分区偏移量
#   - 扩展各类启动镜像(initramfs、bl2、bl31)的大小限制
#   - 增加最终固件镜像(sysupgrade.itb)的容量
#
# Arguments:
#   $1 - 追加的分区大小（单位: MB）
#
# Globals:
#   None
#
# Outputs:
#   修改进度信息到 stdout
#   错误信息到 stderr
#
# Returns:
#   0 - 修改成功
#   1 - 文件不存在或 sed 操作失败
#
# Examples:
#   modify_partition 50  # 扩展 50MB
#######################################
modify_partition() {
    local append_size="$1"
    local partition_file="target/linux/mediatek/image/filogic.mk"
    local scope_build_start='^define\sBuild\/mt798x-gpt'
    local scope_build_end='^endef'
    local scope_device_start='^define\sDevice\/bananapi_bpi-r4-common'
    local scope_device_end='^endef'

    # 检查文件是否存在
    if [[ ! -f "${partition_file}" ]]; then
        printf "Error: File %s does not exist.\n" "${partition_file}" >&2
        return 1
    fi

    printf "Modifying %s...\n" "${partition_file}"

    # 计算新的分区大小（原始值 + 追加大小）
    local new_32=$((32 + append_size))
    local new_44=$((44 + append_size))
    local new_45=$((45 + append_size))
    local new_51=$((51 + append_size))
    local new_52=$((52 + append_size))
    local new_56=$((56 + append_size))
    local new_64=$((64 + append_size))

    # 执行 sed 操作：在指定作用域内替换分区大小
    # 第一个作用域 (Build/mt798x-gpt): 修改 GPT 分区表定义
    # 第二个作用域 (Device/bananapi_bpi-r4-common): 修改设备镜像大小限制
    if ! sed -i -E \
        -e "/${scope_build_start}/,/${scope_build_end}/ {
       # 修改分区表偏移量
       /recovery/s/32M@/${new_32}M@/
       /install/s/@44M/@${new_44}M/
       /production/s/@64M/@${new_64}M/
     }" \
        -e "/${scope_device_start}/,/${scope_device_end}/ {
       # 修改各类镜像大小限制
       /append-image-stage\s+initramfs-recovery\.itb/s/44m/${new_44}m/
       /mt7988-bl2\s+spim-nand-ubi-comb/s/44M/${new_44}M/
       /mt7988-bl31-uboot\s+.*-snand/s/45M/${new_45}M/
       /mt7988-bl2\s+emmc-comb/s/51M/${new_51}M/
       /mt7988-bl31-uboot\s+.*-emmc/s/52M/${new_52}M/
       /mt798x-gpt\s+emmc/s/56M/${new_56}M/
       /append-image\s+squashfs-sysupgrade\.itb/s/64M/${new_64}M/
       /IMAGE_SIZE/s/64/${new_64}/
     }" \
        "${partition_file}"; then
        printf "Error: Failed to modify %s.\n" "${partition_file}" >&2
        return 1
    fi

    printf "Done. Result:\n"
    return 0
}

#######################################
# 在指定作用域内 grep 匹配行（调试辅助函数）
#
# 用于验证分区修改结果，从配置文件中提取并高亮显示特定范围内的匹配行。
#
# Arguments:
#   $1 - 文件路径
#   $2 - 作用域起始正则表达式
#   $3 - 作用域结束正则表达式
#   $4 - grep 匹配模式（支持 ERE 扩展正则）
#
# Globals:
#   None
#
# Outputs:
#   带颜色高亮的匹配行到 stdout
#   格式: ━━━ 标题 ━━━
#         匹配内容（彩色）
#         ━━━━━━━━━━━━━━━
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   scope_grep "filogic.mk" "$START" "$END" 'recovery|install'
#######################################
scope_grep() {
    local file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    local grep_patterns="$4"

    echo "━━━━━━━━━━━━━━━━━━━━ Partition info from ${start_pattern} to ${end_pattern} ━━━━━━━━━━━━━━━━━━━━"
    sed -n -e "/${start_pattern}/,/${end_pattern}/p" "${file}" | grep -E --color=always "${grep_patterns}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#######################################
# 使用示例（已注释）
#
# 取消注释以下代码可启用分区扩展和结果验证:
#
# local append_size=50
# modify_partition $append_size
# scope_grep "$PARTITION_FILE" "$SCOPE_BUILD_START" "$SCOPE_BUILD_END" \
#   'recovery|install|production'
# scope_grep "$PARTITION_FILE" "$SCOPE_DEVICE_START" "$SCOPE_DEVICE_END" \
#   'append-image-stage\s+initramfs-recovery\.itb|mt7988-bl2\s+spim-nand-ubi-comb|mt7988-bl31-uboot\s+.*-snand|mt7988-bl2\s+emmc-comb|mt7988-bl31-uboot\s+.*-emmc|mt798x-gpt\s+emmc|append-image\s+squashfs-sysupgrade\.itb|IMAGE_SIZE'
#######################################

#######################################
# 辅助函数 - 带时间戳的日志输出
#######################################

#######################################
# 输出带时间戳的日志消息
#
# 格式化日志输出，包含当前时间、日志级别和消息内容。
# 所有输出重定向到 stderr，避免干扰脚本的 stdout 输出。
#
# Arguments:
#   $1 - 日志级别 (INFO|WARN|ERROR)
#   $2... - 日志消息内容
#
# Globals:
#   None
#
# Outputs:
#   格式化日志到 stderr
#   格式: [YYYY-MM-DD HH:MM:SS] [LEVEL] message
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   _log INFO "开始处理软件包"
#   _log ERROR "文件不存在: ${file}"
#######################################
_log() {
    local level="$1"
    shift
    printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "${level}" "$*" >&2
}

#######################################
# 克隆或更新 Git 仓库（带重试机制）
#
# 智能处理仓库下载：如果目录已存在则执行 pull 更新，否则执行 clone。
# 支持失败重试（最多 3 次），每次重试前等待递增的时间。
#
# Arguments:
#   $1 - Git 仓库 URL
#   $2 - 分支名称
#   $3 - git clone 的额外参数 (如 "--depth=1" 或 "--filter=blob:none --sparse")
#   $4 - 目标目录路径 (相对或绝对路径)
#
# Globals:
#   None
#
# Outputs:
#   操作进度信息到 stdout
#   错误信息到 stderr (通过 _log)
#
# Returns:
#   0 - 成功克隆或更新
#   1 - 重试 3 次后仍失败 (脚本直接退出)
#
# Examples:
#   clone_repo 'https://github.com/user/repo' 'main' '--depth=1' 'packages/repo'
#   clone_repo 'https://github.com/user/repo' 'master' '--filter=blob:none --sparse' 'custom-packages/repo'
#######################################
clone_repo() {
    local repo="$1"
    local branch="$2"
    local args="$3"
    local target="$4"
    local attempt

    if [[ -d "${target}" ]]; then
        # 目录已存在，尝试更新
        printf 'Pulling %s at %s...\n' "${repo}" "${target}"
        for attempt in {1..3}; do
            # 清理工作区 -> 恢复修改 -> 拉取更新
            if git -C "${target}" clean -fdx &&
                git -C "${target}" restore . &&
                git -C "${target}" pull; then
                break
            else
                printf 'Pull attempt %d failed, retrying...\n' "${attempt}"
                sleep $((attempt * 2)) # 递增等待时间：2s, 4s, 6s
            fi
        done
    else
        # 目录不存在，克隆新仓库
        printf 'Cloning %s %s to %s, using args: %s\n' \
            "${repo}" "${branch}" "${target}" "${args}"
        for attempt in {1..3}; do
            printf 'Clone attempt %d...\n' "${attempt}"
            # 将参数字符串拆分并传递给 git clone
            if eval "git clone -b '${branch}' ${args} '${repo}' '${target}'"; then
                break
            else
                printf 'Clone attempt %d failed!\n' "${attempt}"
                sleep $((attempt * 2))
                rm -rf "${target}" # 清理失败的半成品
                if [[ "${attempt}" -eq 3 ]]; then
                    _log 'ERROR' "Failed to clone ${repo} after 3 attempts."
                    exit 1
                fi
            fi
        done
    fi
}

#######################################
# 主脚本执行部分
#######################################

#######################################
# 克隆第三方软件包仓库
#
# 从 GitHub 下载各类第三方软件包，扩展 OpenWrt 功能。
# 包括：系统工具、网络应用、主题等。
#######################################

# BPI-R4 PWM 风扇控制
clone_repo 'https://github.com/anoixa/bpi-r4-pwm-fan' \
    'main' \
    '--depth=1' \
    'custom-packages/bpi-r4-pwm-fan'

# ImmortalWrt LuCI 仓库（稀疏克隆：仅 dae/daed 应用）
clone_repo 'https://github.com/immortalwrt/luci' \
    'master' \
    '--filter=blob:none --sparse --depth=1' \
    'custom-packages/luci'
(
    cd 'custom-packages/luci' || exit 1
    git sparse-checkout set applications/luci-app-dae applications/luci-app-daed
)

# Argon 主题配置应用
clone_repo 'https://github.com/jerrykuku/luci-app-argon-config' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-argon-config'

# DDNS-Go 动态域名解析
clone_repo 'https://github.com/sirpdboy/luci-app-ddns-go' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-ddns-go'

# 磁盘管理工具
clone_repo 'https://github.com/lisaac/luci-app-diskman' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-diskman'

# 风扇控制应用
clone_repo 'https://github.com/rockjake/luci-app-fancontrol.git' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-fancontrol'

# FanXpert 风扇控制应用
clone_repo 'https://github.com/Shuery-Shuai/luci-app-fanxpert.git' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-fanxpert'

# Lucky 网络工具
clone_repo 'https://github.com/gdy666/luci-app-lucky.git' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-lucky'

# Nginx 管理应用
clone_repo 'https://github.com/zhanghua000/luci-app-nginx' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-nginx'

# ZeroTier 虚拟局域网
clone_repo 'https://github.com/zhengmz/luci-app-zerotier' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-zerotier'

# Argon 主题
clone_repo 'https://github.com/jerrykuku/luci-theme-argon.git' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-theme-argon'

# OpenClash 代理管理工具
clone_repo 'https://github.com/vernesong/OpenClash' \
    'dev' \
    '--depth=1' \
    'custom-packages/openclash'

# ImmortalWrt 软件包仓库（稀疏克隆：golang、dae、daed）
clone_repo 'https://github.com/immortalwrt/packages' \
    'master' \
    '--filter=blob:none --sparse --depth=1' \
    'custom-packages/packages'
(
    cd 'custom-packages/packages' || exit 1
    git sparse-checkout set lang/golang net/dae net/daed
)

# qBittorrent BT 下载工具
clone_repo 'https://github.com/sbwml/openwrt-qBittorrent' \
    'master' \
    '--depth=1' \
    'custom-packages/qbittorrent'

# 孙大强的软件包备份仓库
clone_repo 'https://github.com/sundaqiang/openwrt-packages-backup' \
    'main' \
    '--depth=1' \
    'custom-packages/sundaqiang'

#######################################
# 添加 XDP sockets 诊断内核模块
#
# 为 ss 工具添加 PF_XDP sockets 监控支持，用于 eBPF XDP 程序的套接字统计。
# 参考: https://github.com/coolsnowwolf/lede/discussions/11799#discussioncomment-8626809
#
# 内核配置:
#   CONFIG_XDP_SOCKETS=y       - XDP sockets 基础支持
#   CONFIG_XDP_SOCKETS_DIAG    - XDP sockets 诊断接口
#
# 模块文件: net/xdp/xsk_diag.ko
#######################################
xdp_sockets_diag_content="
define KernelPackage/xdp-sockets-diag
  SUBMENU:=\$(NETWORK_SUPPORT_MENU)
  TITLE:=PF_XDP sockets monitoring interface support for ss utility
  KCONFIG:= \\
    CONFIG_XDP_SOCKETS=y \\
    CONFIG_XDP_SOCKETS_DIAG
  FILES:=\$(LINUX_DIR)/net/xdp/xsk_diag.ko
  AUTOLOAD:=\$(call AutoLoad,31,xsk_diag)
endef

define KernelPackage/xdp-sockets-diag/description
  Support for PF_XDP sockets monitoring interface used by the ss tool
endef

\$(eval \$(call KernelPackage,xdp-sockets-diag))
"

# 将内核模块定义追加到网络支持模块文件
echo "${xdp_sockets_diag_content}" >>package/kernel/linux/modules/netsupport.mk

#######################################
# 添加无线功率补丁（已禁用）
#
# 以下代码用于解锁 MediaTek MT7988 无线网卡的发射功率限制。
# 参考: https://github.com/Rahzadan/openwrt_bpi-r4_mtk_builder
#
# 警告: 修改发射功率可能违反当地无线电法规，请谨慎使用。
#
# 操作说明:
#   1. 删除原有 wireless-regdb Makefile 和补丁
#   2. 下载修改后的监管数据库配置
#   3. 应用 500-tx_power.patch 补丁
#
# 取消注释以下代码块可启用此功能:
#######################################
# wireless_regdb_makefile="package/firmware/wireless-regdb/Makefile"
# wireless_regdb_patch_dir="package/firmware/wireless-regdb/patches"
# tx_power_patch="${wireless_regdb_patch_dir}/500-tx_power.patch"
#
# rm -f "${wireless_regdb_makefile}"
# rm -f "${wireless_regdb_patch_dir}"/*.patch
#
# wget https://raw.githubusercontent.com/Rahzadan/openwrt_bpi-r4_mtk_builder/main/files/regdb.Makefile \
#   -O "${wireless_regdb_makefile}"
# wget https://raw.githubusercontent.com/Rahzadan/openwrt_bpi-r4_mtk_builder/main/files/500-tx_power.patch \
#   -O "${tx_power_patch}"
