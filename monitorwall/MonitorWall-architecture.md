# MonitorWall — 設計・アーキテクチャドキュメント

**モニタ別ローカル動画壁紙アプリ（macOS / AppKit + AVFoundation）**

作成: 2026-07-07 / 対象: macOS 12+（検証環境 macOS 26.5.2, Apple Silicon）/ 実装言語: Swift 6.3.3（Swift 5 モード）

---

## 1. 背景と目的

### なぜ作ったか
- ゴール: **複数モニタそれぞれに、個別のローカル動画をループ壁紙として設定**する。
- 既存の Plash（Web を壁紙にするアプリ）を検討したが、以下の理由で不採用:
  1. **ソース非公開**: `github.com/sindresorhus/Plash` は `readme.md` / `.editorconfig` / 画像素材のみで **Swift ソースが 0 件**。クローンしてビルド・改造できない。
  2. **マルチモニタ非対応**: アプリバイナリ内の文言に明記 — *"Support for multiple displays is currently limited to the ability to choose which display to show the website on."*（表示先を1つ選べるだけ）。
- そこで、目的特化の軽量アプリを新規実装した。

### Plash との設計思想の違い
| 観点 | Plash | MonitorWall |
|---|---|---|
| 描画基盤 | WKWebView（任意Webページ） | AVPlayerLayer（ローカル動画特化） |
| マルチモニタ | 1画面のみ | **全画面・個別割り当て** |
| 負荷 | Webレンダリング | GPU動画再生（軽量） |
| 依存 | 多数 | ゼロ（標準フレームワークのみ） |

---

## 2. 全体アーキテクチャ

```
NSApplication (.accessory = メニューバー常駐 / Dock非表示 / LSUIElement)
        │
   AppDelegate  ──── 状態管理・UI・設定の中枢
        ├─ [ScreenWallpaper]  × モニタ数     ← 描画+再生の最小単位
        ├─ NSStatusItem (🎬)                 ← メニューUI
        └─ Config (JSON 永続化)              ← displayID → 動画パス
```

- **単一プロセス / 単一 `main.swift`**。DB・外部ライブラリ・パッケージマネージャなし。
- **非サンドボックス**アプリ（任意パスの動画をパス直読みするため）。

---

## 3. コンポーネント詳細

### 3.1 壁紙ウィンドウ層 — `ScreenWallpaper`（1モニタ = 1インスタンス）

各物理モニタにつき 1 つのボーダレスウィンドウを生成し、そこに動画を再生する。

```swift
window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
window.ignoresMouseEvents = true
```

要点:
- **ウィンドウレベル = `desktopIconWindow - 1`**
  デスクトップの絵より上、デスクトップアイコンより下。これで「アイコンの背後で再生される壁紙」として振る舞う。**設計上の最重要ポイント**。
- **`canJoinAllSpaces`**: すべての Space（仮想デスクトップ）に表示。
- **`stationary`**: Space 切替時に一緒に動かない（壁紙として固定）。
- **`ignoresMouseEvents = true`**: クリック・ドラッグがウィンドウを貫通してデスクトップに届く（アイコン選択やRメニューが従来通り使える）。

### 3.2 動画再生層

```swift
let item = AVPlayerItem(url: URL(fileURLWithPath: path))
let queue = AVQueuePlayer()
queue.isMuted = true
looper = AVPlayerLooper(player: queue, templateItem: item)   // 継ぎ目なし無限ループ
playerLayer.player = queue
playerLayer.videoGravity = .resizeAspectFill                 // アスペクト維持で画面いっぱい
```

- **`AVQueuePlayer` + `AVPlayerLooper`**: 単純な「end で seek(0)」だとループの継ぎ目でカクつくため、Looper がキューに次アイテムを積んでシームレス化。
- **`AVPlayerLayer`**（CoreAnimation レイヤ）を `contentView.layer` に載せる → **GPU 合成**で低 CPU 負荷。
- **`.resizeAspectFill`**: 解像度/アスペクト比の異なるモニタでも黒帯なく充填（はみ出しはトリミング）。
- **muted**: 壁紙なので常時ミュート。

### 3.3 モニタ同定 — `CGDirectDisplayID`

```swift
(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
```

- 配列 index（0,1,2…）は**モニタの抜き差しや並び替えでズレる**ため採用しない。
- `CGDirectDisplayID` を**安定キー**として「この物理モニタ ↔ この動画」を紐付ける。

### 3.4 設定の永続化 — `Config`（JSON）

- 保存先: `~/.config/monitorwall/config.json`
- スキーマ:
  ```json
  { "assignments": { "<displayID>": "/path/to/video.mp4" }, "defaultVideo": "/path/or/null" }
  ```
