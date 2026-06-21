#!/bin/bash
#######################################
# 软件包恢复脚本
#
# 根据备份文件自动恢复软件包，支持网络检测、DNS/防火墙临时修改、
# 批量安装、进度显示、安装验证等功能。
#
# 功能特性：
#   - 预安装检查：避免重复安装
#   - 智能网络检测：多镜像源测试
#   - 自动网络修复：临时修改 DNS 和防火墙规则
#   - 批量安装优化：优先批量安装，失败后逐个重试
#   - 实时进度显示：显示安装进度和状态
#   - 安装验证：确保所有包正确安装
#   - 自动清理：脚本退出时恢复原始配置
#
# 用法:
#   restore-packages [备份文件路径]
#
# 示例:
#   # 使用默认备份文件
#   restore-packages
#
#   # 指定备份文件
#   restore-packages /data/packages_backup.txt
#
#   # 禁用自动重启
#   AUTO_REBOOT=false restore-packages
#
#   # 自定义 DNS 服务器
#   DNS_PRIMARY=114.114.114.114 restore-packages
#
# 环境变量:
#   NETWORK_TEST_URL  - 网络测试 URL（默认: immortalwrt.shuery.lssa.fun）
#   DNS_PRIMARY       - 主 DNS 服务器（默认: 223.5.5.5 阿里DNS）
#   DNS_SECONDARY     - 备用 DNS 服务器（默认: 119.29.29.29 腾讯DNS）
#   AUTO_REBOOT       - 安装完成后自动重启（默认: true）
#
# 备份文件格式:
#   每行一个软件包，格式: "包名\t来源"
#   示例:
#     curl        overlay
#     kmod-usb3   rom
#
# 工作流程:
#   1. 检查是否已安装（读取标记文件）
#   2. 预检查：验证备份文件中的包是否已安装
#   3. 网络检测：测试多个镜像源
#   4. 网络修复：必要时临时修改 DNS 和防火墙
#   5. 更新软件源：apk update
#   6. 批量安装：优先批量安装，失败后逐个重试
#   7. 安装验证：确保所有包已正确安装
#   8. 清理：删除备份文件，创建完成标记
#   9. 重启：根据 AUTO_REBOOT 决定是否重启
#
# 退出码:
#   0 - 成功
#   1 - 失败（备份文件不存在、网络不可用、安装失败等）
#
# 作者: Shuery-Shuai
# 日期: 2025-06-27
# 版本: 1.1.0
#######################################

set -euo pipefail

#######################################
# 配置常量
#
# Globals:
#   NETWORK_TEST_URLS    - 网络测试 URL 数组，按顺序测试
#   DNS_PRIMARY          - 主 DNS 服务器地址
#   DNS_SECONDARY        - 备用 DNS 服务器地址
#   MAX_INSTALL_RETRIES  - 软件包安装最大重试次数
#   NETWORK_RETRIES      - 网络检测重试次数
#   NETWORK_TIMEOUT      - 网络请求超时时间（秒）
#   AUTO_REBOOT          - 是否自动重启系统
#   REBOOT_DELAY         - 重启前延迟时间（秒）
#   STATE_DIR            - 状态管理目录，用于存储备份和标记
#######################################
readonly NETWORK_TEST_URLS=(
    "${NETWORK_TEST_URL:-https://rtfw.shuery.lssa.fun}"
    "https://mirrors.tuna.tsinghua.edu.cn"
    "https://mirrors.ustc.edu.cn"
)
readonly DNS_PRIMARY="${DNS_PRIMARY:-223.5.5.5}"        # 阿里DNS
readonly DNS_SECONDARY="${DNS_SECONDARY:-119.29.29.29}" # 腾讯DNS
readonly MAX_INSTALL_RETRIES=3
readonly NETWORK_RETRIES=3
readonly NETWORK_TIMEOUT=5
readonly AUTO_REBOOT="${AUTO_REBOOT:-true}"
readonly REBOOT_DELAY=10

# 状态管理目录（使用 $$ 确保进程唯一性）
readonly STATE_DIR="/tmp/restore-state-$$"

