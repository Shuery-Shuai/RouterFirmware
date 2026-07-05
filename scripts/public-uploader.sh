#!/usr/bin/env bash
#######################################
# public 压缩包上传脚本
#
# 将打包好的 public.zip (或其他指定文件) 上传至当前仓库的 GitHub Release，
# 并输出可直接用于部署工作流的直链下载 URL。
#
# 特性:
#   - 支持从环境变量或安全手动输入获取 GitHub Token (输入无回显)
#   - 可自动生成 Release tag (无需预先存在 Git tag)
#   - 自动创建 Release 时标题和内容包含上传文件详细信息
#   - 手动指定 tag 且 Release 不存在时，同样使用详细描述创建
#
# 流程:
#   1. 检查 gh CLI 是否可用
#   2. 获取 GitHub Token (环境变量或手动输入)
#   3. 确定 Release tag 和文件路径
#   4. 获取文件信息 (大小、修改时间)
#   5. 确保 Release 存在 (自动创建或询问)
#   6. 上传文件并获取下载 URL
#   7. 输出可直接用于部署的 URL
#
# 用法:
#   ./scripts/public-uploader.sh [tag] [file]
#   ./scripts/public-uploader.sh [options]
#   ./scripts/public-uploader.sh --help
#
# 参数:
#   tag  - 可选，Release 对应的 Git 标签 (例如 v1.0.0)。省略时自动生成。
#   file - 可选，要上传的文件路径，默认为 public.zip
#
# 选项:
#   -h, --help              显示此帮助信息
#   --tag=TAG               指定 Release 标签
#   --file=FILE             指定要上传的文件路径
#   --token=TOKEN           直接提供 GitHub Token (不推荐，优先使用环境变量或手动输入)
#
# 环境变量:
#   GH_TOKEN / GITHUB_TOKEN  - GitHub Personal Access Token (需要 repo 权限)
#   LOG_LEVEL                - 日志级别 (继承自 common.sh)
#   LOG_TO_FILE              - 是否写入日志文件 (继承自 common.sh)
#
# 依赖:
#   - common.sh: 提供日志和工具函数 (包括 format_file_size, format_file_date)
#   - GitHub CLI (gh) 已安装
#   - 有效的 GitHub Token
#
# 退出状态:
#   0 - 上传成功
#   1 - 参数错误或依赖缺失
#   2 - GitHub API 调用失败
#
# 示例:
#   # 完全自动，自动生成 tag 并上传默认 public.zip
#   ./scripts/public-uploader.sh
#
#   # 指定 tag
#   ./scripts/public-uploader.sh v1.0.0
#
#   # 指定 tag 和文件
#   ./scripts/public-uploader.sh v1.0.0 /path/to/custom.zip
#
#   # 使用命名参数
#   ./scripts/public-uploader.sh --tag=v1.0.0 --file=public.zip
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

LOG_LEVEL="TRACE"

