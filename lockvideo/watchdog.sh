#!/bin/bash
# ロック中に呼ばれる想定。aerials拡張のCPUを見て「真っ黒（描画不全）」を検出→自動修復。
#   健全ロック時: AerialsExtension CPU ~6% / 壊れ時: ~0.6%  → 閾値2%で判別
export PATH="/usr/bin:/bin:$HOME/bin"
LOG=/tmp/lockvideo.log
THRESH=2.0

pid=$(pgrep -f WallpaperAerialsExtension | head -1)
if [ -z "$pid" ]; then
  echo "$(date '+%F %T') watchdog: aerials拡張 不在 -> 修復" >> "$LOG"
  bash "$(cd "$(dirname "$0")" && pwd)/repair.sh"; exit 0
fi

# 瞬間CPUを数回サンプルし最大値を採用（一過性のディップで誤検出しない）
maxcpu=$(top -l 3 -s 1 -pid "$pid" -stats pid,cpu 2>/dev/null | awk -v p="$pid" '$1==p{print $2}' | sort -rn | head -1)
[ -z "$maxcpu" ] && { echo "$(date '+%F %T') watchdog: CPU取得失敗" >> "$LOG"; exit 0; }

if awk "BEGIN{exit !($maxcpu < $THRESH)}"; then
  echo "$(date '+%F %T') watchdog: aerials CPU ${maxcpu}% < ${THRESH}% = 黒画面検出 -> 自動修復" >> "$LOG"
  bash "$(cd "$(dirname "$0")" && pwd)/repair.sh"
else
  echo "$(date '+%F %T') watchdog: aerials CPU ${maxcpu}% = 健全" >> "$LOG"
fi
