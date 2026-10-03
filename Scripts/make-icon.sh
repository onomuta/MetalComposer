#!/bin/zsh
# Regenerates Assets/AppIcon-1024.png and Assets/AppIcon.icns from Scripts/make-icon.swift.
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
