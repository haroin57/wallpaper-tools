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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wallpapers: [ScreenWallpaper] = []
    private var statusItem: NSStatusItem!
    private var config = loadConfig()

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
        let p = Process()
        p.launchPath = "/bin/bash"
        p.arguments = [NSHomeDirectory() + "/dev/lockvideo/" + name] + extra
        try? p.run()
    }
    @objc private func repairLock() { runScript("repair.sh", ["--force"]) }   // 手動はデバウンス無視

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
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

    private func buildMenu() {
        let menu = NSMenu()
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

        statusItem.menu = menu
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

    @objc private func reload() { config = loadConfig(); rebuild() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - エントリポイント

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dockに出さないメニューバー常駐
app.run()
