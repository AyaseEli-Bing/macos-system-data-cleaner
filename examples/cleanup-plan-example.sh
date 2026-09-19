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

# ── [低风险] 900.7 MB ── 用户应用缓存，应用会自动重建
clean '[低风险] 900.7 MB · com.microsoft.VSCode.ShipIt' 0 '$HOME/Library/Caches/com.microsoft.VSCode.ShipIt'

# ── [低风险] 402.6 MB ── npm 缓存
clean '[低风险] 402.6 MB · content-v2' 0 '$HOME/.npm/_cacache/content-v2'

# ── [低风险] 214.6 MB ── 用户应用缓存，应用会自动重建
clean '[低风险] 214.6 MB · Qianwen' 0 '$HOME/Library/Caches/Qianwen'

# ── [低风险] 169.7 MB ── 用户应用缓存，应用会自动重建
clean '[低风险] 169.7 MB · Homebrew' 0 '$HOME/Library/Caches/Homebrew'

# ── [低风险] 82.6 MB ── Homebrew 下载缓存（brew cleanup 亦可）
clean '[低风险] 82.6 MB · api' 0 '$HOME/Library/Caches/Homebrew/api'

# ── [低风险] 59.2 MB ── Homebrew 下载缓存（brew cleanup 亦可）
clean '[低风险] 59.2 MB · downloads' 0 '$HOME/Library/Caches/Homebrew/downloads'

# ── [低风险] 50.8 MB ── 用户应用缓存，应用会自动重建
clean '[低风险] 50.8 MB · Microsoft Edge' 0 '$HOME/Library/Caches/Microsoft Edge'

# ── [低风险] 23.5 MB ── 用户应用缓存，应用会自动重建
clean '[低风险] 23.5 MB · com.apple.helpd' 0 '$HOME/Library/Caches/com.apple.helpd'

# ── [低风险] 15.8 MB ── Homebrew 下载缓存（brew cleanup 亦可）
clean '[低风险] 15.8 MB · bootsnap' 0 '$HOME/Library/Caches/Homebrew/bootsnap'

# ── [低风险] 12.1 MB ── Homebrew 下载缓存（brew cleanup 亦可）
clean '[低风险] 12.1 MB · portable-ruby-4.0.7.arm64_big_sur.bottle.tar.gz' 0 '$HOME/Library/Caches/Homebrew/portable-ruby-4.0.7.arm64_big_sur.bottle.tar.gz'

# ── [低风险] 10.0 MB ── 用户应用缓存，应用会自动重建
clean '[低风险] 10.0 MB · com.apple.appstoreagent' 0 '$HOME/Library/Caches/com.apple.appstoreagent'

# ── [低风险] 8.7 MB ── 用户应用缓存，应用会自动重建
clean '[低风险] 8.7 MB · Adobe' 0 '$HOME/Library/Caches/Adobe'

# ── [低风险] 6.4 MB ── npm 缓存
clean '[低风险] 6.4 MB · index-v5' 0 '$HOME/.npm/_cacache/index-v5'

# ─────────────────────────────────────────────
# 共 13 项，预计释放 1.9 GB
say ""
rule
say "完成：共 13 项，预计释放 1.9 GB；明细日志：\$LOG"
say "复核命令：du -sh "\$HOME/Library/Caches" ; tmutil listlocalsnapshots /"
