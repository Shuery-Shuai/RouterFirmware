#!/usr/bin/env python3
"""把「官方版本事实 × 站点声明 × 发布树」join 成一张覆盖率报告。

三份数据各代表一种真相，缺一不可：
  * 官方版本事实（--upstream，fetch-upstream-versions.py 的产物）—— 上游现在把谁
    当稳定版 / 旧稳定版，以及官方的完整版本列表；
  * 站点声明（--config 的 config/site.json）—— 我们想跟哪条发行线、当前声明谁；
  * 发布树（--public-dir）—— 我们实际发布了什么。

判定（fail 级别的项可以由 --fail-on 提升为退出码 1）:
  drift  官方 stable / oldstable 的发行线不在我们声明的发行线里——
         上游换线了，需要人决策「跟不跟」（fail 级）
  stale  同一条发行线上官方版本号比声明的更新——页面已自动提示「官方已发布 X」，
         属正常的「声明先于构建」窗口（提示级）
  gap    声明了 stable / oldstable，但发布树里没有该版本（fail 级，仅 --public-dir）
  local  发布树里有、官方版本列表里没有的版本——多半是本地自建（提示级）

用法:
  ./site-coverage.py [--config=config/site.json] [--upstream=upstream-versions.json]
                     [--public-dir=public] [--fail-on=none|drift|gap|any]
                     [--summary=FILE] [--quiet]

退出状态:
  0 - 没有达到 --fail-on 门槛的问题
  1 - 有达到门槛的问题
  2 - 用法 / 配置 / IO 错误

依赖: 仅 Python 标准库（site_versions 为同目录模块）。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from site_versions import parse_version_key

FAIL_LEVELS = {
    "none": frozenset(),
    "drift": frozenset({"drift"}),
    "gap": frozenset({"gap"}),
    "any": frozenset({"drift", "gap"}),
}

FINDING_ICONS = {"drift": "❌", "gap": "❌", "stale": "⚠️", "local": "ℹ️"}


def warn(message: str) -> None:
    print(f"警告: {message}", file=sys.stderr)


def release_line(version: str) -> str:
    """取发行线（主次版本号）：'25.12.5' → '25.12'，'25.12.0-rc2' → '25.12'。"""
    parts = version.split("-")[0].split(".")
    return ".".join(parts[:2]) if len(parts) >= 2 else version


def load_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"{path} 无法解析: {exc}")
        return None


def declared_lines(firmware: dict) -> set[str]:
    """该固件声明的发行线集合（stable + oldstable）。"""
    return {release_line(str(firmware[key])) for key in ("stable", "oldstable")
            if firmware.get(key)}


def local_versions(public_dir: Path | None, firmware_id: str) -> dict[str, tuple[int, ...]]:
    """发布树里可链接的版本目录（含 targets/ 才算）。"""
    found: dict[str, tuple[int, ...]] = {}
    if public_dir is None:
        return found
    releases = public_dir / firmware_id / "releases"
    if not releases.is_dir():
        return found
    for entry in releases.iterdir():
        if not entry.is_dir() or not (entry / "targets").is_dir():
            continue
        key = parse_version_key(entry.name)
        if key is not None:
            found[entry.name] = key
    return found


def compare_firmware(firmware: dict, upstream: dict, public_dir: Path | None) -> dict:
    """对单个固件做三方比对，返回报告行与发现列表。"""
    firmware_id = str(firmware.get("id", ""))
    official_stable = str(upstream.get("stable") or "")
    official_oldstable = str(upstream.get("oldstable") or "")
    official_versions = [item for item in upstream.get("versions", []) if isinstance(item, str)]
    declared_stable = str(firmware.get("stable") or "")
    declared_oldstable = str(firmware.get("oldstable") or "")
    lines = declared_lines(firmware)
    local = local_versions(public_dir, firmware_id)
    findings: list[dict] = []

    for key, official, declared, label in (
        ("stable", official_stable, declared_stable, "稳定版"),
        ("oldstable", official_oldstable, declared_oldstable, "旧稳定版"),
    ):
        if official and release_line(official) not in lines:
            findings.append({
                "kind": "drift", "firmware": firmware_id,
                "message": f"官方{label}已是 {official}（{release_line(official)} 线），"
                           f"但 site.json 只声明了 {sorted(lines) or '（无）'}",
            })
        elif official and declared and official != declared:
            findings.append({
                "kind": "stale", "firmware": firmware_id,
                "message": f"官方{label} {official} 比声明的 {declared} 新",
            })
        if declared and public_dir is not None and declared not in local:
            findings.append({
                "kind": "gap", "firmware": firmware_id,
                "message": f"声明了{label} {declared}，但发布树里没有该版本"
                           f"（{firmware_id}/releases/{declared}/targets 不存在）",
            })

    for version in sorted(local, key=lambda name: local[name], reverse=True):
        if official_versions and version not in official_versions:
            findings.append({
                "kind": "local", "firmware": firmware_id,
                "message": f"本地有 {version}，但不在官方版本列表里（本地构建？）",
            })

    return {
        "id": firmware_id,
        "official": {"stable": official_stable, "oldstable": official_oldstable},
        "declared": {"stable": declared_stable, "oldstable": declared_oldstable},
        "local": sorted(local, key=lambda name: local[name], reverse=True),
        "has_upstream": bool(official_stable or official_oldstable or official_versions),
        "findings": findings,
    }


def render_markdown(rows: list[dict], upstream_time: str, public_dir: Path | None) -> str:
    """生成 Markdown 报告（用于命令行与 GITHUB_STEP_SUMMARY）。"""
    lines = ["## 站点覆盖率", ""]
    if upstream_time:
        lines.append(f"官方版本事实抓取于 {upstream_time}。")
    lines.append(f"发布树：{'已参与比对（' + str(public_dir) + '）' if public_dir else '未参与比对'}。")
    lines += ["", "| 发行版 | 官方稳定 | 官方旧稳定 | 声明稳定 | 声明旧稳定 | 本地版本 |",
              "| --- | --- | --- | --- | --- | --- |"]
    for row in rows:
        official, declared, local = row["official"], row["declared"], row["local"]
        lines.append("| {id} | {os} | {oo} | {ds} | {do} | {local} |".format(
            id=row["id"],
            os=official["stable"] or "—", oo=official["oldstable"] or "—",
            ds=declared["stable"] or "—", do=declared["oldstable"] or "—",
            local=", ".join(local) if local else "—",
        ))

    lines += ["", "### 发现", ""]
    findings = [item for row in rows for item in row["findings"]]
    if not findings:
        lines.append("- ✅ 未发现缺口")
    else:
        for item in findings:
            lines.append(f"- {FINDING_ICONS.get(item['kind'], '•')} **{item['kind']}**"
                         f"（{item['firmware']}）：{item['message']}")
    lines += ["", "> drift / gap 为 fail 级（用 `--fail-on` 决定是否退出 1）；"
                  "stale / local 为提示级。", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="比对官方版本事实、站点声明与发布树")
    parser.add_argument("--config", default="config/site.json", help="站点配置")
    parser.add_argument("--upstream", default="", help="上游版本事实（缺省则只做本地检查）")
    parser.add_argument("--public-dir", default="", help="发布树根目录（缺省则不比对本地）")
    parser.add_argument("--fail-on", default="none", choices=sorted(FAIL_LEVELS),
                        help="达到哪个级别就退出 1（默认 none：只报告）")
    parser.add_argument("--summary", default="", help="把 Markdown 报告追加到该文件"
                                                    "（CI 传 GITHUB_STEP_SUMMARY）")
    parser.add_argument("--quiet", action="store_true", help="不打印报告到 stdout")
    args = parser.parse_args()

    config_path = Path(args.config)
    if not config_path.is_file():
        print(f"错误: 配置文件不存在: {config_path}", file=sys.stderr)
        return 2
    config = load_json(config_path)
    if not isinstance(config, dict):
        print(f"错误: 配置无法解析: {config_path}", file=sys.stderr)
        return 2

    fail_levels = FAIL_LEVELS[args.fail_on]
    upstream: dict = {}
    upstream_time = ""
    if args.upstream:
        upstream_path = Path(args.upstream)
        if not upstream_path.is_file():
            if fail_levels:
                print(f"错误: --fail-on={args.fail_on} 需要上游版本事实，但 {upstream_path} 不存在",
                      file=sys.stderr)
                return 2
            warn(f"上游版本事实不存在，只做本地检查: {upstream_path}")
        else:
            data = load_json(upstream_path)
            if isinstance(data, dict) and isinstance(data.get("firmwares"), dict):
                upstream = data["firmwares"]
                upstream_time = str(data.get("fetched_at", ""))
            else:
                warn(f"上游版本事实格式不符，忽略: {upstream_path}")

    public_dir = Path(args.public_dir) if args.public_dir else None
    if public_dir is not None and not public_dir.is_dir():
        print(f"错误: 发布目录不存在: {public_dir}", file=sys.stderr)
        return 2

    # 门槛各自需要对应的输入：要求判某某却拿不到依据时不能静默通过
    if "drift" in fail_levels and not upstream:
        print(f"错误: --fail-on={args.fail_on} 需要可用的上游版本事实"
              f"（--upstream 指向 fetch-upstream-versions.py 的产物）", file=sys.stderr)
        return 2
    if "gap" in fail_levels and public_dir is None:
        print(f"错误: --fail-on={args.fail_on} 需要 --public-dir 才能判断发布缺口",
              file=sys.stderr)
        return 2

    rows = [compare_firmware(firmware, upstream.get(str(firmware.get("id", "")), {}), public_dir)
            for firmware in config.get("firmwares", []) if isinstance(firmware, dict)]

    report = render_markdown(rows, upstream_time, public_dir)
    if not args.quiet:
        print(report)
    if args.summary:
        try:
            with Path(args.summary).open("a", encoding="utf-8") as handle:
                handle.write(report + "\n")
        except OSError as exc:
            print(f"错误: 摘要写入失败: {exc}", file=sys.stderr)
            return 2

    findings = [item for row in rows for item in row["findings"]]
    hits = [item for item in findings if item["kind"] in fail_levels]
    if hits:
        print(f"错误: {len(hits)} 项达到 --fail-on={args.fail_on} 门槛", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
