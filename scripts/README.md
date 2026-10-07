# 编译脚本集合

## 概述

OpenWrt 编译工具链已拆分为模块化脚本，支持独立运行或通过主协调脚本组合使用。

所有脚本支持三种参数传递方式，并提供 `--help` 选项。

## 脚本结构

### 主脚本

- **make.sh** - 主协调脚本，按序调用其他脚本完成整个编译流程

### 功能脚本

- **source-management.sh** - 源码管理（克隆、更新、切换版本）
- **feeds-management.sh** - Feeds 管理（更新、安装、运行 DIY 脚本）
- **config-management.sh** - 配置管理（生成配置、应用补丁、生成 feeds 列表）
- **build.sh** - 编译（下载、编译）

### 辅助脚本

- **common.sh** - 共享工具库（日志、验证、参数解析等）
- **copy-pre-files.sh** - 复制编译前文件
- **copy-bin-files.sh** - 复制编译产物（支持 snapshots 和 releases 目录结构）
- **public-compressor.sh** - 将 public 目录打包为 zip 压缩包
- **public-uploader.sh** - 上传 zip 包到 GitHub Release 并返回直链，支持 Token / gh CLI 认证
- **upstream-tag.sh** - 上游版本 Tag 检查（输出跟踪矩阵与发行线最新 Tag）
- **prune-releases.py** - 按 keep_stable 裁剪发布树中的历史稳定版（保留最近 N 个）
- **fetch-upstream-versions.py** - 抓取上游官方版本事实（.versions.json），失败回退缓存
- **generate-site-landing.py** - 生成站点首页与各发行版首页（只链接真实存在的目录）
- **generate-site-listings.py** - 为发布树每个目录生成官方风格的目录列表页
- **site-coverage.py** - 官方事实 × 站点声明 × 发布树的三方覆盖率比对（CI 用它做缺口告警）
- **verify-site-structure.sh** - 发布前校验站点目录结构（守门）

## 使用方式

所有脚本支持三种参数传递方式：

1. **位置参数**（传统方式）：`./script.sh value1 value2`
2. **命名参数**：`./script.sh --param=value`
3. **混合方式**：`./script.sh value1 --param2=value2`

**优先级**：命名参数 > 位置参数 > 默认值

查看任意脚本的帮助：

```bash
./make.sh --help
./build.sh -h
```

### 完整编译流程

```bash
# 位置参数（传统方式）
./make.sh [firmware] [version] [profile] [ask-menuconfig]

# 命名参数
./make.sh --firmware=TYPE --version=VER --profile=PROF --ask-menuconfig=BOOL

# 布尔选项可省略取值：--ask-menuconfig 等价于 --ask-menuconfig=true
./make.sh --firmware=openwrt --ask-menuconfig

# 混合使用
./make.sh immortalwrt --version=snapshots --profile=bananapi_bpi-r4
```

参数说明：

- `firmware` - 固件类型，默认 `immortalwrt`（支持: openwrt, immortalwrt）
- `version` - 版本号，默认 `snapshots`
- `profile` - 设备 profile，默认 `bananapi_bpi-r4`
- `ask-menuconfig` - 是否在编译前询问运行 menuconfig，默认 `false`（仅 TTY 环境下会真正询问）
- `--non-interactive` - 强制非交互：提示一律取默认值，无 TTY 时自动生效
- `--prompt-timeout=SEC` - 交互提示超时秒数，`0` 表示永不超时，默认 `60`
- `--no-log-file` - 关闭文件日志（默认：本地开启并写入 `logs/build-<时间戳>.log`，CI 关闭）
- `--capture-build-log[=PATH]` - 留存 `make` 原始输出（默认：本地开启并写入 `logs/build-<时间戳>.make.log`，CI 关闭）
- `--no-capture-build-log` - 关闭原始输出留存（磁盘紧张时使用）
- `--allow-diy-failure` - 允许 `diy-part1/2.sh` 失败后继续（默认：失败即终止构建）

交互提示的三态语义（menuconfig 与差异配置保存均适用）：