#######################################
# 统一认证流程
#
# 检查 GitHub CLI 是否安装，并引导用户选择认证方式：
#   1. 手动输入 Token（自动打开浏览器到权限设置页面）
#   2. 使用 GitHub CLI 登录
# 若已存在 GH_TOKEN 或 GITHUB_TOKEN 环境变量则直接使用。
#
# Globals:
#   GH_TOKEN (可能被设置)
#
# Arguments:
#   None
#
# Returns:
#   0 - 认证成功设置
#   1 - 用户取消或 gh 未安装
#######################################
authenticate() {
	# 检查 gh 命令是否可用
	if ! command -v gh &>/dev/null; then
		log FATAL "未找到 GitHub CLI (gh)。请安装后重试"
	fi

	# 若已有环境变量 Token，直接使用
	if [[ -n "${GH_TOKEN:-}" ]] || [[ -n "${GITHUB_TOKEN:-}" ]]; then
		export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
		log INFO "已从环境变量加载 GitHub Token"
		return
	fi

	# 若 gh 已登录，也无需额外操作
	if gh auth status &>/dev/null; then
		log INFO "GitHub CLI 已登录，直接使用现有会话"
		return
	fi

	# 交互选择认证方式
	echo ""
	log INFO "未检测到有效的 GitHub 认证信息，请选择认证方式："
	echo "  1. 使用 GitHub Token (推荐，简单快捷)"
	echo "  2. 使用 GitHub CLI 登录 (gh auth login)"
	echo ""
	read -r -p "请输入选择 [1-2] (默认 1): " auth_choice
	auth_choice="${auth_choice:-1}"

	case "${auth_choice}" in
	1)
		# Token 登录
		local token_url="https://github.com/settings/tokens/new?scopes=repo,workflow&description=public-uploader"
		log INFO "将打开浏览器到 Token 生成页面（已预设 repo、workflow 权限）"
		log INFO "若未自动打开，请手动访问："
		echo "  ${token_url}"
		# 尝试自动打开浏览器
		if command -v xdg-open &>/dev/null; then
			xdg-open "${token_url}" 2>/dev/null || true
		elif command -v open &>/dev/null; then
			open "${token_url}" 2>/dev/null || true
		fi
		echo ""
		read -r -s -p "请粘贴生成的 Token (输入不会显示): " token
		echo ""
		if [[ -z "${token}" ]]; then
			log FATAL "Token 不能为空"
		fi
		export GH_TOKEN="${token}"
		log SUCCESS "Token 已设置"
		;;
	2)
		# gh auth login
		log INFO "启动 GitHub CLI 登录向导..."
		gh auth login
		if ! gh auth status &>/dev/null; then
			log FATAL "GitHub CLI 登录失败"
		fi
		log SUCCESS "GitHub CLI 登录成功"
		;;
	*)
		log FATAL "无效的选择，请输入 1 或 2"
		;;
	esac
}

#######################################
# 确保 Release 存在，不存在时根据情况自动创建或询问
#
# Arguments:
#   $1 - tag 名称
#   $2 - Release 标题
#   $3 - Release 描述 (notes)
#   $4 - 是否自动创建 ("true"/"false")
#
# Returns:
#   0 - Release 已存在或成功创建
#   1 - 用户拒绝创建或创建失败
#######################################
ensure_release() {
	local tag="$1"
	local title="$2"
	local notes="$3"
	local auto_create="$4"

	if gh release view "${tag}" &>/dev/null; then
		log INFO "Release '${tag}' 已存在，文件将追加到该 Release"
		return
	fi

	# Release 不存在
	if [[ "${auto_create}" == "true" ]]; then
		log INFO "自动创建 Release '${tag}' ..."
		gh release create "${tag}" --title "${title}" --notes "${notes}" --draft=false
		log SUCCESS "Release '${tag}' 创建成功"
	else
		log WARN "Release '${tag}' 不存在"
		log INFO "将使用以下信息创建 Release:"
		echo "  标题: ${title}"
		echo "  描述:"
		echo "${notes}"
		read -r -p "是否创建该 Release？[y/N] " confirm
		if [[ "${confirm,,}" =~ ^y(es)?$ ]]; then
			log INFO "正在创建 Release '${tag}' ..."
			gh release create "${tag}" --title "${title}" --notes "${notes}" --draft=false
			log SUCCESS "Release '${tag}' 创建成功"
		else
			log FATAL "用户取消操作"
		fi
	fi
}

#######################################
# 上传文件到 Release 并输出下载 URL
#
# Arguments:
#   $1 - Release tag
#   $2 - 要上传的文件路径
#
# Returns:
#   0 - 上传成功且获取到 URL
#   1 - 文件不存在或上传/获取失败
#######################################
upload_asset() {
	local tag="$1"
	local file="$2"

	require_file "${file}" "待上传文件不存在"

	log INFO "正在上传 ${file} 到 Release '${tag}' ..."
	gh release upload "${tag}" "${file}" --clobber

	local repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
	local asset_url
	asset_url=$(gh api "repos/${repo}/releases/tags/${tag}" \
		--jq '.assets[] | select(.name=="'"$(basename "${file}")"'") | .browser_download_url' 2>/dev/null || true)

	if [[ -z "${asset_url}" ]]; then
		log FATAL "上传可能失败，无法获取下载 URL"
	fi

	log SUCCESS "上传成功！"
	echo ""
	log INFO "=== 用于工作流的 archive-url ==="
	echo "${asset_url}"
	echo ""
	log INFO "直接复制上面的 URL 到 GitHub Actions 手动触发时的 archive-url 字段即可"
}

