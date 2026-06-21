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
- **generate-index.sh** - 生成索引

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

# 混合使用
./make.sh immortalwrt --version=snapshots --profile=bananapi_bpi-r4
```

参数说明：

- `firmware` - 固件类型，默认 `immortalwrt`（支持: openwrt, immortalwrt）
- `version` - 版本号，默认 `snapshots`
- `profile` - 设备 profile，默认 `bananapi_bpi-r4`
- `ask-menuconfig` - 是否在编译前询问运行 menuconfig，默认 `false`

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
```

示例：

```bash
./config-management.sh ./sources/immortalwrt immortalwrt snapshots bananapi_bpi-r4 false
./config-management.sh --source-dir=./sources/immortalwrt --firmware=immortalwrt --version=snapshots --profile=bananapi_bpi-r4
```

功能：生成默认配置（make defconfig）、生成 customfeeds.list、应用 diff.config、可选运行 menuconfig。

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

功能：多线程下载源码包，多线程编译固件（失败时自动回退到单线程）。

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

功能：将编译产物分发到 public/ 目录（snapshots 直接复制，releases 按主次版本共享 packages）。

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

releases 版本采用共享目录结构，相同主次版本（MAJOR.MINOR）的 packages 共享存储：

```pre
public/immortalwrt/releases/
├── 25.12.0/
│   ├── targets/                    # 版本特定的固件
│   └── packages -> ../packages-25.12/  (符号链接)
├── 25.12.1/
│   ├── targets/
│   └── packages -> ../packages-25.12/
├── 24.10.6/
│   ├── targets/
│   └── packages -> ../packages-24.10/
├── packages-25.12/                 # 25.12.x 系列共享包库
└── packages-24.10/                 # 24.10.x 系列共享包库
```

**优点**：节省存储空间（相同主次版本不重复存储 packages）、同主次版本复用已编译的 packages。

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
