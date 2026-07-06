import Cocoa
guard let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var total = 0, visible = 0
for w in all {
    guard (w[kCGWindowOwnerName as String] as? String) == "MonitorWall" else { continue }
    total += 1
    let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let wd = Int(b["Width"] as? Double ?? 0), ht = Int(b["Height"] as? Double ?? 0)
    print("window \(wd)x\(ht)  alpha=\(alpha)")
    if alpha > 0.01 { visible += 1 }
}
print("MonitorWall: total=\(total) visible(alpha>0)=\(visible)")
