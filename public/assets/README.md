# 构建资源说明

本目录存放由 RouterFirmware 构建流程使用并随站点发布的配置、脚本和静态资源。资源按用途拆分；请查看对应目录中的说明，不要直接修改生成后的固件或发布文件。

## 目录

| 目录                                     | 用途                                                  |
| ---------------------------------------- | ----------------------------------------------------- |
| [`common/`](./common/)                   | 多个固件共用的运行时文件、构建辅助脚本和 APK 仓库公钥 |
| [`bananapi_bpi-r4/`](./bananapi_bpi-r4/) | Banana Pi BPI-R4 的配置与设备专用构建脚本             |
| [`site/`](./site/)                       | 下载站页面使用的样式与前端脚本                        |

## 构建流程中的使用方式

主构建脚本会根据固件和设备 profile 从本目录读取配置与 DIY 脚本，并将设备运行时文件放入固件源码树。通常无需手动复制这些文件；从仓库根目录运行：

```shell
./scripts/make.sh immortalwrt snapshots
```

默认固件、版本和 profile 由 [`config/site.json`](https://github.com/Shuery-Shuai/RouterFirmware/blob/main/config/site.json) 提供。要修改固件配置，请编辑 `bananapi_bpi-r4/configs/` 中的基础配置或版本差异配置；要修改多个设备共用的构建逻辑，则编辑 `common/scripts/`。

> [!WARNING]
>
> `common/keys/public-key.pem` 是软件包仓库的公钥，可随固件和站点发布。对应私钥不得放入 `public/assets/` 或提交到仓库。

## 许可证

本仓库代码、脚本、配置与文档采用 [Apache License 2.0](https://github.com/Shuery-Shuai/RouterFirmware/blob/main/LICENSE)。
