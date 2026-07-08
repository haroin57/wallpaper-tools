#!/bin/bash
# LockVideo 診断: ロック画面動画が反映されない時の切り分け用。
#   必要なログと状態を一括ダンプし、末尾に「よくある原因」を提示する。
#   使い方:  bash diagnose.sh
export PATH="/opt/homebrew/bin:$HOME/bin:/usr/bin:/bin"
SELF="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/monitorwall"
WP="$HOME/Library/Application Support/com.apple.wallpaper"
MAN="$WP/aerials/manifest/entries.json"
IDX="$WP/Store/Index.plist"
APPLY="$SELF/apply.py"; [ -f "$APPLY" ] || APPLY="$CFG/../$(basename "$SELF")/apply.py"

hr(){ printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }

hr "0. 環境"
echo "sw_vers: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)  arch: $(uname -m)"
echo "python3: $(command -v python3 || echo '無し')   ffmpeg: $(command -v ffmpeg || echo '無し ← 変換不可')"
echo "apply.py: $APPLY $( [ -f "$APPLY" ] && echo '(あり)' || echo '(見つからない)')"

hr "1. Aerial 前提（これが無いと注入先が無く全滅）"
if [ -f "$MAN" ]; then
  n=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('assets',[])))" "$MAN" 2>/dev/null || echo '?')
  echo "manifest: あり  aerial assets: $n  （モニタ1枚につき2枠必要）"
else
  echo "manifest: 無し ← システム設定 > 壁紙 で Aerial/ダイナミック壁紙を一度設定してください"
fi

hr "2. 割り当て（MonitorWall が書く displayUUID -> 動画）"
echo "--- lock_assignments.json ---"; cat "$CFG/lock_assignments.json" 2>/dev/null || echo "(無し=まだ設定されていない)"
echo; echo "--- lock_slots.json（動的採取した双子スロット）---"; cat "$CFG/lock_slots.json" 2>/dev/null || echo "(無し)"

hr "3. 接続中ディスプレイ（実 UUID）"
python3 - <<'PY' 2>/dev/null || echo "(取得失敗)"
import ctypes
cg=ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf=ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
cs=ctypes.CDLL("/System/Library/Frameworks/ColorSync.framework/ColorSync")
src=cs if hasattr(cs,"CGDisplayCreateUUIDFromDisplayID") else cg
MAX=16;arr=(ctypes.c_uint32*MAX)();cnt=ctypes.c_uint32(0)
cg.CGGetActiveDisplayList.argtypes=[ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32),ctypes.POINTER(ctypes.c_uint32)]
cg.CGGetActiveDisplayList(MAX,arr,ctypes.byref(cnt))
src.CGDisplayCreateUUIDFromDisplayID.restype=ctypes.c_void_p;src.CGDisplayCreateUUIDFromDisplayID.argtypes=[ctypes.c_uint32]
cg.CGMainDisplayID.restype=ctypes.c_uint32
cf.CFUUIDCreateString.restype=ctypes.c_void_p;cf.CFUUIDCreateString.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
cf.CFStringGetCString.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_long,ctypes.c_uint32]
cf.CFRelease.argtypes=[ctypes.c_void_p]
def u(d):
    r=src.CGDisplayCreateUUIDFromDisplayID(d)
    if not r:return None
    s=cf.CFUUIDCreateString(None,r);b=ctypes.create_string_buffer(64)
    ok=cf.CFStringGetCString(s,b,64,0x08000100);cf.CFRelease(s);cf.CFRelease(r)
    return b.value.decode() if ok else None
main=u(cg.CGMainDisplayID())
for i in range(cnt.value):
    uu=u(arr[i]);print(f"  {uu}{'  [main]' if uu==main else ''}")
PY

hr "4. MonitorWall のログ"
echo "--- lock.log (末尾40:選択→変換→適用の流れ) ---"; tail -40 "$CFG/lock.log" 2>/dev/null || echo "(無し)"
echo; echo "--- ffmpeg.log (進捗行を除いた末尾20:変換エラー確認用) ---"
tr '\r' '\n' < "$CFG/ffmpeg.log" 2>/dev/null | grep -vE '^\s*frame=' | tail -20 || echo "(無し)"

hr "5. apply.py 手動実行（RESULT とスロット割当）"
if [ -f "$APPLY" ]; then python3 "$APPLY"; echo "(exit $?)"; else echo "apply.py が見つからない"; fi
echo; echo "--- /tmp/lockvideo.log (末尾40) ---"; tail -40 /tmp/lockvideo.log 2>/dev/null || echo "(無し)"

hr "6. 実際に適用されたか（Index.plist の権威データ／スキーマ自動判定）"
python3 - "$IDX" <<'PY' 2>/dev/null || echo "(Index.plist 読めず)"
import plistlib,sys
idx=plistlib.load(open(sys.argv[1],'rb'))
def cfg(b):
    try:return plistlib.loads(b["Content"]["Choices"][0]["Configuration"]).get("assetID")[:8]
    except:return "?"
sd=idx.get("SystemDefault",{})
asd=idx.get("AllSpacesAndDisplays")
scene = (isinstance(sd,dict) and ("Idle" in sd or "Desktop" in sd)) or \
        (isinstance(asd,dict) and asd.get("Type")=="individual")
if scene:
    print("  スキーマ: Desktop/Idle（新・macOS26）")
    for key in ("AllSpacesAndDisplays","SystemDefault"):
        sc=idx.get(key)
        if isinstance(sc,dict):
            for name in ("Desktop","Idle"):
                b=sc.get(name)
                if isinstance(b,dict) and "Content" in b: print(f"  {key}.{name} -> {cfg(b)}")
    for d,dv in (idx.get("Displays") or {}).items():
        for name in ("Desktop","Idle"):
            b=dv.get(name) if isinstance(dv,dict) else None
            if isinstance(b,dict) and "Content" in b: print(f"  Displays[{d[:8]}].{name} -> {cfg(b)}")
else:
    print("  スキーマ: Linked（旧）")
    for sk,sv in (idx.get("Spaces") or {}).items():
        print(f"  Space {sk[:8] or chr(39)*2+'(cur)'} Default={cfg(sv.get('Default',{}).get('Linked',{}))}")
        for d,dv in (sv.get("Displays") or {}).items():
            print(f"       Displays[{d[:8]}] -> {cfg(dv.get('Linked',{}))}")
    print(f"  SystemDefault -> {cfg(sd.get('Linked',{}))}")
PY

hr "判定の目安"
cat <<'EOF'
  ・1が「無し/0」            → Aerial 壁紙を未設定。システム設定>壁紙 で空撮系を選ぶ
  ・ffmpeg.log にエラー       → 変換失敗。ffmpeg 未導入なら brew install ffmpeg
  ・apply.py が "no assigned displays connected"
                             → lock_assignments の UUID が実接続(3)と不一致。メニューから設定し直す
  ・5は通るのに画面に出ない   → 6の Spaces が割当スロットを指していれば config は正常＝描画側の問題。
                             端末で `killall WallpaperAgent` を試す
EOF
