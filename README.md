# macOS System Data Cleaner

定位并回收 macOS「**系统数据** (System Data)」占用空间 —— 一个**只读优先、默认不删除**的 Bash/Zsh 清理工具。

macOS 的存储空间把既不属于 App、也不属于文档/照片的残留统称为「系统数据」：缓存、日志、临时文件、构建产物、模拟器数据、Time Machine 本地快照……它可能悄悄吃掉几十上百 GB，而系统自带的「存储管理」又语焉不详。

这个脚本做的事很简单：**告诉你空间被谁吃了、每一项能不能删、删了有多大风险，然后把删除权完完整整交回你手上。**

---

## 核心原则

> **脚本的默认行为是「什么都不删」。**

删除操作一共要经过 7 道闸门，任何一道不通过都会被拦下：

| # | 闸门 | 说明 |
|---|---|---|
| 1 | **默认只读** | 不带任何参数即 `--scan`，绝不删除任何文件 |
| 2 | **白名单扫描** | 只枚举脚本内登记的目录，**不递归扫全盘** |
| 3 | **关键路径黑名单** | `/System` `/usr` `/bin` `/etc` `/private/var/db` `~/Documents` `~/Library/Application Support` `~/Library/Mail` … 命中即拒绝，哪怕你已确认 |
| 4 | **默认不删除** | 逐项交互确认，只有输入 `yes` 才执行；**回车或任意其他输入 = 跳过** |
| 5 | **占位检测** | 比对 `lsof` 快照，正被进程打开的路径标记 BUSY 并跳过 |
| 6 | **软链接不删** | 避免误删链接指向的真实目标 |
| 7 | **最小删除单元** | 只删父目录的**直接子项**，永不删除父目录本身 |

---

## 安装

```bash
git clone https://github.com/AyaseElibing/macos-system-data-cleaner.git
cd macos-system-data-cleaner
chmod +x macos_systemdata_cleaner.sh
```

或单文件下载：

```bash
curl -O https://raw.githubusercontent.com/AyaseElibing/macos-system-data-cleaner/main/macos_systemdata_cleaner.sh
chmod +x macos_systemdata_cleaner.sh
```

## 用法

### 1. 只读扫描（默认）

```bash
./macos_systemdata_cleaner.sh --scan
./macos_systemdata_cleaner.sh --scan --min-size 1      # 显示 ≥1 MiB 的项（默认 10 MiB）
./macos_systemdata_cleaner.sh --scan --json            # 额外输出 JSON 报告
```

输出按风险分三档，每项显示 **路径 · 占用大小 · 是否需要 sudo · 清理说明**：

```
① 低风险 — 用户缓存 / 日志 / 临时文件（默认可安全回收）
──────────────────────────────────────────────────────────
风险     占用        sudo   路径
──────────────────────────────────────────────────────────
低风险   900.7 MB     -     $HOME/Library/Caches/com.microsoft.VSCode.ShipIt
                             └ 用户应用缓存，应用会自动重建
低风险   402.6 MB     -     $HOME/.npm/_cacache/content-v2
                             └ npm 缓存
低风险   214.6 MB     -     $HOME/Library/Caches/Qianwen
                             └ 用户应用缓存，应用会自动重建
──────────────────────────────────────────────────────────
小计：29 项，共 1.9 GB
```

完整示例见 [`examples/scan-report.txt`](examples/scan-report.txt)。

### 2. 生成可执行清理方案

```bash
./macos_systemdata_cleaner.sh --plan
```

生成 `cleanup-plan-<时间戳>.sh`。这个方案脚本本身也是**默认演练**的：

```bash
./cleanup-plan-20260919-112054.sh          # APPLY=0 → 只打印将执行的命令，不删文件
APPLY=1 ./cleanup-plan-20260919-112054.sh  # 逐项再确认一次，输入 yes 才真删
```

每条命令执行前会**二次校验**路径是否命中关键路径名单、是否正被进程占用 —— 即便有人手工改坏了路径，也不会误伤系统。

### 3. 交互式清理

```bash
./macos_systemdata_cleaner.sh --clean                  # 逐项确认，回车=跳过
./macos_systemdata_cleaner.sh --clean --trash          # 用户级目录移入废纸篓（可恢复）
./macos_systemdata_cleaner.sh --clean --risk medium    # 放开中风险（系统级缓存/日志）
```

---

## 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--scan` | ✓ 默认 | 只读扫描并列出可清理项 |
| `--plan` | | 生成可执行清理方案（不删除任何东西） |
| `--clean` | | 进入交互式逐项确认清理 |
| `--risk low\|medium` | `low` | 允许清理的风险上限 |
| `--min-size N` | `10` | 仅列出 ≥ N MiB 的项目 |
| `--trash` | 关 | 用户级目录改「移入废纸篓」而非 `rm` |
| `--no-lsof` | 关 | 跳过占用检测（更快，安全性下降） |
| `--json` | 关 | 额外输出 JSON 报告 |
| `--out DIR` | 当前目录 | 报告 / 方案的输出目录 |

---

## 风险分级标准

| 等级 | 典型路径 | 处理方式 |
|---|---|---|
| **低风险** | `~/Library/Caches`、`~/Library/Logs`、`~/.npm/_cacache`、`~/Library/Caches/Homebrew`、`~/Library/Caches/pip`、`~/.Trash` | 应用会自动重建，`--clean` 默认可清 |
| **中风险** | `/Library/Caches`、`/var/log`、`/tmp`（≥7 天未访问）、Xcode `DerivedData`、`CoreSimulator/Devices`、`~/.gradle/caches`、`~/.m2/repository` | 需显式 `--risk medium`；删除后首次运行可能变慢 |
| **高风险（仅提示）** | `~/Library/Application Support/MobileSync/Backup`、`/private/var/folders`、Xcode `Archives`、Docker 数据 | **脚本永不删除**，只列出供人工判断 |

⚠️ 特别注意：`CoreSimulator/Devices` 删除后模拟器会**恢复出厂设置**（含已安装 App 与数据），Docker 数据请用 Docker Desktop 自带清理。

---

## 关于「系统数据」虚高的真正元凶

很多时候大头根本不是缓存，而是 **Time Machine 本地快照**（APFS 快照不显示在扫描里）。脚本启动时会顺带列出：

```bash
tmutil listlocalsnapshots /              # 查看
sudo tmutil deletelocalsnapshots <date>  # 删除指定快照（脚本不会代劳）
```

macOS 通常会在磁盘吃紧时自动回收快照，若长期未释放可手动处理。**切勿手动删除 `/System/Volumes/...` 下的快照目录。**

---

## 兼容性

- macOS 自带 **bash 3.2**（不使用关联数组），同时兼容现代 bash 5.x
- 依赖 BSD 版 `du` / `stat` / `lsof`，无需安装任何第三方工具
- zsh 用户请用 `bash macos_systemdata_cleaner.sh` 运行

---

## 免责声明

本工具只做**路径列举与体积统计**，不保证所有项删除后都无任何副作用。执行任何实际删除前请确认你有可用的备份。**作者不对数据丢失承担责任。**

## License

MIT