#######################################
# 上传脚本主函数
#
# 执行完整的上传流程：
#   1. 解析命令行参数
#   2. 检查依赖和 Token
#   3. 确定 tag 和文件
#   4. 确保 Release 存在
#   5. 上传并输出下载 URL
#
# Globals:
#   PARSED_ARGS (关联数组，由 parse_args 填充)
#
# Arguments:
#   $@ - 命令行参数
#
# Outputs:
#   多级别日志输出到 stderr
#   最终的下载 URL 输出到 stdout
#
# Returns:
#   0 - 上传成功
#   1 - 参数错误或前置检查失败
#   2 - API 调用失败
#######################################
main() {
	# 解析命令行参数
	declare -A PARSED_ARGS
	parse_args "$@"

	# 处理帮助选项
	if [[ -n "${PARSED_ARGS['h']:-}" || -n "${PARSED_ARGS['help']:-}" ]]; then
		show_help "public-uploader.sh" \
			"上传 public 压缩包至 GitHub Release" \
			"[options] [tag] [file]" \
			"  -h, --help              显示此帮助信息" \
			"  --tag=TAG               指定 Release 标签 (省略则自动生成)" \
			"  --file=FILE             要上传的文件路径 (默认: public.zip)" \
			"  --token=TOKEN           直接提供 GitHub Token (不推荐)" \
			"" \
			"位置参数:" \
			"  tag                     Release 标签 (等同于 --tag)" \
			"  file                    文件路径 (等同于 --file)"
		exit 0
	fi

	# 统一验证
	authenticate

	# 获取参数（优先命名参数，其次位置参数）
	local tag="${PARSED_ARGS['tag']:-${PARSED_ARGS[_POSITIONAL_0]:-}}"
	local file="${PARSED_ARGS['file']:-${PARSED_ARGS[_POSITIONAL_1]:-public.zip}}"
	local auto_tag="false"

	# 若未提供 tag，自动生成
	if [[ -z "${tag}" ]]; then
		tag="manual-upload-$(date +%Y%m%d-%H%M%S)"
		auto_tag="true"
		log INFO "未指定 tag，将自动生成: ${tag}"
	else
		log INFO "使用指定 tag: ${tag}"
	fi

	log INFO "上传文件: ${file}"

	# 提前检查文件存在并获取信息
	require_file "${file}" "待上传文件不存在"

	# 获取文件信息
	local file_name
	file_name=$(basename "${file}")
	local file_size
	file_size=$(format_file_size "$(stat -c%s "${file}")")
	local file_date
	file_date=$(format_file_date "${file}")
	local upload_timestamp
	upload_timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	# 构建 Release 标题和描述
	local title="手动上传部署 - ${upload_timestamp}"
	local notes="## 部署文件信息

- **文件名**: ${file_name}
- **文件大小**: ${file_size}
- **文件修改时间**: ${file_date}
- **上传时间**: ${upload_timestamp}

> 由 \`public-uploader.sh\` 自动上传至 GitHub Pages 部署工作流。

**使用方法**：在 GitHub Actions 中选择 \`upload-archive: true\` 并填入此 Release 中对应文件的下载链接。"

	# 如果用户提供了自定义 tag，可以在 notes 中注明
	if [[ -n "${PARSED_ARGS['tag']:-}" ]] || [[ -n "${PARSED_ARGS[_POSITIONAL_0]:-}" ]]; then
		notes+="
- **发布标签**: ${tag}"
	fi

	ensure_release "${tag}" "${title}" "${notes}" "${auto_tag}"
	upload_asset "${tag}" "${file}"
}

# 执行主函数
main "$@"
