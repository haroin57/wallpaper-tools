#!/bin/bash
# 解除トリガー専用のWallpaperAgent先回り再起動。
# 実証済みの根本原因: 同一のaerials拡張プロセスは「1回目のロックは動くが2回目のロックで確実にスタールする」
# (経過時間は無関係)。よって解除の度に必ずプロセスを更新し、次のロックには常に「1回目」状態で臨む。
# repair.sh(watchdog用・30秒デバウンス)とは別の短いクールダウンのみ(重複起動の抑止だけが目的)。
export PATH="/opt/homebrew/bin:$HOME/bin:/usr/bin:/bin"
CFG="$HOME/.config/monitorwall"; mkdir -p "$CFG"
LOCKD="$CFG/refresh.lock.d"
mkdir "$LOCKD" 2>/dev/null || exit 0
trap 'rmdir "$LOCKD" 2>/dev/null' EXIT
now=$(date +%s); last=$(cat "$CFG/last_refresh" 2>/dev/null || echo 0)
if [ $((now - last)) -lt 3 ]; then exit 0; fi
echo "$now" > "$CFG/last_refresh"
/usr/bin/killall WallpaperAgent 2>/dev/null
echo "$(date '+%F %T') proactive refresh (unlock-triggered)" >> /tmp/lockvideo.log
