#!/bin/bash
# Builds Headroom.app. Usage:
#   ./build.sh            build into ./build/Headroom.app
#   ./build.sh install    build, copy to ~/Applications, and launch
set -euo pipefail
cd "$(dirname "$0")"

# Prefer the Command Line Tools: they compile without accepting the full Xcode license.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools/usr/bin ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
if [[ -z "${SDK:-}" ]]; then
  SDK="$(xcrun --show-sdk-path)"
  # The Command Line Tools' macOS 27 SDK declares SwiftUI's @State as a macro whose plugin only
  # ships with Xcode, so use their macOS 26 SDK when it's there.
  if [[ "${DEVELOPER_DIR:-}" == *CommandLineTools* && -d "$DEVELOPER_DIR/SDKs/MacOSX26.sdk" ]]; then
    SDK="$DEVELOPER_DIR/SDKs/MacOSX26.sdk"
  fi
fi
APP=build/Headroom.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

# Universal binary: Apple silicon and Intel.
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos14.0" \
    -o "build/obj/Headroom-$arch" Sources/*.swift
done
lipo -create build/obj/Headroom-* -output "$APP/Contents/MacOS/Headroom"

"$APP/Contents/MacOS/Headroom" --make-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.headroom</string>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Shows what's using your Mac's memory.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Headroom 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Headroom.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Headroom.app"
  echo "Installed to ~/Applications/Headroom.app and launched"
fi
