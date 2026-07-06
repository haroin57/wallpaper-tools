# wallpaper-tools

macOS のデスクトップ壁紙とロック画面を、モニタごとに個別のローカル動画へ差し替えるための実験的ツール一式。

Apple純正の壁紙エンジン（[Plash](https://github.com/sindresorhus/Plash) 等の後継的な発想）はソースコードが非公開で、かつマルチモニタの個別割当に対応していない。
本リポジトリは目的特化で以下の2つを実装した:

| ツール | 対象 | 実現方法 |
|---|---|---|
| **monitorwall** | デスクトップ壁紙 | 独自の常駐アプリ（AppKit + AVFoundation） |
| **lockvideo** | ロック画面 | macOS純正の aerial（動く壁紙）システムへの動画注入 |

両者は完全に独立していて、片方だけ使うこともできる。

## 要件

- macOS 12 以降（開発・検証は macOS 26 Tahoe / Apple Silicon）
- Xcode Command Line Tools（`swiftc` / `codesign` が使えること）
- Python 3（macOS標準で同梱）
- `ffmpeg`（動画をHEVC `.mov` へ変換する場合。`brew install ffmpeg`）

---

## monitorwall — モニタ別デスクトップ動画壁紙

各ディスプレイに個別のローカル動画をループ再生するメニューバー常駐アプリ。詳細な設計は [`monitorwall/MonitorWall-architecture.md`](monitorwall/MonitorWall-architecture.md) を参照。

### ビルド・インストール

```bash
cd monitorwall
bash build.sh                                  # MonitorWall.app を生成
cp -R MonitorWall.app /Applications/
open /Applications/MonitorWall.app
```

### 使い方

メニューバーの **🎬** アイコンから操作する。

| メニュー項目 | 内容 |
|---|---|
| Display N: 動画を選択… | そのモニタに割り当てる動画ファイルを選ぶ |
| クリア | そのモニタの動画を外し、背後の通常の壁紙に戻す |
| 全モニタに同じ動画… | 一括設定 |
| 再読み込み | 設定ファイルを読み直す |
| 🔧 ロック壁紙を修復 | lockvideo（下記）の強制修復を手動実行 |

設定は `~/.config/monitorwall/config.json` に保存される。ロック／スリープ時は自動で一時停止し、解除時に同期して再生を再開する。

---

## lockvideo — ロック画面への動画注入

`~/Library/Application Support/com.apple.wallpaper/` 配下の `Index.plist` / `entries.json` を書き換え、macOSの aerial（動く壁紙）システムに自作動画を割り当てる。あわせて、macOS側の実装都合による黒画面（後述）を検出・自動修復する仕組みを含む。

### セットアップ

1. 動画をHEVC `.mov` に変換する（aerialの想定フォーマットに合わせる）:
   ```bash
   ffmpeg -i input.mp4 -an -c:v hevc_videotoolbox -q:v 55 -tag:v hvc1 -pix_fmt yuv420p output.mov
   ```
2. `lockvideo/apply.py` の `PAIRS_RAW` を編集し、ディスプレイUUID（`system_profiler SPDisplaysDataType` 等で確認）と動画ファイルのパスを対応させる。
3. 一度 System設定 → 壁紙 で任意のaerialを選択し、`Index.plist` にaerial選択の型を作っておく（初回のみ必要）。
4. 適用する:
   ```bash
   python3 apply.py
   killall WallpaperAgent
   ```
5. 永続化・自動修復のため LaunchAgent を登録する（任意。`WatchPaths` で `Index.plist`/`entries.json`/動画フォルダを監視し、macOS側のリセットを検知して自動で再適用する）:
   ```xml
   <!-- ~/Library/LaunchAgents/com.example.lockvideo.plist -->
   <key>ProgramArguments</key>
   <array><string>/bin/bash</string><string>/path/to/lockvideo/reapply.sh</string></array>
   <key>WatchPaths</key>
   <array>
     <string>~/Library/Application Support/com.apple.wallpaper/aerials/videos</string>
     <string>~/Library/Application Support/com.apple.wallpaper/Store/Index.plist</string>
     <string>~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json</string>
   </array>
   ```
   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.lockvideo.plist
   ```

### スクリプト一覧

| ファイル | 役割 |
|---|---|
| `apply.py` | Index.plistへモニタ別assetIDを注入。entries.jsonの再ダウンロードURL・pointsOfInterestを無効化（reset防止）。意味的冪等（再実行しても不要な変更をしない） |
| `repair.sh` | 黒画面検出時の強制修復。mkdirロック＋30秒デバウンスで多重実行・暴走を防止 |
| `reapply.sh` | LaunchAgent(`WatchPaths`)からの自動再適用。`repair.sh`と同じロック/デバウンスを共有し、自己増殖ループを防止 |
| `refresh.sh` | ロック解除の直後に先回りでWallpaperAgentを再起動（3秒クールダウンのみ）。次のロックを常に「健全な初回」として迎えるための対策 |
| `watchdog.sh` | ロック中のCPU使用率から黒画面を検出（aerials拡張は健全時~6%、スタール時~0.3%） |
| `restore.sh` | 元の状態（純正aerial）へ完全復元。`--yes`を付けて実行 |
| `sleepmonitor.swift` | ロック/スリープ関連の全通知とaerials拡張のCPU推移を記録する診断ツール |
| `displays.swift` | 接続中ディスプレイのUUID・解像度を一覧表示 |
| `Index.baseline.plist` / `Index.preB.plist` | 復元用のバックアップスナップショット |

### なぜ黒画面が起きるか（既知の挙動）

Apple純正の `WallpaperAerialsExtension` は、同一プロセス内で**2回目以降のロック**時にデコーダが正しく再初期化されず、CPU使用率が0%近くに張り付いて描画が止まることがある（クローズドソースの実装都合）。`refresh.sh` はロック解除の度にプロセスを再起動することでこれを回避し、`watchdog.sh` はそれでも発生した場合の安全網として動作する。

### 既知の制約

- macOSのバージョンアップで `com.apple.wallpaper` の内部スキーマが変わると壊れる可能性がある。
- 動画ファイル本体（`*.mov`）はこのリポジトリに含まれない（サイズが大きく、著作権のある素材の可能性があるため）。`.gitignore`で除外している。
- コールドブート直後のログイン画面（System Volume限定）には対応不可。対象は「ログイン後のロック」のみ。
- 4K動画の常時デコードはノートPCのバッテリーに不利。

---

## ライセンス

未設定（All rights reserved）。個人利用目的のツール。
