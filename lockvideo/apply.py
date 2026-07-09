#!/usr/bin/env python3
# LockVideo: 自作動画を macOS aerial(ロック画面)へ注入。Backdrop手法の踏襲。
#  - モニタ別に動画割当（Index.plist Displays 注入）
#  - entries.json の再DL元URLを無効化（原本復元＝reset防止）
#  - 意味的冪等: assetIDマッピング/ファイルサイズ/URL のみを比較（WallpaperAgentのタイムスタンプ更新は無視）
#  - 双子スロット交互切替: WallpaperCreationRequestが前回と同一だとupdate()経路(不安定)に落ち、
#    差分があればinvalidate()+新規init()経路(安定)になる観測に基づき、解除の度にassetIDを
#    同一内容の別UUIDへ切替えてWallpaperAgent自体は再起動しない(--rotate)。
#  - 動的ディスプレイ検出: 実接続中のディスプレイのみを CoreGraphics(ctypes) で取得して対象化。
#    1画面時は macOS が per-display ではなく SystemDefault を適用するため、SystemDefault を
#    メインディスプレイの現行スロットに追従させる（内蔵1枚のとき割当が無視される問題の根治）。
#  終了コード: 0=適用した(要WallpaperAgent再起動) / 42=既に整合(何もしない)
import json, os, copy, plistlib, sys, shutil, ctypes

HOME = os.path.expanduser("~")
WP   = f"{HOME}/Library/Application Support/com.apple.wallpaper"
IDX  = f"{WP}/Store/Index.plist"
VID  = f"{WP}/aerials/videos"
MAN  = f"{WP}/aerials/manifest/entries.json"
STATE = f"{HOME}/.config/monitorwall/rotation_state.json"
LOCK_CFG    = f"{HOME}/.config/monitorwall/lock_assignments.json"   # displayUUID -> 動画パス (MonitorWallが書く)
SLOTS_CACHE = f"{HOME}/.config/monitorwall/lock_slots.json"         # 新規ディスプレイの採取スロット安定化

# 配布可能版はマシン固有のデフォルト割当を持たない。割当は全て lock_assignments.json
# （MonitorWall が接続中ディスプレイの実 displayUUID で動的に書く）から供給し、双子スロットは
# aerial マニフェストの空きアセットIDから動的採取して lock_slots.json に固定する。
PAIRS_RAW = {}
AERIAL_PROVIDER = "com.apple.wallpaper.choice.aerials"

# 新スキーマ(macOS 26 Tahoe: Desktop/Idle シーンモデル)で書き込むシーン。既定で Desktop(壁紙) と
# Idle(ロック画面) の両方へ同一スロットを注入する。ロック画面だけにしたいなら ("Idle",) にする。
# 旧 Linked スキーマでは未使用。
SCENE_KEYS = ("Desktop", "Idle")


def _require_store():
    """aerial 壁紙ストアの有無で macOS 世代を早期判定する。動画ロック画面は
    com.apple.wallpaper + aerial ストアが導入された macOS 14 Sonoma 以降が前提で、
    Ventura(13) 以前には注入先が存在しない。traceback ではなく理由を返して止める。"""
    if not os.path.isdir(WP) or not os.path.exists(MAN):
        sys.exit("lockvideo: aerial 壁紙ストア(com.apple.wallpaper)が見つかりません。"
                 "動画ロック画面は macOS 14 Sonoma 以降が必要です"
                 f"（missing: {MAN}）")


