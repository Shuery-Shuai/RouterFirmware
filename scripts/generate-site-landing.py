#!/usr/bin/env python3
"""生成站点落地页（中文默认、可切换英文）与各发行版落地页。

官方发布站首页是**手写** HTML（栏目：Stable Release / Old Stable Release /
Development Snapshots / Release Archive）。本脚本按同样的栏目骨架生成我们自己的
首页，差别在于：内容来自 `config/site.json`、双语内嵌，并且**只链接发布树里真实
存在的目录**——页面不产生死链。

三个事实来源，各管一件事：
  * config/site.json —— 意图：跟哪些发行版、当前稳定版 / 旧稳定版是谁、站点文案
    与站点装饰（样式表 / 公钥 / 脚本路径）。脚本里不写死任何发行版或设备数据。
  * 发布树（public/）—— 现实：某个版本目录是否真的发布了（含 targets/ 才算）。
  * --upstream（可选，由 fetch-upstream-versions.py 生成）—— 官方如何标定
    stable / oldstable，用于「本地尚未构建」时给出准确提示、并标注本地多出来的
    版本。缺失时退化为纯声明渲染（本地预览不会因此失败）。

渲染规则:
  * 稳定版 / 旧稳定版：按声明渲染；<id>/releases/<版本>/targets/ 存在才给链接，
    否则渲染为纯文本 + 提示（官方已发布 X / 本镜像尚未构建）；
  * 开发快照：<id>/snapshots/targets/ 存在才给链接，同样不产生死链；
  * 版本归档：从发布树派生（releases/ 下除声明的 stable / oldstable 之外的真实
    目录，按版本号倒序），所以不需要手工记账，也不会指向已被裁剪的版本；
  * 发行版目录整体不存在时仍渲染其栏目（提示未构建），但不给「浏览全部文件」链接。

用法:
  ./generate-site-landing.py [--public-dir=public] [--config=config/site.json]
                             [--upstream=upstream-versions.json] [--quiet]

生成物:
  <public-dir>/index.html               站点首页
  <public-dir>/<firmware>/index.html    各发行版首页（目录存在才写）

依赖: 仅 Python 标准库（site_i18n / site_versions 为同目录模块）。
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path

from site_i18n import LANG_TOGGLE, SITE_JS_PATH, asset_url, icon_tags, line, title_tag
from site_versions import parse_version_key

# 发行版栏目中「稳定版 / 旧稳定版」两个声明的键与文案
RELEASE_ROWS = (
    ("stable", "最新稳定版", "current stable"),
    ("oldstable", "旧稳定版", "security fixes only"),
)


def warn(message: str) -> None:
    print(f"警告: {message}", file=sys.stderr)


def local_facts(public_dir: Path, firmware: dict) -> dict:
    """扫描发布树，得到该固件本地真实可链接的内容（现实）。"""
    firmware_dir = public_dir / firmware["id"]
    versions: dict[str, tuple[int, ...]] = {}
    releases = firmware_dir / "releases"
    if releases.is_dir():
        for entry in releases.iterdir():
            # 只有含 targets/ 的版本目录才可链接——链接目标就是它的 targets/
            if not entry.is_dir() or not (entry / "targets").is_dir():
                continue
            key = parse_version_key(entry.name)
            if key is not None:
                versions[entry.name] = key
    return {
        "exists": firmware_dir.is_dir(),
        "versions": versions,
        "snapshots": (firmware_dir / "snapshots" / "targets").is_dir(),
    }


def upstream_firmware(upstream: dict, firmware_id: str) -> dict:
    """取上游事实里某个固件的条目（没有就返回空表）。"""
    firmwares = upstream.get("firmwares") if isinstance(upstream, dict) else None
    entry = firmwares.get(firmware_id) if isinstance(firmwares, dict) else None
    return entry if isinstance(entry, dict) else {}


def release_item(firmware: dict, key: str, label_zh: str, label_en: str,
                 facts: dict, upstream: dict) -> str:
    """一条发行版条目：本地有就链接，没有就纯文本 + 提示（绝不产生死链）。"""
    version = str(firmware[key])
    firmware_id = firmware["id"]
    href = f"/{firmware_id}/releases/{version}/targets/"
    if version in facts["versions"]:
        return (f'<li>{line(label_zh, label_en)}：<strong>'
                f'<a href="{html.escape(href)}">{html.escape(version)}</a></strong></li>')
    official = upstream.get(key) or ""
    if official and official != version:
        hint_zh = f"官方已发布 {official}，本镜像尚未构建"
        hint_en = f"official release {official} is not built here yet"
    else:
        hint_zh, hint_en = "本镜像尚未构建", "not built here yet"
    return (f'<li>{line(label_zh, label_en)}：{html.escape(version)} '
            f'<small>（{line(hint_zh, hint_en)}）</small></li>')


def firmware_sections(config: dict, firmware: dict, public_dir: Path, upstream: dict) -> str:
    """一个发行版的栏目（稳定版 / 旧稳定版 / 开发快照 / 版本归档）。

    只产出栏目内容，不包外层 div：官方首页是「一个内容 div + 栏目间 <hr/> 分隔」，
    表面样式由官方 CSS 的 .container>div 提供。栏目之间用 <hr/> 由调用方拼接。
    """
    firmware_id = firmware["id"]
    facts = local_facts(public_dir, firmware)
    upstream_entry = upstream_firmware(upstream, firmware_id)
    parts: list[str] = [f'<h2>{html.escape(firmware.get("title", firmware_id))}</h2>']

    labels = {"stable": ("稳定版", "Stable Release"), "oldstable": ("旧稳定版", "Old Stable Release")}
    for key, row_zh, row_en in RELEASE_ROWS:
        version = firmware.get(key)
        if not version:
            continue
        parts.append("<h3>" + line(*labels[key], "span") + "</h3>")
        parts.append("<ul>")
        parts.append(release_item(firmware, key, row_zh, row_en, facts, upstream_entry))
        parts.append("</ul>")

    if firmware.get("snapshots"):
        parts.append("<h3>" + line("开发快照", "Development Snapshots", "span") + "</h3>")
        parts.append("<ul>")
        lead = line("随上游更新，可能不稳定", "tracking upstream, may be unstable")
        if facts["snapshots"]:
            parts.append(f'<li>{lead}：<strong>'
                         f'<a href="/{firmware_id}/snapshots/targets/">snapshots</a></strong></li>')
        else:
            parts.append(f'<li>{lead}：snapshots '
                         f'<small>（{line("本镜像尚未构建", "not built here yet")}）</small></li>')
        parts.append("</ul>")

    archived = sorted((name for name in facts["versions"]
                       if name not in {firmware.get("stable"), firmware.get("oldstable")}),
                      key=lambda name: facts["versions"][name], reverse=True)
    if archived:
        official_versions = [item for item in upstream_entry.get("versions", [])
                             if isinstance(item, str)]
        parts.append("<h3>" + line("版本归档", "Release Archive", "span") + "</h3>")
        parts.append("<ul>")
        for version in archived:
            suffix = ""
            if official_versions and version not in official_versions:
                suffix = " <small>" + line("本地构建", "local build") + "</small>"
            parts.append(f'<li>{line("历史版本", "archived release")}：<strong>'
                         f'<a href="/{firmware_id}/releases/{html.escape(version)}/targets/">'
                         f'{html.escape(version)}</a></strong>{suffix}</li>')
        parts.append("</ul>")

    package_key = config.get("package_key")
    if package_key:
        parts.append(f'<p><small>{line("软件包仓库公钥", "Package repository public key")}：'
                     f'<a href="{html.escape(package_key)}">{html.escape(package_key)}</a></small></p>')
    if facts["exists"]:
        parts.append(f'<p><small><a href="/{firmware_id}/">' +
                     line("浏览该发行版的全部文件", "Browse all files of this firmware") + "</a></small></p>")
    return "\n".join(parts)


def page_shell(public_dir: Path, title: str, title_en: str, body: str,
               stylesheet: str = "") -> str:
    head = [
        "<!DOCTYPE html>",
        "<html lang='zh-CN'>",
        "<head>",
        "<meta charset='utf-8'/>",
        "<meta name='viewport' content='width=device-width, initial-scale=1.0'/>",
    ]
    if stylesheet:
        head.append(f"<link rel='stylesheet' href='{html.escape(stylesheet, quote=True)}' />")
    head += [
        f"<link rel='stylesheet' href='{asset_url(public_dir, 'assets/site/base.css')}' />",
        icon_tags(public_dir),
        title_tag(title, title_en),
        "</head>",
        "",
        "<body>",
        '<div class="container">',
        LANG_TOGGLE,
        body,
        "<footer>",
        line("本页由构建流程自动生成，内容来自 config/site.json。",
             "This page is generated at build time from config/site.json."),
        "</footer>",
        "</div>",
        f"<script src='{asset_url(public_dir, SITE_JS_PATH)}' defer></script>",
        "</body>",
        "</html>",
        "",
    ]
    return "\n".join(head)


def render_index(config: dict, public_dir: Path, upstream: dict) -> str:
    body = [
        "<h1>" + line(config.get("title", "固件下载"), "Firmware Downloads", "span") + "</h1>",
        "<p>" + line(config.get("description", ""), config.get("description_en", ""), "span") + "</p>",
        "<div>",  # 官方首页只有一个内容 div，栏目之间用 <hr/> 分隔
    ]
    blocks = [firmware_sections(config, fw, public_dir, upstream)
              for fw in config.get("firmwares", []) if isinstance(fw, dict)]
    scripts_path = config.get("scripts_path")
    if scripts_path:
        blocks.append(
            "<h2>" + line("构建脚本与配置", "Build scripts and configs", "span") + "</h2>"
            "<p>" + line("设备脚本、配置与说明文档位于", "Device scripts, configs and docs live under", "span")
            + f' <a href="{html.escape(scripts_path)}">{html.escape(scripts_path)}</a>。</p>'
        )
    body.append("\n<hr/>\n".join(blocks))
    body.append("</div>")
    return page_shell(public_dir, config.get("title", "固件下载"),
                      config.get("title_en") or "Firmware Downloads", "\n".join(body),
                      str(config.get("stylesheet") or ""))


def render_firmware_index(config: dict, firmware: dict, public_dir: Path, upstream: dict) -> str:
    firmware_id = firmware["id"]
    body = [
        "<h1>" + html.escape(firmware.get("title", firmware_id)) + "</h1>",
        '<p><small><a href="/">' + line("← 返回站点首页", "← Back to site home", "span") + "</a></small></p>",
        "<div>",
        firmware_sections(config, firmware, public_dir, upstream),
        "</div>",
    ]
    return page_shell(public_dir, firmware.get("title", firmware_id),
                      firmware.get("title_en") or firmware.get("title", firmware_id),
                      "\n".join(body), str(config.get("stylesheet") or ""))


def load_upstream(path: Path | None) -> dict:
    """读取上游版本事实（可选）；缺失或格式不符时告警并退化为纯声明渲染。"""
    if path is None:
        return {}
    if not path.is_file():
        warn(f"上游版本事实不存在，退化为纯声明渲染: {path}")
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"上游版本事实无法解析，退化为纯声明渲染: {exc}")
        return {}
    if not isinstance(data, dict) or not isinstance(data.get("firmwares"), dict):
        warn(f"上游版本事实格式不符（缺少 firmwares），退化为纯声明渲染: {path}")
        return {}
    for firmware_id, entry in data["firmwares"].items():
        if isinstance(entry, dict) and entry.get("state") == "cache":
            warn(f"{firmware_id}: 上游版本事实来自缓存（{entry.get('fetched_at') or '时间未知'}），"
                 "页面提示可能不是官方最新")
    return data


def report_declaration_drift(config: dict, upstream: dict) -> None:
    """声明落后于官方时给出告警（不中止：页面已按现实渲染，不会出现死链）。"""
    for firmware in config.get("firmwares", []):
        if not isinstance(firmware, dict):
            continue
        entry = upstream_firmware(upstream, str(firmware.get("id", "")))
        for key in ("stable", "oldstable"):
            declared, official = firmware.get(key), entry.get(key)
            if declared and official and declared != official:
                warn(f"{firmware.get('id')}: 声明的 {key}={declared} 落后于官方 {official}")


def main() -> int:
    parser = argparse.ArgumentParser(description="生成站点落地页（中文默认、可切英文）")
    parser.add_argument("--public-dir", default="public", help="发布树根目录（默认 public）")
    parser.add_argument("--config", default="config/site.json", help="站点配置（默认 config/site.json）")
    parser.add_argument("--upstream", default="",
                        help="上游版本事实（fetch-upstream-versions.py 的产物；缺省不用）")
    parser.add_argument("--quiet", action="store_true", help="不打印细节")
    args = parser.parse_args()

    public_dir = Path(args.public_dir).resolve()
    config_path = Path(args.config).resolve()
    if not public_dir.is_dir():
        print(f"错误: 发布目录不存在: {public_dir}", file=sys.stderr)
        return 1
    if not config_path.is_file():
        print(f"错误: 配置文件不存在: {config_path}", file=sys.stderr)
        return 1

    config = json.loads(config_path.read_text(encoding="utf-8"))
    upstream = load_upstream(Path(args.upstream).resolve() if args.upstream else None)
    report_declaration_drift(config, upstream)

    (public_dir / "index.html").write_text(render_index(config, public_dir, upstream), encoding="utf-8")
    if not args.quiet:
        print(f"  已生成 {public_dir}/index.html")

    for firmware in config.get("firmwares", []):
        if not isinstance(firmware, dict) or "id" not in firmware:
            continue
        firmware_dir = public_dir / str(firmware["id"])
        if not firmware_dir.is_dir():
            continue
        (firmware_dir / "index.html").write_text(
            render_firmware_index(config, firmware, public_dir, upstream), encoding="utf-8")
        if not args.quiet:
            print(f"  已生成 {firmware_dir}/index.html")

    print("落地页生成完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
