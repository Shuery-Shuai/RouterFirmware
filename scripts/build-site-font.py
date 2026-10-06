#!/usr/bin/env python3
"""把站点字体子集化并 base64 内联进 site.css。

为什么这么做：
  * 站点文本只用到几百个码点，而完整 Sarasa 字体是 9 MB/字重、11 个文件共 91 MB；
    直接发布既拖慢部署又白占 GitHub Pages 的 1 GB 配额。
  * 内联进 CSS 后页面不再额外请求字体文件（一次 CSS 请求即含字形数据）。

做法：
  1. 扫描发布树与文档，收集实际用到的码点（外加 ASCII 与常用全角标点保底）；
  2. 用 fontTools 对指定字重做子集（woff2 输出）；
  3. 生成 site.css：@font-face 用 data URI 内联子集，并附带站点自身样式。

用法（需要 fontTools + brotli，建议在构建容器内执行）:
  ./build-site-font.py [--public-dir=public]
                       [--fonts-dir=fonts-src/sarasa]
                       [--weights=regular,bold]
                       [--out-css=public/assets/site/site.css]

依赖: fontTools（含 brotli），例如 Debian 的 python3-fonttools + python3-brotli。
"""

from __future__ import annotations

import argparse
import base64
import inspect
import re
import sys
from pathlib import Path

# 站点字体族名（与 CSS 中 font-family 对应）
FAMILY = "Sarasa Mono SC Subset"

# 各字重在 @font-face 中的 weight 值，以及对应的源文件名前缀
WEIGHT_MAP = {
    "regular": (400, "sarasa-mono-sc-regular-nerd-font.woff2"),
    "bold": (700, "sarasa-mono-sc-bold-nerd-font.woff2"),
    "italic": (400, "sarasa-mono-sc-italic-nerd-font.woff2"),
    "light": (300, "sarasa-mono-sc-light-nerd-font.woff2"),
}

# 保底码点：ASCII 可打印 + 常用 CJK 标点与全角符号
BASE_RANGES = [(0x20, 0x7E), (0x3000, 0x303F), (0xFF00, 0xFFEF)]

TAG_RE = re.compile(r"(?s)<(script|style)\b.*?</\1>|<[^>]+>")


