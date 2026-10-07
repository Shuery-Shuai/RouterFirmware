#!/usr/bin/env python3
"""抓取上游官方下载站的版本事实（.versions.json），归一化成站点可消费的产物。

站点页面要回答两件事：官方现在把哪个版本当作最新稳定版 / 旧稳定版，以及官方
还有哪些历史版本。答案在官方下载站的 /.versions.json 里（OpenWrt 与
ImmortalWrt 同构）：

    {"stable_version": "25.12.5", "oldstable_version": "24.10.8",
     "upcoming_version": "", "versions_list": ["25.12.5", "25.12.4", ...]}

上游地址来自 config/site.json 里每个固件声明的 downloads（下载站根目录，抓取
<downloads>/.versions.json），脚本内不写死任何发行版：未声明 downloads 的固件跳过并
告警，--source=ID=URL 可临时覆盖。抓取失败时**不会静默当作「官方没有」**：先回退到
上次的产物（同一格式，见 --cache）并显式告警；连缓存都没有才退出 1，且不写出残缺产物。

产物格式（schema 1）:
    {
      "schema": 1,
      "fetched_at": "2026-10-07T13:05:00+00:00",
      "firmwares": {
        "openwrt": {
          "source": "https://downloads.openwrt.org/.versions.json",
          "state": "fresh",           # fresh=本次抓到；cache=回退到上次产物
          "fetched_at": "2026-10-07T13:05:00+00:00",
          "stable": "25.12.5", "oldstable": "24.10.8", "upcoming": "",
          "versions": ["25.12.5", "25.12.4", ...]
        }
      }
    }

用法:
  ./fetch-upstream-versions.py [--output=upstream-versions.json]
                               [--cache=upstream-versions.json]
                               [--config=config/site.json]
                               [--source=ID=URL]... [--offline] [--timeout=20] [--quiet]

  --source 可重复，覆盖 config 里声明的下载站地址；取值以 .json 结尾时视为完整
  URL，否则补上 /.versions.json（测试用 file:// 夹具走这条路）。

退出状态:
  0 - 产物已写出（可能有告警：回退缓存、未声明上游的固件、被丢弃的异常条目）
  1 - 已声明来源的固件拿不到数据（抓取失败且无可用缓存），或配置/产物读写失败

依赖: 仅 Python 标准库。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 1

VERSIONS_FILE = ".versions.json"

# 版本号形状：25.12.5 / 24.10.3 / 25.12.0-rc5；允许前导 v（归一化时去掉）
_VERSION_RE = re.compile(r"^v?\d+(?:\.\d+)+(?:[-._][A-Za-z0-9.]+)?$")

_USER_AGENT = "RouterFirmware-site-bot (+https://github.com/Shuery-Shuai/RouterFirmware)"


def log(message: str, quiet: bool = False) -> None:
    """打印一行日志（--quiet 时静默）；告警一律走 stderr，不受 --quiet 影响。"""
    if not quiet:
        print(message)


def warn(message: str) -> None:
    print(f"警告: {message}", file=sys.stderr)


def now() -> str:
    """当前 UTC 时间（RFC 3339，秒级）。"""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def resolve_url(source: str) -> str:
    """把 --source 的取值解析成完整 URL：给的是目录就补 /.versions.json。"""
    return source if source.endswith(".json") else f"{source.rstrip('/')}/{VERSIONS_FILE}"


def fetch(url: str, timeout: float) -> object:
    """抓取并解析上游 JSON（file:// 同样支持，便于离线测试）。"""
    request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def normalize(payload: object, url: str) -> dict:
    """把上游 .versions.json 归一化成一条记录；形状不对时抛 ValueError。"""
    if not isinstance(payload, dict):
        raise ValueError("顶层不是 JSON 对象")
    stable = payload.get("stable_version")
    if not isinstance(stable, str):
        raise ValueError("缺少 stable_version 字段")
    raw_versions = payload.get("versions_list")
    if not isinstance(raw_versions, list):
        raise ValueError("缺少 versions_list 字段")

    versions: list[str] = []
    dropped = 0
    for item in raw_versions:
        if not isinstance(item, str) or not _VERSION_RE.match(item):
            dropped += 1
            continue
        version = item.removeprefix("v")
        if version not in versions:
            versions.append(version)
    if dropped:
        warn(f"{url}: versions_list 里有 {dropped} 个条目不是合法版本号，已丢弃")

    def optional(key: str) -> str:
        value = payload.get(key)
        return value.removeprefix("v") if isinstance(value, str) else ""

    stable = stable.removeprefix("v")
    if stable and stable not in versions:
        warn(f"{url}: stable_version={stable} 不在 versions_list 里（上游数据不一致）")
    return {
        "stable": stable,
        "oldstable": optional("oldstable_version"),
        "upcoming": optional("upcoming_version"),
        "versions": versions,
    }


def load_cache(path: Path) -> dict:
    """读取上次产物作为回退来源；不存在或格式不符时返回空表并告警。"""
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"缓存 {path} 无法解析，忽略: {exc}")
        return {}
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        warn(f"缓存 {path} 不是本脚本的产物（schema != {SCHEMA}），忽略")
        return {}
    firmwares = data.get("firmwares")
    return firmwares if isinstance(firmwares, dict) else {}


