#!/bin/bash
# LockVideo 復元/アンインストール: 自作動画ロック画面を完全に元へ戻す。
#   使い方: bash ~/dev/lockvideo/restore.sh --yes
#   （--yes 無しでは何もしない＝誤爆防止）
set -u
WP="$HOME/Library/Application Support/com.apple.wallpaper"
BK="$HOME/aerial-backup"
LV="$HOME/dev/lockvideo"
U=$(id -u)
THIRD="B2FC91ED-6891-4DEB-85A1-268B2B4160B6"   # 注入した3本目スロット（未DL枠を流用）
ORIG_SLOTS=(F439B0A7-D18C-4B14-9681-6520E6A74FE9 4C108785-A7BA-422E-9C79-B0129F1D5550)

if [ "${1:-}" != "--yes" ]; then
  echo "これは自作動画ロック画面を元に戻します（LaunchAgent停止・Index.plist復元・純正aerial復元）。"
  echo "実行するには:  bash ~/dev/lockvideo/restore.sh --yes"
  exit 0
fi

echo "[1] LaunchAgent 停止（永続化ヘルパーを解除）"
launchctl bootout gui/$U/com.haroin.lockvideo 2>/dev/null && echo "  bootout OK" || echo "  (既に未ロード)"

echo "[2] Index.plist をベースライン(自作前)へ復元"
if [ -f "$LV/Index.baseline.plist" ]; then
  cp "$LV/Index.baseline.plist" "$WP/Store/Index.plist" && echo "  復元OK"
else
  echo "  ⚠ ベースラインが無い → Displays等を除去して既定化"
  /usr/bin/python3 - "$WP/Store/Index.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]; idx=plistlib.load(open(p,'rb'))
idx["Displays"]={}; idx.pop("AllSpacesAndDisplays",None)
plistlib.dump(idx, open(p,'wb'), fmt=plistlib.FMT_BINARY)
print("  Displays除去")
PY
fi

echo "[3] 純正aerial動画を復元"
for u in "${ORIG_SLOTS[@]}"; do
  if [ -f "$BK/$u.mov" ]; then
    cp "$BK/$u.mov" "$WP/aerials/videos/$u.mov" && echo "  復元 ${u:0:8}"
  else
    echo "  ⚠ backupなし ${u:0:8}（スキップ）"
  fi
done
# 注入した3本目スロット（純正には存在しない）を削除
[ -f "$WP/aerials/videos/$THIRD.mov" ] && rm -f "$WP/aerials/videos/$THIRD.mov" && echo "  注入スロット ${THIRD:0:8} 削除"

echo "[4] entries.json を退避（macOSが純正を再取得）"
MAN="$WP/aerials/manifest/entries.json"
[ -f "$MAN" ] && mv "$MAN" "$LV/entries.json.restored-aside" && echo "  退避（次のaerial操作で再生成）" || echo "  (無し)"

echo "[5] WallpaperAgent 再起動で反映"
killall WallpaperAgent 2>/dev/null; sleep 1

echo
echo "✅ 復元完了。ロック画面は既定に戻りました。"
echo "   スクリプト一式は $LV に残置。完全削除するなら:"
echo "     rm -rf $LV ~/Library/LaunchAgents/com.haroin.lockvideo.plist $BK"
