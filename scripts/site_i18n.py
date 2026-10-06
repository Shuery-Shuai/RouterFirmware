"""站点双语文案的共享定义（中 / 英）。

生成器（落地页、目录列表页）共用这里的标记约定，前端由
public/assets/site/site.js 负责切换：

    <span data-zh="中文" data-en="English">中文</span>   —— 无 JS 时显示中文
    <title data-zh="…" data-en="…">English</title>      —— 无 JS 时显示英文（官方风格）

英文缺省时回退中文：宁可显示中文，也不要出现空白节点。
"""

import hashlib
import html
from pathlib import Path

SITE_JS_PATH = "assets/site/site.js"


def asset_url(public_dir: Path, site_path: str) -> str:
    """给站点静态资源加内容指纹：/assets/site/x.js?v=<sha256 前 8 位>。

    固定 URL 的静态资源会被浏览器长期缓存（GitHub Pages 默认 max-age=600），
    部署后旧脚本可能继续生效——曾把图标按钮改回文字、把说明块渲染坏。
    带指纹后每个版本都是新 URL，部署即生效；文件缺失时退回不带查询串的 URL。
    """
    path = public_dir / site_path
    if path.is_file():
        digest = hashlib.sha256(path.read_bytes()).hexdigest()[:8]
        return f"/{site_path}?v={digest}"
    return f"/{site_path}"


def icon_tags(public_dir: Path) -> str:
    """站点图标与主题色。路径从站点根起，任意深度的目录页都指向同一份。

    favicon.ico 必须在站点根：浏览器没有 link 也会请求它。SVG 给视网膜屏，
    apple-touch-icon.png 是 iOS 主屏幕的约定路径。指纹只打在 SVG 上，
    避免 /favicon.ico 带上查询串（部分浏览器会忽略，再自己请求一次无指纹的地址）。
    """
    return "\n".join([
        f"<link rel='icon' href='{asset_url(public_dir, 'favicon.svg')}' type='image/svg+xml'/>",
        "<link rel='icon' href='/favicon.ico' sizes='any'/>",
        "<link rel='apple-touch-icon' href='/apple-touch-icon.png'/>",
        "<meta name='theme-color' content='#002B49'/>",
    ])


# 语言切换入口：图标按钮「文A」（用字形实现，随字体渲染，无外部资源/无矢量图）。
# 位置：.container 的直接子元素、标题上方一行（用 <p> 而非 <div>，否则官方
# .container>div 规则会把它当成一张卡片）。无障碍：图标 aria-hidden，
# title / aria-label 由 site.js 切换为「目标语言」。
LANG_TOGGLE = (
    '<p class="site-lang">'
    '<a id="lang-toggle" href="#" title="English" aria-label="English">'
    '<span class="lang-icon" aria-hidden="true">文<span class="lang-a">A</span></span>'
    "</a>"
    "</p>"
)


def line(zh: str, en: str, tag: str = "span", attrs: str = "", raw: bool = False) -> str:
    """双语行内元素。

    Args:
        zh: 中文文案。
        en: 英文文案；为空时回退中文。
        tag: 包裹标签，默认 span。
        attrs: 追加到开始标签的属性文本（如 ' class="n"'）。
        raw: zh/en 已是安全 HTML（可含 <code> 等内联标记）；此时会加 data-html，
             前端改用 innerHTML 切换，初始文本仍为中文。

    Returns:
        带 data-zh / data-en 的 HTML 片段，初始文本为中文。
    """
    en = en or zh
    body = zh if raw else html.escape(zh)
    html_flag = ' data-html="1"' if raw else ""
    return (
        f"<{tag}{attrs}{html_flag} data-zh=\"{html.escape(zh, quote=True)}\" "
        f'data-en="{html.escape(en, quote=True)}">{body}</{tag}>'
    )


def title_tag(zh: str, en: str) -> str:
    """可随语言切换的 <title>（无 JS 时呈现英文，保持官方观感）。"""
    return (
        f'<title data-zh="{html.escape(zh, quote=True)}" '
        f'data-en="{html.escape(en or zh, quote=True)}">{html.escape(en or zh)}</title>'
    )
