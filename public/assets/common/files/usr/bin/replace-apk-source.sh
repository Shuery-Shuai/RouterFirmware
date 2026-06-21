#!/bin/bash
#######################################
# APK/OPKG 软件源智能替换脚本
#
# 根据官方源的网络可用性和性能，自动决定使用官方源或镜像源。
# 支持 OpenWrt 和 ImmortalWrt 两个发行版，自动检测包管理器类型（APK/OPKG）。
#
# 功能特性：
#   - 自动检测包管理器（APK 或 OPKG）
#   - 网络质量评估（延迟和速度测试）
#   - 智能源切换（官方源可用时优先使用）
#   - 支持自定义镜像源和性能阈值
#   - 完整的日志记录（可选 syslog 集成）
#
# 决策逻辑：
#   1. 测试官方源的延迟和下载速度
#   2. 如果官方源可用且性能良好 → 使用官方源（或从镜像切换回官方）
#   3. 如果官方源不可达或性能差 → 切换到镜像源
#
# 用法:
#   replace-apk-source.sh
#
# 示例:
#   # 基本使用
#   replace-apk-source.sh
#
#   # 自定义镜像源
#   OPENWRT_MIRROR=https://mirrors.aliyun.com/openwrt replace-apk-source.sh
#
#   # 调整性能阈值
#   MAX_LATENCY=3.0 MIN_SPEED=100000 replace-apk-source.sh
#
#   # 启用 syslog 日志
#   LOG_TO_SYSLOG=1 replace-apk-source.sh
#
# 环境变量:
#   OPENWRT_OFFICIAL      - OpenWrt 官方源 URL（默认: downloads.openwrt.org）
#   OPENWRT_MIRROR        - OpenWrt 镜像源 URL（默认: mirrors.ustc.edu.cn/openwrt）
#   IMMORTALWRT_OFFICIAL  - ImmortalWrt 官方源 URL（默认: downloads.immortalwrt.org）
#   IMMORTALWRT_MIRROR    - ImmortalWrt 镜像源 URL（默认: immortalwrt.kyarucloud.moe）
#   MAX_LATENCY           - 最大可接受延迟（秒，默认: 2.0）
#   MIN_SPEED             - 最小可接受速度（字节/秒，默认: 200000 = 200KB/s）
#   LOG_TO_SYSLOG         - 是否记录到 syslog（0/1，默认: 0）
#
# 性能阈值说明：
#   MAX_LATENCY   - 超过此延迟视为官方源不可用
#   MIN_SPEED     - 低于此速度视为官方源性能差
#
# 配置文件位置：
#   APK:  /etc/apk/repositories.d/distfeeds.list, /etc/apk/repositories
#   OPKG: /etc/opkg/distfeeds.conf, /etc/opkg/customfeeds.conf
#
# 工作流程：
#   1. 检测包管理器类型（APK 或 OPKG）
#   2. 测试 OpenWrt 官方源网络质量
#   3. 根据测试结果决定是否替换源
#   4. 测试 ImmortalWrt 官方源网络质量
#   5. 根据测试结果决定是否替换源
#
# 退出码:
#   0 - 成功
#   1 - 失败（未找到包管理器等）
#
# 作者: Shuery-Shuai
# 版本: 1.1.0
#######################################

set -e

#######################################
# 临时文件管理
#
# 全局数组，用于记录所有需要清理的临时文件。
# 每个临时文件创建后应添加到此数组中。
#
# Globals:
#   TMP_FILES - 临时文件路径数组
#######################################
TMP_FILES=()

#######################################
# 清理所有临时文件
#
# 在脚本退出时自动调用，删除所有记录在 TMP_FILES 数组中的临时文件。
# 使用 -f 标志以确保删除失败不会导致脚本异常退出。
#
# Globals:
#   TMP_FILES - 读取要删除的临时文件列表
#
# Arguments:
#   None
#
# Outputs:
#   None
#
# Returns:
#   0 - 总是成功
#######################################
cleanup_tmp() {
    for f in "${TMP_FILES[@]}"; do
        rm -f "$f"
    done
}
# 注册退出清理钩子，确保脚本退出时清理临时文件
trap cleanup_tmp EXIT

