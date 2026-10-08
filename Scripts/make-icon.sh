#!/bin/zsh
# Regenerates the app icons (Scripts/make-icon.swift) and the .mcomp document icons
# (Scripts/make-document-icon.swift) for macOS and iOS.
set -e
cd "$(dirname "$0")/.."
swift Scripts/make-icon.swift Assets/AppIcon-1024.png
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Assets/AppIcon.icns"
# iOS: the same artwork as a full, opaque square.
swift Scripts/make-icon.swift iOS/Player/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png --ios

# Composition files (.mcomp): Assets/DocumentIcon.icns for the Mac builds, PNGs for iOS.
swift Scripts/make-document-icon.swift Assets/DocumentIcon-1024.png
ICONSET=$(mktemp -d)/DocumentIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/DocumentIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/DocumentIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Assets/DocumentIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Assets/DocumentIcon.icns"
for s in 64 320; do
  sips -z $s $s Assets/DocumentIcon-1024.png --out "iOS/Player/DocumentIcon-$s.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/DocumentIcon-1024.png --out "iOS/Player/DocumentIcon-$s@2x.png" >/dev/null
  sips -z $((s*3)) $((s*3)) Assets/DocumentIcon-1024.png --out "iOS/Player/DocumentIcon-$s@3x.png" >/dev/null
done
echo "Wrote iOS/Player/DocumentIcon-*.png"
