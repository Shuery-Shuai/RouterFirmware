#!/bin/bash
#######################################
# ImmortalWrt 构建自定义脚本 - 第二阶段
#
# 在 feeds 安装完成后执行的自定义脚本，用于系统配置和软件包集成。
# 主要功能包括:
#   - 修改系统默认配置 (IP 地址、默认 Shell)
#   - 为自定义软件包创建符号链接到 feeds 目录
#   - 修补 LuCI 集合和软件包配置
#   - 修改特定软件包版本和构建配置
#   - 重命名冲突的软件包 (qBittorrent)
#
# 执行时机:
#   在 ./scripts/feeds install -a 之后、make menuconfig 之前执行
#   适用于集成第三方软件包和修改 feeds 内容
#
# 用法:
#   bash diy-part2.immortalwrt.sh
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
# 适用固件: ImmortalWrt (社区版本)
# 适用设备: BananaPi BPI-R4
#
# 与 diy-part2.openwrt.sh 的区别:
#   - easyupdate.sh 修改更全面（支持 ImmortalWrt 特有格式）
#   - 添加 qbittorrent-original 重命名逻辑
#   - 添加 fan2go 版本修改
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
#######################################
clone_repo() {
	local repo="$1"
	local branch="$2"
	local args="$3"
	local target="$4"
	local attempt

	if [[ -d "${target}" ]]; then
		printf 'Pulling %s at %s...\n' "${repo}" "${target}"
		for attempt in {1..3}; do
			if git -C "${target}" clean -fdx &&
				git -C "${target}" restore . &&
				git -C "${target}" pull; then
				break
			else
				printf 'Pull attempt %d failed, retrying...\n' "${attempt}"
				sleep $((attempt * 2))
			fi
		done
	else
		printf 'Cloning %s %s to %s, using args: %s\n' \
			"${repo}" "${branch}" "${target}" "${args}"
		for attempt in {1..3}; do
			printf 'Clone attempt %d...\n' "${attempt}"
			if eval "git clone -b '${branch}' ${args} '${repo}' '${target}'"; then
				break
			else
				printf 'Clone attempt %d failed!\n' "${attempt}"
				sleep $((attempt * 2))
				rm -rf "${target}"
				if [[ "${attempt}" -eq 3 ]]; then
					_log 'ERROR' "Failed to clone ${repo} after 3 attempts."
					exit 1
				fi
			fi
		done
	fi
}

# 以下辅助函数与 diy-part2.openwrt.sh 相同，注释略
# 详细文档请参考 diy-part2.openwrt.sh

