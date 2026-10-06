#!/usr/bin/env python3
"""生成站点落地页（中文默认、可切换英文）与各发行版落地页。

官方发布站首页是**手写** HTML（栏目：Stable Release / Old Stable Release /
Development Snapshots / Release Archive）。本脚本按同样的栏目骨架生成我们自己的
首页，差别只在于：内容由 `config/site.json` 驱动、双语内嵌、并在生成前校验所声明的
版本在发布树里真实存在（避免出现指向不存在目录的死链）。

用法:
  ./generate-site-landing.py [--public-dir=public] [--config=config/site.json]
                             [--allow-missing] [--quiet]

生成物:
  <public-dir>/index.html         站点首页（双发行版）
  <public-dir>/<firmware>/index.html   各发行版首页

依赖: 仅 Python 标准库。
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path

from site_i18n import LANG_TOGGLE, SITE_JS, line, title_tag

# 官方样式表：跨域引用官方那份（不复制文件，避免再分发）
OFFICIAL_CSS = "https://downloads.immortalwrt.org/openwrt.css"

# 内嵌的极简语言切换脚本（无 JS 时页面显示中文默认文案）
def page_shell(title: str, title_en: str, body: str) -> str:
    return "\n".join([
        "<!DOCTYPE html>",
        "<html lang='zh-CN'>",
        "<head>",
        "<meta charset='utf-8'/>",
        "<meta name='viewport' content='width=device-width, initial-scale=1.0'/>",
        f"<link rel='stylesheet' href='{OFFICIAL_CSS}' />",
        "<link rel='stylesheet' href='/assets/site/base.css' />",
        title_tag(title, title_en),
        "</head>",
        "",
        "<body>",
        LANG_TOGGLE,
        '<div class="container">',
        body,
        "<footer>",
        line("本页由构建流程自动生成，内容来自 config/site.json。", "This page is generated at build time from config/site.json."),
        "</footer>",
        "</div>",
        f"<script src='{SITE_JS}' defer></script>",
        "</body>",
        "</html>",
        "",
    ])


def firmware_sections(fw: dict) -> str:
    """一个发行版的栏目（稳定版 / 旧稳定版 / 开发快照 / 版本归档）。

    只产出栏目内容，不包外层 div：官方首页是「一个内容 div + 栏目间 <hr/> 分隔」，
    表面样式由官方 CSS 的 .container>div 提供。
    """
    fid = fw["id"]
    parts: list[str] = []
    parts.append(f'<h2>{html.escape(fw.get("title", fid))}</h2>')

    def entry(version: str, label_zh: str, label_en: str) -> str:
        href = f"/{fid}/releases/{version}/targets/"
        return (f'<li>{line(label_zh, label_en)}：<strong><a href="{href}">{html.escape(version)}</a></strong></li>')

    if fw.get("stable"):
        parts.append("<h3>" + line("稳定版", "Stable Release", "span") + "</h3>")
        parts.append("<ul>")
        parts.append(entry(fw["stable"], "最新稳定版", "current stable"))
        parts.append("</ul>")
    if fw.get("oldstable"):
        parts.append("<h3>" + line("旧稳定版", "Old Stable Release", "span") + "</h3>")
        parts.append("<ul>")
        parts.append(entry(fw["oldstable"], "仍在收安全修复", "security fixes only"))
        parts.append("</ul>")
    if fw.get("snapshots"):
        parts.append("<h3>" + line("开发快照", "Development Snapshots", "span") + "</h3>")
        parts.append("<ul>")
        parts.append(
            f'<li>{line("随上游更新，可能不稳定", "tracking upstream, may be unstable")}：'
            f'<strong><a href="/{fid}/snapshots/targets/">snapshots</a></strong></li>'
        )
        parts.append("</ul>")
    if fw.get("archive"):
        parts.append("<h3>" + line("版本归档", "Release Archive", "span") + "</h3>")
        parts.append("<ul>")
        for version in fw["archive"]:
            parts.append(entry(version, "历史版本", "archived release"))
        parts.append("</ul>")

    parts.append(
        f'<p><small>{line("软件包仓库公钥", "Package repository public key")}：'
        f'<a href="/assets/common/keys/public-key.pem">/assets/common/keys/public-key.pem</a></small></p>'
    )
    parts.append('<p><small><a href="/' + fid + '/">' +
                 line("浏览该发行版的全部文件", "Browse all files of this firmware") + "</a></small></p>")
    return "\n".join(parts)


def render_index(config: dict, public_dir: Path) -> str:
    body = [
        "<h1>" + line(config.get("title", "固件下载"), "Firmware Downloads", "span") + "</h1>",
        "<p>" + line(config.get("description", ""), config.get("description_en", ""), "span") + "</p>",
        "<div>",  # 官方首页只有一个内容 div，栏目之间用 <hr/> 分隔
    ]
    blocks = [firmware_sections(fw) for fw in config.get("firmwares", [])]
    blocks.append(
        "<h2>" + line("构建脚本与配置", "Build scripts and configs", "span") + "</h2>"
        "<p>" + line("设备脚本、配置与说明文档位于", "Device scripts, configs and docs live under", "span")
        + ' <a href="/assets/">/assets/</a>。</p>'
    )
    body.append("\n<hr/>\n".join(blocks))
    body.append("</div>")
    return page_shell(config.get("title", "固件下载"),
                      config.get("title_en") or "Firmware Downloads", "\n".join(body))


def render_firmware_index(config: dict, fw: dict) -> str:
    body = [
        "<h1>" + html.escape(fw.get("title", fw["id"])) + "</h1>",
        '<p><small><a href="/">' + line("← 返回站点首页", "← Back to site home", "span") + "</a></small></p>",
        "<div>",
        firmware_sections(fw),
        "</div>",
    ]
    return page_shell(fw.get("title", fw["id"]),
                      fw.get("title_en") or fw.get("title", fw["id"]), "\n".join(body))


def validate(config: dict, public_dir: Path, allow_missing: bool) -> list[str]:
    """校验声明的版本在发布树里真实存在，返回问题列表。"""
    problems: list[str] = []
    for fw in config.get("firmwares", []):
        fid = fw["id"]
        base = public_dir / fid
        if not base.is_dir():
            problems.append(f"发行版目录不存在: {base}")
            continue
        for key in ("stable", "oldstable"):
            version = fw.get(key)
            if version and not (base / "releases" / version / "targets").is_dir():
                problems.append(f"{fid}: {key}={version} 在发布树中不存在（{base}/releases/{version}/targets）")
        for version in fw.get("archive") or []:
            if not (base / "releases" / version / "targets").is_dir():
                problems.append(f"{fid}: archive 中声明的 {version} 不存在")
        if fw.get("snapshots") and not (base / "snapshots" / "targets").is_dir():
            problems.append(f"{fid}: 声明了 snapshots，但 {base}/snapshots/targets 不存在")
    if problems and not allow_missing:
        return problems
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description="生成站点落地页（中文默认、可切英文）")
    parser.add_argument("--public-dir", default="public", help="发布树根目录（默认 public）")
    parser.add_argument("--config", default="config/site.json", help="站点配置（默认 config/site.json）")
    parser.add_argument("--allow-missing", action="store_true", help="版本缺失时只警告不失败（本地预览用）")
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
    problems = validate(config, public_dir, args.allow_missing)
    if problems:
        print("错误: config/site.json 声明的版本与发布树不一致：", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    (public_dir / "index.html").write_text(render_index(config, public_dir), encoding="utf-8")
    if not args.quiet:
        print(f"  已生成 {public_dir}/index.html")

    for fw in config.get("firmwares", []):
        fw_dir = public_dir / fw["id"]
        if not fw_dir.is_dir():
            continue
        (fw_dir / "index.html").write_text(render_firmware_index(config, fw), encoding="utf-8")
        if not args.quiet:
            print(f"  已生成 {fw_dir}/index.html")

    print("落地页生成完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
