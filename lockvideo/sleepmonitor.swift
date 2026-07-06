import Cocoa

// スリープ/ウェイク/ロック/解除の全通知とaerials拡張の生死・CPUを記録する診断ツール。
// 使い方: 実行したまま、スリープ/ウェイクを何度か繰り返してもらい、ログで相関を見る。

let logPath = "/tmp/sleepmonitor.log"
func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let ext = aerialsExtPID()
    let cpu = ext.map { cpuOf(pid: $0) } ?? -1
    let line = "\(ts)  \(msg)  |  aerialsExtPID=\(ext.map(String.init) ?? "NONE") cpu=\(String(format: "%.1f", cpu))%\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
    print(line, terminator: "")
}

func aerialsExtPID() -> Int32? {
    let p = Process()
    p.launchPath = "/usr/bin/pgrep"
    p.arguments = ["-f", "WallpaperAerialsExtension"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").first.flatMap { Int32($0) }
}

func cpuOf(pid: Int32) -> Double {
    let p = Process()
    p.launchPath = "/bin/ps"
    p.arguments = ["-o", "%cpu=", "-p", "\(pid)"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
}

log("=== sleepmonitor 起動 ===")

let dnc = DistributedNotificationCenter.default()
dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in log("EVENT screenIsLocked") }
dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in log("EVENT screenIsUnlocked") }

let ws = NSWorkspace.shared.notificationCenter
ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in log("EVENT screensDidSleep") }
ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in log("EVENT screensDidWake") }
ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in log("EVENT willSleep(system)") }
ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in log("EVENT didWake(system)") }

// 定期サンプリング（通知が来なくても状態変化を追跡）
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in log("tick") }

RunLoop.main.run()
