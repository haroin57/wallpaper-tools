#!/bin/bash
# MonitorWall + LockVideo フルシステム インストーラー（配布可能版）
#   - MonitorWall.app をビルドして /Applications へ
#   - lockvideo スクリプト群を ~/.local/share/monitorwall へ配置
#   - launchd エージェント2つ（アプリ常駐 / 壁紙リセット復旧）を登録
#   - 現在の壁紙設定をバックアップ（アンインストール時に復元）
#
# 前提: macOS(Apple Silicon想定) / Xcode か Command Line Tools(swiftc) / Homebrew ffmpeg /
#       「システム設定 > 壁紙」で Aerial(空撮)系ダイナミック壁紙を一度設定済みであること
#       （macOS が aerial マニフェストとアセットスロットを用意しないと注入先が無いため）。
# 使い方: bash install.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${MONITORWALL_HOME:-$HOME/.local/share/monitorwall}"
CFG="$HOME/.config/monitorwall"
LA="$HOME/Library/LaunchAgents"
APP_DST="/Applications/MonitorWall.app"
WP="$HOME/Library/Application Support/com.apple.wallpaper"
MAN="$WP/aerials/manifest/entries.json"
IDX="$WP/Store/Index.plist"
ID_APP="com.monitorwall.app"
ID_LV="com.monitorwall.lockvideo"
GUI="gui/$(id -u)"

say()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; exit 1; }

# ── 1. 前提チェック ───────────────────────────────────────────────
say "前提チェック"
[ "$(uname)" = "Darwin" ] || die "macOS 専用です"
command -v python3 >/dev/null 2>&1 || die "python3 が見つかりません"
xcrun --find swiftc >/dev/null 2>&1 || die "swiftc がありません。'xcode-select --install' で Command Line Tools を入れてください"
command -v ffmpeg  >/dev/null 2>&1 || die "ffmpeg がありません。'brew install ffmpeg' を実行してください（動画のHEVC変換に使用）"
[ -f "$MAN" ] || die "aerial マニフェストが無い: $MAN
   先に「システム設定 > 壁紙」で Aerial/ダイナミック壁紙を1つ選んでから再実行してください。"
ASSETS=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('assets',[])))" "$MAN" 2>/dev/null || echo 0)
[ "$ASSETS" -ge 4 ] || die "aerial アセットスロットが不足（$ASSETS 個）。壁紙で Aerial を設定してスロットを確保してください（モニタ1枚につき2枠使用）。"
say "  OK — python3 / swiftc / ffmpeg / aerial assets=$ASSETS"

# ── 2. 稼働中インスタンス・旧エージェントの停止（移行対応） ─────────
say "稼働中インスタンスと旧エージェントを停止"
mkdir -p "$PREFIX/backup"
for id in "$ID_APP" "$ID_LV" com.haroin.monitorwall com.haroin.lockvideo; do
  if launchctl print "$GUI/$id" >/dev/null 2>&1; then
    launchctl bootout "$GUI/$id" 2>/dev/null || true
    say "  bootout $id"
  fi
  # 旧 com.haroin.* の plist は無効化して退避（再ロード事故防止）
  case "$id" in com.haroin.*)
    [ -f "$LA/$id.plist" ] && mv -f "$LA/$id.plist" "$PREFIX/backup/$id.plist.disabled" && warn "  旧plist退避: $id" || true ;;
  esac
done
pkill -x MonitorWall 2>/dev/null || true
sleep 1

# ── 3. 現在の壁紙設定をバックアップ ───────────────────────────────
say "現在の壁紙設定をバックアップ → $PREFIX/backup"
[ -f "$IDX" ] && cp -f "$IDX" "$PREFIX/backup/Index.original.plist" && say "  Index.plist を退避" || true

# ── 4. MonitorWall.app をビルドしてインストール ──────────────────
say "MonitorWall.app をビルド"
( cd "$REPO/monitorwall" && MONITORWALL_BUNDLE_ID="$ID_APP" bash build.sh ) >/tmp/monitorwall_build.log 2>&1 \
  || { cat /tmp/monitorwall_build.log; die "ビルド失敗（/tmp/monitorwall_build.log 参照）"; }
rm -rf "$APP_DST"
ditto "$REPO/monitorwall/MonitorWall.app" "$APP_DST"
say "  → $APP_DST"

# ── 5. lockvideo スクリプトを配置 ─────────────────────────────────
say "lockvideo スクリプトを配置 → $PREFIX"
mkdir -p "$PREFIX" "$CFG"
cp -f "$REPO/lockvideo/apply.py" "$PREFIX/"
for s in repair.sh reapply.sh refresh.sh watchdog.sh rotate.sh uninstall.sh; do
  [ -f "$REPO/lockvideo/$s" ] && cp -f "$REPO/lockvideo/$s" "$PREFIX/" || true
done
chmod +x "$PREFIX"/*.sh 2>/dev/null || true

# ── 6. launchd エージェントを生成・ロード ────────────────────────
say "launchd エージェントを登録"
mkdir -p "$LA"

cat > "$LA/$ID_APP.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$ID_APP</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DST/Contents/MacOS/MonitorWall</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MONITORWALL_HOME</key><string>$PREFIX</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

cat > "$LA/$ID_LV.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$ID_LV</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PREFIX/reapply.sh</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$WP/aerials/videos</string>
        <string>$WP/Store/Index.plist</string>
        <string>$WP/aerials/manifest/entries.json</string>
    </array>
    <key>StartInterval</key><integer>300</integer>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

for id in "$ID_LV" "$ID_APP"; do
  launchctl bootout "$GUI/$id" 2>/dev/null || true
  launchctl bootstrap "$GUI" "$LA/$id.plist" || die "launchctl bootstrap 失敗: $id"
  say "  loaded $id"
done

# ── 完了 ─────────────────────────────────────────────────────────
say "インストール完了"
cat <<EOF

  次の手順:
    1. メニューバーの MonitorWall アイコン（起動済み）を開く
    2. 各 Display のサブメニューで「動画を選択…」→ デスクトップ動画壁紙を設定
    3. ロック画面: 同サブメニュー内「── ロック画面 ──> 動画を選択…」で設定
       （初回変換は数十秒。完了通知が出るまで待つ）

  アンインストール（壁紙も元に戻す）:
    bash "$PREFIX/uninstall.sh"

  注意:
    - ad-hoc 署名のため初回起動時に Gatekeeper 警告が出る場合があります
      （システム設定 > プライバシーとセキュリティ から許可）。
    - この方式は macOS の Aerial 壁紙内部構造に依存するため、
      OS のメジャーアップデートで動作が変わる可能性があります。
EOF
