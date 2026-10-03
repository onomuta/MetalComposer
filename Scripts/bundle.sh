#!/bin/zsh
# Builds Metal Composer and wraps it in a double-clickable .app bundle.
#   ./Scripts/bundle.sh [debug|release]
# Environment:
#   VERSION=0.1.0   version shown in Finder / About (default: 0.1.0-dev)
#   UNIVERSAL=1     build for both Apple silicon and Intel (release distribution)
#   SIGN_IDENTITY="Developer ID Application: …"
#                   sign for distribution (hardened runtime + secure timestamp);
#                   without it the app is signed ad hoc for local use
set -e
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
VERSION=${VERSION:-0.1.0-dev}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

if [[ "$UNIVERSAL" == "1" ]]; then
  swift build -c "$CONFIG" --arch arm64 --arch x86_64
  BINARY=".build/apple/Products/${(C)CONFIG}/MetalComposer"
else
  swift build -c "$CONFIG"
  BINARY=".build/$CONFIG/MetalComposer"
fi

APP="build/Metal Composer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BINARY" "$APP/Contents/MacOS/MetalComposer"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Metal Composer</string>
  <key>CFBundleDisplayName</key><string>Metal Composer</string>
  <key>CFBundleIdentifier</key><string>dev.metalcomposer.app</string>
  <key>CFBundleExecutable</key><string>MetalComposer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Audio Input and Audio Spectrum patches react to sound from the microphone or audio input.</string>
</dict>
</plist>
PLIST
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements Scripts/MetalComposer.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/MetalComposer"))"
