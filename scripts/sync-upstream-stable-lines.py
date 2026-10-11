#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Sync stable release lines in site.json from freshly fetched upstream facts."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

from site_versions import parse_version_key

_RELEASE_VERSION_RE = re.compile(r"^\d+(?:\.\d+)+$")
DEFAULT_KEEP_STABLE = 2


def release_line(version: str) -> str:
    return ".".join(version.split(".")[:2])


def keep_count(config: dict, firmware: dict) -> int:
    value = firmware.get("keep_stable", config.get("keep_stable", DEFAULT_KEEP_STABLE))
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(
            f"[{firmware.get('id')}] keep_stable 必须是 ≥ 0 的整数，当前值: {value!r}"
        )
    return value


def stable_versions(record: dict) -> dict[str, str]:
    """Return the newest stable patch version for each release line."""
    versions = record.get("versions")
    if not isinstance(versions, list):
        raise ValueError("上游版本列表缺失或格式错误")

    candidates = [item for item in versions if isinstance(item, str)]
    candidates.extend(
        value for key in ("stable", "oldstable")
        if isinstance((value := record.get(key)), str) and value
    )

    latest: dict[str, tuple[tuple[int, ...], str]] = {}
    for version in candidates:
        if not _RELEASE_VERSION_RE.fullmatch(version):
            continue
        key = parse_version_key(version)
        if key is None:
            continue
        line = release_line(version)
        if line not in latest or key > latest[line][0]:
            latest[line] = (key, version)
    return {line: item[1] for line, item in latest.items()}


def select_lines(record: dict, count: int) -> list[str]:
    versions = stable_versions(record)
    official_stable = record.get("stable")
    if not isinstance(official_stable, str) or not _RELEASE_VERSION_RE.fullmatch(official_stable):
        raise ValueError("上游官方 stable 版本缺失或不是正式稳定版本")
    stable_line = release_line(official_stable)
    if count == 0:
        official_lines = []
        for key in ("stable", "oldstable"):
            version = record.get(key)
            if isinstance(version, str):
                line = release_line(version)
                if line in versions and line not in official_lines:
                    official_lines.append(line)
        if not official_lines or official_lines[0] != stable_line:
            raise ValueError("上游 stable / oldstable 数据与版本列表不一致")
        return official_lines
    ordered = sorted(
        versions,
        key=lambda line: (parse_version_key(versions[line]) or (), line),
        reverse=True,
    )
    if not ordered or ordered[0] != stable_line:
        raise ValueError("上游 stable 版本与版本列表顺序不一致")
    return ordered[:count]


def sync_config(config: dict, upstream: dict) -> bool:
    firmwares = config.get("firmwares")
    records = upstream.get("firmwares")
    if not isinstance(firmwares, list) or not isinstance(records, dict):
        raise ValueError("站点配置或上游版本事实缺少 firmwares 列表")

    changed = False
    for firmware in firmwares:
        if not isinstance(firmware, dict):
            continue
        firmware_id = firmware.get("id")
        if not isinstance(firmware_id, str) or not firmware_id:
            continue
        if not firmware.get("downloads"):
            continue

        record = records.get(firmware_id)
        if not isinstance(record, dict):
            raise ValueError(f"[{firmware_id}] 上游版本事实缺失")
        if record.get("state") != "fresh":
            raise ValueError(
                f"[{firmware_id}] 上游数据不是本次新抓取（state={record.get('state')!r}），"
                "拒绝自动更新"
            )

        count = keep_count(config, firmware)
        lines = select_lines(record, count)
        if not lines:
            raise ValueError(f"[{firmware_id}] 上游没有可跟踪的稳定发行线")
        versions = stable_versions(record)
        updates = {
            "stable": versions[lines[0]],
            "oldstable": versions[lines[1]] if len(lines) > 1 else None,
            "tracked_lines": lines,
        }
        for key, value in updates.items():
            if firmware.get(key) != value:
                firmware[key] = value
                changed = True
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description="按上游版本事实同步站点稳定发行线")
    parser.add_argument("--config", default="config/site.json", help="站点配置")
    parser.add_argument("--upstream", default="upstream-versions.json", help="上游版本事实")
    args = parser.parse_args()

    config_path = Path(args.config)
    upstream_path = Path(args.upstream)
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        upstream = json.loads(upstream_path.read_text(encoding="utf-8"))
        if not isinstance(config, dict) or not isinstance(upstream, dict):
            raise ValueError("配置和上游版本事实必须是 JSON 对象")
        changed = sync_config(config, upstream)
        if changed:
            temporary = config_path.with_name(config_path.name + ".tmp")
            try:
                temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n",
                                     encoding="utf-8")
                os.replace(temporary, config_path)
            finally:
                temporary.unlink(missing_ok=True)
            print(f"已按上游稳定发行线更新 {config_path}")
        else:
            print("稳定发行线已与上游保持一致")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"错误: 无法同步稳定发行线: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