#######################################
# 输出格式化的日志消息
#
# 输出带有时间戳和级别标签的日志消息到 stderr。
# 支持可选的 syslog 集成，当 LOG_TO_SYSLOG=1 时同时写入系统日志。
#
# 日志格式: [时间戳] [级别] 消息
#
# Arguments:
#   $1 - 日志级别 (INFO|WARN|ERROR 等)
#   $2 - 日志消息内容
#
# Globals:
#   LOG_TO_SYSLOG - 是否启用 syslog（0=禁用, 1=启用，默认: 0）
#
# Outputs:
#   格式化的日志输出到 stderr
#   如果启用 syslog，同时通过 logger 写入系统日志
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   log INFO "Starting service"
#   log ERROR "Connection failed"
#   LOG_TO_SYSLOG=1 log WARN "High memory usage"
#######################################
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >&2
    # 如果启用 syslog 且 logger 命令可用，写入系统日志
    if [ "${LOG_TO_SYSLOG:-0}" = "1" ]; then
        command -v logger >/dev/null 2>&1 && logger -t "uci-sources" "$level: $message"
    fi
    return 0
}

#######################################
# OpenWrt 源配置
#
# 定义 OpenWrt 官方源和镜像源的 URL 及其匹配模式。
# 支持通过环境变量自定义源地址。
#
# Globals:
#   OPENWRT_OFFICIAL         - OpenWrt 官方源 URL
#   OPENWRT_OFFICIAL_PATTERN - 官方源的 sed 匹配模式（支持 http/https）
#   OPENWRT_MIRROR           - OpenWrt 镜像源 URL
#   OPENWRT_MIRROR_PATTERN   - 镜像源的 sed 匹配模式（支持 http/https）
#######################################
OPENWRT_OFFICIAL="${OPENWRT_OFFICIAL:-https://downloads.openwrt.org}"
OPENWRT_OFFICIAL_PATTERN="https\?://downloads\.openwrt\.org"
OPENWRT_MIRROR="${OPENWRT_MIRROR:-https://mirrors.ustc.edu.cn/openwrt}"
OPENWRT_MIRROR_PATTERN="https\?://mirrors\.ustc\.edu\.cn/openwrt"

#######################################
# ImmortalWrt 源配置
#
# 定义 ImmortalWrt 官方源和镜像源的 URL 及其匹配模式。
# 支持通过环境变量自定义源地址。
#
# Globals:
#   IMMORTALWRT_OFFICIAL         - ImmortalWrt 官方源 URL
#   IMMORTALWRT_OFFICIAL_PATTERN - 官方源的 sed 匹配模式（支持 http/https）
#   IMMORTALWRT_MIRROR           - ImmortalWrt 镜像源 URL
#   IMMORTALWRT_MIRROR_PATTERN   - 镜像源的 sed 匹配模式（支持 http/https）
#######################################
IMMORTALWRT_OFFICIAL="${IMMORTALWRT_OFFICIAL:-https://downloads.immortalwrt.org}"
IMMORTALWRT_OFFICIAL_PATTERN="https\?://downloads\.immortalwrt\.org"
IMMORTALWRT_MIRROR="${IMMORTALWRT_MIRROR:-https://immortalwrt.kyarucloud.moe}"
IMMORTALWRT_MIRROR_PATTERN="https\?://immortalwrt\.kyarucloud\.moe"

#######################################
# 性能阈值配置
#
# 定义判断官方源是否可用的性能标准。
# 官方源的延迟超过 MAX_LATENCY 或速度低于 MIN_SPEED 时，将切换到镜像源。
# 支持通过环境变量自定义阈值。
#
# Globals:
#   MAX_LATENCY - 最大可接受延迟（秒，超过此值视为不可用）
#   MIN_SPEED   - 最小可接受速度（字节/秒，低于此值视为性能差）
#######################################
# 性能阈值（可通过环境变量自定义）
MAX_LATENCY="${MAX_LATENCY:-2.0}"
MIN_SPEED="${MIN_SPEED:-200000}"  # 200KB/s

