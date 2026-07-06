# wallpaper-tools

macOS のデスクトップ壁紙・ロック画面をモニタ別に動画へ差し替えるツール一式。

## monitorwall/

モニタごとに個別のローカル動画をデスクトップ壁紙として再生するメニューバー常駐アプリ（AppKit + AVFoundation）。

- `main.swift` — 本体（単一ファイル）
- `build.sh` — `swiftc` でコンパイルし `.app` バンドルを生成・ad-hoc署名
- `MonitorWall.app` — ビルド済みアプリ
- `wincheck.swift` / `wincheck2.swift` — `CGWindowList` でウィンドウ生成・可視状態を検証する診断ツール
- `MonitorWall-architecture.md` — 設計ドキュメント

設計の要点は `MonitorWall-architecture.md` を参照。

## lockvideo/

macOS の aerial（動く壁紙）システムに自作動画を注入し、ロック画面の背景として表示する仕組み。
`~/Library/Application Support/com.apple.wallpaper/` 配下の Index.plist / entries.json を操作する。

- `apply.py` — Index.plist へモニタ別 assetID を注入。entries.json の再ダウンロードURL・pointsOfInterest を無効化（reset防止）
- `repair.sh` — 黒画面検出時の強制修復（ロック＋mkdirデバウンス）
- `reapply.sh` — LaunchAgent(WatchPaths)からの再適用。repair.sh と同じロック/デバウンスを共有
- `refresh.sh` — 解除トリガー専用の先回りWallpaperAgent再起動（3秒クールダウン）
- `watchdog.sh` — ロック中のCPU使用率で黒画面を検出（aerials拡張が健全なら~6%、スタール時は~0.3%）
- `restore.sh` — 元の状態（純正aerial）へ完全復元
- `sleepmonitor.swift` / `displays.swift` — ロック/スリープ通知とディスプレイ情報の診断ツール
- `Index.baseline.plist` / `Index.preB.plist` — 復元用のバックアップスナップショット

### 既知の制約
- macOS のバージョンアップで `com.apple.wallpaper` の内部スキーマが変わると壊れる可能性がある。
- 動画ファイル本体（`*.mov`）はこのリポジトリに含まれない（サイズが大きく、著作権のある素材のため）。運用には `~/dev/lockvideo/*.mov` に該当ファイルを別途配置する必要がある。
- コールドブート直後のログイン画面（System Volume限定）には対応不可。対象は「ログイン後のロック」のみ。
