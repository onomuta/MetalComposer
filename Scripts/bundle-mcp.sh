#!/bin/zsh
# Builds Mirage MCP, the settings and activity app for mirage-mcp, with mirage-mcp inside it
# (docs/decisions/0002-mcp-companion-app.md). AI clients start Contents/MacOS/mirage-mcp.
#   ./Scripts/bundle-mcp.sh [debug|release]
# Environment: VERSION, UNIVERSAL=1, SIGN_IDENTITY — as for bundle.sh.
set -e
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
VERSION=${VERSION:-0.1.0-dev}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

if [[ "$UNIVERSAL" == "1" ]]; then
  swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product MirageMCPApp
  swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product mirage-mcp
  PRODUCTS=".build/apple/Products/${(C)CONFIG}"
else
  swift build -c "$CONFIG" --product MirageMCPApp
  swift build -c "$CONFIG" --product mirage-mcp
  PRODUCTS=".build/$CONFIG"
fi

APP="build/Mirage MCP.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$PRODUCTS/MirageMCPApp" "$APP/Contents/MacOS/MirageMCP"
cp "$PRODUCTS/mirage-mcp" "$APP/Contents/MacOS/mirage-mcp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mirage MCP</string>
  <key>CFBundleDisplayName</key><string>Mirage MCP</string>
  <key>CFBundleIdentifier</key><string>dev.metalcomposer.mcp</string>
  <key>CFBundleExecutable</key><string>MirageMCP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict>
</plist>
PLIST
if [[ -n "$SIGN_IDENTITY" ]]; then
  # The server inside first, then the app (no entitlements: no microphone, no sandbox).
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/mirage-mcp"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
else
  codesign --force --sign - "$APP/Contents/MacOS/mirage-mcp" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/MirageMCP"))"