- `Codable` で読み書き。`assignments` に無いモニタは `defaultVideo` にフォールバック。

### 3.5 動的追従

```swift
NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
    name: NSApplication.didChangeScreenParametersNotification, object: nil)
```

- モニタ増減・解像度変更・配置変更を検知 → `rebuild()`（全 `ScreenWallpaper` を teardown → 再生成）。
- 検証済み: 4画面 → 3画面への変化にも自動追従。

### 3.6 UI 層 — `NSStatusItem`

- メニューバー 🎬 アイコン。
- Display 別サブメニュー: `動画を選択…`（`NSOpenPanel`）/ `クリア` / 現在ファイル名表示。
- グローバル: `全モニタに同じ動画…` / `再読み込み` / `終了`。

---

## 4. データフロー（動画選択時）

```
メニュー "動画を選択…"
  → NSOpenPanel で path 取得
  → config.assignments[displayID] = path
  → saveConfig()                       # JSON へ即永続化
  → wallpapers[該当].setVideo(path)    # そのモニタだけ即差し替え（他は無停止）
  → buildMenu()                        # "現在: xxx.mp4" 表示更新
```

起動時フロー:
```
applicationDidFinishLaunching
  → statusItem 生成
  → rebuild(): NSScreen.screens を走査
       各 screen について ScreenWallpaper 生成
       assignments[displayID] ?? defaultVideo を setVideo
  → 画面変更通知を購読
```

---

## 5. ビルド構成

- コンパイル: `xcrun swiftc -O -swift-version 5 -framework Cocoa -framework AVFoundation main.swift -o MonitorWall`
- `.app` バンドルを手組み:
  - `Contents/MacOS/MonitorWall`（実行バイナリ）
  - `Contents/Info.plist`（`LSUIElement=true`, `NSHighResolutionCapable=true`, `NSPrincipalClass=NSApplication` ほか）
- 署名: `codesign --force --deep --sign -`（ad-hoc）
- ビルドスクリプト: `build.sh`（コンパイル → バンドル生成 → 署名を一括）

### ファイル構成
```
~/dev/monitorwall/
├── main.swift            # 全ロジック（単一ファイル）
├── build.sh              # ビルドスクリプト
├── wincheck.swift        # 検証用（CGWindowList でウィンドウ確認）
└── MonitorWall.app       # ビルド成果物
成果物設置: /Applications/MonitorWall.app
設定: ~/.config/monitorwall/config.json
```

---

## 6. 検証結果

`CGWindowListCopyWindowInfo` によるウィンドウ検証（画面録画権限不要）:

```
window: layer=-2147483604 size=1710x1112   # MacBook Air 内蔵
window: layer=-2147483604 size=3440x1440   # ウルトラワイド
window: layer=-2147483604 size=2560x1440   # 外部モニタ
MonitorWall windows = 3
NSScreen count = 3
```

- 3モニタ = 3ウィンドウ（`NSScreen` 数と一致）。
- `layer=-2147483604` = `desktopIconWindow - 1`（壁紙レイヤ）に正しく配置。
- クラッシュログなし。

---

## 7. 設計上の割り切り（トレードオフ）

- **非サンドボックス**: サンドボックス下では任意パスの mp4 読取に security-scoped bookmark が必要。個人ツールのため非サンドボックスで単純化。配布する場合は bookmark 対応が必要。
- **WKWebView 不使用**: 目的がローカル動画なので AVPlayer 直挿しで軽量化。Web ページ壁紙は非対応（Plash の領分）。
- **状態は薄く**: 永続化は JSON 一枚。DB・設定フレームワーク不使用。
- **自動起動は任意**: LaunchAgent（`~/Library/LaunchAgents/com.haroin.monitorwall.plist`）を用意済みだが、永続化は明示操作（`launchctl load -w ...`）に委ねる。

---

## 8. 今後の拡張余地

- **Space ごとに別動画**（現状は全 Space 共通）。
- **HDR / 広色域**動画のトーンマッピング最適化。
- **バッテリー時に一時停止**（省電力）。
- **再生位置の同期 / ランダム開始**。
- **設定 GUI**（現状はメニューバー + JSON）。
- **サンドボックス化 + 署名/公証**（配布用）。

---

## 付録: なぜ Plash ではダメだったか（一次情報）

- リポジトリ内容（GitHub API 実測）: `.editorconfig`, `.gitattributes`, `Stuff/`, `readme.md` のみ。`Plash/`（ソース）は HTTP 404。
- `.swift` ファイル数: **0**。
- アプリバイナリ内文言: *"Support for multiple displays is currently limited to the ability to choose which display to show the website on."*

→ 「クローンして改造・ビルド」は不可能。目的特化の新規実装が唯一の現実解だった。