| 场景 | 取值 |
| ---- | ---- |
| 非 TTY（CI / docker 无 `-it`） | 一律取安全默认（不运行 menuconfig、不覆盖差异配置） |
| TTY + 回车 | 取提示语里的大写默认值（`[Y/n]` → 运行，`[y/N]` → 保留） |
| TTY + 超时 | 与回车相同，并在日志中记录超时 |

### 构建失败诊断

编译失败时脚本会自动补齐"失败现场"，避免 FATAL 旁边只有硬编码路径：

1. **收割 OpenWrt 自己的失败日志**：列出 `sources/<firmware>/logs/` 中**本次构建新增**的文件并打印各自尾部
   （例如 `logs/package/feeds/packages/<pkg>/dump.txt`）。镜像组装、签名等阶段失败时不会留下这类日志，
   此时会明确提示"OpenWrt 未产生失败日志目录"。
2. **打印留存文件位置与尾部**：`logs/build-<时间戳>.make.log` 含下载、并行编译、单线程重试的完整原始输出
   （本地默认开启，CI 关闭以免占用 runner 的 14GB 磁盘）。

失败时的输出形如：

```text
[💀 FATAL] [build] 单线程重试仍然失败
[🚫 ERROR] [build] 本轮运行日志: .../logs/build-20261005_153929.log
[🚫 ERROR] [build] 构建原始输出: .../logs/build-20261005_153929.make.log（尾部 40 行）
    ...（make 原始输出尾部）...
[🚫 ERROR] [build] OpenWrt 失败现场: .../logs/package/feeds/packages/<pkg>/dump.txt
    ...（dump.txt 尾部）...
```

示例：

```bash
./make.sh immortalwrt snapshots bananapi_bpi-r4 false
./make.sh --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4 --ask-menuconfig=false
./make.sh  # 使用所有默认值
```

### 独立运行子脚本

#### source-management.sh

```bash
./source-management.sh <source_dir> <firmware> <version>
./source-management.sh --source-dir=PATH --firmware=TYPE --version=VER
```

示例：

```bash
./source-management.sh ./sources immortalwrt snapshots
./source-management.sh --source-dir=./sources --firmware=openwrt --version=23.05.3
```

功能：克隆仓库（目录不存在时）或更新并切换到指定版本（分支或标签）。

#### feeds-management.sh

```bash
./feeds-management.sh <source_dir> <firmware>
./feeds-management.sh --source-dir=PATH --firmware=TYPE
```

示例：

```bash
./feeds-management.sh ./sources/immortalwrt immortalwrt
./feeds-management.sh --source-dir=./sources/immortalwrt --firmware=immortalwrt
```

功能：运行 diy-part1/2.sh（如果存在）、更新并安装 feeds。

#### config-management.sh

```bash
./config-management.sh <source_dir> <firmware> <version> <profile> [ask-menuconfig]
./config-management.sh --source-dir=PATH --firmware=TYPE --version=VER --profile=PROF --ask-menuconfig=BOOL
./config-management.sh --source-dir=PATH --ask-menuconfig --prompt-timeout=0
```

示例：

```bash
./config-management.sh ./sources/immortalwrt immortalwrt snapshots bananapi_bpi-r4 false
./config-management.sh --source-dir=./sources/immortalwrt --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
```

功能：生成默认配置（make defconfig）、生成 customfeeds.list、应用 diff.config、可选运行 menuconfig。

说明：

- 完整配置文件（`<firmware>.config`）只由人工维护，脚本从不回写；
- 差异配置文件（`<firmware>.<version>.diff.config`）用于保证构建期配置一致，**允许不保存**，因此其覆盖提示默认取否；
- 目标差异文件不存在时会直接落盘，并在日志中提示需人工确认后纳入版本控制；
- 生成物是"相对上游构建系统默认配置"的**完整 overlay**（上游 `scripts/diffconfig.sh` 忽略传入参数），
  不是与 `.config.defconfig` 的逐项 diff——回写它可完整复现目标配置，属预期行为；
