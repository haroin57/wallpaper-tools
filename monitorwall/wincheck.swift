import Cocoa
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var n = 0
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if owner == "MonitorWall" {
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let wd = b["Width"] as? Double ?? 0, ht = b["Height"] as? Double ?? 0
        print("window: layer=\(layer) size=\(Int(wd))x\(Int(ht))")
        n += 1
    }
}
print("MonitorWall windows = \(n)")
print("NSScreen count = \(NSScreen.screens.count)")
