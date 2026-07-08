#!/bin/bash
# MonitorWall + LockVideo アンインストーラー（配布可能版）
#   - launchd エージェントを停止・削除
#   - MonitorWall.app を削除
#   - 壁紙設定をインストール時のバックアップへ復元（aerial 原本の再取得を誘導）
#   - スクリプト配置先を削除（設定は既定で残す。全消しは --purge）
# 使い方: bash uninstall.sh [--yes] [--purge]
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${MONITORWALL_HOME:-$SELF}"
CFG="$HOME/.config/monitorwall"
LA="$HOME/Library/LaunchAgents"
APP_DST="/Applications/MonitorWall.app"
WP="$HOME/Library/Application Support/com.apple.wallpaper"
IDX="$WP/Store/Index.plist"
MAN="$WP/aerials/manifest/entries.json"
GUI="gui/$(id -u)"

YES=0; PURGE=0
for a in "$@"; do
  case "$a" in --yes) YES=1;; --purge) PURGE=1;; esac
done

say(){ printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[!]\033[0m %s\n" "$*"; }

if [ "$YES" != "1" ]; then
  echo "MonitorWall/LockVideo をアンインストールし、ロック画面/壁紙を元へ戻します。"
  echo "  実行するには:  bash \"$SELF/uninstall.sh\" --yes"
  echo "  設定も全削除するなら:  bash \"$SELF/uninstall.sh\" --yes --purge"
  exit 0
fi

say "launchd エージェントを停止・削除"
for id in com.monitorwall.app com.monitorwall.lockvideo com.haroin.monitorwall com.haroin.lockvideo; do
  launchctl bootout "$GUI/$id" 2>/dev/null || true
  rm -f "$LA/$id.plist"
done
pkill -x MonitorWall 2>/dev/null || true
sleep 1

say "MonitorWall.app を削除"
rm -rf "$APP_DST"

say "壁紙設定を復元"
if [ -f "$PREFIX/backup/Index.original.plist" ]; then
  cp -f "$PREFIX/backup/Index.original.plist" "$IDX" && say "  Index.plist をバックアップから復元"
else
  warn "  バックアップが無いので Displays/Spaces の注入だけ除去します"
  /usr/bin/python3 - "$IDX" <<'PY' 2>/dev/null || true
import plistlib,sys
p=sys.argv[1]; idx=plistlib.load(open(p,'rb'))
idx["Displays"]={}
idx.pop("AllSpacesAndDisplays",None)
plistlib.dump(idx, open(p,'wb'), fmt=plistlib.FMT_BINARY)
PY
fi
# aerial 原本を macOS に再取得させる（上書きした .mov / 消したURLを純正へ戻す）
[ -f "$MAN" ] && mv -f "$MAN" "$PREFIX/backup/entries.json.removed" 2>/dev/null && say "  entries.json を退避（次回の壁紙操作で再生成）"
/usr/bin/killall WallpaperAgent WallpaperAerialsExtension 2>/dev/null || true

if [ "$PURGE" = "1" ]; then
  say "設定・スクリプトを全削除（--purge）"
  rm -rf "$CFG"
  rm -rf "$PREFIX"
else
  say "スクリプト配置先を削除（設定 $CFG は保持）"
  # backup は消す前に設定ディレクトリへ逃がす
  [ -d "$PREFIX/backup" ] && mkdir -p "$CFG/backup" && cp -f "$PREFIX/backup/"* "$CFG/backup/" 2>/dev/null || true
  rm -rf "$PREFIX"
fi

say "アンインストール完了。ロック画面/壁紙は元に戻りました。"
