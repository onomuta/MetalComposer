#!/bin/zsh
# Notarizes and staples a Developer ID–signed build/Mirage Composer.app, then zips it.
# (The keychain profile keeps its original name, MetalComposer.)
#   ./Scripts/notarize.sh 0.1.0
# One-time setup (stores your Apple ID app-specific password in the keychain):
#   xcrun notarytool store-credentials MetalComposer --apple-id <you@example.com> --team-id BWZ7Q5QLJ5
set -e
cd "$(dirname "$0")/.."
VERSION=${1:?usage: notarize.sh <version>}
PROFILE=${NOTARY_PROFILE:-MetalComposer}
APP="build/Mirage Composer.app"
ZIP="build/MirageComposer-$VERSION-macOS.zip"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -v "$APP"
# Re-zip so the download carries the stapled ticket (works offline on first launch).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarized: $ZIP"
