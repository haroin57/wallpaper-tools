import Cocoa
import AVFoundation

// MARK: - 設定の永続化 (~/.config/monitorwall/config.json)

struct Config: Codable {
    var assignments: [String: String] = [:]   // displayID(文字列) -> 動画パス
    var defaultVideo: String? = nil
}

let configDir  = NSHomeDirectory() + "/.config/monitorwall"
let configPath = configDir + "/config.json"

func loadConfig() -> Config {
    guard let data = FileManager.default.contents(atPath: configPath),
          let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
        return Config()
    }
    return cfg
}

func saveConfig(_ cfg: Config) {
    try? FileManager.default.createDirectory(atPath: configDir,
                                             withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(cfg) {
        try? data.write(to: URL(fileURLWithPath: configPath))
    }
}

// MARK: - ロック画面の割当 (~/.config/monitorwall/lock_assignments.json)
// apply.py が読むフラットな {displayUUID: HEVC .mov パス} 形式。キー削除=既定に戻す。

let lockConfigPath = configDir + "/lock_assignments.json"
let lockVideoDir   = configDir + "/lockvideos"   // 変換後の HEVC .mov 置き場

func loadLockAssignments() -> [String: String] {
    guard let data = FileManager.default.contents(atPath: lockConfigPath),
          let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return dict
}

func saveLockAssignments(_ dict: [String: String]) {
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(dict) {
        try? data.write(to: URL(fileURLWithPath: lockConfigPath))
    }
}

// MARK: - 1モニタ分の壁紙ウィンドウ

final class ScreenWallpaper {
    let displayID: CGDirectDisplayID
    let window: NSWindow
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var duration: Double = 0        // 動画尺（時刻ベース同期用）

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID

        window = NSWindow(contentRect: screen.frame,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false)
        window.isReleasedWhenClosed = false
        // デスクトップアイコンの1つ下＝壁紙レイヤ
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.setFrame(screen.frame, display: true)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        playerLayer.frame = view.bounds
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)
        window.contentView = view
        window.alphaValue = 0            // 透明で常時オンスクリーン（動画セットで不透明化。クリア時は背後の純正壁紙が見える）
        window.orderFront(nil)
    }

    func setVideo(path: String) {
        let url = URL(fileURLWithPath: path)
        let item = AVPlayerItem(url: url)
        duration = CMTimeGetSeconds(AVURLAsset(url: url).duration)   // 尺を取得
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer.player = queue
        queue.play()
        player = queue
        window.alphaValue = 1            // 表示（不透明）
    }

    func clear() {
        player?.pause()
        looper = nil
        player = nil
        playerLayer.player = nil
        window.alphaValue = 0            // 透明化→背後のmacOS純正壁紙が見える
    }

    func pausePlayback() { player?.pause() }   // ロック/スリープ中の省デコード
    // ロック中の経過秒数からロック前の位置を算出してシーク（aerialは頭から再生する前提で続きへ合わせる）
    func syncPosition(elapsed: Double) {
        guard duration > 0, let p = player else { player?.play(); return }
        let off = elapsed.truncatingRemainder(dividingBy: duration)
        p.seek(to: CMTime(seconds: off, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { _ in p.play() }
    }

    func teardown() {
        clear()
        window.orderOut(nil)
        window.close()
    }
}

// MARK: - アプリ本体（メニューバー常駐）

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var wallpapers: [ScreenWallpaper] = []
    private var statusItem: NSStatusItem!
    private var config = loadConfig()
    private var lockAssignments = loadLockAssignments()
    // displayUUID -> 実行中の変換プロセス。保持しないと関数を抜けた時点でARCが解放して
    // terminationHandler が発火しない（ffmpegは走り続けるが完了処理が失われる）。
    // 加えて、同一ディスプレイの変換中は新規選択をブロックするための状態にも使う。
    private var activeConversions: [String: Process] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎬"
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // ロック/スリープ中はデスクトップ動画を一時停止し、ロック画面aerialにデコード資源を譲る
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screenPaused), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screenResumed), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func screensChanged() { rebuild() }
    private var isLocked = false
    private var lockSession = 0
    private var lockedAt: Date?
    // 画面ロック: 一時停止＋「安定して2秒以上ロックされ続けた時だけ」黒画面チェック（高速反復ではlockSession不一致で発火しない）
    @objc private func screenLocked() {
        isLocked = true
        lockedAt = Date()
        lockSession += 1
        let session = lockSession
        wallpapers.forEach { $0.pausePlayback() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.isLocked, session == self.lockSession else { return }
            self.runScript("watchdog.sh")
        }
    }
    @objc private func screenUnlocked() {
        isLocked = false
        lockSession += 1          // 保留中のウォッチドッグを失効させる（高速反復対策）
        let elapsed = Date().timeIntervalSince(lockedAt ?? Date())   // aerialは頭から再生する前提で続きへ合わせる
        wallpapers.forEach { $0.syncPosition(elapsed: elapsed) }
        // 実証済み: Index.plistの assetID を変えるだけでは稼働中のWallpaperAgentに反映されず、
        // 2回目のロックで確実にスタールする(プロセス再起動が必須と判明)。よってkillallに戻す。
        runScript("refresh.sh")
    }
    // ディスプレイスリープ/ウェイクは一時停止/再同期のみ（表示オフでCPU低→誤検出になるのでチェックしない）
    @objc private func screenPaused()  { lockedAt = lockedAt ?? Date(); wallpapers.forEach { $0.pausePlayback() } }
    @objc private func screenResumed() {
        let elapsed = Date().timeIntervalSince(lockedAt ?? Date())
        wallpapers.forEach { $0.syncPosition(elapsed: elapsed) }
    }
    private func runScript(_ name: String, _ extra: [String] = []) {
        // lockvideo スクリプト群の配置先。インストーラが MONITORWALL_HOME を launchd plist に
        // 設定していればそれを、無ければ標準の ~/.local/share/monitorwall を使う（配布可能化）。
        let base = ProcessInfo.processInfo.environment["MONITORWALL_HOME"]
            ?? (NSHomeDirectory() + "/.local/share/monitorwall")
        let p = Process()
        p.launchPath = "/bin/bash"
        p.arguments = [base + "/" + name] + extra
        try? p.run()
    }
    @objc private func repairLock() { runScript("repair.sh", ["--force"]) }   // 手動はデバウンス無視

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // apply.py と同じ displayUUID（CGDisplayCreateUUIDFromDisplayID）でロック割当を突き合わせる
    private func displayUUID(of screen: NSScreen) -> String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID(of: screen))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    // ロック動画フローの診断ログ (~/.config/monitorwall/lock.log)
    private func logLock(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        let path = configDir + "/lock.log"
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            if let d = line.data(using: .utf8) { fh.write(d) }
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    private func notify(_ title: String, _ body: String) {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        let safe = body.replacingOccurrences(of: "\"", with: "'")
        p.arguments = ["-e", "display notification \"\(safe)\" with title \"MonitorWall\" subtitle \"\(title)\""]
        try? p.run()
    }

    private func rebuild() {
        wallpapers.forEach { $0.teardown() }
        wallpapers.removeAll()
        for screen in NSScreen.screens {
            let did = displayID(of: screen)
            let wp = ScreenWallpaper(screen: screen, displayID: did)
            let assigned = config.assignments[String(did)]
            let path = (assigned == "") ? nil : (assigned ?? config.defaultVideo)  // ""=明示クリア（純正壁紙）
            if let p = path, FileManager.default.fileExists(atPath: p) {
                wp.setVideo(path: p)
            }
            wallpapers.append(wp)
        }
        buildMenu()
    }

    // 永続メニュー。delegate 経由で「開くたびに」populateMenu で組み直すので、
    // 変換中フラグ等の現在状態が常に反映される（静的代入だと更新が遅れて
    // 変換中でも「動画を選択…」が押せてしまう問題を根絶）。
    private lazy var statusMenu: NSMenu = {
        let m = NSMenu()
        m.delegate = self
        return m
    }()

    // NSMenuDelegate: メニューが開く直前に毎回呼ばれる
    func menuNeedsUpdate(_ menu: NSMenu) { populateMenu(menu) }

    private func buildMenu() {
        if statusItem.menu !== statusMenu { statusItem.menu = statusMenu }
        populateMenu(statusMenu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "MonitorWall — モニタ別 動画壁紙", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        for (i, screen) in NSScreen.screens.enumerated() {
            let did = displayID(of: screen)
            let title = "Display \(i + 1): \(screen.localizedName)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()

            let setItem = NSMenuItem(title: "動画を選択…", action: #selector(setVideoForDisplay(_:)), keyEquivalent: "")
            setItem.representedObject = NSNumber(value: did); setItem.target = self
            sub.addItem(setItem)

            let clearItem = NSMenuItem(title: "クリア", action: #selector(clearDisplay(_:)), keyEquivalent: "")
            clearItem.representedObject = NSNumber(value: did); clearItem.target = self
            sub.addItem(clearItem)

            if let cur = config.assignments[String(did)] {
                sub.addItem(.separator())
                let label = cur.isEmpty ? "現在: クリア（純正壁紙）" : "現在: " + (cur as NSString).lastPathComponent
                sub.addItem(withTitle: label, action: nil, keyEquivalent: "")
            }

            // ── ロック画面 ── （デスクトップとは別枠。displayUUIDでapply.pyと突き合わせ）
            if let uuid = displayUUID(of: screen) {
                sub.addItem(.separator())
                sub.addItem(withTitle: "── ロック画面 ──", action: nil, keyEquivalent: "")
                if activeConversions[uuid] != nil {
                    // 変換中は新規選択をブロック（同一ファイルへの同時書き込み＝破損を防ぐ）
                    let busy = NSMenuItem(title: "⏳ 変換中…（完了までお待ちください）", action: nil, keyEquivalent: "")
                    busy.isEnabled = false
                    sub.addItem(busy)
                } else {
                    let lockSet = NSMenuItem(title: "動画を選択…", action: #selector(setLockVideoForDisplay(_:)), keyEquivalent: "")
                    lockSet.representedObject = uuid; lockSet.target = self
                    sub.addItem(lockSet)
                    let lockReset = NSMenuItem(title: "既定に戻す", action: #selector(resetLockVideoForDisplay(_:)), keyEquivalent: "")
                    lockReset.representedObject = uuid; lockReset.target = self
                    sub.addItem(lockReset)
                }
                if let lv = lockAssignments[uuid], !lv.isEmpty {
                    sub.addItem(withTitle: "現在: " + (lv as NSString).lastPathComponent, action: nil, keyEquivalent: "")
                }
            }

            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let allItem = NSMenuItem(title: "全モニタに同じ動画…", action: #selector(setVideoForAll), keyEquivalent: "")
        allItem.target = self
        menu.addItem(allItem)
        let reloadItem = NSMenuItem(title: "再読み込み", action: #selector(reload), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)
        let repairItem = NSMenuItem(title: "🔧 ロック壁紙を修復", action: #selector(repairLock), keyEquivalent: "")
        repairItem.target = self
        menu.addItem(repairItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func pickVideo() -> String? {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["mp4", "mov", "m4v", "avi", "webm", "mkv"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Movies")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @objc private func setVideoForDisplay(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber, let path = pickVideo() else { return }
        let did = num.uint32Value
        config.assignments[String(did)] = path
        saveConfig(config)
        wallpapers.first { $0.displayID == did }?.setVideo(path: path)
        buildMenu()
    }

    @objc private func clearDisplay(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        let did = num.uint32Value
        config.assignments[String(did)] = ""   // 明示クリア（defaultVideoにも戻さず純正壁紙を表示）
        saveConfig(config)
        wallpapers.first { $0.displayID == did }?.clear()
        buildMenu()
    }

    @objc private func setVideoForAll() {
        guard let path = pickVideo() else { return }
        config.defaultVideo = path
        for screen in NSScreen.screens {
            config.assignments[String(displayID(of: screen))] = path
        }
        saveConfig(config)
        rebuild()
    }

    // MARK: ロック画面 動画の差し替え

    @objc private func setLockVideoForDisplay(_ sender: NSMenuItem) {
        let uuid = sender.representedObject as? String
        logLock("setLock clicked: uuid=\(uuid ?? "nil")")
        guard let uuid = uuid else { return }
        guard let src = pickVideo() else { logLock("  picker cancelled"); return }
        logLock("  picked: \(src)")
        convertAndApplyLock(uuid: uuid, source: src)
    }

    // 選択動画を HEVC .mov に変換（aerialの想定フォーマット）→ 設定に登録 → repair.sh --force で反映。
    // ffmpeg は重いので非同期。同一ディスプレイの変換が進行中なら新規開始をブロック
    // （同じ出力ファイルへの同時書き込み＝破損を防ぐ）。一時ファイルへ書いて成功時のみ
    // 本来のパスへアトミックに差し替える。
    private func convertAndApplyLock(uuid: String, source: String) {
        if activeConversions[uuid] != nil {
            logLock("  guard: already converting \(uuid)")
            notify("変換中です", "完了までお待ちください")
            return
        }
        try? FileManager.default.createDirectory(atPath: lockVideoDir, withIntermediateDirectories: true)
        let out = lockVideoDir + "/" + uuid + ".mov"
        // 一時ファイルも .mov 拡張子にする（ffmpegは拡張子で出力フォーマットを決めるため。
        // 以前 .tmp にしていて "Unable to choose an output format" で即死していた）
        let tmp = lockVideoDir + "/" + uuid + ".tmp.mov"
        try? FileManager.default.removeItem(atPath: tmp)
        logLock("  ffmpeg start -> \(tmp)")
        notify("変換中…", (source as NSString).lastPathComponent)
        let ff = Process()
        ff.launchPath = "/opt/homebrew/bin/ffmpeg"
        // -nostdin: GUI/launchd 起動だと inherited stdin を ffmpeg が誤読して即終了しうる
        ff.arguments = ["-nostdin", "-y", "-i", source, "-an",
                        "-c:v", "hevc_videotoolbox", "-q:v", "55",
                        "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
                        "-f", "mov", tmp]   // 出力フォーマットを明示（拡張子非依存で確実）
        // 入出力を明示制御: stdin=/dev/null、stdout/stderr は ffmpeg.log へ捕獲
        // （launchd から継承した壊れた fd に ffmpeg が書けず失敗するのを防ぐ＋診断）
        ff.standardInput = FileHandle.nullDevice
        let ffLogPath = configDir + "/ffmpeg.log"
        FileManager.default.createFile(atPath: ffLogPath, contents: nil)
        if let lh = try? FileHandle(forWritingTo: URL(fileURLWithPath: ffLogPath)) {
            ff.standardOutput = lh
            ff.standardError = lh
        }
        // launchd 由来の XPC 変数を落とし、PATH に homebrew を通したクリーン環境
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "XPC_SERVICE_NAME")
        env.removeValue(forKey: "XPC_FLAGS")
        ff.environment = env
        ff.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activeConversions[uuid] = nil          // 保持解除＋ガード解除
                self.logLock("  ffmpeg exit=\(p.terminationStatus) tmpExists=\(FileManager.default.fileExists(atPath: tmp))")
                guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: tmp) else {
                    try? FileManager.default.removeItem(atPath: tmp)
                    self.notify("変換に失敗しました", "ffmpegを確認してください")
                    self.buildMenu()
                    return
                }
                try? FileManager.default.removeItem(atPath: out)
                try? FileManager.default.moveItem(atPath: tmp, toPath: out)   // アトミック差し替え
                self.lockAssignments[uuid] = out
                saveLockAssignments(self.lockAssignments)
                self.runScript("repair.sh", ["--force"])    // apply.py が新configを読んで反映
                self.logLock("  applied: config written + repair.sh --force")
                self.notify("ロック画面を更新しました", (source as NSString).lastPathComponent)
                self.buildMenu()
            }
        }
        do {
            try ff.run()
            activeConversions[uuid] = ff   // 完了ハンドラ発火まで保持＋変換中ガード
            buildMenu()                    // メニューを「⏳ 変換中…」に更新
        } catch { notify("変換を開始できません", "ffmpeg 未インストール?") }
    }

    // キー削除＝この画面のロック割当を外し、apply.py の既定(PAIRS_RAW)へ戻す
    @objc private func resetLockVideoForDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        lockAssignments.removeValue(forKey: uuid)
        saveLockAssignments(lockAssignments)
        runScript("repair.sh", ["--force"])
        buildMenu()
    }

    @objc private func reload() { config = loadConfig(); lockAssignments = loadLockAssignments(); rebuild() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - エントリポイント

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dockに出さないメニューバー常駐
app.run()