#######################################
# 主函数：软件包恢复流程
#
# 执行完整的软件包恢复流程，包括预检查、网络检测、网络修复、
# 软件源更新、软件包安装、验证和系统重启。
#
# Globals:
#   STATE_DIR       - 状态管理目录
#   AUTO_REBOOT     - 是否自动重启
#   REBOOT_DELAY    - 重启延迟时间
#
# Arguments:
#   $1 - 备份文件路径（可选，默认: /etc/backup/installed_packages.txt）
#
# Outputs:
#   日志信息输出到终端和日志文件
#   创建 /tmp/packages-has-installed 标记文件
#
# Returns:
#   0 - 成功完成恢复流程
#   1 - 失败（备份文件不存在、网络不可用、安装失败等）
#
# Examples:
#   main                              # 使用默认备份文件
#   main "/data/backup.txt"          # 使用指定备份文件
#######################################
main() {
    # 初始化状态目录
    mkdir -p "$STATE_DIR"

    # 设置退出时自动恢复配置
    trap cleanup EXIT

    # 初始化路径
    local backup_file="${1:-/etc/backup/installed_packages.txt}"
    local log_file
    log_file="/var/log/package-restore-$(date +'%Y%m%d%H%M%S').log"
    local installed_flag="/tmp/packages-has-installed"

    # 保存日志路径到状态目录
    echo "$log_file" > "$STATE_DIR/log_file"

    # 初始化日志
    log_header "$log_file" "开始恢复软件包" "backup_file=$backup_file"

    # 检查是否已安装
    if [ -f "$installed_flag" ] || check_all_packages_installed "$backup_file" "$log_file"; then
        log_info "$log_file" "所有软件包已安装，无需操作"
        return 0
    fi

    # 验证备份文件
    if [ ! -f "$backup_file" ]; then
        log_error "$log_file" "备份文件不存在: $backup_file"
        return 1
    fi

    # 网络状态检测
    if ! check_network "$log_file"; then
        log_info "$log_file" "首次网络检测失败，尝试修复网络配置..."

        # 备份并修改DNS
        backup_and_set_dns "$log_file"

        # 备份并修改防火墙
        local fw_type
        fw_type=$(detect_firewall_type)
        if [ -n "$fw_type" ]; then
            backup_and_set_firewall "$fw_type" "$log_file"
        fi

        # 第二次检测
        if ! check_network "$log_file"; then
            log_error "$log_file" "无法连接软件源，恢复中止"
            return 1
        fi
    fi

    # 更新软件源
    if ! update_package_lists "$log_file"; then
        log_error "$log_file" "软件源更新失败"
        return 1
    fi

    # 安装并验证软件包
    if ! install_and_verify_packages "$backup_file" "$log_file"; then
        log_error "$log_file" "软件包安装验证失败"
        return 1
    fi

    # 删除备份文件（安装验证成功后）
    if rm -f "$backup_file"; then
        log_info "$log_file" "已删除备份文件: $backup_file"
    fi

    # 创建安装完成标记
    if touch "$installed_flag"; then
        log_info "$log_file" "已创建安装完成标记: $installed_flag"
    else
        log_error "$log_file" "无法创建安装完成标记: $installed_flag"
    fi

    # 最终系统重启
    log_info "$log_file" "===== 所有软件包验证成功 ====="

    if [ "$AUTO_REBOOT" = "true" ]; then
        log_info "$log_file" "系统将在${REBOOT_DELAY}秒后重启..."
        sleep "$REBOOT_DELAY"
        reboot
    else
        log_info "$log_file" "自动重启已禁用，请手动重启系统"
    fi
}

#=== 日志函数 ===#