- 编译缓存 ccache 由脚本自动启用：检测到 `ccache` 命令时幂等写入 `CONFIG_CCACHE=y`，
  缺失时仅告警（不阻断构建，也不再静默跳过）。

#### build.sh

```bash
./build.sh <source_dir>
./build.sh --source-dir=PATH
```

示例：

```bash
./build.sh ./sources/immortalwrt
./build.sh --source-dir=./sources/immortalwrt
```

功能：多线程下载源码包并编译固件；失败后先做并行重试、再回退单线程详细模式
（`--retry-count` / `--serial-retry-count` 可调，重试前会做执行位自检）。

#### copy-pre-files.sh

```bash
./copy-pre-files.sh <firmware> <version> <profile>
./copy-pre-files.sh --firmware=TYPE --version=VER --profile=PROF
```

示例：

```bash
./copy-pre-files.sh immortalwrt snapshots bananapi_bpi-r4
./copy-pre-files.sh --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
```

功能：将 .config、diff.config、diy-part1/2.sh 及 files/ 目录复制到源码目录。

#### copy-bin-files.sh

```bash
./copy-bin-files.sh <firmware> <version>
./copy-bin-files.sh --firmware=TYPE --version=VER
```

示例：

```bash
./copy-bin-files.sh immortalwrt snapshots
./copy-bin-files.sh --firmware=openwrt --version=23.05.2
```

功能：将编译产物分发到 public/ 目录（snapshots 直接复制，releases 按**完整版本号**隔离存放）。

#### public-compressor.sh

```bash
./public-compressor.sh [输出路径]
./public-compressor.sh --help
```

示例：

```bash
./public-compressor.sh                          # 生成 public.zip
./public-compressor.sh /tmp/firmware.zip        # 指定输出路径
```

功能：将仓库根目录下的 public 文件夹压缩为 zip 包，用于手动上传部署。

#### public-uploader.sh

```bash
./public-uploader.sh [tag] [file]
./public-uploader.sh [options]
./public-uploader.sh --help
```

参数：

- `tag` - 可选的 Release 标签，省略时自动生成 manual-upload-时间戳
- `file` - 要上传的文件，默认 public.zip

选项：

- `--tag=TAG` - 指定 Release 标签
- `--file=FILE` - 指定文件路径
- `--token=TOKEN` - 直接提供 GitHub Token（不推荐）
- `--help` - 显示帮助

示例：

```bash
# 全自动：自动生成 tag，上传默认 public.zip
./public-uploader.sh

# 指定 tag
./public-uploader.sh v1.0.0

# 指定 tag 和文件
./public-uploader.sh v1.0.0 /path/to/custom.zip

# 使用命名参数
./public-uploader.sh --tag=v1.0.0 --file=public.zip
```

功能：将打包好的 zip 上传到 GitHub Release，输出可直接用于手动部署工作流的直链下载地址。支持交互式选择认证方式（Token 或 gh CLI），自动创建 Release 时生成包含文件大小、修改时间等详细信息的 Markdown 描述。

#### upstream-tag.sh

```bash
./upstream-tag.sh plan [--config=PATH]
./upstream-tag.sh select [--config=PATH] --firmware=FW --line=LINE
./upstream-tag.sh --help
```

示例：

```bash
# 输出跟踪矩阵（供 GitHub Actions matrix 使用）
./upstream-tag.sh plan

# 输出 25.12 发行线上最新的正式版 Tag
./upstream-tag.sh select --firmware=openwrt --line=25.12
```

功能：读取 `config/site.json` 声明的 `stable` / `oldstable` 发行线，通过 `git ls-remote` 查询上游版本 Tag，供 `upstream-tag-checker.yml` 判断是否需要触发正式版编译。

