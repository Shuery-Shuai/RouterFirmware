# Banana Pi BPI-R4 构建资源

本目录包含面向 Banana Pi BPI-R4（设备 profile：`bananapi_bpi-r4`）的固件配置与构建脚本。目标平台为 MediaTek Filogic；通用逻辑见 [`../common/README.md`](../common/README.md)。

## 目录结构

| 路径 | 用途 |
| --- | --- |
| `configs/<固件>.config` | OpenWrt 或 ImmortalWrt 的基础构建配置 |
| `configs/<固件>.<版本>.diff.config` | 对基础配置应用的版本差异项 |
| `scripts/diy-part1.<固件>.sh` | Feeds 更新前执行的设备专属准备步骤 |
| `scripts/diy-part2.<固件>.sh` | Feeds 更新后、安装前执行的调整步骤 |
| `scripts/libs/` | BPI-R4 专属函数 |
| `scripts/mods/` | BPI-R4 专属源码修改函数 |

当前提供的配置文件：

| 固件 | 基础配置 | 版本差异配置 |
| --- | --- | --- |
| ImmortalWrt | `configs/immortalwrt.config` | `configs/immortalwrt.snapshots.diff.config`、`configs/immortalwrt.25.12.0.diff.config` |
| OpenWrt | `configs/openwrt.config` | `configs/openwrt.snapshots.diff.config`、`configs/openwrt.25.12.2.diff.config` |

版本差异配置是可选项：构建脚本按固件和版本查找匹配文件；没有对应文件时只使用基础配置。文件名表示配置适用目标，不代表该版本当前一定在站点发布。

## 构建脚本

### 第一阶段：`diy-part1`

构建流程在 Feeds 更新前运行对应的 `diy-part1.<固件>.sh`。该阶段会准备设备专属源码修改并获取所需第三方包仓库。BPI-R4 分区扩展调用默认处于注释状态；如需启用，先核对上游目标源码中的分区定义及设备存储布局。

### 第二阶段：`diy-part2`

构建流程在 Feeds 更新后、安装 Feeds 前运行对应的 `diy-part2.<固件>.sh`。脚本会整合自定义包，并按固件执行所需的配置或兼容性修补。两个发行版的处理并不完全相同，应修改对应文件，不要将其中一个版本的步骤直接复制到另一个版本。

具体可调用的通用函数由 [`../common/scripts/`](../common/README.md) 提供；BPI-R4 专属函数和修改分别位于本目录的 `scripts/libs/` 与 `scripts/mods/`。

## 配置与构建

通常由仓库构建脚本自动选择 profile 并应用配置，无需手动复制文件：

```shell
./scripts/make.sh immortalwrt snapshots bananapi_bpi-r4
./scripts/make.sh openwrt snapshots bananapi_bpi-r4
```

需要构建正式版时，将 `snapshots` 替换为目标版本号。基础配置用于提供固件选项；若版本差异文件存在，构建流程会将其叠加到基础配置。

修改配置后，应检查生成的 `.config` 并运行对应构建测试。尤其注意软件包名称、内核选项和第三方包依赖可能随上游分支或版本变化。

## 设备与安全提示

- 本目录仅提供 BPI-R4 profile 的配置；不要据此假设其他设备也受支持。
- 分区脚本会修改镜像/分区相关构建参数，启用前应确认升级和恢复方案。
- 第三方包由构建脚本拉取；修改仓库或版本时，建议固定并验证来源。
- 软件源公钥及公共运行时脚本位于 [`../common/`](../common/README.md)。

## 许可证

本仓库代码、脚本、配置与文档采用 [Apache License 2.0](https://github.com/Shuery-Shuai/RouterFirmware/blob/main/LICENSE)。