#######################################
# 记录日志头信息
#
# 在日志文件中写入带时间戳的标题行，用于标记重要操作节点。
# 格式：分隔线 + 时间戳 + 标题 + 可选附加信息
#
# Globals:
#   无
#
# Arguments:
#   $1 - 日志文件路径
#   $2 - 标题文本（必需）
#   $3 - 附加信息（可选，为空时不输出）
#
# Outputs:
#   将格式化的标题信息追加到日志文件
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   log_header "$log_file" "开始恢复软件包" "backup_file=/etc/backup.txt"
#   log_header "$log_file" "安装完成" ""
#######################################
log_header() {
    local log_file="$1"
    local title="$2"
    local info="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%dT%H:%M:%S%z')

    {
        echo "===== $timestamp - $title ====="
        [ -n "$info" ] && echo "信息: $info"
        echo
    } >>"$log_file"
}

#######################################
# 记录信息日志
#
# 记录普通信息级别的日志，同时输出到终端和日志文件。
# 每条日志前自动添加 ISO 8601 格式的时间戳。
#
# Globals:
#   无
#
# Arguments:
#   $1 - 日志文件路径
#   $2 - 日志消息内容
#
# Outputs:
#   将带时间戳的消息输出到 stdout 并追加到日志文件
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   log_info "$log_file" "开始安装软件包"
#   log_info "$log_file" "网络检测通过"
#######################################
log_info() {
    local log_file="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +'%Y-%m-%dT%H:%M:%S%z')

    echo "[$timestamp] $message" | tee -a "$log_file"
}

#######################################
# 记录错误日志
#
# 记录错误级别的日志，输出到 stderr 和日志文件。
# 每条错误日志前自动添加时间戳和 "[错误]" 标签。
#
# Globals:
#   无
#
# Arguments:
#   $1 - 日志文件路径
#   $2 - 错误消息内容
#
# Outputs:
#   将带时间戳和错误标签的消息输出到 stderr 并追加到日志文件
#
# Returns:
#   1 - 总是返回 1（表示错误状态）
#
# Examples:
#   log_error "$log_file" "备份文件不存在"
#   log_error "$log_file" "网络连接失败"
#######################################
log_error() {
    local log_file="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +'%Y-%m-%dT%H:%M:%S%z')

    echo "[$timestamp][错误] $message" | tee -a "$log_file" >&2
    return 1
}

#######################################
# 清理函数：恢复原始配置
#
# 脚本退出时自动调用（通过 trap 机制），用于恢复脚本运行期间
# 临时修改的系统配置，包括 DNS 和防火墙规则。
# 确保无论脚本是正常退出还是异常退出，都能恢复原始配置。
#
# Globals:
#   STATE_DIR - 状态目录，存储备份文件和标记文件
#
# Arguments:
#   无
#
# Outputs:
#   恢复配置时输出日志信息
#
# Returns:
#   无返回值（清理函数，总是尽力执行）
#
# 工作流程:
#   1. 读取日志文件路径
#   2. 检查 DNS 修改标记，存在则恢复 /etc/resolv.conf
#   3. 检查防火墙修改标记，存在则恢复对应类型的规则
#   4. 清理整个状态目录
#
# Examples:
#   trap cleanup EXIT  # 在脚本开始时设置自动清理
#######################################
cleanup() {
    local log_file
    log_file=$(cat "$STATE_DIR/log_file" 2>/dev/null || echo "/dev/null")

    # 恢复DNS配置
    if [ -f "$STATE_DIR/dns_modified" ]; then
        if [ -f "$STATE_DIR/resolv.conf.backup" ]; then
            log_info "$log_file" "恢复原始DNS配置..."
            mv -f "$STATE_DIR/resolv.conf.backup" /etc/resolv.conf
        fi
    fi

    # 恢复防火墙配置
    if [ -f "$STATE_DIR/firewall_modified" ]; then
        local fw_type
        fw_type=$(cat "$STATE_DIR/firewall_type" 2>/dev/null || echo "")

        if [ -n "$fw_type" ]; then
            log_info "$log_file" "恢复原始防火墙配置 ($fw_type)..."

            case "$fw_type" in
            iptables)
                # 恢复 IPv4 规则
                if [ -f "$STATE_DIR/iptables.backup" ]; then
                    iptables-restore < "$STATE_DIR/iptables.backup" 2>/dev/null || true
                fi
                # 恢复 IPv6 规则
                if [ -f "$STATE_DIR/ip6tables.backup" ]; then
                    ip6tables-restore < "$STATE_DIR/ip6tables.backup" 2>/dev/null || true
                fi
                ;;
            nftables)
                # 清空规则集后恢复备份
                if [ -f "$STATE_DIR/nftables.backup" ]; then
                    nft flush ruleset 2>/dev/null || true
                    nft -f "$STATE_DIR/nftables.backup" 2>/dev/null || true
                fi
                ;;
            esac
        fi
    fi

    # 清理状态目录
    rm -rf "$STATE_DIR"
}

