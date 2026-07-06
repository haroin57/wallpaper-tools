import Cocoa
for s in NSScreen.screens {
    let did = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
    let uuid = cf.map { CFUUIDCreateString(nil, $0)! as String } ?? "?"
    let main = (did == CGMainDisplayID()) ? " [MAIN]" : ""
    print("\(uuid)\t\(Int(s.frame.width))x\(Int(s.frame.height))\t\(s.localizedName)\(main)")
}