- `plan`：输出单行 JSON 数组（matrix include 列表），无跟踪目标时输出 `[]`
- `select`：输出发行线上最新的正式版 Tag（如 `v25.12.6`）；该发行线尚无正式版时回退到最新预发布版（`rc` / `beta` / `alpha`），无 Tag 时输出为空
- 是否已经编译过由调用方（工作流缓存）判断，脚本不维护基线；新增发行线只需在 `site.json` 中声明
- 上游仓库地址取自 `site.json` 的 `firmwares[].repo`（脚本里不写死发行版数据）；未声明 `repo` 的固件会被 `plan` 跳过、被 `select` 报错
- 日志一律写入 stderr，stdout 只输出结果，便于工作流捕获

#### prune-releases.py

```bash
./prune-releases.py [--public-dir=public] [--config=config/site.json]
                    [--keep=N] [--protect=25.12.5,24.10.3] [--dry-run] [--quiet]
```

示例：

```bash
# 预演：只打印将要删除的目录
./prune-releases.py --dry-run

# 按 site.json 的 keep_stable 裁剪（CI 里就是这一条）
./prune-releases.py --public-dir=public --config=config/site.json --protect=25.12.5

# 临时覆盖保留数量
./prune-releases.py --keep=1
```

功能：删除 `public/<固件>/releases/<版本>/` 中超出保留数量的稳定版目录（**真的删除整棵目录**，CI 用它控制发布树体积）。

- 保留数量取自 `config/site.json`：固件条目的 `keep_stable` 覆盖站点级同名设定，`--keep` 再覆盖两者；`0` 表示不裁剪，缺省用内置默认值 2
- 计数口径：所有版本目录都参与排序（版本号逐段按整数比较，`25.12.10` > `25.12.2`）；被钉住的版本即使排在 N 名之外也保留
- 钉住不删：`site.json` 的 `stable` / `oldstable` / `archive` 声明过的版本，以及 `--protect` 传入的版本（CI 传入本次正在编译的版本）
- 绝不触碰：`snapshots/`、`releases/packages-*`、目录名不含数字的目录、符号链接与非目录条目；删除前校验目标必须是 `releases/` 的直接子目录
- 回归测试：`bash scripts/tests/prune-releases-test.sh`（改删除逻辑后先跑通它）

#### fetch-upstream-versions.py

```bash
./fetch-upstream-versions.py [--output=upstream-versions.json]
                             [--cache=upstream-versions.json]
                             [--config=config/site.json]
                             [--source=ID=URL]... [--offline] [--timeout=20] [--quiet]
```

示例：

```bash
# CI：抓取上游版本事实，产物同时是下次运行的回退缓存
./fetch-upstream-versions.py --output=upstream-versions.json

# 本地：不联网，直接用上次产物
./fetch-upstream-versions.py --offline --cache=upstream-versions.json
```

功能：抓取各上游官方下载站的 `/.versions.json`（`stable_version` / `oldstable_version` /
`upcoming_version` / `versions_list`，OpenWrt 与 ImmortalWrt 同构），归一化成一份站点
可消费的版本事实产物，供落地页生成器与守门脚本使用。

- 抓哪些固件由 `config/site.json` 的固件清单决定，上游地址取自每个固件的 `downloads`（下载站根目录，自动补 `/.versions.json`）；脚本里不写死任何发行版，未声明 `downloads` 的固件跳过并告警（不中止），`--source=ID=URL` 可临时覆盖
- **抓取失败不会静默当作「官方没有」**：先回退到上次产物（`--cache`，缺省与 `--output` 同一文件）并在 stderr 告警，条目 `state` 标为 `cache` 且保留原始 `fetched_at`；连缓存都没有才退出 1，且不写出残缺产物
- `--offline` 完全不访问网络（本地预览与测试用）；产物带 `schema` 字段做格式版本（当前为 1）；写出走「先写 `.tmp` 再替换」，下游不会读到半截文件
- 归一化：`versions_list` 里非法条目丢弃（数字 / null / 空串 / 非版本字符串）、去掉前导 `v`、去重；`stable_version` 不在 `versions_list` 里只告警不失败（上游数据不一致，交由调用方判断）
- 回归测试：`bash scripts/tests/fetch-upstream-versions-test.sh`（全程离线，41 条断言）

#### generate-site-landing.py