#######################################
# 包管理器检测和配置文件设置
#
# 自动检测系统使用的包管理器类型（APK 或 OPKG），
# 并设置对应的软件源配置文件列表。
#
# 检测顺序：
#   1. 检查是否存在 apk 命令 → APK 包管理器
#   2. 检查是否存在 opkg 命令 → OPKG 包管理器
#   3. 都不存在 → 报错退出
#
# Globals:
#   FEEDS_FILES - 设置为对应包管理器的配置文件路径（空格分隔）
#
# Outputs:
#   日志信息：检测到的包管理器类型或错误信息
#
# Returns:
#   0 - 检测成功
#   1 - 未找到支持的包管理器
#######################################
# 自动检测包管理器并设置配置文件列表
if command -v apk >/dev/null 2>&1; then
    # APK 包管理器（Alpine/OpenWrt 23.05+）
    FEEDS_FILES="/etc/apk/repositories.d/distfeeds.list /etc/apk/repositories"
    log INFO "Detected APK package manager"
elif command -v opkg >/dev/null 2>&1; then
    # OPKG 包管理器（传统 OpenWrt）
    FEEDS_FILES="/etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf"
    log INFO "Detected opkg package manager"
else
    # 未找到任何已知的包管理器
    log ERROR "No known package manager found"
    exit 1
fi

#######################################
# 检查 URL 的网络延迟和下载速度
#
# 使用 curl 或 wget 测试指定 URL 的可达性和性能指标。
# 优先使用 curl（支持精确的时间和速度测量），回退到 wget（仅秒级延迟）。
#
# 测试方法：
#   - curl: 执行 HEAD 请求，获取精确的响应时间和下载速度
#   - wget: 使用 --spider 模式，仅测试可达性和整数秒级延迟
#
# Arguments:
#   $1 - 要测试的 URL
#
# Globals:
#   TMP_FILES - 添加临时文件到清理列表
#
# Outputs:
#   成功时输出: "延迟(秒) 速度(字节/秒)"
#   示例: "0.523 1048576" 或 "2 0"（wget 模式速度为 0）
#
# Returns:
#   0 - URL 可达且成功获取性能数据
#   1 - URL 不可达或测试失败
#
# Examples:
#   check_url "https://downloads.openwrt.org"
#   # 输出: "1.234 524288"
#
#   check_url "https://invalid.example.com"
#   # 返回 1（无输出）
#######################################
# 检查 URL 延迟和速度
check_url() {
    local url="$1"
    local latency speed result ret
    local tmp_file

    if command -v curl >/dev/null 2>&1; then
        # 使用 curl 进行精确测量
        tmp_file=$(mktemp -t uci-check.XXXXXX)
        TMP_FILES+=("$tmp_file")

        # 获取总时间和下载速度
        result=$(curl -L -I --max-time 10 -s -w "%{time_total} %{speed_download}" -o "$tmp_file" "$url" 2>/dev/null)
        ret=$?

        if [ $ret -eq 0 ]; then
            # 解析延迟和速度
            latency=$(printf "%s" "$result" | awk '{print $1}')
            speed=$(printf "%s" "$result" | awk '{print $2}')
            # 验证数据有效性
            if [ -n "$latency" ] && [ "$latency" != "0" ]; then
                printf "%s %s\n" "$latency" "$speed"
                return 0
            fi
        fi
        return 1
    elif command -v wget >/dev/null 2>&1; then
        # 使用 wget 进行基本测试（BusyBox 环境兼容）
        # 注意: wget 仅提供秒级精度，速度数据不可用
        local start_sec end_sec elapsed
        start_sec=$(date +%s)
        wget --spider --timeout=10 --tries=1 -q "$url" >/dev/null 2>&1
        ret=$?
        end_sec=$(date +%s)

        if [ $ret -eq 0 ]; then
            elapsed=$((end_sec - start_sec))
            # 避免除零，最小设为 1 秒
            [ "$elapsed" -eq 0 ] && elapsed=1
            # wget 模式速度为 0（不可用）
            printf "%d 0\n" "$elapsed"
            return 0
        fi
        return 1
    else
        # 无可用的网络测试工具
        log WARN "Neither curl nor wget available, cannot check URL"
        return 1
    fi
}

