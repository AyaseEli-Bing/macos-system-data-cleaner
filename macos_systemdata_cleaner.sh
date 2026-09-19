#!/usr/bin/env bash
# ==============================================================================
# macos_systemdata_cleaner.sh —— macOS「系统数据(System Data)」扫描与安全清理
# ------------------------------------------------------------------------------
# 安全设计（7 道闸门）：
#   1. 默认只读：不带参数 = --scan，绝不删除任何文件。
#   2. 白名单扫描：只枚举 CATALOG 中显式登记的目录，绝不递归扫全盘。
#   3. 黑名单防护：命中 PROTECTED 规则的路径拒绝删除（即便用户已确认）。
#   4. 默认不删除：清理逐项交互确认，只有输入 yes 才执行；回车/其他 = 跳过。
#   5. 占位防护：被进程打开(lsof)的路径标记 BUSY，拒绝删除。
#   6. 符号链接防护：软链接本身一律不删，避免误删链接目标。
#   7. 最小删除单元：只删「父目录的直接子项」，永不删除父目录本身。
#
# 用法：
#   ./macos_systemdata_cleaner.sh --scan     只读扫描并列出可清理项（默认）
#   ./macos_systemdata_cleaner.sh --plan     生成可执行清理方案脚本（不执行）
#   ./macos_systemdata_cleaner.sh --clean    交互式逐项确认清理
#
# 选项：
#   --risk low|medium    允许清理的风险上限，默认 low
#   --min-size N         仅列出 ≥ N MiB 的项目，默认 10
#   --trash              用户级目录改「移入废纸篓」而非 rm（可恢复）
#   --no-lsof            跳过「文件被占用」检测（更快，但安全性下降）
#   --json               额外输出 JSON 报告
#   --out DIR            报告/方案输出目录，默认当前目录
#   -h, --help           显示帮助
#
# 兼容 macOS 自带 bash 3.2（不使用关联数组）。zsh 下请用 `bash 本脚本` 运行。
# ==============================================================================

set -uo pipefail
shopt -s nullglob dotglob

# ------------------------------------------------------------------------------
# 0. 全局配置
# ------------------------------------------------------------------------------
MODE="scan"
MAX_RISK="low"
MIN_SIZE_MB=10
USE_TRASH=0
USE_LSOF=1
WANT_JSON=0
OUT_DIR="$(pwd)"
TMP_AGE_DAYS=7

RUN_ID="$(date +%Y%m%d-%H%M%S)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sysdata.XXXXXX")" || exit 1
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

ENTRIES="${TMPROOT}/entries.tsv"   # risk \t kb \t path \t note \t sudo
OPENLIST="${TMPROOT}/open.txt"
PLAN_FILE=""
: > "$ENTRIES"

if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
  C_RST=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

# ------------------------------------------------------------------------------
# 1. 参数解析
# ------------------------------------------------------------------------------
usage() { sed -n '2,40p' "$0" | sed 's/^#\{1,2 \}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scan)     MODE="scan" ;;
    --plan)     MODE="plan" ;;
    --clean)    MODE="clean" ;;
    --risk)     shift; MAX_RISK="${1:-low}" ;;
    --min-size) shift; MIN_SIZE_MB="${1:-10}" ;;
    --trash)    USE_TRASH=1 ;;
    --no-lsof)  USE_LSOF=0 ;;
    --json)     WANT_JSON=1 ;;
    --out)      shift; OUT_DIR="${1:-$(pwd)}" ;;
    -h|--help)  usage ;;
    *) echo "未知参数: $1（用 -h 查看帮助）" >&2; exit 2 ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || { echo "本脚本仅支持 macOS" >&2; exit 1; }
case "$MAX_RISK" in low|medium) ;; *) echo "--risk 只能是 low 或 medium" >&2; exit 2 ;; esac
mkdir -p "$OUT_DIR" 2>/dev/null || OUT_DIR="${TMPDIR:-/tmp}"

