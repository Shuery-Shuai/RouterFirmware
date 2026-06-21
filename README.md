# 路由器固件构建项目

[![Router Firmware Builder](https://github.com/Shuery-Shuai/RouterFirmware/actions/workflows/rtfw-builder.yml/badge.svg)](https://github.com/Shuery-Shuai/RouterFirmware/actions/workflows/rtfw-builder.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

路由器固件自动构建系统，支持自定义固件、版本、设备，并在 Github 工作流构建后上传至 Github 页面部署。

## 目录

- [自动化构建与部署](#自动化构建与部署)
- [支持设备](#支持设备)
- [项目特点](#项目特点)
- [固件内置组件](#固件内置组件)
- [支持安装的扩展包](#支持安装的扩展包)
- [快速开始](#快速开始)
- [Docker 构建支持](#docker-构建支持)
- [VS Code Dev Container](#vs-code-dev-container)
- [脚本文档](#脚本文档)
- [系统工具脚本](#系统工具脚本)
- [项目结构](#项目结构)
- [贡献指南](#贡献指南)
- [许可证](#许可证)
- [致谢](#致谢)

## 自动化构建与部署

本项目通过 GitHub Actions 实现了全自动的固件编译、更新检测与部署流水线。

### 主要工作流

| 工作流文件名                     | 用途                                               | 触发方式                                                                                                                                            |
| -------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rtfw-builder.yml`               | 编译固件并部署到 GitHub Pages                      | ① `push` 到 `main` 分支或版本标签<br>② `repository_dispatch` 外部触发<br>③ 手动 `workflow_dispatch`（可配置固件类型、版本、设备、menuconfig、缓存） |
| `immortalwrt-update-checker.yml` | 每 3 天检查 ImmortalWrt 上游源码更新，自动触发编译 | ① 定时触发（UTC 16:00）<br>② 手动强制触发                                                                                                           |
| `openwrt-update-checker.yml`     | 每周五检查 OpenWrt 上游源码更新，自动触发编译      | ① 定时触发（UTC 2:00）<br>② 手动强制触发                                                                                                            |

### 编译流程亮点

- **智能参数解析**：同时支持手动输入、外部 API 调用和默认值
- **历史产物复用**：下载上一次成功构建的产物，跳过 `assets/` 目录，加速增量编译
- **缓存加速**：可选的 ccache + 工具链缓存，大幅缩短重复构建时间
- **自动部署**：编译成功后，固件及索引页自动发布到 GitHub Pages
- **运行记录清理**：自动保留最近 7 天的工作流日志

## 支持设备

- **Bananapi BPI-R4** - MediaTek MT7988A 四核 ARM Cortex-A73 路由器

## 项目特点

### 🚀 核心特性

- ✅ 基于 **ImmortalWrt/OpenWrt** 最新源码构建
- ✅ 使用**测试版内核**，获得最新硬件支持
- ✅ **极简固件设计**，仅包含基础组件，性能优先
- ✅ 针对 **BPI-R4 硬件优化**的内核配置
- ✅ **自动化构建流程**，脚本驱动的完整编译流程（支持 GitHub Actions 本地模拟）
- ✅ **Google Shell Style Guide** 规范的代码注释

### 📦 智能软件包管理

- **自动恢复已安装软件包** - 固件更新时保留用户安装的软件包
- **智能网络检测** - 自动测试多个镜像源，优选最快源
- **批量安装优化** - 优先批量安装，失败后逐个重试
- **实时进度显示** - 安装过程中显示详细进度和状态

> [!TIP]
>
> **首次使用建议：**
>
> - 安装后立即修改默认密码（默认无密码）
> - 定期备份配置文件到本地
> - 如遇网络问题，可尝试重置防火墙设置
> - 查看日志文件：`/var/log/package-restore-*.log`

### 🔄 自动更新支持

系统内置 **easyupdate** 工具，支持一键在线升级固件。

> [!WARNING]
>
> **手动更新注意事项：**
>
> - 更新固件前，务必在更新选项中勾选 **"备份已安装软件包"**
> - 更新完成后系统将自动恢复之前安装的软件包
> - 软件包恢复过程中（约 5-15 分钟）请勿断电或重启
> - 恢复失败时可查看日志：`/var/log/package-restore-*.log`

### 📁 特殊配置保留

> [!IMPORTANT]
>
> **使用 qbittorrent-original 时的额外配置：**
>
> qBittorrent 的配置文件存储在 `/etc/qbittorrent/` 目录，需要手动添加到系统升级保存列表：
>
> 1. 编辑配置文件：
>
>    ```bash
>    vi /etc/sysupgrade.conf
>    ```
>
> 2. 添加以下内容：
>
>    ```conf
>    /etc/qbittorrent/
>    ```
>
> 3. 保存后，升级固件时该目录的配置将自动保留

## 固件内置组件

本项目支持多个固件版本，不同版本内置的组件略有差异。下表列出各版本的详细配置：

### OpenWrt 固件

#### OpenWrt Snapshots（开发版）

**基础特性：**

- ✅ 使用**测试版内核** (`CONFIG_TESTING_KERNEL=y`)
- ✅ 基于 **mbedtls** 加密库（体积小、性能优）
- ✅ 内置 DAE 内核支持（BPF、XDP）

**内置组件：**

| 分类     | 软件包                | 说明                          |
| -------- | --------------------- | ----------------------------- |
| 界面相关 | luci-theme-argon      | Argon 主题（现代化深色主题）  |
|          | luci-app-argon-config | Argon 主题配置工具            |
| 网络组件 | luci-nginx            | Nginx 前端引擎（替代 uhttpd） |
|          | luci-app-nginx        | Nginx 前端管理界面            |
| 系统管理 | luci-app-diskman      | 磁盘管理工具                  |

#### OpenWrt 25.12.2（稳定版）

**基础特性：**

- ✅ 使用**稳定版内核**（不启用 TESTING_KERNEL）
- ✅ 基于 **mbedtls** 加密库
- ✅ 内置 DAE 内核支持（BPF、XDP）

**内置组件：**

与 Snapshots 版本相同（Argon 主题 + Nginx + Diskman）

---

### ImmortalWrt 固件

#### ImmortalWrt Snapshots（开发版）

**基础特性：**

- ✅ 使用**稳定版内核**（不启用 TESTING_KERNEL）
- ✅ 基于 **OpenSSL** 加密库（兼容性好）
- ✅ 内置 **bridger** 智能网络分流
- ✅ 内置 **automount** 自动挂载
- ✅ 使用 **dnsmasq-full** 完整版
- ✅ 使用 **wpad-openssl** 无线认证
- ✅ 内置中文语言包 (`default-settings-chn`)

**内置组件：**

| 分类     | 软件包                | 说明                          |
| -------- | --------------------- | ----------------------------- |
| 界面相关 | luci-theme-argon      | Argon 主题（现代化深色主题）  |
|          | luci-app-argon-config | Argon 主题配置工具            |
| 网络组件 | luci-nginx            | Nginx 前端引擎（替代 uhttpd） |
|          | luci-app-nginx        | Nginx 前端管理界面            |

#### ImmortalWrt 25.12.0-rc2（候选版）

**基础特性：**

- ✅ 使用**稳定版内核**
- ✅ 基于 **OpenSSL** 加密库
- ✅ 内置 **bridger** + **automount**
- ✅ 内置 **autocore** 系统自动优化
- ✅ 内置 **block-mount** 块设备挂载
- ✅ 使用 **dnsmasq-full** + **wpad-openssl**
- ✅ 内置中文语言包

**内置组件：**

与 Snapshots 版本相同（Argon 主题 + Nginx）

---

### 版本选择建议

| 固件版本                  | 适用场景                   | 内核版本 | 加密库  | 特色功能         |
| ------------------------- | -------------------------- | -------- | ------- | ---------------- |
| **OpenWrt Snapshots**     | 追求最新硬件支持和内核特性 | 测试版   | mbedtls | 最新内核、体积小 |
| **OpenWrt 25.12.2**       | 追求稳定性和长期使用       | 稳定版   | mbedtls | 稳定可靠、体积小 |
| **ImmortalWrt Snapshots** | 追求中文优化和国内网络环境 | 稳定版   | OpenSSL | 中文优化、分流   |
| **ImmortalWrt 25.12.0**   | 追求稳定的中文固件         | 稳定版   | OpenSSL | 中文优化、稳定   |

## 支持安装的扩展包

所有固件版本都预编译了以下扩展包，可通过 `opkg install` 或 LuCI 界面安装：

### OpenWrt 版本扩展包

#### OpenWrt 系统工具

| 软件包              | 说明                         | Snapshots | 25.12.2 |
| ------------------- | ---------------------------- | --------- | ------- |
| bpi-r4-pwm-fan      | BPI-R4 PWM 风扇控制          | ✅        | ✅      |
| luci-app-easyupdate | 系统简易更新工具             | ✅        | ✅      |
| luci-app-fancontrol | 简易风扇控制界面             | ✅        | ✅      |
| luci-app-fanxpert   | 风扇智能控制（温度曲线调节） | ✅        | ✅      |

#### OpenWrt 网络应用

| 软件包             | 说明                       | Snapshots | 25.12.2 |
| ------------------ | -------------------------- | --------- | ------- |
| luci-app-dae       | 大鹅网络工具（高性能代理） | ✅        | ✅      |
| luci-app-daed      | 大鹅面板（DAE 图形界面）   | ✅        | ✅      |
| luci-app-ddns-go   | DDNS-Go 动态域名服务       | ✅        | ✅      |
| luci-app-docker    | Docker 容器管理            | ✅        | ✅      |
| luci-app-lucky     | 大吉内网穿透工具           | ✅        | ✅      |
| luci-app-openclash | OpenClash 代理工具         | ✅        | ✅      |
| luci-app-zerotier  | ZeroTier 虚拟网络          | ✅        | ✅      |

#### OpenWrt 下载工具

| 软件包               | 说明               | Snapshots | 25.12.2 |
| -------------------- | ------------------ | --------- | ------- |
| luci-app-qbittorrent | qBittorrent 下载器 | ✅        | ✅      |

---

### ImmortalWrt 版本扩展包

#### ImmortalWrt 系统工具

| 软件包              | 说明                         | Snapshots | 25.12.0-rc2 |
| ------------------- | ---------------------------- | --------- | ----------- |
| luci-app-easyupdate | 系统简易更新工具             | ✅        | ✅          |
| luci-app-fancontrol | 简易风扇控制界面             | ✅        | ✅          |
| luci-app-fanxpert   | 风扇智能控制（温度曲线调节） | ✅        | ✅          |
| fan2go              | 风扇智能控制守护进程         | ✅        | ✅          |

#### ImmortalWrt 网络应用

| 软件包             | 说明                       | Snapshots | 25.12.0-rc2 |
| ------------------ | -------------------------- | --------- | ----------- |
| luci-app-dae       | 大鹅网络工具（高性能代理） | ✅        | ✅          |
| luci-app-lucky     | 大吉内网穿透工具           | ✅        | ✅          |
| luci-app-openclash | OpenClash 代理工具         | ✅        | ✅          |

#### ImmortalWrt 下载工具

| 软件包                        | 说明                   | Snapshots | 25.12.0-rc2 |
| ----------------------------- | ---------------------- | --------- | ----------- |
| luci-app-qbittorrent-original | qBittorrent 原版下载器 | ✅        | ✅          |

---

### 设备专属支持

#### Bananapi BPI-R4

所有固件版本都针对 BPI-R4 硬件进行了优化，内置以下硬件驱动：

| 组件类型 | 驱动模块                 | 说明                    |
| -------- | ------------------------ | ----------------------- |
| 无线网卡 | kmod-mt7996-firmware     | MT7996 WiFi 7 驱动      |
|          | kmod-mt7996-233-firmware | MT7996 国家码固件       |
|          | mt7988-wo-firmware       | MT7988 Wireless Offload |
| 硬件监控 | kmod-hwmon-pwmfan        | PWM 风扇监控            |
|          | kmod-i2c-mux-pca954x     | I2C 多路复用器          |
|          | kmod-eeprom-at24         | EEPROM 读取             |
|          | kmod-rtc-pcf8563         | RTC 实时时钟            |
| 网络硬件 | kmod-sfp                 | SFP 光模块支持          |
|          | kmod-phy-aquantia        | Aquantia 万兆网卡 PHY   |
| USB      | kmod-usb3                | USB 3.0 支持            |
| 加密加速 | kmod-crypto-hw-safexcel  | 硬件加密加速            |
| 文件系统 | e2fsprogs                | ext2/3/4 文件系统工具   |
|          | f2fsck / mkf2fs          | F2FS 文件系统工具       |

> [!NOTE]
>
> **软件包安装方式：**
>
> 1. **通过 LuCI 界面**：系统 → 软件包 → 搜索并安装
> 2. **通过命令行**：`opkg update && opkg install <软件包名>`
> 3. **批量安装示例**：`opkg install luci-app-docker luci-app-openclash luci-app-qbittorrent`
>
> 如需添加其他软件包支持，请在 [Issues](https://github.com/Shuery-Shuai/RouterFirmware/issues) 中提出需求。

## 快速开始

### 本地构建

```bash
# 克隆项目
git clone https://github.com/Shuery-Shuai/RouterFirmware.git
cd RouterFirmware

# 构建 ImmortalWrt 快照固件
./scripts/make.sh immortalwrt snapshots

# 构建 OpenWrt 快照固件
./scripts/make.sh openwrt snapshots
```

### 参数说明

```bash
./scripts/make.sh <发行版> <版本> [设备]
```

- `<发行版>`: `immortalwrt` 或 `openwrt`
- `<版本>`: 目标版本号或 `snapshots`，如 `25.12.2`、`24.10.3`、`snapshots`
- `[设备]`: 可选，默认为 `bananapi_bpi-r4`

### 构建产物

编译完成后，固件文件位于：

```text
public/firmware/<发行版>/<版本>/<设备>/
```

## Docker 构建支持

使用 Docker 在隔离环境中构建固件，避免本地依赖冲突。

### 方法一：直接构建（推荐）

```bash
# 1. 构建 Docker 镜像
docker build -t routerfirmware-builder .

# 2. 运行构建（一次性）
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  routerfirmware-builder \
  bash -lc "./scripts/make.sh immortalwrt snapshots"
```

### 方法二：交互式容器

```bash
# 1. 启动交互式容器
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  routerfirmware-builder

# 2. 在容器内运行构建命令
./scripts/make.sh immortalwrt snapshots
```

### Docker 构建说明

- **磁盘空间**: 建议至少 50GB 可用空间
- **内存**: 建议 8GB 以上
- **网络**: 首次构建需从 GitHub 克隆源码，耗时较长
- **持久化**: 源码和构建产物会保存在宿主机当前目录

## VS Code Dev Container

本项目支持 **VS Code Remote - Containers**，提供开箱即用的开发环境。

### 使用步骤

1. **安装插件**
   - 安装 [Remote - Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) 扩展

2. **打开容器**
   - 在 VS Code 中打开项目根目录
   - 按 `F1`，选择 `Remote-Containers: Reopen in Container`
   - 等待容器启动（首次启动需构建镜像）

3. **开始构建**

   ```bash
   ./scripts/make.sh immortalwrt snapshots
   ```

### Dev Container 特性

- ✅ 自动配置构建环境
- ✅ 工作区挂载到 `/workspace`
- ✅ 内置 Git、Bash 等开发工具
- ✅ 支持容器内 Docker 构建

## 脚本文档

所有脚本遵循 **Google Shell Style Guide** 规范，包含详细的中文注释。

### 核心构建脚本

| 脚本文件                       | 功能说明                           |
| ------------------------------ | ---------------------------------- |
| `scripts/make.sh`              | 主入口：协调整个构建流程           |
| `scripts/common.sh`            | 通用函数库：日志、工具函数         |
| `scripts/source-management.sh` | 源码管理：克隆、切换版本           |
| `scripts/feeds-management.sh`  | Feeds 管理：更新、安装依赖         |
| `scripts/config-management.sh` | 配置管理：生成 .config 文件        |
| `scripts/copy-pre-files.sh`    | 复制编译前配置：DIY 脚本、配置文件 |
| `scripts/build.sh`             | 执行编译：多线程编译、错误处理     |
| `scripts/copy-bin-files.sh`    | 复制产物：固件、哈希、元数据       |
| `scripts/generate-index.sh`    | 生成索引：JSON 格式的文件列表      |

### DIY 自定义脚本

| 脚本文件                   | 功能说明                       |
| -------------------------- | ------------------------------ |
| `diy-part1.sh`             | 第一阶段：feeds 更新前执行     |
| `diy-part2.openwrt.sh`     | 第二阶段：OpenWrt 专用配置     |
| `diy-part2.immortalwrt.sh` | 第二阶段：ImmortalWrt 专用配置 |

## 系统工具脚本

固件内置的系统管理脚本，位于 `/usr/bin/`：

### restore-packages.sh

**软件包自动恢复脚本** - 系统更新后自动恢复已安装的软件包

**功能特性：**

- ✅ 预安装检查：避免重复安装
- ✅ 智能网络检测：测试多个镜像源
- ✅ 自动网络修复：临时修改 DNS 和防火墙
- ✅ 批量安装优化：批量安装 + 失败重试
- ✅ 实时进度显示：`[12/50] 安装 curl... [成功]`
- ✅ 安装验证：确保所有包正确安装
- ✅ 自动清理：退出时恢复原始配置

**环境变量配置：**

```bash
# 自定义 DNS 服务器
DNS_PRIMARY=114.114.114.114 restore-packages

# 禁用自动重启
AUTO_REBOOT=false restore-packages

# 指定备份文件
restore-packages /data/custom_backup.txt
```

**查看日志：**

```bash
tail -f /var/log/package-restore-*.log
```

### replace-apk-source.sh

**软件源智能替换脚本** - 根据网络质量自动选择最优软件源

**功能特性：**

- ✅ 自动检测包管理器（APK/OPKG）
- ✅ 网络质量评估（延迟 + 速度）
- ✅ 智能源切换（官方源可用时优先使用）
- ✅ 支持自定义镜像源和阈值

**决策逻辑：**

```pre
测试官方源 → 延迟 < 2.0s 且速度 > 200KB/s
  ├─ 是 → 使用官方源
  └─ 否 → 切换到镜像源
```

**环境变量配置：**

```bash
# 自定义镜像源
OPENWRT_MIRROR=https://mirrors.aliyun.com/openwrt replace-apk-source.sh

# 调整性能阈值
MAX_LATENCY=3.0 MIN_SPEED=100000 replace-apk-source.sh

# 启用 syslog 日志
LOG_TO_SYSLOG=1 replace-apk-source.sh
```

## 项目结构

```pre
RouterFirmware/
├── .github/workflows/              # GitHub Actions 工作流
│   ├── rtfw-builder.yml            # 固件构建与部署
│   ├── immortalwrt-update-checker.yml # ImmortalWrt 更新检测
│   └── openwrt-update-checker.yml  # OpenWrt 更新检测
├── scripts/                        # 构建脚本（含详细注释）
│   ├── make.sh                     # 主构建脚本
│   ├── common.sh                   # 通用函数库
│   ├── source-management.sh        # 源码管理
│   ├── feeds-management.sh         # Feeds 管理
│   ├── config-management.sh        # 配置管理
│   ├── copy-pre-files.sh           # 复制编译前文件
│   ├── build.sh                    # 执行编译
│   ├── copy-bin-files.sh           # 复制编译产物
│   └── generate-index.sh           # 生成文件索引
├── public/                         # 公共资源
│   ├── assets/                     # 设备配置文件
│   │   ├── bananapi_bpi-r4/        # BPI-R4 配置
│   │   │   ├── diy-part1.sh        # DIY 脚本第一阶段
│   │   │   ├── diy-part2.openwrt.sh
│   │   │   └── diy-part2.immortalwrt.sh
│   │   └── common/                 # 通用配置
│   │       └── files/              # 固件内置文件
│   │           └── usr/bin/        # 系统工具脚本
│   │               ├── restore-packages.sh
│   │               └── replace-apk-source.sh
│   └── firmware/                   # 构建产物输出目录（GitHub Pages 部署源）
├── sources/                        # 源码目录（构建时生成）
│   ├── immortalwrt/                # ImmortalWrt 源码
│   └── openwrt/                    # OpenWrt 源码
├── Dockerfile                      # Docker 构建镜像
├── .devcontainer/                  # VS Code Dev Container 配置
└── README.md                       # 本文件
```

## 贡献指南

欢迎贡献代码、报告问题或提出建议！

### 代码规范

- **Shell 脚本**: 遵循 [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- **注释**: 使用中文注释，详细说明功能和用法
- **函数注释**: 包含 Globals、Arguments、Outputs、Returns、Examples
- **测试**: 使用 `bash -n` 检查语法

### 提交流程

1. Fork 本项目
2. 创建特性分支：`git checkout -b feature/your-feature`
3. 提交更改：`git commit -am 'Add some feature'`
4. 推送到分支：`git push origin feature/your-feature`
5. 提交 Pull Request

### 报告问题

在 [Issues](https://github.com/Shuery-Shuai/RouterFirmware/issues) 中提交问题时，请包含：

- 问题描述和复现步骤
- 使用的固件版本和设备型号
- 相关日志输出（如有）

## 许可证

- 本项目脚本采用 [MIT License](LICENSE)
- 本项目 GitHub Actions 工作流改编自 [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)，采用 MIT License

## 致谢

- **[ImmortalWrt](https://github.com/immortalwrt/immortalwrt)** - 感谢 ImmortalWrt 项目团队的持续贡献
- **[OpenWrt](https://openwrt.org/)** - 感谢 OpenWrt 社区的开源精神
- **[P3TERX](https://github.com/P3TERX)** - 感谢提供 Actions 工作流模板
- **[sundaqiang](https://github.com/sundaqiang)** - 感谢提供构建流程参考

---

<div align="center">

**⭐ 如果这个项目对你有帮助，请给个 Star！**

[报告问题](https://github.com/Shuery-Shuai/RouterFirmware/issues) · [提出建议](https://github.com/Shuery-Shuai/RouterFirmware/issues) · [贡献代码](https://github.com/Shuery-Shuai/RouterFirmware/pulls)

</div>