def collect_codepoints(public_dir: Path, extra_files: list[Path]) -> set[int]:
    """扫描发布树里的 HTML/README 与仓库文档，收集用到的码点。"""
    texts: list[str] = []
    for pattern in ("**/*.html", "**/README.md", "**/*.md"):
        for path in public_dir.glob(pattern):
            try:
                texts.append(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
    for path in extra_files:
        if path.is_file():
            texts.append(path.read_text(encoding="utf-8", errors="replace"))

    blob = "\n".join(texts)
    blob = TAG_RE.sub(" ", blob)  # 去掉标签与 script/style 内容

    codepoints = {ord(ch) for ch in blob if ord(ch) > 31}
    for start, end in BASE_RANGES:
        codepoints.update(range(start, end + 1))
    return codepoints


def subset_font(src: Path, dst: Path, codepoints: set[int]) -> int:
    """按码点集生成 woff2 子集，返回子集字节数。"""
    try:
        from fontTools import subset  # 延迟导入：缺依赖时给出可操作的报错
    except ImportError as exc:  # pragma: no cover - 环境相关
        raise SystemExit(
            "错误: 缺少 fontTools（子集化需要它 + brotli）。\n"
            "  容器内安装: apt-get update && apt-get install -y python3-fonttools python3-brotli\n"
            "  或:        pip3 install --break-system-packages fonttools brotli\n"
            f"  原始错误: {exc}"
        ) from exc

    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["*"]
    options.drop_tables += ["EBDT", "EBLC", "EBSC", "SVG "]  # 站点不需要的点阵/矢量表

    font = subset.load_font(str(src), options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=codepoints)
    subsetter.subset(font)

    dst.parent.mkdir(parents=True, exist_ok=True)
    # recalcTimestamp=False：保留源字体的 head.modified，使子集输出逐字节可复现。
    # 注意该关键字只在较新的 fontTools 上存在（4.38 的签名只有 reorderTables），
    # 因此按签名探测后再传，避免 TypeError。
    save_kwargs: dict[str, object] = {"reorderTables": False}
    if "recalcTimestamp" in inspect.signature(font.save).parameters:
        save_kwargs["recalcTimestamp"] = False
    else:
        print("  提示: 当前 fontTools 不支持 recalcTimestamp，子集可能因时间戳不可逐字节复现")
    font.save(str(dst), **save_kwargs)
    font.close()
    return dst.stat().st_size


def build_css(weights: list[tuple[int, Path]], inline: bool) -> str:
    """生成 site.css：@font-face（内联或引用文件）+ 站点样式。"""
    lines = [
        "/* 站点样式：由 scripts/build-site-font.py 生成，请勿手改 */",
        f"/* 字体: {FAMILY}（子集，{'base64 内联' if inline else '外部文件'}） */",
    ]
    for weight, woff2 in weights:
        if inline:
            data = base64.b64encode(woff2.read_bytes()).decode("ascii")
            src = f"url(data:font/woff2;base64,{data}) format('woff2')"
        else:
            src = f"url('/{woff2.as_posix().split('public/', 1)[-1]}') format('woff2')"
        lines.append(
            "@font-face{"
            f"font-family:'{FAMILY}';font-style:normal;font-weight:{weight};"
            f"font-display:swap;src:{src}}}"
        )

    lines.append(
        """
/* 页面基础版式、.container / .container>div 卡片、footer 全部由官方 openwrt.css 提供——
   落地页与列表页都只用官方的类名（.container + 直接子 div），不另造卡片样式。 */
:root {
  /* 不声明 color-scheme：交由浏览器自行适配（自动暗色目前接受，刻意不做 light-only） */
  --site-mono: 'Sarasa Mono SC Subset', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
/* 语言切换与站点基础样式在 base.css（所有页面都引入），此处只放字体与 README 组件样式 */
/* 目录说明块（每目录的 README 渲染结果）
   表面样式（背景/圆角/阴影/内边距）不在这里定义：说明块是 .container 的直接子 div，
   由官方 openwrt.css 的 .container>div 规则统一提供，与官方页面完全一致。
   下外边距按官方留白节奏取 2em：官方 table 只设 margin-bottom（下方留白），
   上方的说明块必须自己留出间距，否则两块会贴在一起。 */
.readme {
  line-height: 1.7;
  font-family: var(--site-mono);
  margin: 0 0 2em;
}
.readme h2, .readme h3, .readme h4 { margin: 0.6em 0 0.3em; }
.readme code, .readme pre, .readme kbd {
  font-family: var(--site-mono);
  background: #f5f5f5;
  border-radius: 3px;
  padding: 0 0.25em;
}
.readme pre { padding: 0.6em 0.8em; overflow-x: auto; }
.readme pre code { background: none; padding: 0; }
.readme blockquote {
  margin: 0.6em 0;
  padding-left: 0.8em;
  border-left: 3px solid #ccc;
  color: #555;
}
.readme ul { margin: 0.3em 0 0.6em 1.2em; }
.readme a { color: #00a3e1; }
/* README 内的分隔线（Markdown 的 ---）：官方 CSS 没有为块内 hr 提供样式 */
.readme hr { border: 0; border-top: 1px solid #ccc; margin: 1.2em 0; }
/* README 内的表格 */
.readme table { border-collapse: collapse; margin: 0.6em 0; }
.readme th, .readme td { border: 1px solid #ccc; padding: 0.25em 0.6em; }
/* README 代码块：行号（CSS 计数器，无 JS 也成立）+ 复制按钮；高亮配色来自 highlight.js 主题 */
.readme .code-block { position: relative; counter-reset: code-line; margin: 0.8em 0; }
/* 代码块必须覆盖 .readme 的 1.7 正文行距，否则行距会被拉到 ~27px（曾出现"行距太大"）。
   white-space：外层 pre 用 normal，让行间可能残留的换行节点塌陷；行内保留缩进交给 .code-line。 */
.readme .code-block pre { margin: 0; padding: 0.6em 0; background: #f6f8fa; border-radius: 4px; overflow-x: auto; line-height: 1.45; white-space: normal; }
.readme .code-block code.hljs { display: block; padding: 0; background: none; line-height: inherit; }
.readme .code-line { display: block; min-height: 1.45em; padding: 0 1em 0 3.4em; position: relative; white-space: pre; }
.readme .code-line::before {
  counter-increment: code-line;
  content: counter(code-line);
  position: absolute;
  left: 0;
  width: 2.6em;
  text-align: right;
  color: #9aa0a6;
  user-select: none;
}
.readme .copy-btn {
  position: absolute;
  top: 0.4em;
  right: 0.6em;
  z-index: 1;
  font: inherit;
  font-size: 80%;
  line-height: 1.6;
  padding: 0 0.5em;
  color: #333;
  background: #fff;
  border: 1px solid #bbb;
  border-radius: 3px;
  cursor: pointer;
}
.readme .copy-btn:hover { background: #f0f0f0; }
""".strip()
    )
    return "\n".join(lines) + "\n"


def verify_manifest(fonts_dir: Path, manifest: Path) -> tuple[list[str], int]:
    """按哈希清单校验本地字体副本，返回（问题列表, 校验条数）。"""
    import hashlib

    problems: list[str] = []
    checked = 0
    if not manifest.is_file():
        return [f"清单不存在: {manifest}"], 0
    for line in manifest.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        digest, name = parts[0], parts[1].lstrip("*")
        checked += 1
        path = fonts_dir / name
        if not path.is_file():
            problems.append(f"{name}: 缺失")
            continue
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            problems.append(f"{name}: 哈希不符")
    return problems, checked


def main() -> int:
    parser = argparse.ArgumentParser(description="子集化站点字体并内联进 site.css")
    parser.add_argument("--public-dir", default="public", help="发布树根目录（默认 public）")
    parser.add_argument("--fonts-dir", default="fonts-src/sarasa",
                        help="源字体目录（默认 fonts-src/sarasa，不入库）")
    parser.add_argument("--manifest", default="config/fonts.sha256",
                        help="源字体哈希清单（默认 config/fonts.sha256）")
    parser.add_argument("--verify", action="store_true",
                        help="只按清单校验本地字体副本，不做子集化")
    parser.add_argument("--reuse-subsets", action="store_true",
                        help="复用 out-dir 里已有的子集文件，只重新生成 CSS"
                             "（无需 fontTools 与源字体，适合只改样式时用）")
    parser.add_argument("--weights", default="regular,bold",
                        help="需要的字重（逗号分隔，默认 regular,bold）")
    parser.add_argument("--out-css", default="public/assets/site/site.css",
                        help="输出的 CSS 路径")
    parser.add_argument("--out-dir", default="sources/site-font-subset",
                        help="子集字体输出目录（默认 sources/，不随站点发布）")
    parser.add_argument("--no-inline", action="store_true",
                        help="不内联，改为在 CSS 里引用子集文件")
    args = parser.parse_args()

    public_dir = Path(args.public_dir).resolve()
    fonts_dir = Path(args.fonts_dir).resolve()
    manifest = Path(args.manifest).resolve()

    weight_names = [w.strip() for w in args.weights.split(",") if w.strip()]
    for name in weight_names:
        if name not in WEIGHT_MAP:
            print(f"错误: 未知字重 {name}（可选: {', '.join(WEIGHT_MAP)}）", file=sys.stderr)
            return 1

    codepoints: set[int] = set()
    if args.reuse_subsets:
        print(f"复用已有子集（--reuse-subsets）：只重新生成 {args.out_css}")
    else:
        if not fonts_dir.is_dir():
            print(f"错误: 字体目录不存在: {fonts_dir}", file=sys.stderr)
            print("  源字体不入库（91 MB，见 .gitignore 的 fonts-src/）。请从备份恢复后核对清单：", file=sys.stderr)
            print(f"    mkdir -p {fonts_dir} && (恢复 11 个 .woff2) && "
                  f"(cd {fonts_dir} && shasum -a 256 -c {manifest})", file=sys.stderr)
            return 1

        problems, checked = verify_manifest(fonts_dir, manifest)
        if problems:
            print("错误: 源字体与清单不一致：", file=sys.stderr)
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
            return 1
        print(f"源字体清单校验通过（{checked} 个文件，清单 {manifest.name}）")
        if args.verify:
            return 0

        codepoints = collect_codepoints(public_dir, [Path("README.md")])
        print(f"收集到 {len(codepoints)} 个码点（含 ASCII 与常用标点保底）")

    weights: list[tuple[int, Path]] = []
    for name in weight_names:
        weight, filename = WEIGHT_MAP[name]
        dst = Path(args.out_dir) / f"site-font-{name}.woff2"
        if args.reuse_subsets:
            if not dst.is_file():
                print(f"错误: 子集文件不存在: {dst}（先不带 --reuse-subsets 生成一次）", file=sys.stderr)
                return 1
            print(f"  复用 {name:<8} {dst.stat().st_size / 1024:6.1f} KB  {dst}")
        else:
            src = fonts_dir / filename
            if not src.is_file():
                print(f"错误: 源字体不存在: {src}", file=sys.stderr)
                return 1
            size = subset_font(src, dst, codepoints)
            print(f"  子集 {name:<8} {src.stat().st_size / 1024 / 1024:5.1f} MB → {size / 1024:6.1f} KB  {dst}")
        weights.append((weight, dst))

    css = build_css(weights, inline=not args.no_inline)
    out_css = Path(args.out_css)
    out_css.parent.mkdir(parents=True, exist_ok=True)
    out_css.write_text(css, encoding="utf-8")
    print(f"已生成 {out_css}（{out_css.stat().st_size/1024:.1f} KB）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
