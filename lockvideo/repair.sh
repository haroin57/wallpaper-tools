#!/bin/bash
# ロック壁紙レンダリングの強制復帰: WallpaperAgent と aerials 拡張を落として再適用。
# 「生きてるのに真っ黒」状態のリカバリ（configがCLEANでも強制的に描画を初期化）。
export PATH="/opt/homebrew/bin:$HOME/bin:/usr/bin:/bin"
CFG="$HOME/.config/monitorwall"; mkdir -p "$CFG"
# 直列化: 同時実行を1本に（macOSにflock CLIが無いのでmkdirのアトミック性を利用）
LOCKD="$CFG/repair.lock.d"
mkdir "$LOCKD" 2>/dev/null || { echo "$(date '+%F %T') repair skipped (already running)" >> /tmp/lockvideo.log; exit 0; }
trap 'rmdir "$LOCKD" 2>/dev/null' EXIT
# デバウンス: 直近30秒以内の再実行はスキップ（killall連打＝ブラックアウト自己誘発を防止。--forceで無視）
now=$(date +%s); last=$(cat "$CFG/last_repair" 2>/dev/null || echo 0)
if [ "$1" != "--force" ] && [ $((now - last)) -lt 30 ]; then
  echo "$(date '+%F %T') repair skipped (debounce ${last})" >> /tmp/lockvideo.log; exit 0
fi
echo "$now" > "$CFG/last_repair"
/usr/bin/killall WallpaperAgent WallpaperAerialsExtension 2>/dev/null
sleep 1
/usr/bin/python3 "$HOME/dev/lockvideo/apply.py" >/dev/null 2>&1
/usr/bin/killall WallpaperAgent 2>/dev/null
echo "$(date '+%F %T') manual/forced repair" >> /tmp/lockvideo.log
