# 通用构建与运行时资源

`common/` 放置不绑定特定设备的构建辅助脚本、固件运行时文件和 APK 软件包仓库公钥。设备专属资源位于 [`../bananapi_bpi-r4/`](../bananapi_bpi-r4/)。

## 目录结构

| 路径                  | 内容                                               |
| --------------------- | -------------------------------------------------- |
| `files/`              | 编入固件根文件系统的通用配置、热插拔钩子和管理脚本 |
| `scripts/libs/`       | DIY 构建脚本共用的函数库                           |
| `scripts/mods/`       | 可复用的源码修改函数                               |
| `keys/public-key.pem` | APK 仓库签名公钥                                   |

## 固件运行时文件

### 软件源切换

`files/usr/bin/replace-apk-source.sh` 可识别 APK 或 OPKG 软件包管理器，并根据官方源的连通性和性能选择官方源或镜像源。`files/etc/hotplug.d/iface/88-replace-apk-source` 在 WAN 接口 `ifup` 后延迟调用该脚本。

可通过环境变量覆盖镜像和检测参数，例如：

```shell
OPENWRT_MIRROR=https://mirrors.example.invalid/openwrt \
  /usr/bin/replace-apk-source.sh

MAX_LATENCY=3.0 MIN_SPEED=100000 \
  /usr/bin/replace-apk-source.sh
```

可配置项包括 `OPENWRT_MIRROR`、`IMMORTALWRT_MIRROR`、`MAX_LATENCY`、`MIN_SPEED` 和 `LOG_TO_SYSLOG`。运行前请确认镜像地址与设备所用发行版、版本和架构兼容。

### 软件包恢复

`files/usr/bin/restore-packages.sh` 用于恢复备份的软件包列表。`files/etc/hotplug.d/iface/99-restore-package` 只响应 WAN 接口 `ifup`，等待网络连通后再调用恢复脚本；它会在后台运行，避免阻塞 hotplug 处理。

默认备份文件为 `/etc/backup/installed_packages.txt`。可手动指定备份文件，或使用 `--help` 查看脚本选项：

```shell
/usr/bin/restore-packages.sh --help
/usr/bin/restore-packages.sh /path/to/installed_packages.txt
```

恢复过程的日志默认写入 `/var/log/`，无法写入时回退到 `/tmp/`。安装过程可能修改系统配置或触发重启；执行前请先检查备份文件内容并确保网络可用。

### APK feeds 配置

固件构建时，`scripts/config-management.sh` 根据当前固件、版本及 `.config` 中的 target、subtarget 和软件包架构，生成 `files/etc/apk/repositories.d/customfeeds.list`。地址指向站点上对应的快照目录或 `releases/<版本>/` 目录。

一般不需要手工维护该文件。设备上的配置说明见 [`files/etc/apk/repositories.d/`](./files/etc/apk/repositories.d/)。

### 其他通用文件

`files/` 还包含 Nginx 配置及 SSH 配置片段。构建流程会将这些文件同步到固件源码的 `files/` 目录；如需调整，请先确认修改会影响哪些发行版。

## 构建脚本库

`scripts/libs/index.sh` 会加载同目录下的函数库；`scripts/mods/index.sh` 会加载可复用的源码修改函数。DIY 脚本通过 source 这两个索引文件使用对应函数。

- `libs/`：下载、feed、Git、日志、Makefile、软件包更新、分区、符号链接和版本处理等工具。
- `mods/`：Rust 构建配置调整、LuCI 集合补丁、qBittorrent 依赖处理、执行权限修复、默认 Shell、easyupdate 和 DAE 等修改。

这些脚本由项目构建流程调用，不是面向路由器终端的独立管理命令。

## 公钥

`keys/public-key.pem` 是设备验证 APK 仓库签名所需的公钥。它不包含私钥，也不是 HTTPS/TLS 证书。不要将私钥添加到此目录。

## 修改与验证

修改运行时文件后，应验证目标固件中的路径、执行权限及脚本语法；修改构建函数后，应至少运行相关的离线回归测试。完整构建入口与配置说明见仓库根目录 [`README.md`](https://github.com/Shuery-Shuai/RouterFirmware/blob/main/README.md)。