_relpath() {
	local from_dir="$1"
	local to_path="$2"
	local abs_from abs_to

	abs_from="$(cd "${from_dir}" && pwd)" || return 1
	abs_to="$(cd "${to_path}" && pwd)" || return 1

	local from_parts to_parts
	IFS='/' read -ra from_parts <<<"${abs_from}"
	IFS='/' read -ra to_parts <<<"${abs_to}"

	local i=0
	while [[ ${i} -lt ${#from_parts[@]} &&
		${i} -lt ${#to_parts[@]} &&
		"${from_parts[${i}]}" == "${to_parts[${i}]}" ]]; do
		((i++))
	done

	local up_count=$((${#from_parts[@]} - i))
	local rel_path=''
	local j

	for ((j = 0; j < up_count; j++)); do
		rel_path+='../'
	done

	for ((j = i; j < ${#to_parts[@]}; j++)); do
		rel_path+="${to_parts[${j}]}"
		if [[ ${j} -lt $((${#to_parts[@]} - 1)) ]]; then
			rel_path+='/'
		fi
	done

	printf '%s' "${rel_path}"
}

_create_relative_symlink() {
	local source_abs="$1"
	local target_link="$2"
	local target_dir

	target_dir="$(dirname "${target_link}")"
	mkdir -p "${target_dir}"

	if [[ -L "${target_link}" ]] || [[ -d "${target_link}" ]]; then
		_log 'WARN' "  Removing existing symlink/directory at ${target_link}"
		rm -rf "${target_link}"
	fi

	local rel_target
	rel_target="$(_relpath "${target_dir}" "${source_abs}")"
	if [[ -z "${rel_target}" ]]; then
		_log 'ERROR' "  Failed to compute relative path from ${target_dir} to ${source_abs}"
		return 1
	fi

	if ln -s "${rel_target}" "${target_link}"; then
		_log 'INFO' "  SUCCESS: Created symlink ${target_link} -> ${rel_target}"
		return 0
	else
		_log 'ERROR' "  FAILED: Could not create symlink ${target_link}"
		return 1
	fi
}

_extract_pkg_name() {
	local abs_dir="$1"
	local makefile="${abs_dir}/Makefile"
	local pkg_name

	if [[ ! -f "${makefile}" ]]; then
		return 1
	fi

	pkg_name="$(grep -E '^\s*PKG_NAME\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*PKG_NAME\s*:?=\s*(.+)\s*$/\1/')"

	if [[ -z "${pkg_name}" ]]; then
		pkg_name="$(basename "${abs_dir}")"
	fi

	printf '%s' "${pkg_name}"
}

resolve_target_path() {
	local abs_dir="$1"
	local pkg_name="$2"
	local target_path=''

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
		local makefile="${abs_dir}/Makefile"
		local section=''
		if [[ -f "${makefile}" ]]; then
			section="$(grep -E '^\s*SECTION\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*SECTION\s*:?=\s*([^[:space:]]+).*$/\1/')"
		fi
		_log 'INFO' "  Extracted SECTION from Makefile: '${section}'"

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
				target_path="feeds/base/${pkg_name}"
				_log 'INFO' "  Default fallback -> feeds/base"
			fi
		fi
	fi

	printf '%s' "${target_path}"
}

create_symlinks() {
	local custom_dir="$1"

	if [[ ! -d "${custom_dir}" ]]; then
		_log 'ERROR' "Custom directory ${custom_dir} does not exist."
		return 1
	fi

	_log 'INFO' "Starting symlink creation for packages in ${custom_dir}"

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
	declare -A cache_map
	declare -A manual_map
	declare -A manual_skip

	if [[ -f "${cache_file}" ]]; then
		_log 'INFO' "Loading cache from ${cache_file}"
		local auto_count=0 manual_count=0
		while IFS='|' read -r rel_path mtime target_path skip_flag; do
			[[ -z "${rel_path}" || "${rel_path}" == \#* ]] && continue

			if [[ ! -d "${custom_dir}/${rel_path}" ]]; then
				_log 'WARN' "Stale cache entry '${rel_path}' (source missing), skipping."
				continue
			fi

			if [[ "${mtime}" =~ ^[0-9]+$ ]]; then
				cache_map["${rel_path}"]="${mtime}|${target_path}"
				((auto_count++))
			else
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

	while IFS= read -r dir; do
		[[ "${dir}" == "${custom_dir}" ]] && continue

		((total_packages++))
		local abs_dir
		abs_dir="$(cd "${dir}" && pwd)"

		local pkg_name
		pkg_name="$(_extract_pkg_name "${abs_dir}")"
		if [[ -z "${pkg_name}" ]]; then
			pkg_name="$(basename "${dir}")"
		fi

		_log 'INFO' '----------------------------------------'
		_log 'INFO' "Processing package #${total_packages}: ${pkg_name} (directory: $(basename "${dir}"))"
		_log 'INFO' "  Source directory: ${abs_dir}"

		local abs_custom_dir
		abs_custom_dir="$(cd "${custom_dir}" && pwd)"
		local rel_path="${abs_dir#"${abs_custom_dir}"/}"

		local makefile_path="${abs_dir}/Makefile"
		local current_mtime
		current_mtime="$(stat -c %Y "${makefile_path}" 2>/dev/null || printf '0')"

		local target_path=''
		local used_cache=0
		local skip_this=0

		if [[ -n "${manual_map[${rel_path}]}" ]]; then
			target_path="${manual_map[${rel_path}]}"
			[[ "${manual_skip[${rel_path}]}" == "skip" ]] && skip_this=1
			_log 'INFO' "  Using manual entry: target='${target_path}', skip=${skip_this}"
			used_cache=1
			((cache_hits++))
		fi

		if [[ ${used_cache} -eq 0 && -n "${cache_map[${rel_path}]}" ]]; then
			local cached_entry="${cache_map[${rel_path}]}"
			local cached_mtime="${cached_entry%%|*}"
			local cached_target="${cached_entry#*|}"

			if [[ "${cached_mtime}" == "${current_mtime}" ]]; then
				target_path="${cached_target}"
				used_cache=1
				((cache_hits++))
				_log 'INFO' "  Cache hit (mtime ${current_mtime}) -> ${target_path}"
			else
				_log 'INFO' "  Cache stale (mtime changed: ${cached_mtime} -> ${current_mtime})"
				unset "cache_map[${rel_path}]"
			fi
		fi

		if [[ ${used_cache} -eq 0 ]]; then
			((cache_misses++))
			target_path="$(resolve_target_path "${abs_dir}" "${pkg_name}")"
			if [[ -n "${target_path}" ]]; then
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

		if _create_relative_symlink "${abs_dir}" "${target_path}"; then
			((successful_links++))
		else
			((failed_links++))
		fi
	done < <(find "${custom_dir}" -type d \( -name '.git' -o -name 'files' \) -prune -o \
		-type d -exec test -f {}/Makefile \; -print -prune | sort)

	if [[ ${#manual_map[@]} -gt 0 ]]; then
		_log 'INFO' 'Processing manual-only symlink entries...'
		for rel_path in "${!manual_map[@]}"; do
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

# 修改默认 IP 地址
BASE_FILE_CONFIG='package/base-files/files/bin/config_generate'
if [[ -f "${BASE_FILE_CONFIG}" ]]; then
	sed -i 's/192.168.1.1/192.168.0.1/g' "${BASE_FILE_CONFIG}"
else
	printf 'File %s does not exist.\n' "${BASE_FILE_CONFIG}" >&2
fi

# 修改默认 shell
PASSWD_FILE='package/base-files/files/etc/passwd'
if [[ -f "${PASSWD_FILE}" ]]; then
	sed -i 's/\/bin\/ash/\/bin\/bash/' "${PASSWD_FILE}"
else
	printf 'File %s does not exist.\n' "${PASSWD_FILE}" >&2
fi

#######################################
# 2. 修改 easyupdate.sh 以支持 ImmortalWrt 固件
#
# 将更新脚本从 OpenWrt 适配到 ImmortalWrt：
#   - 替换所有 OpenWrt/openwrt 为 ImmortalWrt/immortalwrt
#   - 强制保留配置 (-k 参数)
#   - 调整文件名截取范围 (0:11 而非 0:7)
#   - 修改固件后缀为 squashfs-sysupgrade.itb
#   - 修正校验文件扩展名
#######################################
EASYUPDATE_FILE="custom-packages/sundaqiang/luci/applications/luci-app-easyupdate/root/usr/bin/easyupdate.sh"
if [[ -f "${EASYUPDATE_FILE}" ]]; then
	printf "Modifying %s...\n" "${EASYUPDATE_FILE}"
	sed -i -E \
		-e "/curl|filename/s/OpenWrt/ImmortalWrt/g" \
		-e "/curl|filename/s/openwrt/immortalwrt/g" \
		-e "/curl|filename/s/Openwrt/Immortalwrt/g" \
		-e "/sysupgrade\s+\\\$keepconfig\s*\\\$file/s/sysupgrade/sysupgrade -k/g" \
		-e "/file[Nn]ame/s/0:7/0:11/g" \
		-e "/^\s*file/s/\\\$\{checkShaRet/\/tmp\/\\\$\{checkShaRet/g" \
		-e "/Check\s+whether\s+EFI\s+firmware/,/^\s*fi/ {
        /^\s+fi/a\    suffix='squashfs-sysupgrade.itb'
        s/^/#/
      }" \
		-e "/^\s*function\s+checkSha/,/^\s*\}/ {
        s/img\.gz/\itb/
      }" \
		"${EASYUPDATE_FILE}"
else
	echo "File ${EASYUPDATE_FILE} does not exist." >&2
fi

#######################################
# 3. 重命名 qBittorrent 应用避免冲突
#
# ImmortalWrt 自带 luci-app-qbittorrent，
# 将第三方版本重命名为 luci-app-qbittorrent-original。
#######################################
QBIT_APP_PATH="custom-packages/qbittorrent"
if [[ -d "${QBIT_APP_PATH}" ]]; then
	printf "Modifying %s...\n" "${QBIT_APP_PATH}"
	if [[ -d "${QBIT_APP_PATH}/luci-app-qbittorrent" ]]; then
		mv "${QBIT_APP_PATH}/luci-app-qbittorrent" "${QBIT_APP_PATH}/luci-app-qbittorrent-original"
	fi
	sed -i "s/luci-app-qbittorrent/luci-app-qbittorrent-original/" "${QBIT_APP_PATH}/luci-app-qbittorrent-original/Makefile"
else
	echo "Dir ${QBIT_APP_PATH} does not exist." >&2
fi

# 创建符号链接
create_symlinks 'custom-packages'

#######################################
# 4. 修改 LuCI 集合
modify_luci_collection 'feeds/luci/collections/luci/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

modify_luci_collection 'feeds/luci/collections/luci-light/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /uhttpd/d; s/luci-theme-bootstrap/luci-theme-argon/g; s/rpcd-mod-rrdns\s*\\/rpcd-mod-rrdns/g; }'

modify_luci_collection 'feeds/luci/collections/luci-nginx/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-theme-bootstrap/luci-theme-argon/g; }'

modify_luci_collection 'feeds/luci/collections/luci-ssl/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

modify_luci_collection 'feeds/luci/collections/luci-ssl-openssl/Makefile' \
	-e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

#######################################
# 5. 修改 Rust 构建配置
RUST_MAKEFILE='feeds/packages/lang/rust/Makefile'
if [[ -f "${RUST_MAKEFILE}" ]]; then
	printf 'Modifying %s...\n' "${RUST_MAKEFILE}"
	sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' "${RUST_MAKEFILE}"
else
	printf 'File %s does not exist.\n' "${RUST_MAKEFILE}" >&2
fi

#######################################
# 6. 添加执行权限
RESTORE_PACKAGES_FILE='files/usr/bin/restore-packages.sh'
if [[ -f "${RESTORE_PACKAGES_FILE}" ]]; then
	printf 'Setting execute permission on %s...\n' "${RESTORE_PACKAGES_FILE}"
	chmod +x "${RESTORE_PACKAGES_FILE}"
else
	printf 'File %s does not exist.\n' "${RESTORE_PACKAGES_FILE}" >&2
fi

#######################################
# 7. 修改 dae 版本为 v1.1.0rc1
#######################################
DAE_MAKEFILE='feeds/packages/net/dae/Makefile'
if [[ -f "${DAE_MAKEFILE}" ]]; then
	printf "Modifying %s...\n" "${DAE_MAKEFILE}"
	sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=1.1.0_rc1/" "${DAE_MAKEFILE}"
	sed -i "s/PKG_SOURCE:=.*/PKG_SOURCE:=\$(PKG_NAME)-1.1.0rc1.zip/" "${DAE_MAKEFILE}"
	sed -i "s#PKG_SOURCE_URL:=.*#PKG_SOURCE_URL:=https://github.com/daeuniverse/dae/releases/download/v1.1.0rc1/dae-full-src.zip?#" "${DAE_MAKEFILE}"
	sed -i "s/PKG_HASH:=.*/PKG_HASH:=726a049813a4d5b800c441ea76ff0ce1846596c180fba0e8ec920a129b3b6e0a/" "${DAE_MAKEFILE}"
else
	printf "File %s does not exist.\n" "${DAE_MAKEFILE}" >&2
fi

#######################################
# 8. 修改 fan2go 版本为 0.13.0
#
# 更新风扇控制软件到指定版本。
#######################################
FAN2GO_MAKEFILE='feeds/packages/utils/fan2go/Makefile'
if [[ -f "${FAN2GO_MAKEFILE}" ]]; then
	printf 'Modifying %s...\n' "${FAN2GO_MAKEFILE}"
	sed -i 's/PKG_VERSION:=.*/PKG_VERSION:=0.13.0/' "${FAN2GO_MAKEFILE}"
	sed -i 's/PKG_HASH:=.*/PKG_HASH:=d693bc3ed4c43c8f120433ff17cecca9b98def829e031759373e6ff1ed8def61/' "${FAN2GO_MAKEFILE}"
else
	printf 'File %s does not exist.\n' "${FAN2GO_MAKEFILE}" >&2
fi
