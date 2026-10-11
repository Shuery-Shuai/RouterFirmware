# APK 自定义软件源

固件构建时，项目会根据所选固件、版本、target 和软件包架构生成 `customfeeds.list`。该文件包含对应固件仓库的 target、base、luci 和 packages 源，路径与下载站发布目录一致：

- 快照版：`/<固件>/snapshots/...`
- 正式版：`/<固件>/releases/<版本>/...`

因此通常无需手动填写目录或版本号。构建生成的 URL 以 `https://rtfw.shuery.lssa.fun/` 为站点根地址。

如果要在设备上增加额外 APK 源，请按设备当前系统的 APK 配置格式添加到单独的 `.list` 文件中，并先确认软件包与固件版本、架构兼容。不要用手工修改覆盖构建生成的 `customfeeds.list`，否则后续固件重建时会被重新生成。

> [!WARNING]
>
> 安装软件包前请确认源地址可信，并确保使用与设备固件匹配的软件包。APK 仓库签名公钥见 `/etc/apk/keys/public-key.pem`。
