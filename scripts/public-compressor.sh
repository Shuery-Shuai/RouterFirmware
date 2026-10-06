#!/usr/bin/env bash
#######################################
# public 目录打包脚本
#
# 将仓库根目录下的 public/ 文件夹压缩为 public.zip，
# 用于通过 GitHub Actions 手动部署至 GitHub Pages。
#
# 流程:
#   1. 检查 public 目录是否存在
#   2. 使用 zip 命令递归打包为 public.zip
#   3. 输出压缩包路径及后续操作提示
#
# 用法:
#   ./scripts/public-compressor.sh [输出文件路径]
#   ./scripts/public-compressor.sh --help
#
# 参数:
#   $1 (可选) - 输出压缩包的路径，默认: public.zip
#
# 选项:
#   -h, --help              显示此帮助信息
#
# 环境变量:
#   LOG_LEVEL      - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE    - 是否写入日志文件 (继承自 common.sh)
#
# 依赖:
#   - common.sh: 提供日志和工具函数
#   - zip 命令（系统自带）
#   - public/ 目录必须存在
#
# 退出状态:
#   0 - 压缩成功
#   1 - 目录不存在或压缩过程出错
#
# 示例:
#   ./scripts/public-compressor.sh
#   ./scripts/public-compressor.sh /tmp/firmware.zip
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

# 设置日志级别为 TRACE 以输出所有级别日志
LOG_LEVEL="TRACE"

#######################################
# 打包 public 目录
#
# 执行完整的打包流程：
#   1. 验证 public 目录存在
#   2. 压缩为指定的 zip 文件
#   3. 输出完成信息及下一步操作指南
#
# Globals:
#   None
#
# Arguments:
#   $1 - 输出文件路径 (可选，默认 public.zip)
#
# Outputs:
#   多级别日志输出到 stderr
#   生成的压缩包文件
#
# Returns:
#   0 - 成功
#   1 - 目录不存在或压缩失败
#
# Examples:
#   main
#   main "custom.zip"
#######################################
main() {
    # 解析命令行参数
    declare -A PARSED_ARGS
    parse_args "$@"

    # 处理帮助选项
    if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
        show_help "public-compressor.sh" \
            "打包 public 目录为 zip 压缩包" \
            "[options] [输出路径]" \
            "  -h, --help              显示此帮助信息" \
            "" \
            "位置参数:" \
            "  输出路径               zip 文件的保存位置 (默认: public.zip)"
        exit 0
    fi

    # 获取输出文件路径（优先位置参数，否则默认）
    local output_file="${PARSED_ARGS[_POSITIONAL_0]:-public.zip}"

    # 验证 public 目录存在
    require_dir "public" "public 目录不存在，请在仓库根目录执行此脚本"

    # 压缩并处理错误
    # 注意：必须打包 public 的“内容”，而不是 public 目录本身。
    # 若 zip 内自带顶层 public/，部署流程解包到 public/ 后会得到
    # public/public/** 的嵌套副本（线上站点曾因此凭空膨胀一倍以上）。
    log INFO "正在压缩 public -> ${output_file} ..."
    local output_abs
    output_abs="$(cd "$(dirname "${output_file}")" && pwd)/$(basename "${output_file}")"
    if (cd public && zip -rq "${output_abs}" .); then
        log SUCCESS "压缩完成: ${output_abs}"
        echo ""
        log INFO "=== 下一步操作 ==="
        log INFO "1. 将 ${output_file} 上传到可公开访问的服务器"
        log INFO "   - 或使用 './scripts/public-uploader.sh' 上传至 GitHub Release"
        log INFO "2. 获取该文件的直链下载 URL"
        log INFO "3. 在 GitHub Actions 手动触发 'Router Firmware Builder'，选择 upload-archive: true 并填入链接"
    else
        log FATAL "压缩过程失败，请检查磁盘空间或权限"
    fi
}

# 执行主函数
main "$@"