#=== 检查函数 ===#

#######################################
# 预安装检查：验证所有包是否已安装
#
# 在执行安装操作前，检查备份文件中的所有用户安装包（来源为 overlay）
# 是否已经存在于系统中。如果所有包都已安装，则跳过后续安装流程。
#
# Globals:
#   无
#
# Arguments:
#   $1 - 备份文件路径（格式：包名\t来源）
#   $2 - 日志文件路径
#
# Outputs:
#   输出检查过程日志信息
#
# Returns:
#   0 - 所有用户包已安装（或无需安装的包）
#   1 - 存在未安装的包或备份文件不存在
#
# 工作流程:
#   1. 检查备份文件是否存在
#   2. 提取所有来源为 overlay 的包名
#   3. 逐个检查包是否已通过 apk 安装
#   4. 记录未安装的包并返回检查结果
#
# Examples:
#   if check_all_packages_installed "/etc/backup.txt" "$log_file"; then
#       echo "所有包已安装，跳过"
#   fi
#######################################
check_all_packages_installed() {
    local backup_file="$1"
    local log_file="$2"
    local user_pkgs="/tmp/user-pkgs-check.list"
    local all_installed=1

    # 检查备份文件是否存在
    if [ ! -f "$backup_file" ]; then
        log_info "$log_file" "备份文件不存在，跳过预检查"
        return 1
    fi

    # 提取所有用户安装包
    if ! grep '\toverlay' "$backup_file" | awk '{print $1}' >"$user_pkgs"; then
        log_info "$log_file" "未找到 overlay 包"
        : >"$user_pkgs"
    fi

    # 没有用户包时直接返回成功
    if [ ! -s "$user_pkgs" ]; then
        log_info "$log_file" "无用户安装包需要检查"
        rm -f "$user_pkgs"
        return 0
    fi

    # 检查每个包是否已安装
    while IFS= read -r pkg; do
        if ! apk info --installed "$pkg" >/dev/null 2>&1; then
            log_info "$log_file" "包未安装: $pkg"
            all_installed=0
        fi
    done <"$user_pkgs"

    # 清理临时文件
    rm -f "$user_pkgs"

    if [ "$all_installed" -eq 1 ]; then
        log_info "$log_file" "所有用户安装包已存在"
        return 0
    fi
    return 1
}

#######################################
# 网络检测：尝试多个镜像源
#
# 通过 curl 测试多个预定义的镜像源 URL，验证网络连接可用性。
# 支持多次重试，每次重试间隔递增，提高网络波动情况下的成功率。
#
# Globals:
#   NETWORK_TEST_URLS - 测试 URL 数组（包含多个镜像源）
#   NETWORK_RETRIES   - 最大重试次数（默认 3 次）
#   NETWORK_TIMEOUT   - 单次连接超时时间（秒）
#
# Arguments:
#   $1 - 日志文件路径
#
# Outputs:
#   输出网络检测结果日志
#
# Returns:
#   0 - 网络连接正常（至少一个 URL 可达）
#   1 - 所有 URL 均不可达
#
# 工作流程:
#   1. 外层循环：最多重试 NETWORK_RETRIES 次
#   2. 内层循环：依次测试 NETWORK_TEST_URLS 中的每个 URL
#   3. 任意一个 URL 响应成功，立即返回 0
#   4. 单轮失败后等待递增时间（2s, 4s, 6s...）后重试
#   5. 所有重试耗尽后返回 1
#
# Examples:
#   if check_network "$log_file"; then
#       echo "网络可用"
#   else
#       echo "网络不可用，需要修复"
#   fi
#######################################
check_network() {
    local log_file="$1"
    local i=1

    while [ "$i" -le "$NETWORK_RETRIES" ]; do
        # 依次测试每个镜像源
        for test_url in "${NETWORK_TEST_URLS[@]}"; do
            if curl --connect-timeout "$NETWORK_TIMEOUT" -kIs "$test_url" >/dev/null 2>&1; then
                log_info "$log_file" "网络连接正常 (通过 $test_url)"
                return 0
            fi
        done

        # 未达到最大重试次数时等待后重试
        if [ "$i" -lt "$NETWORK_RETRIES" ]; then
            log_info "$log_file" "网络检查失败 (尝试 $i/$NETWORK_RETRIES)，等待后重试..."
            sleep $((i * 2))  # 递增等待时间：2s, 4s, 6s...
        fi
        i=$((i + 1))
    done

    log_info "$log_file" "所有网络测试URL均无法连接"
    return 1
}

