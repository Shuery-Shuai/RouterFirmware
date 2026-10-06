#!/usr/bin/env python3
"""生成发布站图标（favicon / apple-touch）。

标记是一枚四口路由器正面：海军蓝圆角方块、白色机身、两组青色网口。
四口分成 2+2，对应 Banana Pi BPI-R4 的网口排布；颜色取自站点样式表
（--main-dark-color #002B49、--main-bright-color #00A3E1），不借用
OpenWrt 或 Banana Pi 的商标图形。笔画像素按 16px 还能分开来设计。

输出（相对 --public-dir，默认 public）:
  favicon.svg              现代浏览器，任意缩放仍清晰
  favicon.ico              16 与 32，浏览器会无条件请求 /favicon.ico
  apple-touch-icon.png     180² 不透明方图，iOS 主屏幕会自动寻找这个路径

用法:
  ./build-site-icon.py [--public-dir=public]

依赖: 仅 Python 标准库。
"""

from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path

# 与 downloads 页 openwrt.css 的品牌色一致
NAVY = (0x00, 0x2B, 0x49, 255)
CYAN = (0x00, 0xA3, 0xE1, 255)
WHITE = (255, 255, 255, 255)
TRANSPARENT = (0, 0, 0, 0)

# 几何全部落在 32×32 设计网格上。16px 缩小后网口仍是分开的两对，
# 天线宽度约 1px，不会糊成一根。
TILE = (0.0, 0.0, 32.0, 32.0, 7.0)
ANTENNAS = (
    (9.4, 6.4, 2.4, 7.4, 1.2),   # 左，压在左端口组中线
    (20.2, 6.4, 2.4, 7.4, 1.2),  # 右
)
BODY = (4.6, 12.8, 22.8, 13.6, 2.4)
PORTS = (
    (7.2, 16.4, 3.0, 6.4, 0.55),
    (11.0, 16.4, 3.0, 6.4, 0.55),
    (18.0, 16.4, 3.0, 6.4, 0.55),
    (21.8, 16.4, 3.0, 6.4, 0.55),
)


def _in_round_rect(px: float, py: float, x: float, y: float, w: float, h: float, r: float) -> bool:
    r = min(max(r, 0.0), w / 2, h / 2)
    if x + r <= px <= x + w - r and y <= py <= y + h:
        return True
    if x <= px <= x + w and y + r <= py <= y + h - r:
        return True
    for cx, cy in ((x + r, y + r), (x + w - r, y + r), (x + r, y + h - r), (x + w - r, y + h - r)):
        dx, dy = px - cx, py - cy
        if dx * dx + dy * dy <= r * r:
            return True
    return False


def color_at(px: float, py: float, *, opaque: bool) -> tuple[int, int, int, int]:
    """设计网格上的一个采样点。opaque 时四角填海军蓝（iOS 会自己裁圆角）。"""
    if not _in_round_rect(px, py, *TILE):
        return NAVY if opaque else TRANSPARENT
    color = NAVY
    for shape in ANTENNAS:
        if _in_round_rect(px, py, *shape):
            color = WHITE
    if _in_round_rect(px, py, *BODY):
        color = WHITE
    for shape in PORTS:
        if _in_round_rect(px, py, *shape):
            color = CYAN
    return color


def render(size: int, *, ss: int, opaque: bool) -> list[list[tuple[int, int, int, int]]]:
    """超采样后取平均，避免 16px 上网口边缘发虚或断开。"""
    pixels: list[list[tuple[int, int, int, int]]] = []
    samples = ss * ss
    for y in range(size):
        row: list[tuple[int, int, int, int]] = []
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    px = (x + (sx + 0.5) / ss) / size * 32
                    py = (y + (sy + 0.5) / ss) / size * 32
                    sample = color_at(px, py, opaque=opaque)
                    for i in range(4):
                        acc[i] += sample[i]
            row.append(tuple(int(channel / samples + 0.5) for channel in acc))  # type: ignore[arg-type]
        pixels.append(row)
    return pixels


def _png_chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def png_bytes(pixels: list[list[tuple[int, int, int, int]]], *, rgb: bool = False) -> bytes:
    height = len(pixels)
    width = len(pixels[0])
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter: None
        for r, g, b, _a in row:
            raw.extend((r, g, b) if rgb else (r, g, b, _a))
    # iOS 要求主屏幕图标不带透明通道；favicon 保留 RGBA，圆角外透明。
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2 if rgb else 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + _png_chunk(b"IEND", b"")
    )


def ico_bytes(images: list[tuple[int, bytes]]) -> bytes:
    """Vista 风格 ICO：每个尺寸内嵌一份 PNG。现代浏览器都认。"""
    count = len(images)
    header = struct.pack("<HHH", 0, 1, count)
    entries = bytearray()
    payload = bytearray()
    offset = 6 + 16 * count
    for size, png in images:
        entries += struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(png), offset)
        payload += png
        offset += len(png)
    return header + bytes(entries) + bytes(payload)


def _num(value: float) -> str:
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return text or "0"


def _rect(shape: tuple[float, float, float, float, float], fill: str) -> str:
    x, y, w, h, r = shape
    return (
        f'<rect x="{_num(x)}" y="{_num(y)}" width="{_num(w)}" height="{_num(h)}" '
        f'rx="{_num(r)}" fill="{fill}"/>'
    )


def svg_text() -> str:
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" role="img">',
        "<title>RouterFirmware</title>",
        _rect(TILE, "#002B49"),
    ]
    parts.extend(_rect(shape, "#fff") for shape in ANTENNAS)
    parts.append(_rect(BODY, "#fff"))
    parts.extend(_rect(shape, "#00A3E1") for shape in PORTS)
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def build(public_dir: Path) -> None:
    public_dir.mkdir(parents=True, exist_ok=True)
    (public_dir / "favicon.svg").write_text(svg_text(), encoding="utf-8")
    png16 = png_bytes(render(16, ss=8, opaque=False))
    png32 = png_bytes(render(32, ss=6, opaque=False))
    (public_dir / "favicon.ico").write_bytes(ico_bytes([(16, png16), (32, png32)]))
    # iOS 不喜欢透明角，圆角由系统遮罩裁；这里铺满海军蓝。
    (public_dir / "apple-touch-icon.png").write_bytes(
        png_bytes(render(180, ss=4, opaque=True), rgb=True)
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="生成发布站图标（favicon / apple-touch）")
    parser.add_argument("--public-dir", default="public", help="发布树根目录（默认 public）")
    args = parser.parse_args()
    public_dir = Path(args.public_dir).resolve()
    build(public_dir)
    print(f"  已生成 {public_dir / 'favicon.svg'}")
    print(f"  已生成 {public_dir / 'favicon.ico'}")
    print(f"  已生成 {public_dir / 'apple-touch-icon.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
