#!/bin/bash
# Build, sign, notarize, and staple MemorAI for distribution.
#
# Prereqs (one-time setup):
#   1. Keychain has "Developer ID Application: NEO, OOO (Z97S2HH3V5)" cert.
#   2. `xcrun notarytool store-credentials memorai-notary --apple-id m@thatsme.ru --team-id Z97S2HH3V5 --password <app-specific>` has been run.
#
# Usage: ./release-notarized.sh <version>   e.g. ./release-notarized.sh 1.3.1

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>    (e.g. 1.3.1)"
    exit 1
fi

APP="MemorAI.app"
ZIP="MemorAI.app.zip"
SIGN_IDENTITY="Developer ID Application: NEO, OOO (Z97S2HH3V5)"
KEYCHAIN_PROFILE="memorai-notary"
ENTITLEMENTS="/tmp/memorai-entitlements-notarize.plist"

cd "$(dirname "$0")"

echo "[1/7] Verifying signing identity…"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: NEO, OOO"; then
    echo "❌ Developer ID Application cert not found in keychain. Create one at developer.apple.com first."
    exit 1
fi

echo "[2/7] Writing entitlements…"
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.screen-capture</key>
    <true/>
</dict>
</plist>
EOF

echo "[3/7] Swift build (release)…"
swift build -c release > /dev/null

echo "[4/7] Assembling app bundle…"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MemorAI "$APP/Contents/MacOS/MemorAI"
cp Info.plist "$APP/Contents/"
[[ -f MemorAI.icns ]] && cp MemorAI.icns "$APP/Contents/Resources/" || true

echo "[5/7] Signing with Developer ID (hardened runtime + timestamp)…"
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "[6/7] Zipping and submitting to Apple notary service (waits for verdict)…"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "[7/7] Stapling ticket and re-zipping…"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "✅ Done. $ZIP is notarized, stapled, and ready to ship."
echo ""
echo "Sanity check:"
spctl --assess --type execute --verbose=4 "$APP" || true
echo ""
echo "Upload to GitHub release v$VERSION:"
echo "  gh release upload v$VERSION $ZIP --clobber"