def cached_record(entry: object) -> dict | None:
    """从缓存条目里取出可用的记录；条目残缺时返回 None。"""
    if not isinstance(entry, dict) or not isinstance(entry.get("versions"), list):
        return None
    return {
        "fetched_at": str(entry.get("fetched_at", "")),
        "stable": str(entry.get("stable", "")),
        "oldstable": str(entry.get("oldstable", "")),
        "upcoming": str(entry.get("upcoming", "")),
        "versions": [item for item in entry["versions"] if isinstance(item, str)],
    }


def collect(sources: dict[str, str], cache: dict, offline: bool,
            timeout: float, quiet: bool) -> tuple[dict[str, dict], bool]:
    """逐个固件取数：优先抓取，失败回退缓存；返回 (记录表, 是否有固件彻底取不到)。"""
    records: dict[str, dict] = {}
    failed = False
    for firmware, url in sources.items():
        fresh: dict | None = None
        if not offline:
            try:
                fresh = normalize(fetch(url, timeout), url)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                warn(f"{firmware}: 抓取失败（{url}）: {exc}")
        if fresh is not None:
            records[firmware] = {"source": url, "state": "fresh", "fetched_at": now(), **fresh}
            log(f"  {firmware}: 稳定 {fresh['stable'] or '—'} / 旧稳定 "
                f"{fresh['oldstable'] or '—'}（{len(fresh['versions'])} 个版本）", quiet)
            continue
        fallback = cached_record(cache.get(firmware))
        if fallback is None:
            warn(f"{firmware}: 既抓不到也没有可用缓存")
            failed = True
            continue
        warn(f"{firmware}: 回退到缓存（{fallback['fetched_at'] or '抓取时间未知'}）")
        records[firmware] = {"source": url, "state": "cache", **fallback}
    return records, failed


def declared_firmwares(config: object) -> list[dict]:
    """取 config/site.json 里声明的固件条目（顺序即声明顺序）。"""
    firmwares = config.get("firmwares") if isinstance(config, dict) else None
    if not isinstance(firmwares, list):
        return []
    return [fw for fw in firmwares
            if isinstance(fw, dict) and isinstance(fw.get("id"), str) and fw["id"]]


def parse_sources(values: list[str] | None) -> dict[str, str]:
    """解析 --source=ID=URL（可重复）。"""
    sources: dict[str, str] = {}
    for raw in values or []:
        firmware, separator, url = raw.partition("=")
        if not separator or not firmware.strip() or not url.strip():
            raise ValueError(f"--source 需要 ID=URL 形式，当前值: {raw}")
        sources[firmware.strip()] = url.strip()
    return sources


def write_artifact(path: Path, records: dict[str, dict], quiet: bool) -> bool:
    """原子写出产物（先写 .tmp 再替换，避免下游读到半截文件）。"""
    artifact = {"schema": SCHEMA, "fetched_at": now(), "firmwares": records}
    temporary = path.with_name(path.name + ".tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary.write_text(json.dumps(artifact, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
        temporary.replace(path)
    except OSError as exc:
        print(f"错误: 产物写入失败: {exc}", file=sys.stderr)
        temporary.unlink(missing_ok=True)
        return False
    log(f"已生成 {path}", quiet)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="抓取并归一化上游官方版本事实")
    parser.add_argument("--output", default="upstream-versions.json",
                        help="产物路径（默认 upstream-versions.json）")
    parser.add_argument("--cache", default=None,
                        help="抓取失败时的回退来源（默认与 --output 同一文件）")
    parser.add_argument("--config", default="config/site.json",
                        help="站点配置，决定抓哪些固件（默认 config/site.json）")
    parser.add_argument("--source", action="append", default=None, metavar="ID=URL",
                        help="覆盖某个固件的上游地址（可重复）")
    parser.add_argument("--offline", action="store_true",
                        help="不访问网络，只用缓存（本地预览与测试用）")
    parser.add_argument("--timeout", type=float, default=20.0, help="单个请求超时秒数")
    parser.add_argument("--quiet", action="store_true", help="不打印细节")
    args = parser.parse_args()

    try:
        overrides = parse_sources(args.source)
    except ValueError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 1

    config_path = Path(args.config)
    if not config_path.is_file():
        print(f"错误: 配置文件不存在: {config_path}", file=sys.stderr)
        return 1
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"错误: 配置无法解析: {exc}", file=sys.stderr)
        return 1

    output = Path(args.output)
    cache_path = Path(args.cache) if args.cache else output
    sources: dict[str, str] = {}
    for firmware in declared_firmwares(config):
        fid = firmware["id"]
        downloaded = firmware.get("downloads")
        source = overrides.get(fid) or (downloaded if isinstance(downloaded, str) else None)
        if not source:
            warn(f"{fid}: config 未声明 downloads 也没有 --source，跳过")
            continue
        sources[fid] = resolve_url(source)
    if not sources:
        print("错误: 没有任何可抓取的固件（检查 config 的 firmwares[].downloads 或 --source）",
              file=sys.stderr)
        return 1

    if args.offline:
        log("离线模式：不访问网络，只用缓存", args.quiet)
    log("抓取上游版本事实:", args.quiet)
    records, failed = collect(sources, load_cache(cache_path), args.offline, args.timeout, args.quiet)
    if failed:
        print("错误: 有固件既抓不到也没有可用缓存，未写出产物", file=sys.stderr)
        return 1
    return 0 if write_artifact(output, records, args.quiet) else 1


if __name__ == "__main__":
    sys.exit(main())
