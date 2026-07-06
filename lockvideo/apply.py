#!/usr/bin/env python3
# LockVideo: 自作動画を macOS aerial(ロック画面)へ注入。Backdrop手法の踏襲。
#  - モニタ別に動画割当（Index.plist Displays 注入）
#  - entries.json の再DL元URLを無効化（原本復元＝reset防止）
#  - 意味的冪等: assetIDマッピング/ファイルサイズ/URL のみを比較（WallpaperAgentのタイムスタンプ更新は無視）
#  - 双子スロット交互切替: WallpaperCreationRequestが前回と同一だとupdate()経路(不安定)に落ち、
#    差分があればinvalidate()+新規init()経路(安定)になる観測に基づき、解除の度にassetIDを
#    同一内容の別UUIDへ切替えてWallpaperAgent自体は再起動しない(--rotate)。
#  終了コード: 0=適用した(要WallpaperAgent再起動) / 42=既に整合(何もしない)
import json, os, copy, plistlib, sys, shutil

HOME = os.path.expanduser("~")
WP   = f"{HOME}/Library/Application Support/com.apple.wallpaper"
IDX  = f"{WP}/Store/Index.plist"
VID  = f"{WP}/aerials/videos"
MAN  = f"{WP}/aerials/manifest/entries.json"
SRC  = f"{HOME}/dev/lockvideo"
STATE = f"{HOME}/.config/monitorwall/rotation_state.json"

# 割当: displayUUID -> (動画, (スロットA, スロットB))  Noneは未使用実カタログIDを動的採取して埋める
PAIRS_RAW = {
    "CD62BA3B-F31E-43FD-8D38-9A33BA1FD64E": (f"{SRC}/shoujo-hevc.mov",
        ("F439B0A7-D18C-4B14-9681-6520E6A74FE9", "52ACB9B8-75FC-4516-BC60-4550CFF3B661")),  # ウルトラワイド(メイン) → 少女終末旅行
    "37D8832A-2D66-02CA-B9F7-8F30A301B230": (f"{SRC}/shigure-hevc.mov",
        ("4C108785-A7BA-422E-9C79-B0129F1D5550", "CF6347E2-4F81-4410-8892-4830991B6C5A")),  # 内蔵 → しぐれうい(4K)
    "0BF12135-4B8E-4D78-BC1C-BB70D3272F29": (f"{SRC}/inaba-hevc.mov",
        (None, "6D6834A4-2F0F-479A-B053-7D4DC5CB8EB7")),                                    # MSI → きみに回帰線
}
FALLBACK_SLOT = "F439B0A7-D18C-4B14-9681-6520E6A74FE9"
AERIAL_PROVIDER = "com.apple.wallpaper.choice.aerials"

def resolve_pairs(man):
    used = {s for _, (a, b) in PAIRS_RAW.values() for s in (a, b) if s}
    free = iter(a["id"] for a in man.get("assets", []) if a.get("id") and a["id"] not in used)
    out = {}
    for d, (v, (a, b)) in PAIRS_RAW.items():
        a = a or next(free)
        b = b or next(free)
        out[d] = (v, (a, b))
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

def files_ok(pairs):
    for _, (v, (a, b)) in pairs.items():
        for s in (a, b):
            dst = f"{VID}/{s}.mov"
            if not os.path.exists(dst) or os.path.getsize(dst) != os.path.getsize(v):
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

def index_ok(pairs, state):
    try: idx = plistlib.load(open(IDX, "rb"))
    except Exception: return False
    disp = idx.get("Displays", {})
    if set(disp.keys()) != set(pairs.keys()): return False
    for d in pairs:
        if cfg_asset(disp[d]["Linked"]) != active_slot(pairs, state, d): return False
    if cfg_asset(idx.get("SystemDefault", {}).get("Linked", {})) != FALLBACK_SLOT: return False
    if isinstance(idx.get("AllSpacesAndDisplays"), dict): return False
    return True

def linked(template, slot):
    L = copy.deepcopy(template)
    c = L["Content"]["Choices"][0]
    c["Provider"] = AERIAL_PROVIDER
    c["Configuration"] = plistlib.dumps({"assetID": slot}, fmt=plistlib.FMT_BINARY)
    c["Files"] = []
    L["Content"]["EncodedOptionValues"] = plistlib.dumps({"values": {}}, fmt=plistlib.FMT_BINARY)
    return L

def write_index(pairs, state):
    idx = plistlib.load(open(IDX, "rb"))
    template = (idx.get("Displays") or {}).get(next(iter(pairs)), {}).get("Linked") \
        or idx["SystemDefault"]["Linked"]
    idx["SystemDefault"]["Linked"] = linked(template, FALLBACK_SLOT)
    idx["AllSpacesAndDisplays"] = "$null"
    idx["Displays"] = {d: {"Linked": linked(template, active_slot(pairs, state, d)), "Type": "linked"}
                        for d in pairs}
    plistlib.dump(idx, open(IDX, "wb"), fmt=plistlib.FMT_BINARY)

def ensure_assets(pairs, man, slots):
    """全スロットの動画ファイル配置＋manifestのurl/POIクリア（steady-state維持用）"""
    for _, (v, (a, b)) in pairs.items():
        for s in (a, b):
            dst = f"{VID}/{s}.mov"
            if not os.path.exists(dst) or os.path.getsize(dst) != os.path.getsize(v):
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
    man = json.load(open(MAN))
    pairs = resolve_pairs(man)
    slots = all_slots(pairs)
    state = load_state()
    if files_ok(pairs) and manifest_ok(man, slots) and index_ok(pairs, state):
        print("RESULT: CLEAN"); sys.exit(42)
    ensure_assets(pairs, man, slots)
    write_index(pairs, state)
    print("RESULT: CHANGED")
    for d in pairs:
        print(f"  {d[:8]} <- slot {active_slot(pairs, state, d)[:8]}")
    sys.exit(0)

def cmd_rotate():
    """解除トリガー用: 双子スロットを交互切替。killall不要(WallpaperCreationRequestに差分を作るだけ)。"""
    man = json.load(open(MAN))
    pairs = resolve_pairs(man)
    slots = all_slots(pairs)
    state = load_state()
    ensure_assets(pairs, man, slots)   # 両スロットの健全性は毎回軽く保証(コピー済みならno-op)
    new_state = {d: 1 - state.get(d, 0) for d in pairs}
    write_index(pairs, new_state)
    save_state(new_state)
    print("RESULT: ROTATED")
    for d in pairs:
        print(f"  {d[:8]} -> slot {active_slot(pairs, new_state, d)[:8]} (was {active_slot(pairs, state, d)[:8]})")
    sys.exit(0)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--rotate":
        cmd_rotate()
    else:
        cmd_ensure()