```bash
./generate-site-landing.py [--public-dir=public] [--config=config/site.json]
                           [--upstream=upstream-versions.json] [--quiet]
```

功能：生成站点首页与各发行版首页（栏目骨架对齐官方发布站：Stable / Old Stable /
Development Snapshots / Release Archive）。三个事实来源各管一件事：`config/site.json`
给**意图**（跟哪些发行版、当前稳定版是谁、站点装饰），发布树给**现实**（哪些版本
真的发布了），`--upstream` 给**官方标定**（用于提示与标注）。脚本里不写死任何
发行版或设备数据。

- **只链接真实存在的目录**：稳定版 / 旧稳定版 / 快照条目在 `<id>/releases/<版本>/targets/`
  （或 `<id>/snapshots/targets/`）存在时才渲染成链接，否则渲染为纯文本 + 提示
  （「官方已发布 X，本镜像尚未构建」/「本镜像尚未构建」），因此页面不会产生死链
- **版本归档从发布树派生**：列出 `releases/` 下除声明 `stable` / `oldstable` 之外、
  且含 `targets/` 的目录（按版本号倒序）；不在官方 `versions_list` 里的标「本地构建」。
  这条栏目不需要在 `site.json` 手工记账
- 声明的版本落后于官方（`--upstream` 里的 `stable` / `oldstable`）时向 stderr 告警，
  但页面已按现实渲染，不会因此失败
- `--upstream` 缺失 / 损坏 / 条目为 `cache` 状态时告警并退化渲染，不中止
- 站点装饰全部来自配置：`stylesheet`（官方样式表，未配置就不引用）、`package_key`
  （软件包仓库公钥路径）、`scripts_path`（构建脚本与配置的位置）
- 回归测试：`bash scripts/tests/generate-site-landing-test.sh`（全程离线，40 条断言）

#### generate-site-listings.py

```bash
./generate-site-listings.py [--public-dir=public] [--config=config/site.json]
                            [--skip=assets/site] [--landing-paths=...] [--dry-run] [--quiet]
```

功能：为发布树里每个目录生成官方风格的目录列表页（`index.html`），规格对照
downloads.immortalwrt.org 的 `dir-index.cgi` 输出。

- 站点根与各发行版根的 `index.html` 归 `generate-site-landing.py`（落地页目录由
  `--config` 的固件清单识别，本脚本跳过不写），其余目录逐个生成；跳过 `assets/site`
  与隐藏项，避免父目录列表出现指向 404 的死链
- 官方样式表来自 `config/site.json` 的 `stylesheet`（未配置就只用站点自身的 base.css）
- 两个生成器的执行顺序固定为先 listings 后 landing，`verify-site-structure.sh` 的
  断言 8 会抓「落地页被列表页覆盖」这类顺序错误

#### site-coverage.py

```bash
./site-coverage.py [--config=config/site.json] [--upstream=upstream-versions.json]
                   [--public-dir=public] [--fail-on=none|drift|gap|any]
                   [--summary=FILE] [--quiet]
```

功能：把「官方版本事实 × 站点声明 × 发布树」三方 join 成一张覆盖率报告，回答
「上游换了哪条线我们没跟、声明了却没发布的是谁、本地多出来的是什么」。

- 分级：`drift`（官方 stable / oldstable 的发行线不在声明里）与 `gap`（声明了却没发布）
  是 fail 级；`stale`（同线上官方补丁更新）与 `local`（本地有、官方没有）是提示级
- `--fail-on` 决定退出码：`none`（默认，只报告）/ `drift` / `gap` / `any`；要求的
  依据缺失时（判 drift 却没有上游事实、判 gap 却没有发布树）退出 2，**不静默通过**
- `--summary` 把报告追加到文件（CI 传 `$GITHUB_STEP_SUMMARY`，报告直接进 Job Summary）
- CI 用法：`rtfw-builder.yml` 用 `--fail-on=none` 只报告（发布本身有效，不该被缺口卡住）；
  `upstream-tag-checker.yml` 的 coverage job 用 `--fail-on=drift` 变红提醒「上游换线了」
