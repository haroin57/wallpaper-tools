# wallpaper-tools

macOS のデスクトップ壁紙とロック画面を、モニタごとに個別のローカル動画へ差し替えるための実験的ツール一式。

Apple純正の壁紙エンジン（[Plash](https://github.com/sindresorhus/Plash) 等の後継的な発想）はソースコードが非公開で、かつマルチモニタの個別割当に対応していない。
本リポジトリは目的特化で以下の2つを実装した:

| ツール | 対象 | 実現方法 |
|---|---|---|
| **monitorwall** | デスクトップ壁紙 | 独自の常駐アプリ（AppKit + AVFoundation） |
| **lockvideo** | ロック画面 | macOS純正の aerial（動く壁紙）システムへの動画注入 |

両者は完全に独立していて、片方だけ使うこともできる。

## クイックスタート（インストーラー）

フルシステム（アプリ＋ロック画面＋自動修復＋launchd登録＋バックアップ）を一括で入れる:

```bash
# 事前に「システム設定 > 壁紙」で Aerial/ダイナミック壁紙を一度だけ選んでおく（注入先スロットの生成に必要）
git clone https://github.com/haroin57/wallpaper-tools.git
cd wallpaper-tools
bash install.sh
```

インストーラーがやること:

- `MonitorWall.app` をビルドして `/Applications` へ配置（ad-hoc署名）
- lockvideo スクリプト群を `~/.local/share/monitorwall/` へ配置
- launchd エージェント2つ（アプリ常駐 / 壁紙リセットの自動復旧）を登録
- 現在の壁紙設定を `~/.local/share/monitorwall/backup/` へ退避（アンインストール時に復元）

割り当ては**すべてメニューバーの MonitorWall から動的に**行う（接続中モニタを実 displayUUID で自動検出。設定ファイルの手編集は不要）。

アンインストール（壁紙も元に戻す）:

```bash
bash ~/.local/share/monitorwall/uninstall.sh --yes          # 設定は残す
bash ~/.local/share/monitorwall/uninstall.sh --yes --purge  # 設定も全削除
```

以下は各ツールを個別に理解・手動運用するための詳細。

## 要件

- **monitorwall（デスクトップ壁紙）**: macOS 12 以降
- **lockvideo（ロック画面）**: **macOS 14 Sonoma 以降が必須**。動画ロック画面の基盤である `com.apple.wallpaper` の aerial 壁紙ストアは Sonoma で導入されたもので、Ventura 13 以前には注入先そのものが存在しない。さらに事前に一度「システム設定 > 壁紙」で Aerial/ダイナミック壁紙を選択し、注入先スロットを生成しておくこと
- 開発・検証は macOS 26 Tahoe / Apple Silicon
- Xcode Command Line Tools（`swiftc` / `codesign` が使えること）
- Python 3（macOS標準で同梱）
- `ffmpeg`（動画をHEVC `.mov` へ変換する。`brew install ffmpeg`）

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
| ログイン時に起動 | チェックで macOS のログイン項目に登録／解除（`SMAppService`。macOS 13+） |

設定は `~/.config/monitorwall/config.json` に保存される。ロック／スリープ時は自動で一時停止し、解除時に同期して再生を再開する。

---

## lockvideo — ロック画面への動画注入

`~/Library/Application Support/com.apple.wallpaper/` 配下の `Index.plist` / `entries.json` を書き換え、macOSの aerial（動く壁紙）システムに自作動画を割り当てる。あわせて、macOS側の実装都合による黒画面（後述）を検出・自動修復する仕組みを含む。

### セットアップ

通常は上記の `install.sh` が全部やる。手動で理解したい場合の流れ:

1. 一度 System設定 → 壁紙 で任意のaerialを選択し、`Index.plist` にaerial選択の型と注入先スロットを作っておく（初回のみ）。
2. メニューバーの MonitorWall で、各 Display の「── ロック画面 ──> 動画を選択…」から動画を選ぶ。MonitorWall が動画を HEVC `.mov` に変換し、割り当てを **`~/.config/monitorwall/lock_assignments.json`（`{displayUUID: 動画パス}`）** に書く。
3. `apply.py` がそれを読み、接続中ディスプレイを CoreGraphics で動的検出して、aerialマニフェストの空きスロットを自動採取し `Index.plist` へ注入する:
   ```bash
   python3 apply.py        # 割り当てを反映（冪等。変更が無ければ exit 42）
   killall WallpaperAgent  # 反映（repair.sh --force が killall まで面倒を見る）
   ```

`apply.py` はマシン非依存で、固定のディスプレイUUIDや動画パスを一切ハードコードしない。割り当ては `lock_assignments.json` のみが供給し、双子スロットはマニフェストから動的採取して `lock_slots.json` に固定する。

> **要点（macOSの権威データとスキーマ差）**: `Index.plist` には2つのスキーマが実環境で併存し、`apply.py` は実物を見て両対応で分岐する（OSバージョンでは決まらない）。
> - **Linked（旧）**: 各スコープが `Linked` 一枚。権威は `Spaces[*].Displays[uuid]`、単一画面時は `SystemDefault`。`AllSpacesAndDisplays` は `"$null"`。
> - **Desktop/Idle（新・macOS 26 Tahoe）**: 各スコープが `Desktop`(壁紙)/`Idle`(ロック画面) の2シーン。権威は `AllSpacesAndDisplays`(Type=individual)。ここを潰すと割当が消えるので `"$null"` にしてはいけない。既定で `Desktop` と `Idle` の両方へ注入する（ロック画面だけにしたい場合は `SCENE_KEYS = ("Idle",)`）。
>
> どちらも WallpaperAgent 再起動で巻き戻らないよう、権威データまで書き込む。

### スクリプト一覧

| ファイル | 役割 |
|---|---|
| `apply.py` | Index.plistへモニタ別assetIDを注入。entries.jsonの再ダウンロードURL・pointsOfInterestを無効化（reset防止）。意味的冪等（再実行しても不要な変更をしない） |
| `repair.sh` | 黒画面検出時の強制修復。mkdirロック＋30秒デバウンスで多重実行・暴走を防止 |
| `reapply.sh` | LaunchAgent(`WatchPaths`)からの自動再適用。`repair.sh`と同じロック/デバウンスを共有し、自己増殖ループを防止 |
| `refresh.sh` | ロック解除の直後に先回りでWallpaperAgentを再起動（3秒クールダウンのみ）。次のロックを常に「健全な初回」として迎えるための対策 |
| `watchdog.sh` | ロック中のCPU使用率から黒画面を検出（aerials拡張は健全時~6%、スタール時~0.3%） |
| `diagnose.sh` | ロック画面が反映されない時の切り分け。Aerial前提・割当・変換ログ・apply結果・Spaces適用状態を一括ダンプし原因の目安を提示 |
| `uninstall.sh` | フルシステムのアンインストール＋壁紙復元（`install.sh` が退避したバックアップから）。`--yes`／`--purge` |
| `restore.sh` | （旧・手動運用向け）元の状態へ復元する簡易版。配布版では `uninstall.sh` を使う |
| `sleepmonitor.swift` | ロック/スリープ関連の全通知とaerials拡張のCPU推移を記録する診断ツール |
| `displays.swift` | 接続中ディスプレイのUUID・解像度を一覧表示 |
| `Index.baseline.plist` / `Index.preB.plist` | 復元用のバックアップスナップショット |

### なぜ黒画面が起きるか（既知の挙動）

Apple純正の `WallpaperAerialsExtension` は、同一プロセス内で**2回目以降のロック**時にデコーダが正しく再初期化されず、CPU使用率が0%近くに張り付いて描画が止まることがある（クローズドソースの実装都合）。`refresh.sh` はロック解除の度にプロセスを再起動することでこれを回避し、`watchdog.sh` はそれでも発生した場合の安全網として動作する。

### 既知の制約

- macOSのバージョンアップで `com.apple.wallpaper` の内部スキーマ（特に `Spaces`）が変わると壊れる可能性がある。
- アプリは **ad-hoc署名**のため、初回起動時に Gatekeeper の警告が出る場合がある（システム設定 > プライバシーとセキュリティ から許可）。公式のDeveloper ID署名・notarizeは行っていない。
- 動画ファイル本体（`*.mov`）はこのリポジトリに含まれない（サイズが大きく、著作権のある素材の可能性があるため）。`.gitignore`で除外している。
- コールドブート直後のログイン画面（System Volume限定）には対応不可。対象は「ログイン後のロック」のみ。
- 4K動画の常時デコードはノートPCのバッテリーに不利。

---

## ライセンス

未設定（All rights reserved）。個人利用目的のツール。