#=== 配置备份与恢复 ===#

#######################################
# 备份并设置DNS配置
#
# 备份当前的 /etc/resolv.conf 文件，并临时修改为指定的 DNS 服务器。
# 用于解决网络连接问题，原始配置将在脚本退出时由 cleanup 函数恢复。
#
# Globals:
#   DNS_PRIMARY   - 主 DNS 服务器地址（默认：223.5.5.5 阿里DNS）
#   DNS_SECONDARY - 备用 DNS 服务器地址（默认：119.29.29.29 腾讯DNS）
#   STATE_DIR     - 状态目录，用于存储备份文件和修改标记
#
# Arguments:
#   $1 - 日志文件路径
#
# Outputs:
#   输出备份和修改 DNS 的日志信息
#
# Returns:
#   0 - 成功备份并修改 DNS
#   1 - 失败（resolv.conf 不存在、备份失败或修改失败）
#
# 副作用:
#   - 创建 $STATE_DIR/resolv.conf.backup 备份文件
#   - 创建 $STATE_DIR/dns_modified 标记文件
#   - 修改 /etc/resolv.conf 内容
#
# Examples:
#   backup_and_set_dns "$log_file"
#######################################
backup_and_set_dns() {
    local log_file="$1"
    log_info "$log_file" "备份DNS配置..."

    # 检查 resolv.conf 是否存在
    if [ ! -f /etc/resolv.conf ]; then
        log_info "$log_file" "警告：/etc/resolv.conf 不存在，跳过DNS修改"
        return 1
    fi

    # 备份原始 DNS 配置
    if ! cp /etc/resolv.conf "$STATE_DIR/resolv.conf.backup"; then
        log_error "$log_file" "备份 resolv.conf 失败"
        return 1
    fi

    # 写入新的 DNS 服务器
    if ! printf "nameserver %s\nnameserver %s\n" "$DNS_PRIMARY" "$DNS_SECONDARY" >/etc/resolv.conf; then
        log_error "$log_file" "修改 resolv.conf 失败"
        return 1
    fi

    # 标记DNS已修改
    touch "$STATE_DIR/dns_modified"
    log_info "$log_file" "DNS已临时设置为: $DNS_PRIMARY, $DNS_SECONDARY"
    return 0
}

#######################################
# 检测防火墙类型
#
# 自动检测系统使用的防火墙类型（nftables 或 iptables）。
# 优先检测 nftables，其次检测 iptables，均不可用时返回空字符串。
#
# Globals:
#   无
#
# Arguments:
#   无
#
# Outputs:
#   输出防火墙类型字符串到 stdout：
#     "nftables" - 系统使用 nftables
#     "iptables" - 系统使用 iptables
#     ""         - 未检测到可用的防火墙
#
# Returns:
#   0 - 总是成功
#
# 检测逻辑:
#   1. 检查 nft 命令是否存在且能成功列出规则集
#   2. 检查 iptables 命令是否存在且能成功列出规则
#   3. 两者都不可用时返回空字符串
#
# Examples:
#   fw_type=$(detect_firewall_type)
#   if [ "$fw_type" = "nftables" ]; then
#       echo "系统使用 nftables"
#   fi
#######################################
detect_firewall_type() {
    # 优先检测 nftables
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        echo "nftables"
    # 其次检测 iptables
    elif command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1; then
        echo "iptables"
    # 未检测到可用防火墙
    else
        echo ""
    fi
}

