#!/bin/bash
#######################################
# BananaPi BPI-R4 构建自定义脚本 - 函数库
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