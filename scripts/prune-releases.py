#!/usr/bin/env python3
"""按保留策略裁剪发布树中的稳定版目录（只保留版本号最新的 N 个）。

发布树里每个新稳定版都会占一个目录 <public-dir>/<固件id>/releases/<版本>/，不裁剪
时历史版本会一直堆积（GitHub Pages 单站上限 1 GB）。本脚本按 config/site.json 的
keep_stable 设定，保留版本号最新的 N 个，其余目录整棵删除。

保留数量取值:
  keep_stable: N（N ≥ 1）  保留版本号最新的 N 个稳定版目录
  keep_stable: 0           不裁剪（保留全部）
  缺省                      用内置默认值 2
固件级 keep_stable 覆盖站点级同名设定；--keep 再覆盖两者。

计数口径: 所有版本目录都参与"N 个"的排序与计数；被钉住的版本（见下）即使排在
N 名之外也保留，因此 site.json 手工归档过的版本会让实际目录数多于 N。

永不删除:
  - snapshots/ 目录与它下面的内容（开发快照，不是稳定版）
  - releases/packages-* 目录（官方共享包目录，不是版本目录）
  - site.json 声明过的版本（stable / oldstable / archive）——声明即保护，
    否则手工归档的版本会被下一次构建删掉
  - --protect 指定的版本（CI 传入本次正在构建的版本，防止重建旧版后被立刻删除）
  - 目录名里不含数字的目录（版本号无法比较，保守保留并告警）
  - 符号链接与非目录条目（一律不动）

用法:
  ./prune-releases.py [--public-dir=public] [--config=config/site.json]
                      [--keep=N] [--protect=25.12.5,24.10.3] [--dry-run] [--quiet]

依赖: 仅 Python 标准库。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from site_versions import parse_version_key

# 站内共享目录前缀：官方布局里 releases/packages-<major.minor> 是跨版本共享的包目录，
# 不含 targets/，不属于"某个稳定版"，因此不参与计数也不删除。
SHARED_PACKAGE_PREFIX = "packages-"

# site.json 未声明 keep_stable 时的内置默认值：当前稳定版 + 上一个稳定版
DEFAULT_KEEP_STABLE = 2


def log(message: str, quiet: bool = False) -> None:
    """打印一行日志（--quiet 时静默）。"""
    if not quiet:
        print(message)


def declared_versions(fw: dict) -> set[str]:
    """收集 site.json 里显式声明的版本号（stable / oldstable / archive）。"""
    declared: set[str] = set()
    for key in ("stable", "oldstable"):
        value = fw.get(key)
        if isinstance(value, str) and value:
            declared.add(value)
    archive = fw.get("archive") or []
    if isinstance(archive, list):
        declared.update(item for item in archive if isinstance(item, str) and item)
    return declared


def resolve_keep(config: dict, fw: dict, override: int | None) -> tuple[int, str]:
    """解析某固件最终生效的保留数量，返回 (数量, 来源说明)。"""
    if override is not None:
        return override, "--keep 命令行覆盖"
    for source, value in (("固件级 keep_stable", fw.get("keep_stable")),
                          ("站点级 keep_stable", config.get("keep_stable"))):
        if value is None:
            continue
        # bool 是 int 的子类，先排掉，避免 true 被当成 1
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"[{fw.get('id')}] {source} 必须是 ≥ 0 的整数，当前值: {value!r}")
        return value, source
    return DEFAULT_KEEP_STABLE, f"内置默认值 {DEFAULT_KEEP_STABLE}"


def prune_firmware(public_dir: Path, fw: dict, keep: int, protected: set[str],
                   dry_run: bool, quiet: bool) -> dict:
    """裁剪单个固件的 releases/ 目录，返回本次统计。

    计数口径：**所有**版本目录都参与"N 个"的排序与计数；site.json 声明过的版本与
    --protect 传入的版本额外"钉住"——即使排在 N 名之外也不删除（否则手工归档的版本
    会被下一次构建删掉，正在重建的旧版会被刚构建完就删掉）。
    """
    firmware = fw["id"]
    releases = public_dir / firmware / "releases"
    declared = declared_versions(fw)
    stats = {"firmware": firmware, "keep": keep, "candidates": 0,
             "kept": [], "dropped": [], "pinned": [], "skipped": []}

    if not releases.is_dir():
        stats["missing"] = True
        log(f"[{firmware}] 没有 releases/ 目录，跳过裁剪", quiet)
        return stats

    versions: list[tuple[tuple[int, ...], str]] = []
    pinned: dict[str, str] = {}
    for entry in sorted(releases.iterdir(), key=lambda p: p.name):
        name = entry.name
        if name.startswith("."):
            continue  # 隐藏目录（.nojekyll 等）不是版本目录
        if entry.is_symlink() or not entry.is_dir():
            continue  # 符号链接与非目录条目一律不动
        if name.startswith(SHARED_PACKAGE_PREFIX):
            stats["skipped"].append(name)
            continue
        key = parse_version_key(name)
        if key is None:
            stats["skipped"].append(name)
            log(f"[{firmware}] 警告: 目录名不含版本号，保守保留: {name}", quiet)
            continue
        versions.append((key, name))
        if name in protected:
            pinned[name] = "本次构建/--protect"
        elif name in declared:
            pinned[name] = "site.json 声明"

    ordered = sorted(versions, key=lambda item: (item[0], item[1]), reverse=True)
    stats["candidates"] = len(ordered)
    if keep == 0:
        kept = [name for _, name in ordered]
        log(f"[{firmware}] keep_stable=0：不裁剪，保留全部 {len(ordered)} 个稳定版目录", quiet)
    else:
        kept = [name for _, name in ordered[:keep]]
    # 被钉住的版本即使排在 N 名之外也保留（不占用也不挤掉计数名额）
    kept.extend(name for name in pinned if name not in kept)
    kept_set = set(kept)

    stats["kept"] = kept
    stats["pinned"] = [f"{name}（{pinned[name]}）" for name in kept if name in pinned]
    stats["dropped"] = [name for _, name in ordered if name not in kept_set]

    if stats["kept"]:
        log(f"[{firmware}] 保留 {len(stats['kept'])} 个: {', '.join(stats['kept'])}", quiet)
    for item in stats["pinned"]:
        log(f"[{firmware}] 钉住: {item}", quiet)
    if stats["skipped"]:
        log(f"[{firmware}] 跳过: {', '.join(stats['skipped'])}", quiet)

    for name in stats["dropped"]:
        target = releases / name

        # 删除前自检：目标必须是 releases/ 的直接子目录，避免任何形式的越界删除
        if target.parent != releases or target.name != name or name in ("", ".", ".."):
            raise ValueError(f"拒绝删除越界路径: {target}")

        if dry_run:
            log(f"[{firmware}] [dry-run] 将删除 {target}", quiet)
        else:
            shutil.rmtree(target)
            log(f"[{firmware}] 已删除 {target}", quiet)

    if not stats["dropped"]:
        log(f"[{firmware}] 无需裁剪", quiet)
    return stats


def write_step_summary(all_stats: list[dict], dry_run: bool) -> None:
    """把裁剪结果写进 GitHub Actions 的步骤摘要（本地运行时该变量不存在）。"""
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    lines = ["### 稳定版保留裁剪" + ("（dry-run）" if dry_run else ""), ""]
    for stats in all_stats:
        if stats.get("missing"):
            lines.append(f"- `{stats['firmware']}`：没有 releases/ 目录，跳过")
            continue
        kept = ", ".join(stats["kept"]) or "无"
        dropped = ", ".join(stats["dropped"]) or "无"
        lines.append(f"- `{stats['firmware']}`（保留数量 {stats['keep']}）："
                     f"保留 {kept}；{'将删除' if dry_run else '已删除'} {dropped}")
        if stats["pinned"]:
            lines.append(f"  - 钉住不删：{', '.join(stats['pinned'])}")
    lines.append("")
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description="按保留策略裁剪发布树中的稳定版目录")
    parser.add_argument("--public-dir", default="public", help="发布树根目录（默认 public）")
    parser.add_argument("--config", default="config/site.json", help="站点配置（默认 config/site.json）")
    parser.add_argument("--keep", type=int, default=None,
                        help="覆盖所有固件的保留数量（0=不裁剪，缺省读 site.json）")
    parser.add_argument("--protect", default="",
                        help="额外保护、绝不删除的版本号（逗号分隔；CI 传入本次构建的版本）")
    parser.add_argument("--dry-run", action="store_true", help="只打印将要删除的目录，不实际删除")
    parser.add_argument("--quiet", action="store_true", help="不打印细节，只保留步骤摘要")
    args = parser.parse_args()

    if args.keep is not None and args.keep < 0:
        print(f"错误: --keep 必须 ≥ 0，当前值: {args.keep}", file=sys.stderr)
        return 1

    public_dir = Path(args.public_dir).resolve()
    config_path = Path(args.config).resolve()
    if not public_dir.is_dir():
        print(f"错误: 发布目录不存在: {public_dir}", file=sys.stderr)
        return 1
    if not config_path.is_file():
        print(f"错误: 配置文件不存在: {config_path}", file=sys.stderr)
        return 1

    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        print(f"错误: 无法解析 {config_path}: {error}", file=sys.stderr)
        return 1

    protected = {item.strip() for item in args.protect.split(",") if item.strip()}
    if protected:
        log(f"额外保护版本: {', '.join(sorted(protected))}", args.quiet)

    firmwares = config.get("firmwares") or []
    if not firmwares:
        print("警告: site.json 未声明任何固件，无需裁剪", file=sys.stderr)
        return 0

    # 磁盘上有、但 site.json 没声明的固件目录不在这里处理：
    # 顶层白名单清理由 verify-site-structure.sh --prune 负责。
    declared_ids = {fw.get("id") for fw in firmwares if isinstance(fw, dict)}
    for entry in sorted(public_dir.iterdir(), key=lambda p: p.name):
        if entry.is_dir() and not entry.is_symlink() and not entry.name.startswith(".") \
                and entry.name not in declared_ids and entry.name != "assets":
            log(f"跳过未在 site.json 声明的顶层目录: {entry.name}", args.quiet)

    all_stats: list[dict] = []
    try:
        for fw in firmwares:
            if not isinstance(fw, dict) or not fw.get("id"):
                raise ValueError(f"site.json 的固件条目缺少 id: {fw!r}")
            keep, source = resolve_keep(config, fw, args.keep)
            log(f"[{fw['id']}] 保留数量 {keep}（{source}）", args.quiet)
            all_stats.append(
                prune_firmware(public_dir, fw, keep, protected, args.dry_run, args.quiet)
            )
    except (OSError, ValueError) as error:
        print(f"错误: {error}", file=sys.stderr)
        return 1

    write_step_summary(all_stats, args.dry_run)

    total_dropped = sum(len(stats["dropped"]) for stats in all_stats)
    if args.dry_run:
        print(f"dry-run 结束：共 {total_dropped} 个稳定版目录待删除（未实际删除）")
    else:
        print(f"裁剪完成：共删除 {total_dropped} 个稳定版目录")
    return 0


if __name__ == "__main__":
    sys.exit(main())
