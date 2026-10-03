#!/bin/zsh
# Builds Metal Composer and wraps it in a double-clickable .app bundle.
set -e
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG"
APP="build/Metal Composer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/MetalComposer" "$APP/Contents/MacOS/MetalComposer"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Metal Composer</string>
  <key>CFBundleIdentifier</key><string>dev.metalcomposer.app</string>
  <key>CFBundleExecutable</key><string>MetalComposer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
