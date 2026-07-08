#!/bin/bash
# LockVideo 再適用ヘルパー: apply.py を実行し、変更があった時だけ WallpaperAgent を再起動。
# macOS が aerial を原本へ戻した(reset)場合に、動画とIndex.plistを復元する。
export PATH="/opt/homebrew/bin:$HOME/bin:/usr/bin:/bin"
CFG="$HOME/.config/monitorwall"; mkdir -p "$CFG"
# repair.sh と同じロック/デバウンスを共有: WatchPaths起因の自己増殖ループ(killall→WallpaperAgentの書込→再発火)を根絶。
# 過去に対策なしで22分間・約10秒毎にkillallが走り続ける暴走を確認済み。
LOCKD="$CFG/repair.lock.d"
mkdir "$LOCKD" 2>/dev/null || { echo "$(date '+%F %T') reapply skipped (already running)" >> /tmp/lockvideo.log; exit 0; }
trap 'rmdir "$LOCKD" 2>/dev/null' EXIT
now=$(date +%s); last=$(cat "$CFG/last_repair" 2>/dev/null || echo 0)
if [ $((now - last)) -lt 30 ]; then
  echo "$(date '+%F %T') reapply skipped (debounce ${last})" >> /tmp/lockvideo.log; exit 0
fi
/usr/bin/python3 "$(cd "$(dirname "$0")" && pwd)/apply.py" >> /tmp/lockvideo.log 2>&1
rc=$?
if [ "$rc" = "0" ]; then
  echo "$now" > "$CFG/last_repair"
  /usr/bin/killall WallpaperAgent 2>/dev/null
  echo "$(date '+%F %T') reapplied (restarted WallpaperAgent)" >> /tmp/lockvideo.log
fi
exit 0
