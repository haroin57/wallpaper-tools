#!/bin/bash
# MonitorWall を .app バンドルとしてビルド
set -euo pipefail
cd "$(dirname "$0")"

APP="MonitorWall.app"
BIN="MonitorWall"
BUNDLE_ID="com.haroin.monitorwall"

echo "== コンパイル =="
xcrun swiftc -O -swift-version 5 \
  -framework Cocoa -framework AVFoundation \
  main.swift -o "$BIN"

echo "== .app バンドル生成 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$BIN</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>MonitorWall</string>
    <key>CFBundleDisplayName</key><string>MonitorWall</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "== ad-hoc 署名 =="
codesign --force --deep --sign - "$APP"

echo "== 完了 =="
echo "$(pwd)/$APP"
