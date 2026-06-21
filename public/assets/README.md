# OpenWrt 编译配置与运行时增强脚本

本仓库为 Banana Pi R4（及兼容设备）提供了完整的 OpenWrt 编译配置和运行时增强脚本，主要包含：

- **智能风扇控制**（BPI-R4 专用）：基于温度的 PWM 风扇调速，支持平滑曲线控制。
- **动态 APK 源替换**（通用）：根据网络接口状态自动切换 APK 软件源，并在断网时恢复已安装包。
- **编译辅助脚本**：分区大小调整、内核模块添加、第三方包克隆等。

## 目录结构

```pre
.
├── common/                               # 通用配置（所有设备共用）
│   └── files/                            # 直接覆盖到 OpenWrt 根文件系统
│       ├── etc/
│       │   ├── apk/repositories.d/
│       │   │   ├── customfeeds.list      # 自定义 APK 源列表（用户填写）
│       │   │   └── README.md             # 源配置说明
│       │   ├── hotplug.d/iface/
│       │   │   ├── 88-replace-apk-source # 接口 up → 替换源
│       │   │   └── 99-restore-package    # 接口 down → 恢复包
│       │   ├── init.d/                   # 仅占位（风扇控制由 bpi-r4 提供）
│       │   └── uci-defaults/             # 占位
│       └── usr/bin/
│           ├── replace-apk-source.sh     # 替换 APK 源脚本
│           └── restore-packages.sh       # 恢复已安装包脚本
│
├── bpi-r4/                               # Banana Pi R4 专用配置
│   ├── files/                            # 覆盖到根文件系统（优先级高于 common）
│   │   ├── etc/init.d/fan-control        # 风扇控制服务脚本
│   │   └── usr/bin/fan-control.sh        # 风扇控制主程序
│   ├── diy-part1.sh                      # 编译前预处理（分区修改、内核模块添加）
│   ├── diy-part2.immortalwrt.sh          # 针对 ImmortalWrt 的 feeds 后处理
│   ├── diy-part2.openwrt.sh              # 针对官方 OpenWrt 的 feeds 后处理
│   ├── immortalwrt.config                # ImmortalWrt 内核配置片段
│   └── openwrt.config                    # 官方 OpenWrt 内核配置片段
│
├── README.md                             # 本文件
└── index.html                            # 防目录列表占位（可忽略）
```

> 注：`index.html` 仅用于防止 Web 服务器列出目录，无实际功能。

## 详细文件说明与使用方式

### 1. 通用部分 (`common/files/`)

#### 1.1 APK 源管理（适用于使用 `apk` 包管理器的固件）

- **`/etc/apk/repositories.d/customfeeds.list`**  
  用户自定义的 APK 源列表，每行一个 URL。例如：

  ```txt
  http://192.168.1.100/alpine/v3.19/main
  http://192.168.1.100/alpine/v3.19/community
  ```

  当网络接口启用时，该文件中的源会替换默认源。

- **`/usr/bin/replace-apk-source.sh`**  
  功能：将 `/etc/apk/repositories` 备份后，替换为 `customfeeds.list` 中的源。  
  手动执行：`/usr/bin/replace-apk-source.sh`  
  执行逻辑：
  - 检查是否存在 `/etc/apk/repositories.bak`，若不存在则备份当前源。
  - 清空 `/etc/apk/repositories` 并写入 `customfeeds.list` 的内容。
  - 可选：运行 `apk update` 更新索引。

- **`/usr/bin/restore-packages.sh`**  
  功能：恢复原始源并重装之前通过自定义源安装的软件包。  
  手动执行：`/usr/bin/restore-packages.sh`  
  执行逻辑：
  - 将 `/etc/apk/repositories` 恢复为备份文件（`/etc/apk/repositories.bak`）。
  - 读取 `/usr/lib/apk/original_packages.list`（在替换源时自动生成），使用 `apk add --force-reinstall` 重新安装这些包。
  - 删除自定义源期间可能安装的非原始包（可选）。

- **热插拔脚本** (`/etc/hotplug.d/iface/88-replace-apk-source` 和 `99-restore-package`)
  - 当网络接口（默认 `wan`）**启动 (up)** 时，`88-replace-apk-source` 被触发，调用 `replace-apk-source.sh`。
  - 当接口**关闭 (down)** 时，`99-restore-package` 被触发，调用 `restore-packages.sh`。
  - **自定义监控接口**：编辑这两个脚本，修改 `INTERFACE="wan"` 为你的接口名（如 `lan`、`wwan`）。
  - **手动测试**：可通过 `ifup wan` 和 `ifdown wan` 模拟接口状态变化来测试。

#### 1.2 注意事项（APK 源部分）

- 脚本假设系统使用 `apk`（Alpine 包管理器）。若使用 `opkg`，需全局替换脚本中的 `apk` 为 `opkg`。
- 恢复包时要求 `/usr/lib/apk/original_packages.list` 存在，该文件由 `replace-apk-source.sh` 自动生成（备份原始包列表）。
- 若需要接口 up 时自动安装自定义源中的新包，请自行修改 `replace-apk-source.sh` 添加 `apk add` 命令。