- 回归测试：`bash scripts/tests/site-coverage-test.sh`（全程离线，21 条断言）

### 站点配置（config/site.json）

站点与构建的实例数据都在这里，脚本不写死发行版 / 设备 / 上游地址：

| 字段 | 作用 | 主要读取方 |
| --- | --- | --- |
| `title` / `description` / `description_en` | 站点首页标题与描述（双语） | 落地页生成器 |
| `stylesheet` | 官方样式表地址（可选；未配置则不引用跨域样式） | 两个站点生成器 |
| `package_key` | 软件包仓库公钥路径（可选） | 落地页生成器 |
| `scripts_path` | 构建脚本与配置的发布路径（可选） | 落地页生成器 |
| `keep_stable` | 默认保留的稳定版数量（站点级，可被固件级覆盖） | prune-releases.py |
| `defaults.firmware` / `version` | 编译缺省的固件与版本（工作流输入为空时用它） | rtfw-builder.yml、构建脚本 |
| `defaults.profile` | 设备 profile 缺省值 | config-management.sh、copy-pre-files.sh |
| `defaults.target` / `device` | target/subtarget 与设备名缺省值 | compare-with-official.sh |
| `defaults.site_icon.lan_groups` | 站点图标网口分组（如 `2+2`） | build-site-icon.py |
| `firmwares[].id` | 发行版目录名，也是发布树里的一级目录 | 全部站点脚本 |
| `firmwares[].title` / `title_en` | 展示名（双语） | 落地页生成器 |
| `firmwares[].repo` | 上游 Git 仓库（Tag 跟踪用，可选） | upstream-tag.sh |
| `firmwares[].downloads` | 上游下载站根目录（版本事实与官方站根，可选） | fetch-upstream-versions.py、compare-with-official.sh |
| `firmwares[].stable` / `oldstable` | 当前 / 旧稳定版声明（意图；也用于 prune 钉住与发行线跟踪） | 落地页、prune、upstream-tag |
| `firmwares[].snapshots` | 是否展示开发快照栏目 | 落地页生成器 |
| `firmwares[].archive` | 手工归档声明（钉住不删；页面归档栏目已改为从发布树派生） | prune-releases.py |
| `firmwares[].keep_stable` | 固件级保留数量覆盖 | prune-releases.py |

> 缺省值一律遵循「命令行参数 → `config/site.json` → 脚本内兜底字面值」的优先级；
> shell 脚本用 `common.sh` 的 `config_value` / `config_firmware_value` 读取配置
> （优先 python3，退回 jq，都不可用时由调用方兜底）。

## 编译产物目录结构

### Snapshots 版本

```pre
public/immortalwrt/snapshots/
├── targets/          # 固件镜像
│   └── mediatek/filogic/...
└── packages/         # 编译产物包
    └── x86_64/base/...
```

### Releases 版本

releases 版本的 packages 与 targets 一样，按**完整版本号**隔离存放：

```pre
public/immortalwrt/releases/
├── 25.12.0/
│   ├── targets/                    # 版本特定的固件
│   └── packages/                   # 该版本的软件包
└── 25.12.1/
    ├── targets/
    └── packages/
```

**为什么不按主次版本共享 packages**：GitHub Pages 没有服务端符号链接，artifact 打包会把软链展开
成实体副本，"共享"不会省下任何体积，反而多一层间接；因此 packages 与 targets 同样按完整版本号存放。

## 构建流程

```pre
make.sh (主协调脚本)
├── 1. source-management.sh  - 克隆/更新源码、切换版本
├── 2. 清理旧产物 (bin 目录)
├── 3. copy-pre-files.sh     - 复制配置文件和 DIY 脚本
├── 4. feeds-management.sh   - DIY 脚本、更新/安装 feeds
├── 5. config-management.sh  - 生成默认配置、customfeeds.list、应用 diff.config
├── 6. build.sh              - 下载源码包、编译
└── 7. copy-bin-files.sh     - 分发编译产物
```

