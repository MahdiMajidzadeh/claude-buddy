#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Claude Usage.app"
ARCH=$(uname -m)

echo "Building for ${ARCH}-apple-macosx13.0 ..."
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
  -target "${ARCH}-apple-macosx13.0" \
  -parse-as-library \
  -framework SwiftUI -framework AppKit \
  -o "$APP/Contents/MacOS/ClaudeUsage" \
  Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleIdentifier</key><string>local.claude.usage.menubar</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy launching it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