---

### 2. BPI-R4 专用部分 (`bpi-r4/files/`)

#### 2.1 风扇控制服务

- **服务脚本**：`/etc/init.d/fan-control`  
  这是一个标准的 OpenWrt init 脚本（使用 `procd`）。主要功能：
  - 设置硬件设备权限（`/sys/class/hwmon/hwmon1/pwm1` 等）。
  - 启动后台守护进程 `/usr/bin/fan-control.sh`。
  - 停止时设置安全转速（150 PWM，约 59% 占空比）。

- **主程序**：`/usr/bin/fan-control.sh`  
  一个持续运行的 Shell 脚本，实现基于温度的风扇 PWM 闭环控制。

  **核心功能**：
  - 自动查找系统中的温度传感器（如 `*cpu*`、`*thermal*`）和 PWM 控制器（如 `*pwm*`、`*fan*`）。
  - 使用**三次贝塞尔曲线**实现温度-转速平滑过渡，避免突变。
  - 支持温度死区、步进平滑、周期性状态日志。

  **可配置参数**（在脚本开头修改）：

  ```bash
  PWM_MIN=0          # PWM 最小值（通常 0 对应停转）
  PWM_MAX=255        # PWM 最大值（255 对应全速）
  TEMP_MIN=35        # 最低参考温度（°C），低于此温度使用起始转速
  TEMP_MAX=75        # 最高参考温度（°C），高于此温度使用全速
  PWM_START=30       # 起始转速百分比（对应 TEMP_MIN）
  PWM_END=100        # 最高转速百分比（对应 TEMP_MAX）
  step_size=2        # PWM 每次变化的步长（使转速平滑变化）
  temp_threshold=2   # 温度变化超过此值才记录日志
  log_interval=300   # 完整状态日志间隔（秒）
  ```

  **手动运行与调试**：

  ```bash
  # 前台运行（查看实时输出）
  /usr/bin/fan-control.sh

  # 查看当前温度与 PWM 值
  cat /sys/class/hwmon/hwmon0/temp1_input   # 温度（毫摄氏度）
  cat /sys/class/hwmon/hwmon1/pwm1          # 当前 PWM 值
  ```

  **自定义温度传感器/PWM 路径**：  
  如果自动检测失败，可以修改 `find_hwmon_paths()` 函数，直接指定路径，例如：

  ```bash
  TEMP_PATH="/sys/class/thermal/thermal_zone0/temp"
  PWM_PATH="/sys/class/hwmon/hwmon1/pwm1"
  ```

#### 2.2 服务管理命令

```bash
# 启用开机自启
/etc/init.d/fan-control enable

# 启动服务
/etc/init.d/fan-control start

# 停止服务（会设置安全转速）
/etc/init.d/fan-control stop

# 重启服务
/etc/init.d/fan-control restart

# 查看状态
/etc/init.d/fan-control status
```

#### 2.3 硬件适配说明

- 脚本默认假设 BPI-R4 的温度传感器位于 `hwmon0`，PWM 控制器位于 `hwmon1`。若实际不同，脚本会自动搜索，但可能需要调整 `setup_permissions()` 中的路径。
- 确保内核启用了 `CONFIG_SENSORS_PWM_FAN` 和相应的温度传感器驱动（在 `.config` 文件中已配置 `CONFIG_PACKAGE_kmod-hwmon-pwmfan=y`）。

---

### 3. 编译辅助脚本 (`bpi-r4/diy-part*.sh` 和 `.config`)

这些脚本用于在 OpenWrt 编译过程中自动修改配置、添加第三方包和内核补丁。

#### 3.1 `diy-part1.sh`（编译前执行）

- **修改分区表**：`modify_partition` 函数可以为 BPI-R4 增加额外分区空间（默认未启用，需手动设置 `append_size`）。
- **添加内核模块**：`xdp-sockets-diag`（用于 `ss` 工具诊断 XDP 套接字）。
- **添加无线功率补丁**：注释部分演示了如何下载 `wireless-regdb` 补丁来解除国家/地区功率限制。

#### 3.2 `diy-part2.openwrt.sh` / `diy-part2.immortalwrt.sh`（更新 feeds 后执行）

- **克隆自定义软件包**：
  - `luci-app-openclash`、`luci-theme-argon`、`luci-app-argon-config`
  - `luci-app-nginx`、`luci-app-lucky`、`luci-app-ddns-go`、`luci-app-zerotier`
  - `luci-app-fancontrol`（注意：此包与本仓库的 `fan-control.sh` 不同，它是 luci 界面包）
  - `bpi-r4-pwm-fan`（硬件驱动）
  - `openwrt-qBittorrent`
  - `dae` 及相关依赖（仅 openwrt 版）
- **修改 LuCI 集合**：移除 `uhttpd` 依赖，将默认主题改为 `argon`。
- **修改 `easyupdate.sh`**：适配 ImmortalWrt 的固件命名和分区格式。
- **禁用 Rust 的 CI-LLVM 下载**（避免编译时下载大文件）。
- **重命名 qBittorrent 的 LuCI 包**（避免与官方包冲突）。