#######################################
# 备份并设置防火墙配置
#
# 根据防火墙类型（iptables 或 nftables）备份当前规则，并设置临时的
# 宽松规则以允许软件包下载（HTTP/HTTPS/DNS）。原始配置将在脚本退出时
# 由 cleanup 函数恢复。
#
# Globals:
#   STATE_DIR - 状态目录，用于存储备份文件和修改标记
#
# Arguments:
#   $1 - 防火墙类型（"iptables" 或 "nftables"）
#   $2 - 日志文件路径
#
# Outputs:
#   输出备份和修改防火墙的日志信息
#
# Returns:
#   0 - 成功备份并修改防火墙规则
#   1 - 失败（备份失败）
#
# 副作用:
#   - 对于 iptables：
#     * 创建 $STATE_DIR/iptables.backup 和 ip6tables.backup
#     * 设置所有链策略为 ACCEPT
#     * 清空现有规则
#     * 添加允许 HTTP(80)、HTTPS(443)、DNS(53) 的规则
#   - 对于 nftables：
#     * 创建 $STATE_DIR/nftables.backup
#     * 清空现有规则集
#     * 创建临时表和链，策略为 ACCEPT
#   - 创建 $STATE_DIR/firewall_type 和 firewall_modified 标记
#
# Examples:
#   fw_type=$(detect_firewall_type)
#   if [ -n "$fw_type" ]; then
#       backup_and_set_firewall "$fw_type" "$log_file"
#   fi
#######################################
backup_and_set_firewall() {
    local fw_type="$1"
    local log_file="$2"

    log_info "$log_file" "备份防火墙配置 ($fw_type)..."

    case "$fw_type" in
    iptables)
        # 备份 IPv4 规则
        if ! iptables-save >"$STATE_DIR/iptables.backup"; then
            log_info "$log_file" "警告：备份 iptables 失败"
            return 1
        fi
        # 备份 IPv6 规则
        if ! ip6tables-save >"$STATE_DIR/ip6tables.backup"; then
            log_info "$log_file" "警告：备份 ip6tables 失败"
            return 1
        fi

        # 设置临时规则：允许 HTTP/HTTPS/DNS 出站流量
        log_info "$log_file" "设置临时防火墙规则 (允许 HTTP/HTTPS)..."
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -F
        iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
        iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

        # IPv6 规则
        ip6tables -P INPUT ACCEPT
        ip6tables -P OUTPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -F
        ip6tables -A OUTPUT -p tcp --dport 80 -j ACCEPT
        ip6tables -A OUTPUT -p tcp --dport 443 -j ACCEPT
        ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
        ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        ;;
    nftables)
        # 备份现有规则集
        if ! nft list ruleset >"$STATE_DIR/nftables.backup"; then
            log_info "$log_file" "警告：备份 nftables 失败"
            return 1
        fi

        # 设置临时规则：创建宽松的临时表
        log_info "$log_file" "设置临时防火墙规则 (允许 HTTP/HTTPS)..."
        nft flush ruleset
        nft add table inet temp_table
        nft add chain inet temp_table input \
            '{ type filter hook input priority 0; policy accept; }'
        nft add chain inet temp_table output \
            '{ type filter hook output priority 0; policy accept; }'
        nft add chain inet temp_table forward \
            '{ type filter hook forward priority 0; policy accept; }'
        ;;
    esac

    # 保存防火墙类型并标记已修改
    echo "$fw_type" >"$STATE_DIR/firewall_type"
    touch "$STATE_DIR/firewall_modified"
    return 0
}

#=== 软件包管理 ===#