## CI/CD 集成示例

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/scripts"

# 完整编译（推荐使用命名参数，可读性更好）
./make.sh \
  --firmware=immortalwrt \
  --version=snapshots \
  --profile=bananapi_bpi-r4 \
  --ask-menuconfig=false

# 逐步执行（便于调试）
SOURCE_DIR="/tmp/openwrt"
./source-management.sh --source-dir="$SOURCE_DIR" --firmware=immortalwrt --version=snapshots
./feeds-management.sh --source-dir="$SOURCE_DIR/immortalwrt" --firmware=immortalwrt
./config-management.sh --source-dir="$SOURCE_DIR/immortalwrt" --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
./build.sh --source-dir="$SOURCE_DIR/immortalwrt"
# 手动打包并上传到 GitHub Release，获取部署链接
./public-compressor.sh
./public-uploader.sh
```

在脚本中使用变量：

```bash
FIRMWARE="immortalwrt"
VERSION="snapshots"
PROFILE="bananapi_bpi-r4"

./make.sh --firmware="$FIRMWARE" --version="$VERSION" --profile="$PROFILE" --ask-menuconfig=false
```

## 日志输出

所有脚本使用统一的日志系统（来自 common.sh）：

- `TRACE` / `DEBUG` - 调试信息（默认不显示）
- `INFO` - 普通信息
- `WARN` - 警告信息
- `ERROR` - 错误信息
- `FATAL` - 致命错误

控制日志级别：

```bash
LOG_LEVEL=DEBUG ./make.sh --firmware=immortalwrt
LOG_TO_FILE=true LOG_FILE_PATH=/tmp/build.log ./build.sh --source-dir=./sources/immortalwrt
```

## 错误处理

所有脚本采用严格错误处理策略：

- `set -euo pipefail` - 任何错误立即退出
- `require_file()` / `require_dir()` - 验证关键文件/目录存在
- `log FATAL` + `exit 1` - 明确报告致命错误

## 技术实现

参数解析由 `common.sh` 中的统一函数提供：

- `parse_args()` - 解析命令行参数到关联数组 `PARSED_ARGS`，支持 `--key=value`、`--key value`、`-h` 及位置参数
- `show_help()` - 输出格式化的帮助信息

在各脚本的 `main()` 中使用方式：

```bash
main() {
  declare -A PARSED_ARGS
  parse_args "$@"

  [[ -n "${PARSED_ARGS[help]:-}" ]] && { show_help ...; exit 0; }

  local source_dir="${PARSED_ARGS[source-dir]:-${PARSED_ARGS[_POSITIONAL_0]:-.}}"
  ...
}
```

## 修改和扩展

### 添加新的编译阶段

1. 创建新脚本（如 `pre-build.sh`），遵循现有结构：

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   source "${SCRIPT_DIR}/common.sh"
   main() {
     declare -A PARSED_ARGS
     parse_args "$@"
     [[ -n "${PARSED_ARGS[help]:-}" ]] && { show_help "pre-build.sh" "..." "..."; exit 0; }
     # 实现逻辑
   }
   main "$@"
   ```

2. 在 make.sh 中的适当位置调用该脚本
3. 更新本 README

### 修改单个阶段

直接编辑对应的脚本即可，无需修改 make.sh 主逻辑。

## 常见问题

**Q: 如何查看脚本帮助？**
A: 所有脚本均支持 `--help` 或 `-h`：`./make.sh --help`

**Q: 如何只重新编译（跳过源码更新）？**
A: `./build.sh --source-dir=./sources/immortalwrt`

**Q: 如何只重新生成配置？**
A: `./config-management.sh --source-dir=./sources/immortalwrt --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4`

**Q: 如何跳过某个阶段？**
A: 使用独立脚本分步运行，或编辑 make.sh 注释掉对应行。

**Q: 编译失败了怎么办？**
A: 查看详细日志输出；可以用 `LOG_LEVEL=DEBUG ./build.sh ...` 获取更多信息，修复问题后重新运行相应脚本。