#### 3.3 配置文件 (`immortalwrt.config` / `openwrt.config`)

- 基于 `make kernel_menuconfig` 生成，包含了针对 BPI-R4 的完整内核选项。
- **关键配置**：
  - 目标平台：`mediatek/filogic`，设备 `bananapi_bpi-r4`
  - 启用 `apk-openssl` 包管理器（快照版）或保持 `opkg`（稳定版）
  - 内置 `luci-light`、`argon` 主题、`nginx`、`easyupdate` 等
  - 支持 `docker`、`dae`、`openclash` 等模块（编译为 `m`，可在固件中按需安装）
  - 内核调试选项（`CONFIG_DEVEL`、`CONFIG_KERNEL_DEBUG_INFO_BTF`）用于支持 eBPF。

**使用方法**：  
在 OpenWrt 源码根目录执行：

```bash
# 复制配置文件
cp bpi-r4/immortalwrt.config .config   # 或 openwrt.config
make defconfig
```

然后按需运行 `make menuconfig` 微调。

---

## 安装与部署

### 方式一：编译时集成（推荐）

1. 克隆本仓库到 OpenWrt 源码根目录下的 `assets` 文件夹（或任意位置）。
2. 将 `common/files` 和 `bpi-r4/files` 的内容复制到源码的 `files` 目录：

   ```bash
   cp -r assets/common/files/* openwrt/files/
   cp -r assets/bpi-r4/files/* openwrt/files/
   ```

3. 执行 `diy-part1.sh` 和对应的 `diy-part2.*.sh`（通常放在 OpenWrt 的 `scripts/` 或编译工作流的适当阶段）。
4. 使用提供的 `.config` 文件或自行配置。
5. 编译固件：

   ```bash
   make -j$(nproc)
   ```

### 方式二：手动部署到已运行的 OpenWrt

> 注意：以下操作会覆盖设备上的同名文件，请提前备份。

```bash
# 将通用配置复制到设备（假设设备 IP 192.168.1.1）
scp -r common/files/* root@192.168.1.1:/

# 将 BPI-R4 专用配置复制到设备
scp -r bpi-r4/files/* root@192.168.1.1:/

# 设置可执行权限（通过 SSH 登录设备后执行）
chmod +x /etc/init.d/fan-control
chmod +x /etc/hotplug.d/iface/*
chmod +x /usr/bin/*.sh

# 启用并启动风扇控制
/etc/init.d/fan-control enable
/etc/init.d/fan-control start
```

**批量复制所有 `files` 到设备的脚本**（在仓库根目录执行）：

```bash
#!/bin/bash
DEVICE_IP="192.168.1.1"   # 修改为你的设备 IP

# 复制 common
scp -r common/files/* root@${DEVICE_IP}:/

# 复制所有平台特定的 files（如 bpi-r4）
for platform in bpi-r4; do   # 可根据需要添加更多平台
    if [ -d "${platform}/files" ]; then
        echo "Copying ${platform}/files to device..."
        scp -r "${platform}/files"/* root@${DEVICE_IP}:/
    fi
done
```

---

## 自定义与调试

### 风扇控制

- **修改温度阈值**：编辑 `/usr/bin/fan-control.sh`，调整 `TEMP_MIN`、`TEMP_MAX`、`PWM_START`、`PWM_END`。
- **调整平滑步长**：修改 `step_size`（值越小变化越平滑，但响应越慢）。
- **查看实时日志**：

  ```bash
  logread -f | grep FAN_CONTROL
  ```

- **临时手动控制风扇**：

  ```bash
  echo 150 > /sys/class/hwmon/hwmon1/pwm1   # 设置 PWM 为 150
  echo 1 > /sys/class/hwmon/hwmon1/pwm1_enable  # 切回自动模式（如果支持）
  ```

### APK 源切换

- **手动触发替换**：`/usr/bin/replace-apk-source.sh`
- **手动恢复**：`/usr/bin/restore-packages.sh`
- **查看当前源**：`cat /etc/apk/repositories`
- **禁用自动切换**：删除或重命名 `/etc/hotplug.d/iface/88-replace-apk-source` 和 `99-restore-package`。

### 编译脚本调试

- 运行 `diy-part1.sh` 前可先 `set -x` 查看详细执行过程。
- 分区修改功能默认注释，如需使用请取消 `modify_partition` 调用并设置 `append_size`。

---

## 依赖关系

- **通用部分**：`apk` 或 `opkg`，`bash`，`curl`（可选）
- **风扇控制**：Linux 内核 `hwmon` 子系统，PWM 风扇驱动（`kmod-hwmon-pwmfan`）
- **编译脚本**：`git`，`sed`，`awk`，`make`

---

## 许可证

- 大部分脚本基于 MIT 或 GPL-3.0 许可证，具体见各文件头注释。
- 本仓库整体采用 **GPL-3.0**。

---

## 贡献与支持

欢迎提交 Issue 或 Pull Request。如有特定硬件的适配需求，请提供相关 `hwmon` 路径信息。
