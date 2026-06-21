#!/bin/bash
#######################################
# OpenWrt 构建自定义脚本 - 第二阶段
#
# 在 feeds 安装完成后执行的自定义脚本，用于系统配置和软件包集成。
# 主要功能包括:
#   - 修改系统默认配置 (IP 地址、默认 Shell)
#   - 为自定义软件包创建符号链接到 feeds 目录
#   - 修补 LuCI 集合和软件包配置
#   - 修改特定软件包版本和构建配置
#
# 执行时机:
#   在 ./scripts/feeds install -a 之后、make menuconfig 之前执行
#   适用于集成第三方软件包和修改 feeds 内容
#
# 用法:
#   bash diy-part2.openwrt.sh
#
# 环境变量:
#   TOPDIR - OpenWrt 源码根目录（自动检测）
#
# 依赖:
#   - sed (用于文件修补)
#   - 第一阶段脚本已执行（custom-packages 目录已创建）
#
# 作者: Shuery-Shuai
# 版本: 2.0.0
# 适用固件: OpenWrt (官方版本)
# 适用设备: BananaPi BPI-R4
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
# 计算相对路径（纯 Bash 实现）
#
# 从源目录计算到目标路径的相对路径，无需外部工具依赖。
# 用于创建可移植的符号链接。
#
# Arguments:
#   $1 - 源目录 (from)
#   $2 - 目标路径 (to)
#
# Globals:
#   None
#
# Outputs:
#   相对路径字符串到 stdout (如 "../../target/dir")
#
# Returns:
#   0 - 成功
#   1 - 目录切换失败
#
# Examples:
#   _relpath "/a/b/c" "/a/d/e"  # 输出: ../../d/e
#   _relpath "/home/user/project" "/opt/lib"  # 输出: ../../../opt/lib
#######################################
_relpath() {
	local from_dir="$1"
	local to_path="$2"
	local abs_from abs_to

	# 获取绝对路径
	abs_from="$(cd "${from_dir}" && pwd)" || return 1
	abs_to="$(cd "${to_path}" && pwd)" || return 1

	# 将路径拆分为数组
	local from_parts to_parts
	IFS='/' read -ra from_parts <<<"${abs_from}"
	IFS='/' read -ra to_parts <<<"${abs_to}"

	# 找到公共前缀的结束位置
	local i=0
	while [[ ${i} -lt ${#from_parts[@]} &&
		${i} -lt ${#to_parts[@]} &&
		"${from_parts[${i}]}" == "${to_parts[${i}]}" ]]; do
		((i++))
	done

	# 计算需要向上的层数 (../)
	local up_count=$((${#from_parts[@]} - i))
	local rel_path=''
	local j

	for ((j = 0; j < up_count; j++)); do
		rel_path+='../'
	done

	# 添加从公共祖先到目标的路径
	for ((j = i; j < ${#to_parts[@]}; j++)); do
		rel_path+="${to_parts[${j}]}"
		if [[ ${j} -lt $((${#to_parts[@]} - 1)) ]]; then
			rel_path+='/'
		fi
	done

	printf '%s' "${rel_path}"
}

#######################################
# 创建相对路径符号链接
#
# 使用相对路径创建符号链接，避免绝对路径导致的可移植性问题。
# 如果目标位置已存在符号链接或目录，则先删除。
#
# Arguments:
#   $1 - 源路径（绝对路径）
#   $2 - 符号链接路径（要创建的链接位置）
#
# Globals:
#   None
#
# Outputs:
#   操作日志到 stderr (通过 _log)
#
# Returns:
#   0 - 符号链接创建成功
#   1 - 相对路径计算失败或 ln 命令失败
#
# Examples:
#   _create_relative_symlink "/path/to/source" "feeds/luci/applications/app"
#######################################
_create_relative_symlink() {
	local source_abs="$1"
	local target_link="$2"
	local target_dir

	target_dir="$(dirname "${target_link}")"
	mkdir -p "${target_dir}"

	# 删除已存在的链接或目录
	if [[ -L "${target_link}" ]] || [[ -d "${target_link}" ]]; then
		_log 'WARN' "  Removing existing symlink/directory at ${target_link}"
		rm -rf "${target_link}"
	fi

	# 计算相对路径
	local rel_target
	rel_target="$(_relpath "${target_dir}" "${source_abs}")"
	if [[ -z "${rel_target}" ]]; then
		_log 'ERROR' "  Failed to compute relative path from ${target_dir} to ${source_abs}"
		return 1
	fi

	# 创建符号链接
	if ln -s "${rel_target}" "${target_link}"; then
		_log 'INFO' "  SUCCESS: Created symlink ${target_link} -> ${rel_target}"
		return 0
	else
		_log 'ERROR' "  FAILED: Could not create symlink ${target_link}"
		return 1
	fi
}

#######################################
# 从 Makefile 提取软件包名称
#
# 尝试从软件包的 Makefile 中提取 PKG_NAME 变量值。
# 如果未找到或 Makefile 不存在，则使用目录名作为回退。
#
# Arguments:
#   $1 - 软件包目录的绝对路径
#
# Globals:
#   None
#
# Outputs:
#   软件包名称到 stdout
#
# Returns:
#   0 - 成功提取或使用回退值
#   1 - Makefile 不存在
#
# Examples:
#   _extract_pkg_name "/path/to/luci-app-example"  # 输出: luci-app-example
#######################################
_extract_pkg_name() {
	local abs_dir="$1"
	local makefile="${abs_dir}/Makefile"
	local pkg_name

	if [[ ! -f "${makefile}" ]]; then
		return 1
	fi

	# 提取 PKG_NAME 变量（支持 := 和 = 两种赋值方式）
	pkg_name="$(grep -E '^\s*PKG_NAME\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*PKG_NAME\s*:?=\s*(.+)\s*$/\1/')"

	if [[ -z "${pkg_name}" ]]; then
		# 回退：使用目录名
		pkg_name="$(basename "${abs_dir}")"
	fi

	printf '%s' "${pkg_name}"
}

#######################################
# 解析软件包的目标 feed 路径
#
# 根据软件包名称和 Makefile 中的 SECTION 变量，智能确定软件包应该链接到哪个 feed 目录。
# 解析策略（按优先级）:
#   1. 快速路径: 基于名称前缀的硬编码规则 (luci-app-* -> feeds/luci/applications)
#   2. SECTION 映射: 从 Makefile 提取 SECTION 变量并映射到对应 feed
#   3. 名称启发式: 基于名称模式推测分类 (net-* -> feeds/packages/net)
#   4. 默认回退: 无法识别时放入 feeds/base
#
# Arguments:
#   $1 - 软件包目录的绝对路径
#   $2 - 软件包名称 (PKG_NAME)
#
# Globals:
#   None
#
# Outputs:
#   目标符号链接路径到 stdout (如 "feeds/luci/applications/luci-app-xxx")
#   解析过程日志到 stderr (通过 _log)
#
# Returns:
#   0 - 总是成功
#
# Examples:
#   resolve_target_path "/path/to/luci-app-example" "luci-app-example"
#   # 输出: feeds/luci/applications/luci-app-example
#######################################
resolve_target_path() {
	local abs_dir="$1"
	local pkg_name="$2"
	local target_path=''

	# 策略 1: LuCI 软件包快速路径（基于命名约定）
	if [[ "${pkg_name}" == luci-app-* ]]; then
		target_path="feeds/luci/applications/${pkg_name}"
		_log 'INFO' '  Fast path: luci-app-* -> applications'
	elif [[ "${pkg_name}" == luci-theme-* ]]; then
		target_path="feeds/luci/themes/${pkg_name}"
		_log 'INFO' '  Fast path: luci-theme-* -> themes'
	elif [[ "${pkg_name}" == luci-lib-* ]]; then
		target_path="feeds/luci/libs/${pkg_name}"
		_log 'INFO' '  Fast path: luci-lib-* -> libs'
	elif [[ "${pkg_name}" == luci-proto-* ]]; then
		target_path="feeds/luci/protocols/${pkg_name}"
		_log 'INFO' '  Fast path: luci-proto-* -> protocols'
	else
		# 策略 2: 从 Makefile 提取 SECTION 变量
		local makefile="${abs_dir}/Makefile"
		local section=''
		if [[ -f "${makefile}" ]]; then
			section="$(grep -E '^\s*SECTION\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*SECTION\s*:?=\s*([^[:space:]]+).*$/\1/')"
		fi
		_log 'INFO' "  Extracted SECTION from Makefile: '${section}'"

		# 策略 3: SECTION 到 feed 的映射表
		if [[ -n "${section}" ]]; then
			case "${section}" in
			luci)
				target_path="feeds/luci/applications/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=luci -> feeds/luci/applications"
				;;
			net | network)
				target_path="feeds/packages/net/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=net -> feeds/packages/net"
				;;
			utils | utilities)
				target_path="feeds/packages/utils/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=utils -> feeds/packages/utils"
				;;
			lang | languages)
				target_path="feeds/packages/lang/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=lang -> feeds/packages/lang"
				;;
			libs | libraries)
				target_path="feeds/packages/libs/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=libs -> feeds/packages/libs"
				;;
			admin | administration)
				target_path="feeds/packages/admin/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=admin -> feeds/packages/admin"
				;;
			devel | development)
				target_path="feeds/packages/devel/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=devel -> feeds/packages/devel"
				;;
			multimedia)
				target_path="feeds/packages/multimedia/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=multimedia -> feeds/packages/multimedia"
				;;
			kernel)
				target_path="feeds/packages/kernel/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=kernel -> feeds/packages/kernel"
				;;
			base)
				target_path="feeds/packages/base/${pkg_name}"
				_log 'INFO' "  Mapped SECTION=base -> feeds/packages/base"
				;;
			*)
				_log 'WARN' "  Unknown SECTION '${section}', falling back to name heuristics"
				;;
			esac
		fi

		# 策略 4: 名称启发式（SECTION 未知或为空时）
		if [[ -z "${target_path}" ]]; then
			if [[ "${pkg_name}" == net-* ]] || [[ "${pkg_name}" == network-* ]]; then
				target_path="feeds/packages/net/${pkg_name}"
				_log 'INFO' "  Name heuristic: net-* -> feeds/packages/net"
			elif [[ "${pkg_name}" == *-utils ]] || [[ "${pkg_name}" == *-tools ]]; then
				target_path="feeds/packages/utils/${pkg_name}"
				_log 'INFO' "  Name heuristic: *-utils/tools -> feeds/packages/utils"
			elif [[ "${pkg_name}" == lang-* ]]; then
				target_path="feeds/packages/lang/${pkg_name}"
				_log 'INFO' "  Name heuristic: lang-* -> feeds/packages/lang"
			elif [[ "${pkg_name}" == lib* ]] || [[ "${pkg_name}" == *-lib ]]; then
				target_path="feeds/packages/libs/${pkg_name}"
				_log 'INFO' "  Name heuristic: lib* -> feeds/packages/libs"
			else
				# 策略 5: 默认回退
				target_path="feeds/base/${pkg_name}"
				_log 'INFO' "  Default fallback -> feeds/base"
			fi
		fi
	fi

	printf '%s' "${target_path}"
}

#######################################
# 为自定义软件包创建符号链接（带缓存优化）
#
# 扫描自定义软件包目录，为每个包创建指向 feeds 目录的符号链接。
# 核心特性:
#   1. 缓存机制: 通过 Makefile 修改时间判断是否需要重新解析
#   2. 手动覆盖: 支持在缓存文件中手动指定目标路径
#   3. 跳过选项: 支持标记某些包跳过链接创建
#   4. 智能扫描: 自动排除 .git 和 files 目录
#
# 缓存格式 (.symlink_cache):
#   自动条目: relative_path|mtime|target_path
#   手动条目: relative_path|manual|target_path|skip
#
# Arguments:
#   $1 - 自定义软件包根目录路径
#
# Globals:
#   TOPDIR - OpenWrt 源码根目录（自动检测或使用已设置的值）
#
# Outputs:
#   处理进度和统计信息到 stderr (通过 _log)
#
# Returns:
#   0 - 成功
#   1 - 目录不存在或无法检测 TOPDIR
#
# Files Modified:
#   ${custom_dir}/.symlink_cache - 缓存文件
#   feeds/*/.../* - 创建的符号链接
#
# Examples:
#   create_symlinks 'custom-packages'
#######################################
create_symlinks() {
	local custom_dir="$1"

	if [[ ! -d "${custom_dir}" ]]; then
		_log 'ERROR' "Custom directory ${custom_dir} does not exist."
		return 1
	fi

	_log 'INFO' "Starting symlink creation for packages in ${custom_dir}"

	# 自动检测 OpenWrt 源码根目录
	if [[ -z "${TOPDIR}" ]]; then
		if [[ -f './rules.mk' ]]; then
			export TOPDIR="${PWD}"
			_log 'INFO' "Auto-detected TOPDIR: ${TOPDIR}"
		elif [[ -f '../rules.mk' ]]; then
			export TOPDIR="${PWD%/*}"
			_log 'INFO' "Auto-detected TOPDIR: ${TOPDIR}"
		else
			_log 'ERROR' 'Cannot find OpenWrt TOPDIR (rules.mk not found).'
			return 1
		fi
	fi

	local cache_file="${custom_dir}/.symlink_cache"
	declare -A cache_map   # 自动缓存: rel_path -> "mtime|target"
	declare -A manual_map  # 手动条目: rel_path -> target_path
	declare -A manual_skip # 跳过标记: rel_path -> "skip"

	# 加载现有缓存（相对路径相对于 custom_dir）
	if [[ -f "${cache_file}" ]]; then
		_log 'INFO' "Loading cache from ${cache_file}"
		local auto_count=0 manual_count=0
		while IFS='|' read -r rel_path mtime target_path skip_flag; do
			# 跳过注释行和空行
			[[ -z "${rel_path}" || "${rel_path}" == \#* ]] && continue

			# 验证源目录是否仍然存在
			if [[ ! -d "${custom_dir}/${rel_path}" ]]; then
				_log 'WARN' "Stale cache entry '${rel_path}' (source missing), skipping."
				continue
			fi

			# 根据 mtime 字段判断条目类型
			if [[ "${mtime}" =~ ^[0-9]+$ ]]; then
				# 数字 mtime: 自动生成的条目
				cache_map["${rel_path}"]="${mtime}|${target_path}"
				((auto_count++))
			else
				# "manual": 用户手动定义的条目
				manual_map["${rel_path}"]="${target_path}"
				[[ "${skip_flag}" == "skip" ]] && manual_skip["${rel_path}"]="skip"
				((manual_count++))
			fi
		done <"${cache_file}"
		_log 'INFO' "Loaded ${auto_count} auto + ${manual_count} manual cache entries"
	fi

	local total_packages=0 successful_links=0 failed_links=0
	local cache_hits=0 cache_misses=0

	_log 'INFO' "Scanning for package directories (containing Makefile) under ${custom_dir}..."

	# 扫描所有包含 Makefile 的目录（排除 .git 和 files）
	while IFS= read -r dir; do
		[[ "${dir}" == "${custom_dir}" ]] && continue

		((total_packages++))
		local abs_dir
		abs_dir="$(cd "${dir}" && pwd)"

		# 提取软件包名称
		local pkg_name
		pkg_name="$(_extract_pkg_name "${abs_dir}")"
		if [[ -z "${pkg_name}" ]]; then
			pkg_name="$(basename "${dir}")"
		fi

		_log 'INFO' '----------------------------------------'
		_log 'INFO' "Processing package #${total_packages}: ${pkg_name} (directory: $(basename "${dir}"))"
		_log 'INFO' "  Source directory: ${abs_dir}"

		# 计算相对于 custom_dir 的路径
		local abs_custom_dir
		abs_custom_dir="$(cd "${custom_dir}" && pwd)"
		local rel_path="${abs_dir#"${abs_custom_dir}"/}"

		local makefile_path="${abs_dir}/Makefile"
		local current_mtime
		current_mtime="$(stat -c %Y "${makefile_path}" 2>/dev/null || printf '0')"

		local target_path=''
		local used_cache=0
		local skip_this=0

		# 优先检查手动定义条目
		if [[ -n "${manual_map[${rel_path}]}" ]]; then
			target_path="${manual_map[${rel_path}]}"
			[[ "${manual_skip[${rel_path}]}" == "skip" ]] && skip_this=1
			_log 'INFO' "  Using manual entry: target='${target_path}', skip=${skip_this}"
			used_cache=1
			((cache_hits++))
		fi

		# 检查自动缓存（仅当没有手动定义时）
		if [[ ${used_cache} -eq 0 && -n "${cache_map[${rel_path}]}" ]]; then
			local cached_entry="${cache_map[${rel_path}]}"
			local cached_mtime="${cached_entry%%|*}"
			local cached_target="${cached_entry#*|}"

			if [[ "${cached_mtime}" == "${current_mtime}" ]]; then
				# 缓存有效（Makefile 未修改）
				target_path="${cached_target}"
				used_cache=1
				((cache_hits++))
				_log 'INFO' "  Cache hit (mtime ${current_mtime}) -> ${target_path}"
			else
				# 缓存失效（Makefile 已修改）
				_log 'INFO' "  Cache stale (mtime changed: ${cached_mtime} -> ${current_mtime})"
				unset "cache_map[${rel_path}]"
			fi
		fi

		# 缓存未命中，重新解析
		if [[ ${used_cache} -eq 0 ]]; then
			((cache_misses++))
			target_path="$(resolve_target_path "${abs_dir}" "${pkg_name}")"
			if [[ -n "${target_path}" ]]; then
				# 保存到缓存（不覆盖手动条目）
				if [[ -z "${manual_map[${rel_path}]}" ]]; then
					cache_map["${rel_path}"]="${current_mtime}|${target_path}"
					_log 'INFO' "  Cached new entry: ${rel_path} -> ${target_path}"
				fi
			fi
		fi

		if [[ -z "${target_path}" ]]; then
			_log 'ERROR' "  Could not determine target path for ${pkg_name}, skipping."
			((failed_links++))
			continue
		fi

		if [[ ${skip_this} -eq 1 ]]; then
			_log 'INFO' "  Skipping symlink creation due to manual skip flag."
			continue
		fi

		_log 'INFO' "  Target symlink path: ${target_path}"

		# 创建符号链接
		if _create_relative_symlink "${abs_dir}" "${target_path}"; then
			((successful_links++))
		else
			((failed_links++))
		fi
	done < <(find "${custom_dir}" -type d \( -name '.git' -o -name 'files' \) -prune -o \
		-type d -exec test -f {}/Makefile \; -print -prune | sort)

	# 处理仅在缓存中存在的手动条目（没有 Makefile 的目录）
	if [[ ${#manual_map[@]} -gt 0 ]]; then
		_log 'INFO' 'Processing manual-only symlink entries...'
		for rel_path in "${!manual_map[@]}"; do
			# 跳过已在扫描中处理的条目
			[[ -f "${custom_dir}/${rel_path}/Makefile" ]] && continue

			local abs_dir="${custom_dir}/${rel_path}"
			local target_path="${manual_map[${rel_path}]}"
			local skip_this=0
			[[ "${manual_skip[${rel_path}]}" == "skip" ]] && skip_this=1

			if [[ ! -d "${abs_dir}" ]]; then
				_log 'WARN' "  Manual entry source directory not found: ${abs_dir}, skipping."
				continue
			fi

			if [[ ${skip_this} -eq 1 ]]; then
				_log 'INFO' "  Manual entry (skip): ${rel_path} -> ${target_path} (skipped)"
				continue
			fi

			_log 'INFO' "  Manual entry: ${rel_path} -> ${target_path}"

			if _create_relative_symlink "${abs_dir}" "${target_path}"; then
				((successful_links++))
			else
				((failed_links++))
			fi
		done
	fi

	# 保存更新后的缓存
	{
		printf '# OpenWrt package symlink cache\n'
		printf '# Format: relative_path|mtime|target_path|skip_flag  (mtime=manual for user-defined entries)\n'
		for rel_path in "${!cache_map[@]}"; do
			printf '%s|%s\n' "${rel_path}" "${cache_map[${rel_path}]}"
		done
		for rel_path in "${!manual_map[@]}"; do
			local skip_part=""
			[[ "${manual_skip[${rel_path}]}" == "skip" ]] && skip_part="|skip"
			printf '%s|manual|%s%s\n' "${rel_path}" "${manual_map[${rel_path}]}" "${skip_part}"
		done
	} >"${cache_file}.tmp" && mv "${cache_file}.tmp" "${cache_file}"

	# 输出统计信息
	_log 'INFO' "Cache saved with ${#cache_map[@]} auto + ${#manual_map[@]} manual entries"
	_log 'INFO' '========================================'
	_log 'INFO' 'Symlink creation completed.'
	_log 'INFO' "Total packages processed: ${total_packages}"
	_log 'INFO' "Cache hits: ${cache_hits}"
	_log 'INFO' "Cache misses: ${cache_misses}"
	_log 'INFO' "Manual entries processed: ${#manual_map[@]}"
	_log 'INFO' "Successful symlinks: ${successful_links}"
	_log 'INFO' "Failed symlinks: ${failed_links}"
}

#######################################
# 修改 LuCI 集合 Makefile
#
# 对 LuCI 集合软件包的 Makefile 应用 sed 表达式，用于调整依赖关系。
# 典型用途: 移除 uhttpd 依赖、替换默认主题、删除不需要的应用。
#
# Arguments:
#   $1 - Makefile 文件路径
#   $2... - sed 表达式参数（直接传递给 sed -i）
#
# Globals:
#   None
#
# Outputs:
#   操作提示到 stdout
#   错误信息到 stderr
#
# Returns:
#   0 - 总是成功（即使文件不存在）
#
# Examples:
#   modify_luci_collection 'feeds/luci/collections/luci/Makefile' \
#     -e '/LUCI_DEPENDS/,/^$/ { /uhttpd/d; }'
#######################################
modify_luci_collection() {
	local makefile="$1"
	shift
	local sed_exprs=("$@")

	if [[ -f "${makefile}" ]]; then
		printf 'Modifying %s...\n' "${makefile}"
		sed -i "${sed_exprs[@]}" "${makefile}"
	else
		printf 'File %s does not exist.\n' "${makefile}" >&2
	fi
}

#######################################
# 主脚本执行部分
#######################################

#######################################
# 1. 修改系统默认配置
#######################################

# 修改默认 IP 地址为 192.168.0.1（避免与常见路由器冲突）
BASE_FILE_CONFIG='package/base-files/files/bin/config_generate'
if [[ -f "${BASE_FILE_CONFIG}" ]]; then
	sed -i 's/192.168.1.1/192.168.0.1/g' "${BASE_FILE_CONFIG}"
else
	printf 'File %s does not exist.\n' "${BASE_FILE_CONFIG}" >&2
fi

# 修改默认 Shell 从 ash 到 bash（提供更好的交互体验）
PASSWD_FILE='package/base-files/files/etc/passwd'
if [[ -f "${PASSWD_FILE}" ]]; then
	sed -i 's/\/bin\/ash/\/bin\/bash/' "${PASSWD_FILE}"
else
	printf 'File %s does not exist.\n' "${PASSWD_FILE}" >&2
fi

#######################################
# 2. 创建自定义软件包符号链接
#
# 将下载的所有自定义软件包链接到 feeds 目录，
# 使其能够被 OpenWrt 构建系统识别。
#######################################
create_symlinks 'custom-packages'

#######################################
# 3. 修改 LuCI 集合配置
#
# 调整 LuCI 各个集合包的依赖关系：
#   - 移除 luci-app-attendedsysupgrade（占用空间大）
#   - 移除 uhttpd 依赖（改用 nginx）
#   - 替换默认主题为 Argon
#######################################

# LuCI 完整版：移除 attendedsysupgrade，修正 package-manager 格式
modify_luci_collection 'feeds/luci/collections/luci/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

# LuCI 轻量版：移除 uhttpd，替换主题为 Argon
modify_luci_collection 'feeds/luci/collections/luci-light/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /uhttpd/d; s/luci-theme-bootstrap/luci-theme-argon/g; s/rpcd-mod-rrdns\s*\\/rpcd-mod-rrdns/g; }'

# LuCI Nginx 版：移除 attendedsysupgrade，替换主题为 Argon
modify_luci_collection 'feeds/luci/collections/luci-nginx/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-theme-bootstrap/luci-theme-argon/g; }'

# LuCI SSL 版：移除 attendedsysupgrade，修正 package-manager 格式
modify_luci_collection 'feeds/luci/collections/luci-ssl/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

# LuCI SSL-OpenSSL 版：移除 attendedsysupgrade，修正 package-manager 格式
modify_luci_collection 'feeds/luci/collections/luci-ssl-openssl/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

#######################################
# 4. 修改 easyupdate.sh 脚本以支持自定义固件格式
#
# 调整更新脚本以适配 BPI-R4 的固件格式（.itb 文件）。
# 修改内容:
#   - 强制保留配置 (-k 参数)
#   - 调整固件文件路径为 /tmp/
#   - 修改固件后缀为 squashfs-sysupgrade.itb
#   - 修正校验文件扩展名
#######################################
EASYUPDATE_FILE='custom-packages/sundaqiang/luci/applications/luci-app-easyupdate/root/usr/bin/easyupdate.sh'
# shellcheck disable=SC2016
if [[ -f "${EASYUPDATE_FILE}" ]]; then
	printf "Modifying %s...\n" "${EASYUPDATE_FILE}"
	sed -i -E \
		-e '/sysupgrade\s+\$keepconfig\s*\$file/s/sysupgrade/sysupgrade -k/g' \
		-e '/^\s*file/s/\$\{checkShaRet/\/tmp\/\$\{checkShaRet/g' \
		-e '/Check\s+whether\s+EFI\s+firmware/,/^\s*fi/ {
        /^\s+fi/a\    suffix='\''squashfs-sysupgrade.itb'\''
        s/^/#/
      }' \
		-e '/^\s*function\s+checkSha/,/^\s*\}/ {
        s/img\.gz/\itb/
      }' \
		"${EASYUPDATE_FILE}"
else
	printf "File %s does not exist.\n" "${EASYUPDATE_FILE}" >&2
fi

#######################################
# 5. 修改 Rust 构建配置
#
# 禁用 CI LLVM 下载，改用系统 LLVM，加快编译速度。
#######################################
RUST_MAKEFILE='feeds/packages/lang/rust/Makefile'
if [[ -f "${RUST_MAKEFILE}" ]]; then
	printf 'Modifying %s...\n' "${RUST_MAKEFILE}"
	sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' "${RUST_MAKEFILE}"
else
	printf 'File %s does not exist.\n' "${RUST_MAKEFILE}" >&2
fi

#######################################
# 6. 添加软件包恢复脚本执行权限
#
# 为自定义的软件包恢复脚本添加可执行权限。
#######################################
RESTORE_PACKAGES_FILE='files/usr/bin/restore-packages.sh'
if [[ -f "${RESTORE_PACKAGES_FILE}" ]]; then
	printf 'Setting execute permission on %s...\n' "${RESTORE_PACKAGES_FILE}"
	chmod +x "${RESTORE_PACKAGES_FILE}"
else
	printf 'File %s does not exist.\n' "${RESTORE_PACKAGES_FILE}" >&2
fi

#######################################
# 7. 修改 dae 版本为 v1.1.0rc1
#
# 指定使用特定版本的 dae 代理软件。
# 包括版本号、源文件、下载地址和校验和。
#######################################
DAE_MAKEFILE='custom-packages/packages/net/dae/Makefile'
if [[ -f "${DAE_MAKEFILE}" ]]; then
	printf "Modifying %s...\n" "${DAE_MAKEFILE}"
	sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=1.1.0_rc1/" "${DAE_MAKEFILE}"
	sed -i "s/PKG_SOURCE:=.*/PKG_SOURCE:=\$(PKG_NAME)-1.1.0rc1.zip/" "${DAE_MAKEFILE}"
	sed -i "s#PKG_SOURCE_URL:=.*#PKG_SOURCE_URL:=https://github.com/daeuniverse/dae/releases/download/v1.1.0rc1/dae-full-src.zip?#" "${DAE_MAKEFILE}"
	sed -i "s/PKG_HASH:=.*/PKG_HASH:=726a049813a4d5b800c441ea76ff0ce1846596c180fba0e8ec920a129b3b6e0a/" "${DAE_MAKEFILE}"
else
	printf "File %s does not exist.\n" "${DAE_MAKEFILE}" >&2
fi