#######################################
# 判断官方源是否可用
#
# 测试官方源的网络连通性和性能，根据延迟和速度判断是否应使用官方源。
#
# 判断逻辑：
#   1. 测试官方源的延迟和速度
#   2. 如果无法连接 → 不可用
#   3. 如果延迟超过 MAX_LATENCY → 不可用
#   4. 如果速度低于 MIN_SPEED（且速度数据有效）→ 不可用
#   5. 否则 → 可用
#
# 该函数的返回值直接决定源替换策略：
#   - 返回 0（可用）→ 保持或切换回官方源
#   - 返回 1（不可用）→ 切换到镜像源
#
# Arguments:
#   $1 - 官方源的 URL
#
# Globals:
#   MAX_LATENCY - 最大可接受延迟阈值（秒）
#   MIN_SPEED   - 最小可接受速度阈值（字节/秒）
#
# Outputs:
#   日志信息：测试过程和判断结果
#
# Returns:
#   0 - 官方源可用（性能良好，不需要替换为镜像）
#   1 - 官方源不可用（需要替换为镜像源）
#
# Examples:
#   if is_official_source_usable "$OPENWRT_OFFICIAL"; then
#       echo "使用官方源"
#   else
#       echo "切换到镜像源"
#   fi
#######################################
# 判断官方源是否可用
# 返回 0=官方源可用（不需要替换），1=官方源不可用（需要替换为镜像）
is_official_source_usable() {
    local official_url="$1"
    local metrics latency speed

    log INFO "Testing connectivity to $official_url"

    # 测试 URL 连通性和性能
    if ! metrics=$(check_url "$official_url"); then
        log WARN "Cannot reach $official_url"
        return 1
    fi

    # 解析延迟和速度数据
    latency=$(printf "%s" "$metrics" | awk '{print $1}')
    speed=$(printf "%s" "$metrics" | awk '{print $2}')
    log INFO "Latency: ${latency}s, Speed: ${speed:-unknown} B/s"

    # 验证延迟数据有效性
    if [ -z "$latency" ] || [ "$latency" = "0" ]; then
        log WARN "Invalid latency from $official_url"
        return 1
    fi

    # 检查延迟是否超过阈值
    if awk "BEGIN {exit ($latency > $MAX_LATENCY) ? 0 : 1}"; then
        log INFO "Latency ${latency}s exceeds threshold ${MAX_LATENCY}s"
        return 1
    fi

    # 检查速度是否低于阈值（如果有速度数据）
    if [ -n "$speed" ] && [ "$speed" != "0" ]; then
        if awk "BEGIN {exit ($speed < $MIN_SPEED) ? 0 : 1}"; then
            log INFO "Speed ${speed}B/s below threshold ${MIN_SPEED}B/s"
            return 1
        fi
    fi

    # 所有检查通过，官方源可用
    log INFO "$official_url is acceptable (latency ${latency}s, speed ${speed:-N/A}B/s)"
    return 0
}

#######################################
# 替换软件源配置
#
# 在所有配置文件中查找匹配指定模式的 URL，并替换为目标 URL。
# 支持自动备份、失败回滚和错误处理。
#
# 工作流程：
#   1. 遍历所有配置文件（FEEDS_FILES）
#   2. 检查文件是否包含匹配的模式
#   3. 备份原始文件
#   4. 执行替换操作
#   5. 如果替换失败，恢复备份
#   6. 如果替换成功，删除备份
#
# 安全特性：
#   - 替换前自动备份原文件
#   - 使用进程 ID 后缀确保备份文件名唯一
#   - 替换失败时自动恢复备份
#
# Arguments:
#   $1 - 要匹配的源 URL 模式（sed 正则表达式）
#   $2 - 替换为的目标 URL
#
# Globals:
#   FEEDS_FILES - 要处理的配置文件列表（空格分隔）
#
# Outputs:
#   日志信息：替换进度、成功或失败信息
#
# Returns:
#   0 - 总是返回 0（即使没有文件被替换）
#
# Examples:
#   # 将镜像源替换为官方源
#   replace_source "$OPENWRT_MIRROR_PATTERN" "$OPENWRT_OFFICIAL"
#
#   # 将官方源替换为镜像源
#   replace_source "$OPENWRT_OFFICIAL_PATTERN" "$OPENWRT_MIRROR"
#######################################
# 替换源：将匹配 pattern 的 URL 替换为 target
replace_source() {
    local pattern="$1"
    local target="$2"
    local feed backup_file
    local replaced=0

    for feed in $FEEDS_FILES; do
        # 跳过不存在的文件
        [ -f "$feed" ] || continue

        # 检查是否需要替换（文件中是否包含匹配的模式）
        if ! grep -qE "$pattern" "$feed"; then
            continue
        fi

        # 备份原文件（使用进程 ID 确保文件名唯一）
        backup_file="${feed}.bak.$$"
        if ! cp "$feed" "$backup_file"; then
            log WARN "Failed to backup $feed, skipping"
            continue
        fi

        log INFO "Replacing $pattern with $target in $feed"

        # 执行替换操作
        if sed -i "s#${pattern}#${target}#g" "$feed"; then
            # 替换成功，删除备份
            rm -f "$backup_file"
            replaced=1
        else
            # 替换失败，恢复备份
            log ERROR "Failed to replace in $feed, restoring backup"
            mv -f "$backup_file" "$feed"
        fi
    done

    # 输出替换结果摘要
    if [ "$replaced" -eq 1 ]; then
        log INFO "Source replacement completed for pattern $pattern"
    else
        log INFO "No files matched pattern $pattern"
    fi
}