# ------------------------------------------------------------------------------
# 2. 工具函数
# ------------------------------------------------------------------------------
log()   { printf '%s\n' "$*"; }
rule()  { printf '%s\n' "────────────────────────────────────────────────────────────────────────────────────────"; }
head1() { printf '\n%s\n' "${C_CYA}${C_BOLD}════════════════════════════════════════════════════════════${C_RST}"
          printf '%s\n' "${C_CYA}${C_BOLD} $1${C_RST}"
          printf '%s\n' "${C_CYA}${C_BOLD}════════════════════════════════════════════════════════════${C_RST}"; }

hr() { awk -v kb="${1:-0}" 'BEGIN{b=kb*1024.0; split("B KB MB GB TB",u," "); i=1;
        while(b>=1024 && i<5){b/=1024; i++}
        if(i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]}'; }

size_kb() { local v; v="$(du -skx "$1" 2>/dev/null | awk 'NR==1{print $1}')"; printf '%s' "${v:-0}"; }

# 单引号转义，供生成的方案脚本安全引用路径
esc_sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

needs_sudo() { [ -w "$1" ] && printf '0' || printf '1'; }

age_days() {
  local now a m
  now="$(date +%s)"
  a="$(stat -f '%a' "$1" 2>/dev/null || echo 0)"
  m="$(stat -f '%m' "$1" 2>/dev/null || echo 0)"
  [ "${a:-0}" -gt "${m:-0}" ] 2>/dev/null || a="$m"
  printf '%s' $(( (now - a) / 86400 ))
}

build_open_list() {
  : > "$OPENLIST"
  if [ "$USE_LSOF" -eq 1 ] && command -v lsof >/dev/null 2>&1; then
    lsof -nP -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u > "$OPENLIST"
  fi
}

is_busy() {
  [ -s "$OPENLIST" ] || return 1
  awk -v p="$1" 'index($0,p)==1{f=1;exit} END{exit !f}' "$OPENLIST"
}

# 命中系统关键路径 → 拒绝删除
is_protected() {
  local p="$1" pat
  [ -n "$p" ] || return 0
  [ -L "$p" ] && return 0
  case "$p" in
    ""|"/"|"."|".."|"/private"|"/tmp"|"/var"|"/Library"|"$HOME"|"$HOME/Library") return 0 ;;
  esac
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$p" in $pat) return 0 ;; esac
  done <<'PROTECTED'