def connected_displays():
    """実接続中ディスプレイの (UUID集合, メインUUID) を CoreGraphics 経由(ctypes/pyobjc非依存)で返す。
    近年 CGDisplayCreateUUIDFromDisplayID は ColorSync にシンボルが移動しているため両方を探索。
    取得に失敗したら (None, None) を返し、呼び出し側は従来動作(全PAIRS+固定FALLBACK)にフォールバックする。"""
    try:
        cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cs = ctypes.CDLL("/System/Library/Frameworks/ColorSync.framework/ColorSync")
    except Exception:
        return None, None
    uuid_src = cs if hasattr(cs, "CGDisplayCreateUUIDFromDisplayID") else \
               (cg if hasattr(cg, "CGDisplayCreateUUIDFromDisplayID") else None)
    if uuid_src is None:
        return None, None
    try:
        MAX = 16
        arr = (ctypes.c_uint32 * MAX)(); cnt = ctypes.c_uint32(0)
        cg.CGGetActiveDisplayList.argtypes = [ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
        if cg.CGGetActiveDisplayList(MAX, arr, ctypes.byref(cnt)) != 0:
            return None, None
        uuid_src.CGDisplayCreateUUIDFromDisplayID.restype = ctypes.c_void_p
        uuid_src.CGDisplayCreateUUIDFromDisplayID.argtypes = [ctypes.c_uint32]
        cg.CGMainDisplayID.restype = ctypes.c_uint32
        cf.CFUUIDCreateString.restype = ctypes.c_void_p
        cf.CFUUIDCreateString.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        cf.CFRelease.argtypes = [ctypes.c_void_p]

        def uuid_of(did):
            ref = uuid_src.CGDisplayCreateUUIDFromDisplayID(did)
            if not ref:
                return None
            sref = cf.CFUUIDCreateString(None, ref)
            buf = ctypes.create_string_buffer(64)
            ok = cf.CFStringGetCString(sref, buf, 64, 0x08000100)  # kCFStringEncodingUTF8
            cf.CFRelease(sref); cf.CFRelease(ref)
            return buf.value.decode() if ok else None

        ids = [arr[i] for i in range(cnt.value)]
        uuids = {u for u in (uuid_of(d) for d in ids) if u}
        main = uuid_of(cg.CGMainDisplayID())
        if not uuids:
            return None, None
        return uuids, main
    except Exception:
        return None, None


def base_pairs():
    """PAIRS_RAW をデフォルトに lock_assignments.json (displayUUID -> 動画パス) を
    上書きした割当。値 "" のディスプレイはロック動画を解除。設定が無ければ
    PAIRS_RAW のまま(後方互換)。既知ディスプレイは双子スロットを固定して動画だけ
    差し替え、新規ディスプレイはスロットを遅延採取して lock_slots.json に固定する。"""
    pairs = {d: (v, tuple(s)) for d, (v, s) in PAIRS_RAW.items()}
    try:
        overrides = json.load(open(LOCK_CFG))
    except Exception:
        overrides = {}
    try:
        cache = json.load(open(SLOTS_CACHE))
    except Exception:
        cache = {}
    for d, video in overrides.items():
        if not video:
            pairs.pop(d, None)
            continue
        if d in pairs:
            pairs[d] = (video, pairs[d][1])              # 動画だけ差し替え(スロット固定)
        else:
            c = cache.get(d)
            pairs[d] = (video, tuple(c) if c else (None, None))
    return pairs


def resolve_pairs(man, connected=None):
    """base_pairs のスロット未確定分(None)を実カタログの空きIDで埋める。
    connected(UUID集合)が渡されたら実接続ディスプレイのみに絞る（動的検出）。"""
    pairs = base_pairs()
    if connected is not None:
        pairs = {d: v for d, v in pairs.items() if d in connected}
    try:
        cache = json.load(open(SLOTS_CACHE))
    except Exception:
        cache = {}
    used = {s for _, (a, b) in pairs.values() for s in (a, b) if s}
    # 他ディスプレイ（未接続含む）にキャッシュ済みのスロットも予約済み扱いにし、
    # フレッシュ採取で別ディスプレイと同じスロットを引く衝突を防ぐ。
    for cs in cache.values():
        used.update(s for s in (cs or []) if s)
    free = iter(a["id"] for a in man.get("assets", []) if a.get("id") and a["id"] not in used)
    out, dirty = {}, False
    for d, (v, (a, b)) in pairs.items():
        na = a or next(free)
        nb = b or next(free)
        out[d] = (v, (na, nb))
        if a is None or b is None:                       # 新規採取分をキャッシュ→次回も安定
            cache[d] = [na, nb]; dirty = True
    if dirty:
        os.makedirs(os.path.dirname(SLOTS_CACHE), exist_ok=True)
        json.dump(cache, open(SLOTS_CACHE, "w"))
    return out

def load_state():
    try: return json.load(open(STATE))
    except Exception: return {}

def save_state(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(st, open(STATE, "w"))

def all_slots(pairs):
    return {s for _, (a, b) in pairs.values() for s in (a, b)}

def active_slot(pairs, state, d):
    v, (a, b) = pairs[d]
    return b if state.get(d, 0) == 1 else a

def system_default_slot(pairs, state, main):
    """1画面時、macOSは per-display の Displays[uuid] ではなく SystemDefault を実際の画面へ適用する。
    そこで SystemDefault をメインディスプレイの現行スロットへ追従させ、内蔵1枚でも割当が反映されるようにする。
    メインが未割当なら先頭の割当ディスプレイのスロットを流用（caller が pairs 非空を保証）。"""
    if main and main in pairs:
        return active_slot(pairs, state, main)
    for d in pairs:
        return active_slot(pairs, state, d)
    return None

def _needs_copy(v, dst):
    """スロット実体を差し替えるべきか。サイズ一致でも中身が違うケース(HW再エンコードで
    バイト数が偶然一致)を取りこぼさないよう、ソースが dst より新しければ再コピーする。"""
    if not os.path.exists(dst):
        return True
    try:
        if os.path.getsize(dst) != os.path.getsize(v):
            return True
        if os.path.getmtime(v) > os.path.getmtime(dst) + 1:  # 1秒の余裕
            return True
    except OSError:
        return True
    return False

def files_ok(pairs):
    for _, (v, (a, b)) in pairs.items():
        for s in (a, b):
            if _needs_copy(v, f"{VID}/{s}.mov"):
                return False
    return True

def manifest_ok(man, slots):
    for a in man.get("assets", []):
        if a.get("id") in slots:
            if any(k.startswith("url-") and a[k] for k in a):
                return False
            if a.get("pointsOfInterest"):   # POIは空が正（区間ループ/途中リセット防止）
                return False
    return True

def cfg_asset(choice):
    try: return plistlib.loads(choice["Content"]["Choices"][0]["Configuration"]).get("assetID")
    except Exception: return None

# ── スキーマ判定 + Desktop/Idle シーン(新スキーマ)ヘルパー ──────────────
# macOS 26(Tahoe)以降、Index.plist は旧 "Linked" 一枚モデルを廃し、各スコープ直下に
# "Desktop"(壁紙) と "Idle"(ロック画面/スクリーンセーバ) の 2 シーンを持つ形へ変わった。
# だが移行済み環境では旧 Linked モデルも現役で併存する（OSバージョンでは決まらない）ため、
# Index.plist の実物を見て両対応で分岐する。
def is_scene_schema(idx):
    sd = idx.get("SystemDefault")
    if isinstance(sd, dict):
        if "Linked" in sd: return False
        if "Idle" in sd or "Desktop" in sd: return True
    asd = idx.get("AllSpacesAndDisplays")
    return isinstance(asd, dict) and asd.get("Type") == "individual"

def _scene_asset(block):
    """Desktop/Idle シーン dict から現在の assetID を取り出す。"""
    try: return plistlib.loads(block["Content"]["Choices"][0]["Configuration"]).get("assetID")
    except Exception: return None

def _set_scene_asset(block, slot):
    """Desktop/Idle シーン dict を in-place で aerial スロットへ差し替え。LastSet/LastUse 等は保つ。"""
    ch = block["Content"]["Choices"][0]
    ch["Provider"] = AERIAL_PROVIDER
    ch["Configuration"] = plistlib.dumps({"assetID": slot}, fmt=plistlib.FMT_BINARY)
    ch["Files"] = []
    if "Shuffle" in block.get("Content", {}):
        block["Content"]["Shuffle"] = "$null"   # aerialシャッフル無効(他アセットへローテーションしスロットが外れるのを防ぐ)
    block["Content"]["EncodedOptionValues"] = plistlib.dumps({"values": {}}, fmt=plistlib.FMT_BINARY)

def _scope_ok(scope, slot):
    for scene in SCENE_KEYS:
        blk = scope.get(scene) if isinstance(scope, dict) else None
        if isinstance(blk, dict) and "Content" in blk and _scene_asset(blk) != slot:
            return False
    return True

def _apply_scope(scope, slot):
    for scene in SCENE_KEYS:
        blk = scope.get(scene) if isinstance(scope, dict) else None
        if isinstance(blk, dict) and "Content" in blk:
            _set_scene_asset(blk, slot)

def index_ok(pairs, state, sysdef):
    try: idx = plistlib.load(open(IDX, "rb"))
    except Exception: return False
    return _index_ok_scene(idx, pairs, state, sysdef) if is_scene_schema(idx) \
        else _index_ok_linked(idx, pairs, state, sysdef)

def _index_ok_scene(idx, pairs, state, sysdef):
    if sysdef:
        if not _scope_ok(idx.get("SystemDefault"), sysdef): return False
        if not _scope_ok(idx.get("AllSpacesAndDisplays"), sysdef): return False
    for d, dval in (idx.get("Displays") or {}).items():
        if d in pairs and not _scope_ok(dval, active_slot(pairs, state, d)): return False
    for _sk, sv in (idx.get("Spaces") or {}).items():
        if not isinstance(sv, dict): continue
        if sysdef and not _scope_ok(sv.get("Default"), sysdef): return False
        for duuid, dval in (sv.get("Displays") or {}).items():
            if duuid in pairs and not _scope_ok(dval, active_slot(pairs, state, duuid)): return False
    return True

def _index_ok_linked(idx, pairs, state, sysdef):
    disp = idx.get("Displays", {})
    if set(disp.keys()) != set(pairs.keys()): return False
    for d in pairs:
        if cfg_asset(disp[d]["Linked"]) != active_slot(pairs, state, d): return False
    if sysdef and cfg_asset(idx.get("SystemDefault", {}).get("Linked", {})) != sysdef: return False
    if isinstance(idx.get("AllSpacesAndDisplays"), dict): return False
    # Spaces（権威データ）も一致していなければ未整合とみなし、書き戻し(reapply)を発火させる
    for _sk, sv in (idx.get("Spaces") or {}).items():
        dfl = sv.get("Default", {})
        if sysdef and isinstance(dfl, dict) and "Linked" in dfl and cfg_asset(dfl["Linked"]) != sysdef:
            return False
        for duuid, dval in (sv.get("Displays") or {}).items():
            if duuid in pairs and cfg_asset(dval.get("Linked", {})) != active_slot(pairs, state, duuid):
                return False
    return True

def linked(template, slot):
    L = copy.deepcopy(template)
    c = L["Content"]["Choices"][0]
    c["Provider"] = AERIAL_PROVIDER
    c["Configuration"] = plistlib.dumps({"assetID": slot}, fmt=plistlib.FMT_BINARY)
    c["Files"] = []
    L["Content"]["EncodedOptionValues"] = plistlib.dumps({"values": {}}, fmt=plistlib.FMT_BINARY)
    return L

def write_index(pairs, state, sysdef):
    idx = plistlib.load(open(IDX, "rb"))
    if is_scene_schema(idx):
        _write_scene(idx, pairs, state, sysdef)
    else:
        _write_linked(idx, pairs, state, sysdef)
    plistlib.dump(idx, open(IDX, "wb"), fmt=plistlib.FMT_BINARY)

def _write_scene(idx, pairs, state, sysdef):
    # 新スキーマ: 全画面スコープ(単一ディスプレイ時の実画面権威)へシーンを注入。
    # AllSpacesAndDisplays は Type=individual の dict なので "$null" にしない（潰すと割当が消える）。
    if sysdef:
        _apply_scope(idx.get("SystemDefault"), sysdef)
        _apply_scope(idx.get("AllSpacesAndDisplays"), sysdef)
    for d, dval in (idx.get("Displays") or {}).items():
        if d in pairs:
            _apply_scope(dval, active_slot(pairs, state, d))
    for _sk, sv in (idx.get("Spaces") or {}).items():
        if not isinstance(sv, dict): continue
        if sysdef:
            _apply_scope(sv.get("Default"), sysdef)
        for duuid, dval in (sv.get("Displays") or {}).items():
            if duuid in pairs:
                _apply_scope(dval, active_slot(pairs, state, duuid))

def _write_linked(idx, pairs, state, sysdef):
    # 旧スキーマ: SystemDefault.Linked + per-display Displays + 権威データ Spaces を書き、
    # 単一ディスプレイ時に効く AllSpacesAndDisplays は "$null" で無効化する。
    template = (idx.get("Displays") or {}).get(next(iter(pairs)), {}).get("Linked") \
        or idx["SystemDefault"]["Linked"]
    if sysdef:
        idx["SystemDefault"]["Linked"] = linked(idx["SystemDefault"]["Linked"], sysdef)
    idx["AllSpacesAndDisplays"] = "$null"
    idx["Displays"] = {d: {"Linked": linked(template, active_slot(pairs, state, d)), "Type": "linked"}
                        for d in pairs}
    for _sk, sv in (idx.get("Spaces") or {}).items():
        dfl = sv.get("Default")
        if sysdef and isinstance(dfl, dict) and "Linked" in dfl:
            dfl["Linked"] = linked(dfl["Linked"], sysdef)
        for duuid, dval in (sv.get("Displays") or {}).items():
            if duuid in pairs and isinstance(dval, dict) and "Linked" in dval:
                dval["Linked"] = linked(dval["Linked"], active_slot(pairs, state, duuid))

def ensure_assets(pairs, man, slots):
    """全スロットの動画ファイル配置＋manifestのurl/POIクリア（steady-state維持用）"""
    for _, (v, (a, b)) in pairs.items():
        for s in (a, b):
            dst = f"{VID}/{s}.mov"
            if _needs_copy(v, dst):
                shutil.copyfile(v, dst)
    ch = 0
    for asset in man.get("assets", []):
        if asset.get("id") in slots:
            for k in list(asset):
                if k.startswith("url-") and asset[k]:
                    asset[k] = ""; ch += 1
            if asset.get("pointsOfInterest"):
                asset["pointsOfInterest"] = {}; ch += 1
    if ch:
        json.dump(man, open(MAN, "w"), ensure_ascii=False)

def cmd_ensure():
    """通常モード: watchdog/reapply用。ファイル/manifest/Index整合を維持(現在のstateのまま)。killall前提。"""
    _require_store()
    man = json.load(open(MAN))
    connected, main = connected_displays()
    pairs = resolve_pairs(man, connected)
    if not pairs:
        print("RESULT: CLEAN (no assigned displays connected)"); sys.exit(42)
    slots = all_slots(pairs)
    state = load_state()
    sysdef = system_default_slot(pairs, state, main)
    if files_ok(pairs) and manifest_ok(man, slots) and index_ok(pairs, state, sysdef):
        print("RESULT: CLEAN"); sys.exit(42)
    ensure_assets(pairs, man, slots)
    write_index(pairs, state, sysdef)
    print("RESULT: CHANGED")
    print(f"  SystemDefault <- slot {sysdef[:8]}" + (f" (main {main[:8]})" if main else ""))
    for d in pairs:
        print(f"  {d[:8]} <- slot {active_slot(pairs, state, d)[:8]}")
    sys.exit(0)

def cmd_rotate():
    """解除トリガー用: 双子スロットを交互切替。killall不要(WallpaperCreationRequestに差分を作るだけ)。"""
    _require_store()
    man = json.load(open(MAN))
    connected, main = connected_displays()
    pairs = resolve_pairs(man, connected)
    if not pairs:
        print("RESULT: CLEAN (no assigned displays connected)"); sys.exit(42)
    slots = all_slots(pairs)
    state = load_state()
    ensure_assets(pairs, man, slots)   # 両スロットの健全性は毎回軽く保証(コピー済みならno-op)
    new_state = dict(state)
    for d in pairs:
        new_state[d] = 1 - state.get(d, 0)
    sysdef = system_default_slot(pairs, new_state, main)
    write_index(pairs, new_state, sysdef)
    save_state(new_state)
    print("RESULT: ROTATED")
    print(f"  SystemDefault -> slot {sysdef[:8]}" + (f" (main {main[:8]})" if main else ""))
    for d in pairs:
        print(f"  {d[:8]} -> slot {active_slot(pairs, new_state, d)[:8]} (was {active_slot(pairs, state, d)[:8]})")
    sys.exit(0)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--rotate":
        cmd_rotate()
    else:
        cmd_ensure()