#######################################
# 更新软件源
#
# 执行 apk update 命令更新软件包索引，为后续安装做准备。
# 所有输出重定向到日志文件以便问题诊断。
#
# Globals:
#   无
#
# Arguments:
#   $1 - 日志文件路径
#
# Outputs:
#   输出更新过程的日志信息
#   apk update 的详细输出追加到日志文件
#
# Returns:
#   0 - 更新成功
#   1 - 更新失败
#
# Examples:
#   if update_package_lists "$log_file"; then
#       echo "软件源更新成功"
#   fi
#######################################
update_package_lists() {
    local log_file="$1"
    log_info "$log_file" "更新软件包列表..."

    # 执行 apk update 并将输出重定向到日志
    if ! apk update >>"$log_file" 2>&1; then
        log_error "$log_file" "apk update 执行失败"
        return 1
    fi

    log_info "$log_file" "软件包列表更新成功"
    return 0
}

#######################################
# 安装并验证软件包
#
# 从备份文件中提取用户软件包和内核模块，按类型分别安装。
# 用户包（来源为 overlay）使用多次重试策略，内核模块（kmod-* 且来源为 rom）
# 仅尝试一次（失败不影响整体流程）。
#
# Globals:
#   MAX_INSTALL_RETRIES - 用户包安装的最大重试次数
#
# Arguments:
#   $1 - 备份文件路径（格式：包名\t来源）
#   $2 - 日志文件路径
#
# Outputs:
#   输出安装过程的日志信息
#
# Returns:
#   0 - 用户包全部安装成功（内核模块失败不影响）
#   1 - 用户包安装失败
#
# 工作流程:
#   1. 从备份文件提取用户安装包（来源为 overlay）
#   2. 从备份文件提取内核模块（kmod-* 且来源为 rom）
#   3. 优先安装用户包，允许多次重试
#   4. 安装内核模块，失败不中断流程（记录警告）
#   5. 清理临时包列表文件
#
# Examples:
#   if install_and_verify_packages "$backup_file" "$log_file"; then
#       echo "软件包安装完成"
#   fi
#######################################
install_and_verify_packages() {
    local backup_file="$1"
    local log_file="$2"
    local user_pkgs="/tmp/user-pkgs.list"
    local kernel_pkgs="/tmp/kernel-pkgs.list"

    # 提取用户安装包列表（来源为 overlay）
    if ! grep 'overlay$' "$backup_file" | awk '{print $1}' >"$user_pkgs"; then
        log_info "$log_file" "未找到用户软件包"
        : >"$user_pkgs"  # 创建空文件
    fi

    # 提取内核模块列表（kmod-* 且来源为 rom）
    if ! grep '^kmod-.*\trom' "$backup_file" | awk '{print $1}' >"$kernel_pkgs"; then
        log_info "$log_file" "未找到内核模块"
        : >"$kernel_pkgs"  # 创建空文件
    fi

    # 安装用户包
    if [ -s "$user_pkgs" ]; then
        log_info "$log_file" "=== 安装用户软件包 ==="
        if ! install_packages_batch "$user_pkgs" "$MAX_INSTALL_RETRIES" "$log_file"; then
            log_error "$log_file" "用户软件包安装失败"
            rm -f "$user_pkgs" "$kernel_pkgs"
            return 1
        fi
    else
        log_info "$log_file" "无用户软件包需要安装"
    fi

    # 安装内核模块（失败不影响整体流程）
    log_info "$log_file" "=== 安装内核模块 ==="
    if [ -s "$kernel_pkgs" ]; then
        if ! install_packages_batch "$kernel_pkgs" 1 "$log_file"; then
            log_info "$log_file" "警告：部分内核模块未正确安装（非致命错误）"
        fi
    else
        log_info "$log_file" "无内核模块需要安装"
    fi

    # 清理临时文件
    rm -f "$user_pkgs" "$kernel_pkgs"
    return 0
}

