#!/bin/bash
# Build sender (arm64, this Mac) and receiver (x86_64 macOS 11 app bundle for the iMac; arm64 copy for loopback tests).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
if [ ! -f icon/icon_1024.png ] || [ icon/make_icon.swift -nt icon/icon_1024.png ]; then   # png is gitignored; regenerate
  swiftc -O -target arm64-apple-macos14 icon/make_icon.swift -o build/make_icon && build/make_icon icon/icon_1024.png
fi
if [ ! -f build/AppIcon.icns ] || [ icon/icon_1024.png -nt build/AppIcon.icns ]; then
  IS=$(mktemp -d /tmp/bcdicon.XXXX)/AppIcon.iconset; mkdir -p "$IS"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz icon/icon_1024.png --out "$IS/icon_${sz}x${sz}.png" >/dev/null
    d=$((sz*2)); sips -z $d $d icon/icon_1024.png --out "$IS/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$IS" -o build/AppIcon.icns
fi
swiftc -O -target arm64-apple-macos14 -import-objc-header Sender/Bridging.h Shared/Protocol.swift Sender/*.swift -o build/bcd-sender
cp Sender/BCKernels.metal build/BCKernels.metal
SAPP=build/BCDSender.app
mkdir -p "$SAPP/Contents/MacOS" "$SAPP/Contents/Resources"
cp build/bcd-sender "$SAPP/Contents/MacOS/bcd-sender"
cp Sender/BCKernels.metal "$SAPP/Contents/Resources/BCKernels.metal"
cp build/AppIcon.icns "$SAPP/Contents/Resources/AppIcon.icns"
cat > "$SAPP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>dev.bcdisplay.sender</string>
<key>CFBundleName</key><string>BCDSender</string>
<key>CFBundleDisplayName</key><string>iMac 屏幕串流 (BCDSender)</string>
<key>CFBundleExecutable</key><string>bcd-sender</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSLocalNetworkUsageDescription</key><string>Finds the iMac on the direct cable and streams the screen to it.</string>
<key>NSBonjourServices</key><array><string>_bcdisplay._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$SAPP"
swiftc -O -target arm64-apple-macos14 Shared/Protocol.swift Receiver/main.swift -o build/bcd-receiver-arm64
APP=build/BCDReceiver.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -target x86_64-apple-macos11 Shared/Protocol.swift Receiver/main.swift -o "$APP/Contents/MacOS/bcd-receiver"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>dev.bcdisplay.receiver</string>
<key>CFBundleName</key><string>BCDReceiver</string>
<key>CFBundleExecutable</key><string>bcd-receiver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Receives the Mac Studio screen over the direct cable.</string>
<key>NSBonjourServices</key><array><string>_bcdisplay._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo BUILD_OK