/System
/System/*
/usr/*
/bin/*
/sbin/*
/etc/*
/cores/*
/private/var/db/*
/var/db/*
/private/var/root/*
/private/var/vm/*
/Library/Application Support/*
/Library/Frameworks/*
/Library/Preferences/*
/Library/LaunchAgents/*
/Library/LaunchDaemons/*
/Library/Keychains/*
/Library/Security/*
/Applications/*
/private/var/folders/*/C/*
/private/var/folders/*/C
*/MobileSync/*
*/AddressBook/*
*/CallHistoryDB/*
*/com.apple.TCC/*
*/Knowledge/*
*/PhotoData/*
*/Mail/*
*/Messages/*
*/Containers/com.docker.docker/*
PROTECTED
  # 用户数据区
  local h="$HOME"
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$p" in $pat) return 0 ;; esac
  done <<PROTECTED2
$h/Documents
$h/Documents/*
$h/Desktop
$h/Desktop/*
$h/Downloads
$h/Downloads/*
$h/Pictures
$h/Pictures/*
$h/Movies
$h/Movies/*
$h/Music
$h/Music/*
$h/Public
$h/Public/*
$h/Library/Mail*
$h/Library/Messages*
$h/Library/Application Support
$h/Library/Application Support/*
$h/Library/Containers
$h/Library/Containers/*
$h/Library/Group Containers
$h/Library/Group Containers/*
$h/Library/Preferences*
$h/Library/Safari*
$h/Library/Calendars/*
$h/Library/Reminders/*
$h/Library/Developer/Xcode/UserData/*
$h/Library/Developer/Xcode/Archives/*
$h/.ssh*
$h/.aws*
$h/.gnupg*
$h/.kube*
PROTECTED2
  return 1
}

risk_text() {
  case "$1" in
    low)    printf '低风险' ;;
    medium) printf '中风险' ;;
    high)   printf '高风险' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# ------------------------------------------------------------------------------
# 3. 扫描（白名单；删除单元 = 父目录的直接子项）
# ------------------------------------------------------------------------------
add_scan() {
  local risk="$1" parent="$2" note="$3" mindays="${4:-0}"
  [ -d "$parent" ] || return 0
  local child kb age sudo
  for child in "$parent"/*; do
    [ -e "$child" ] || continue
    if [ "${mindays:-0}" -gt 0 ]; then
      age="$(age_days "$child")"
      [ "${age:-0}" -ge "$mindays" ] || continue
    fi
    kb="$(size_kb "$child")"
    [ "${kb:-0}" -ge $(( MIN_SIZE_MB * 1024 )) ] || continue
    sudo="$(needs_sudo "$child")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$risk" "$kb" "$child" "$note" "$sudo" >> "$ENTRIES"
  done
}

add_info() {
  local parent="$1" note="$2" kb
  [ -d "$parent" ] || return 0
  kb="$(size_kb "$parent")"
  [ "${kb:-0}" -ge $(( MIN_SIZE_MB * 1024 )) ] || return 0
  printf 'high\t%s\t%s\t%s\t1\n' "$kb" "$parent" "$note" >> "$ENTRIES"
}

run_scan() {
  local H="$HOME"
  # ── 低风险：用户级缓存 / 日志 / 临时文件 ──
  add_scan low "$H/Library/Caches"                        "用户应用缓存，应用会自动重建"
  add_scan low "$H/Library/Logs"                          "用户日志，可重建"
  add_scan low "$H/Library/Logs/DiagnosticReports"        "崩溃报告，纯诊断数据"
  add_scan low "$H/Library/Caches/Homebrew"               "Homebrew 下载缓存（brew cleanup 亦可）"
  add_scan low "$H/.npm/_cacache"                         "npm 缓存"
  add_scan low "$H/.cache/yarn"                           "yarn 缓存"
  add_scan low "$H/Library/Caches/Yarn"                   "yarn 缓存"
  add_scan low "$H/Library/Caches/pip"                    "pip 缓存"
  add_scan low "$H/Library/Caches/go-build"               "Go 构建缓存"
  add_scan low "$H/Library/Caches/CocoaPods"              "CocoaPods 缓存"
  add_scan low "$H/Library/Caches/ms-playwright"          "Playwright 浏览器二进制（删后需重下）"
  add_scan low "$H/.Trash"                                "废纸篓（用户已删除的待清空文件）"

  # ── 中风险：系统级 / 开发产物 ──
  add_scan medium "/Library/Caches"                       "系统级缓存（需 sudo）"
  add_scan medium "/Library/Logs"                         "系统级日志（需 sudo）"
  add_scan medium "/Library/Logs/DiagnosticReports"       "系统崩溃报告（需 sudo）"
  add_scan medium "/var/log"                              "系统日志（需 sudo，仅删子项保留目录）"
  add_scan medium "/tmp"                                  "系统临时目录（仅 ${TMP_AGE_DAYS} 天未访问）" "$TMP_AGE_DAYS"
  add_scan medium "${TMPDIR:-/tmp}"                       "当前会话 TMPDIR（仅 3 天未访问）" 3
  add_scan medium "$H/Library/Developer/Xcode/DerivedData" "Xcode 构建产物，可重建但需重新编译"
  add_scan medium "$H/Library/Developer/Xcode/iOS DeviceSupport" "iOS 设备支持符号，可重建"
  add_scan medium "$H/Library/Developer/CoreSimulator/Devices"   "模拟器设备数据（删除=模拟器恢复出厂）"
  add_scan medium "$H/.gradle/caches"                     "Gradle 依赖缓存"
  add_scan medium "$H/.m2/repository"                     "Maven 本地仓库（重建需联网）"
  add_scan medium "/Library/Developer/CoreSimulator"      "系统级模拟器缓存（需 sudo）"

  # ── 高风险：仅提示，脚本永不删除 ──
  add_info "$H/Library/Application Support/MobileSync/Backup" "iOS 设备备份（数据资产，勿删）"
  add_info "$H/Library/Containers/com.docker.docker"          "Docker 镜像/容器（用 Docker Desktop 清理）"
  add_info "/private/var/folders"                             "系统临时与缓存根（结构敏感，勿手动删）"
  add_info "$H/Library/Developer/Xcode/Archives"              "Xcode 归档（含 dSYM，人工判断）"
}

sort_entries() { sort -t $'\t' -k1,1 -k2,2nr "$ENTRIES" > "${ENTRIES}.s" && mv "${ENTRIES}.s" "$ENTRIES"; }

total_of() { awk -F'\t' -v r="$1" '$1==r{s+=$2} END{printf "%d", s+0}' "$ENTRIES"; }
count_of() { awk -F'\t' -v r="$1" '$1==r{c++}   END{printf "%d", c+0}' "$ENTRIES"; }

print_table() {
  local want="$1" title="$2" risk kb path note sudo mark
  printf '\n%s\n' "${C_BOLD}${title}${C_RST}"
  rule
  printf '%-8s %-11s %-6s %s\n' "风险" "占用" "sudo" "路径"
  rule
  while IFS=$'\t' read -r risk kb path note sudo; do
    [ -z "${path:-}" ] && continue
    [ "$risk" = "$want" ] || continue
    mark="-"; [ "${sudo:-0}" = "1" ] && mark="需"
    printf '%-8s %-11s %-6s %s\n' "$(risk_text "$risk")" "$(hr "$kb")" "$mark" "$path"
    printf '%-8s %-11s %-6s %s\n' "" "" "" "${C_DIM}└ ${note}${C_RST}"
  done < "$ENTRIES"
  rule
  printf '小计：%s 项，共 %s\n' "$(count_of "$want")" "$(hr "$(total_of "$want")")"
}

show_report() {
  head1 "系统数据 · 可清理项扫描报告  ($(date '+%F %T'))"
  log "${C_DIM}模式：只读（未删除任何文件）｜最小显示体积：${MIN_SIZE_MB} MiB｜占位检测：$([ "$USE_LSOF" -eq 1 ] && echo 开 || echo 关)${C_RST}"
  print_table low    "① 低风险 — 用户缓存 / 日志 / 临时文件（默认可安全回收）"
  print_table medium "② 中风险 — 系统缓存 / 日志 / 开发产物（需 --risk medium 才允许清理）"
  print_table high   "③ 高风险 — 仅提示，脚本永不删除，请人工判断"

  local l m t
  l="$(total_of low)"; m="$(total_of medium)"; h="$(total_of high)"; t=$(( l + m + h ))
  log ""
  log "${C_BOLD}汇总${C_RST}"
  log "  可安全回收（低风险）：$(hr "$l")"
  log "  谨慎回收（中风险）  ：$(hr "$m")"
  log "  仅提示（高风险）    ：$(hr "$h")"
  log "  ──────────────────────────────"
  log "  扫描命中总量        ：$(hr "$t")"
}

# ------------------------------------------------------------------------------
# 4. 生成可执行清理方案（--plan，不执行）
# ------------------------------------------------------------------------------
emit_plan() {
  local plan="${OUT_DIR}/cleanup-plan-${RUN_ID}.sh"
  local n=0 total=0 risk kb path note sudo
  {
    cat <<'PLAN_HEADER'
#!/usr/bin/env bash
# ==============================================================================
# 系统数据清理方案（自动生成，可直接执行）
# ==============================================================================
# 安全模式（三重保险）：
#   1. 默认演练：APPLY=0，只打印将要执行的命令，不删除任何文件。
#   2. 需显式开启：APPLY=1 ./cleanup-plan.sh    才进入真实删除。
#   3. 即便 APPLY=1，仍会逐项询问，只有输入 yes 才执行（回车 = 跳过）。
#
# 另外：执行前会二次校验路径是否命中系统关键路径名单、是否正被占用。
# ==============================================================================
set -uo pipefail
APPLY="${APPLY:-0}"
LOG="${HOME}/Desktop/cleanup-log-$(date +%Y%m%d-%H%M%S).txt"
FREED=0

say()  { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------------"; }

# 二次防护：系统关键路径绝不删除
guard() {
  local p="$1"
  [ -e "$p" ] || return 1                       # 已不存在，跳过
  [ -L "$p" ] && { say "  ✖ 软链接，跳过：$p"; return 1; }
  case "$p" in
    "/"|""|"/System"|"/System/"*|"/usr"|"/usr/"*|"/bin"|"/bin/"*|"/sbin"|"/sbin/"*|"/etc"|"/etc/"*)
      say "  ✖ 关键路径，拒绝：$p"; return 1 ;;
    "/Library"|"/var"|"/tmp"|"$HOME"|"$HOME/Library"|"/private"|"/private/"*)
      say "  ✖ 关键路径，拒绝：$p"; return 1 ;;
    "$HOME/Documents"|"$HOME/Documents/"*|"$HOME/Desktop"|"$HOME/Desktop/"*|"$HOME/Downloads"|"$HOME/Downloads/"*)
      say "  ✖ 用户数据目录，拒绝：$p"; return 1 ;;
    "$HOME/Pictures"|"$HOME/Pictures/"*|"$HOME/Movies"|"$HOME/Movies/"*|"$HOME/Music"|"$HOME/Music/"*)
      say "  ✖ 用户数据目录，拒绝：$p"; return 1 ;;
    "$HOME/Library/Application Support"|"$HOME/Library/Application Support/"*|"$HOME/Library/Containers"|"$HOME/Library/Containers/"*)
      say "  ✖ 应用业务数据，拒绝：$p"; return 1 ;;
    "$HOME/Library/Mail"*|"$HOME/Library/Messages"*|"$HOME/Library/Preferences"*|"$HOME/Library/Safari"*)
      say "  ✖ 应用业务数据，拒绝：$p"; return 1 ;;
  esac
  if command -v lsof >/dev/null 2>&1 && lsof -nP "$p" >/dev/null 2>&1; then
    say "  ✖ 正被进程占用，跳过：$p"; return 1
  fi
  return 0
}

# 执行一条清理；APPLY=0 时仅演练
clean() {
  local desc="$1" sudo="$2" path="$3" ans
  say ""
  say "  $desc"
  say "  路径：$path"
  guard "$path" || return 0
  if [ "$APPLY" -ne 1 ]; then
    say "  [演练] 将执行：$([ "$sudo" = 1 ] && echo 'sudo ' )rm -rf -- '$path'"
    return 0
  fi
  printf '  确认请输入 yes（回车 = 跳过）: '
  read -r ans </dev/tty 2>/dev/null || ans=""
  [ "$ans" = "yes" ] || { say "  · 已跳过"; return 0; }
  if [ "$sudo" = 1 ]; then sudo rm -rf -- "$path"; else rm -rf -- "$path"; fi
  say "  ✔ 已删除" 
  printf '%s\t%s\n' "$(date '+%F %T')" "$path" >> "$LOG"
}

say "=================================================================="
say " 清理方案执行 $(date '+%F %T')｜APPLY=$APPLY $([ "$APPLY" = 1 ] && echo '（真实删除）' || echo '（演练，不删任何文件）')"
say "=================================================================="
PLAN_HEADER
  } > "$plan"

  while IFS=$'\t' read -r risk kb path note sudo; do
    [ -z "${path:-}" ] && continue
    [ "$risk" = "high" ] && continue
    [ "$risk" = "medium" ] && [ "$MAX_RISK" != "medium" ] && continue
    is_protected "$path" && continue
    n=$((n+1)); total=$((total + kb))
    local qp qd
    qp="'$(esc_sq "$path")'"
    qd="'[$(risk_text "$risk")] $(hr "$kb") · $(esc_sq "$(basename "$path")")'"
    {
      printf '\n# ── [%s] %s ── %s\n' "$(risk_text "$risk")" "$(hr "$kb")" "$note"
      printf 'clean %s %s %s\n' "$qd" "${sudo:-0}" "$qp"
    } >> "$plan"
  done < "$ENTRIES"

  {
    printf '\n# ─────────────────────────────────────────────\n'
    printf '# 共 %d 项，预计释放 %s\n' "$n" "$(hr "$total")"
    printf 'say ""\nrule\n'
    printf 'say "完成：共 %d 项，预计释放 %s；明细日志：\$LOG"\n' "$n" "$(hr "$total")"
    printf 'say "复核命令：du -sh \"\$HOME/Library/Caches\" ; tmutil listlocalsnapshots /"\n'
  } >> "$plan"
  chmod +x "$plan"
  PLAN_FILE="$plan"
  log ""
  log "${C_GRN}✔ 清理方案已生成：${plan}${C_RST}"
  log "${C_DIM}  共 ${n} 项，预计释放 $(hr "$total")。直接运行 = 演练；APPLY=1 运行 = 逐项确认后真实删除。${C_RST}"
}

# ------------------------------------------------------------------------------
# 5. 交互式清理（--clean，默认不删除）
# ------------------------------------------------------------------------------
confirm_yes() {
  local ans
  printf '%s\n' "$1"
  printf '%s' "  ${C_BOLD}确认请输入 yes（回车或任意其他输入 = 跳过）: ${C_RST}"
  if [ -t 0 ]; then read -r ans; else read -r ans </dev/tty 2>/dev/null || ans=""; fi
  case "$ans" in yes|y|Y|YES) return 0 ;; *) return 1 ;; esac
}

do_clean() {
  head1 "交互式清理（默认不删除）"
  log "${C_DIM}风险上限：${MAX_RISK}｜废纸篓模式：${USE_TRASH}｜占位检测：${USE_LSOF}${C_RST}"
  log "${C_RED}警告：删除操作不可恢复，每一步都会单独确认。${C_RST}"

  local freed=0 done_n=0 skip=0 risk kb path note sudo ok dest
  while IFS=$'\t' read -r risk kb path note sudo; do
    [ -z "${path:-}" ] && continue
    [ "$risk" = "high" ] && continue
    [ "$risk" = "medium" ] && [ "$MAX_RISK" != "medium" ] && continue

    printf '\n%s[%s] %s  %s%s\n' "$C_BOLD" "$(risk_text "$risk")" "$(hr "$kb")" "$path" "$C_RST"
    printf '  %s说明%s：%s\n' "$C_DIM" "$C_RST" "$note"

    if is_protected "$path"; then
      printf '  %s✖ 命中系统关键路径排除名单 → 拒绝删除%s\n' "$C_RED" "$C_RST"; skip=$((skip+1)); continue
    fi
    if is_busy "$path"; then
      printf '  %s✖ 检测到正被进程占用 → 跳过（避免破坏运行中的程序）%s\n' "$C_YEL" "$C_RST"; skip=$((skip+1)); continue
    fi

    confirm_yes "  → 是否删除该项？" || { printf '  %s· 已跳过%s\n' "$C_DIM" "$C_RST"; skip=$((skip+1)); continue; }

    ok=1
    if [ "$USE_TRASH" -eq 1 ] && [ "${sudo:-0}" = "0" ]; then
      dest="${HOME}/.Trash/$(basename "$path")-${RUN_ID}"
      mkdir -p "${HOME}/.Trash" && mv -- "$path" "$dest" || ok=0
      [ "$ok" -eq 1 ] && printf '  %s✔ 已移入废纸篓：%s%s\n' "$C_GRN" "$dest" "$C_RST"
    elif [ "${sudo:-0}" = "1" ]; then
      sudo rm -rf -- "$path" || ok=0
      [ "$ok" -eq 1 ] && printf '  %s✔ 已删除（sudo）%s\n' "$C_GRN" "$C_RST"
    else
      rm -rf -- "$path" || ok=0
      [ "$ok" -eq 1 ] && printf '  %s✔ 已删除%s\n' "$C_GRN" "$C_RST"
    fi

    if [ "$ok" -eq 1 ]; then
      freed=$((freed + kb)); done_n=$((done_n + 1))
    else
      printf '  %s✖ 删除失败（权限不足 / 文件被占用）%s\n' "$C_RED" "$C_RST"
    fi
  done < "$ENTRIES"

  log ""
  log "${C_BOLD}清理结果${C_RST}"
  log "  已处理：${done_n} 项"
  log "  已跳过：${skip} 项"
  log "  释放空间：$(hr "$freed")"
}

# ------------------------------------------------------------------------------
# 6. JSON 报告
# ------------------------------------------------------------------------------
emit_json() {
  local f="${OUT_DIR}/systemdata-report-${RUN_ID}.json" first=1 risk kb path note sudo
  {
    printf '{\n  "generated_at": "%s",\n  "mode": "%s",\n  "max_risk": "%s",\n  "items": [\n' \
      "$(date '+%F %T')" "$MODE" "$MAX_RISK"
    while IFS=$'\t' read -r risk kb path note sudo; do
      [ -z "${path:-}" ] && continue
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '    {"path": "%s", "size_mb": %s, "risk": "%s", "note": "%s", "needs_sudo": %s, "cleanable": %s, "protected": %s}' \
        "$path" "$(( kb / 1024 ))" "$risk" "$note" "${sudo:-0}" \
        "$( [ "$risk" = "high" ] && echo false || echo true )" \
        "$( is_protected "$path" && echo true || echo false )"
    done < "$ENTRIES"
    printf '\n  ]\n}\n'
  } > "$f"
  log "${C_DIM}JSON 报告：${f}${C_RST}"
}

# ------------------------------------------------------------------------------
# 7. 磁盘概况（只读）
# ------------------------------------------------------------------------------
show_context() {
  head1 "磁盘概况"
  df -h / | awk 'NR==2{printf "  根卷：%s  总容量 %s  已用 %s  可用 %s（%s）\n", $1, $2, $3, $4, $5}'
  command -v diskutil >/dev/null 2>&1 && \
    diskutil info / 2>/dev/null | awk -F: '/Purgeable/{gsub(/^[ \t]+/,"",$2); printf "  可清除空间(Purgeable)：%s\n", $2}'
  log ""
  log "${C_DIM}Time Machine 本地快照（系统数据常见元凶；请用 tmutil 清理，勿手动删）：${C_RST}"
  if command -v tmutil >/dev/null 2>&1; then
    local s; s="$(tmutil listlocalsnapshots / 2>/dev/null)"
    [ -n "$s" ] && printf '%s\n' "$s" | sed 's/^/  /' || log "  （无本地快照）"
  fi
}

# ------------------------------------------------------------------------------
# 8. 主流程
# ------------------------------------------------------------------------------
main() {
  show_context
  build_open_list
  run_scan
  sort_entries
  case "$MODE" in
    scan)  show_report ;;
    plan)  show_report; emit_plan ;;
    clean) show_report; do_clean ;;
  esac
  [ "$WANT_JSON" -eq 1 ] && emit_json
  log ""
  log "${C_DIM}下一步：--plan 生成方案脚本；--clean 逐项确认清理（回车=跳过）；--trash 改用废纸篓。${C_RST}"
}

main "$@"