#######################################
# 批量安装软件包（带重试和进度显示）
#
# 从包列表文件中读取软件包名称并安装，支持批量安装和逐个重试策略。
# 优先尝试批量安装以提高效率，失败后自动切换到逐个安装模式以识别
# 问题包。每个包安装后立即验证，未通过验证的包会被标记为失败并重试。
#
# Globals:
#   无
#
# Arguments:
#   $1 - 包列表文件路径（每行一个包名）
#   $2 - 最大重试次数
#   $3 - 日志文件路径
#
# Outputs:
#   实时输出安装进度（[当前/总数] 包名 [状态]）
#   详细输出追加到日志文件
#
# Returns:
#   0 - 所有软件包安装并验证成功
#   1 - 达到最大重试次数后仍有包安装失败
#
# 工作流程:
#   1. 检查包列表文件是否存在且非空
#   2. 尝试批量安装（apk add 所有包）
#   3. 批量失败后逐个安装：
#      - 显示进度条（当前/总数）
#      - 安装成功后验证包是否真正安装
#      - 失败的包记录到临时失败列表
#   4. 检查是否有失败包：
#      - 无失败：返回成功
#      - 有失败且未达重试上限：将失败列表作为新包列表，递增等待后重试
#      - 达到重试上限：输出失败列表并返回错误
#
# Examples:
#   # 安装用户包，最多重试3次
#   install_packages_batch "$user_pkgs" 3 "$log_file"
#
#   # 安装内核模块，仅尝试1次
#   install_packages_batch "$kernel_pkgs" 1 "$log_file"
#######################################
install_packages_batch() {
    local pkg_list="$1"
    local max_retries="$2"
    local log_file="$3"
    local retry_count=0

    # 检查输入文件是否存在且非空
    if [ ! -s "$pkg_list" ]; then
        log_info "$log_file" "包列表为空，跳过安装"
        return 0
    fi

    local total_pkgs
    total_pkgs=$(wc -l < "$pkg_list")
    log_info "$log_file" "准备安装 $total_pkgs 个软件包"

    while [ "$retry_count" -lt "$max_retries" ]; do
        log_info "$log_file" "=== 安装尝试 $((retry_count + 1))/$max_retries ==="

        # 尝试批量安装（效率最高）
        if xargs <"$pkg_list" apk add --no-cache >>"$log_file" 2>&1; then
            log_info "$log_file" "批量安装成功"
            return 0
        fi

        log_info "$log_file" "批量安装失败，逐个安装以识别问题包..."

        # 批量失败后逐个安装
        local failed_file="/tmp/failed-pkgs-$$.list"
        : >"$failed_file"  # 清空失败列表
        local current=0

        while IFS= read -r pkg; do
            current=$((current + 1))
            # 实时显示进度（使用 \r 覆盖同一行）
            echo -ne "\r[$current/$total_pkgs] 安装 $pkg..." | tee -a "$log_file"

            if apk add --no-cache "$pkg" >>"$log_file" 2>&1; then
                # 安装成功后验证包是否真正安装
                if ! apk info --installed "$pkg" >/dev/null 2>&1; then
                    echo "$pkg" >>"$failed_file"
                    echo " [验证失败]" | tee -a "$log_file"
                else
                    echo " [成功]" | tee -a "$log_file"
                fi
            else
                echo "$pkg" >>"$failed_file"
                echo " [安装失败]" | tee -a "$log_file"
            fi
        done <"$pkg_list"
        echo  # 换行，结束进度显示

        # 检查是否全部成功
        if [ ! -s "$failed_file" ]; then
            log_info "$log_file" "所有软件包安装并验证成功"
            rm -f "$failed_file"
            return 0
        fi

        # 准备重试
        retry_count=$((retry_count + 1))
        if [ "$retry_count" -lt "$max_retries" ]; then
            log_info "$log_file" "准备重试失败的软件包..."
            mv "$failed_file" "$pkg_list"  # 使用失败列表替换原列表
            total_pkgs=$(wc -l < "$pkg_list")
            sleep 3  # 等待后重试
        else
            # 达到最大重试次数，输出失败列表
            log_error "$log_file" "以下 $(wc -l < "$failed_file") 个软件包安装失败:"
            cat "$failed_file" | tee -a "$log_file"
            rm -f "$failed_file"
            return 1
        fi
    done

    return 1
}

# 执行主函数
main "$@"