#######################################
# 主流程：软件源智能优化
#
# 按顺序测试并优化 OpenWrt 和 ImmortalWrt 的软件源配置。
# 根据官方源的实际可用性，智能决定使用官方源还是镜像源。
#
# 执行流程：
#   1. 记录脚本启动
#   2. 测试 OpenWrt 官方源
#      - 如果可用 → 确保使用官方源（从镜像切回）
#      - 如果不可用 → 切换到镜像源
#   3. 测试 ImmortalWrt 官方源
#      - 如果可用 → 确保使用官方源（从镜像切回）
#      - 如果不可用 → 切换到镜像源
#   4. 记录完成信息
#   5. 正常退出
#
# 设计原则：
#   - 优先使用官方源（更稳定、更新更快）
#   - 官方源不可用时才使用镜像源
#   - 支持双向切换（官方↔镜像）
#
# Globals:
#   OPENWRT_OFFICIAL          - OpenWrt 官方源 URL
#   OPENWRT_MIRROR_PATTERN    - OpenWrt 镜像源匹配模式
#   OPENWRT_OFFICIAL_PATTERN  - OpenWrt 官方源匹配模式
#   OPENWRT_MIRROR            - OpenWrt 镜像源 URL
#   IMMORTALWRT_OFFICIAL      - ImmortalWrt 官方源 URL
#   IMMORTALWRT_MIRROR_PATTERN - ImmortalWrt 镜像源匹配模式
#   IMMORTALWRT_OFFICIAL_PATTERN - ImmortalWrt 官方源匹配模式
#   IMMORTALWRT_MIRROR        - ImmortalWrt 镜像源 URL
#
# Returns:
#   0 - 总是成功退出
#######################################
# 主流程
log INFO "Starting source optimization (version 1.1.0)"

# 处理 OpenWrt 官方源
log INFO "=== Checking OpenWrt sources ==="
if is_official_source_usable "$OPENWRT_OFFICIAL"; then
    # 官方源可用：如果当前使用镜像源，替换回官方源
    log INFO "OpenWrt official source is usable, ensuring official source"
    replace_source "$OPENWRT_MIRROR_PATTERN" "$OPENWRT_OFFICIAL"
else
    # 官方源不可用：替换为镜像源
    log INFO "OpenWrt official source unusable, switching to mirror"
    replace_source "$OPENWRT_OFFICIAL_PATTERN" "$OPENWRT_MIRROR"
fi

# 处理 ImmortalWrt 官方源
log INFO "=== Checking ImmortalWrt sources ==="
if is_official_source_usable "$IMMORTALWRT_OFFICIAL"; then
    # 官方源可用：如果当前使用镜像源，替换回官方源
    log INFO "ImmortalWrt official source is usable, ensuring official source"
    replace_source "$IMMORTALWRT_MIRROR_PATTERN" "$IMMORTALWRT_OFFICIAL"
else
    # 官方源不可用：替换为镜像源
    log INFO "ImmortalWrt official source unusable, switching to mirror"
    replace_source "$IMMORTALWRT_OFFICIAL_PATTERN" "$IMMORTALWRT_MIRROR"
fi

log INFO "Source optimization finished"
exit 0
