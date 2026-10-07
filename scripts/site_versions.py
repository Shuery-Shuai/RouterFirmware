#!/usr/bin/env python3
"""版本号比较的共享规则（目录名 → 可比较的整数元组）。

同一棵发布树会被两个脚本按版本号排序：generate-site-landing.py 用它给「版本归档」
排序，prune-releases.py 用它决定保留最新的 N 个稳定版。规则必须只有一处，
否则页面上的顺序与裁剪结果可能不一致。

用法（模块）:
    from site_versions import parse_version_key

    key = parse_version_key("25.12.10")   # (25, 12, 10)
    key = parse_version_key("nightly")    # None（无法比较）

依赖: 仅 Python 标准库。
"""

from __future__ import annotations

import re

_VERSION_NUM_RE = re.compile(r"\d+")


def parse_version_key(name: str) -> tuple[int, ...] | None:
    """把目录名解析成可比较的版本号元组；不含数字时返回 None。

    '25.12.10' → (25, 12, 10)，'24.10.3' → (24, 10, 3)，'v25.12' → (25, 12)。
    逐段按整数比较，所以 25.12.10 大于 25.12.2（字符串比较会判反）。
    """
    parts = _VERSION_NUM_RE.findall(name)
    if not parts:
        return None
    return tuple(int(part) for part in parts)
