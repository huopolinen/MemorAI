#!/bin/bash
# Build a DMG installer for MemorAI with a styled background.
#
# Assumes MemorAI.app in the repo root is already signed with Developer ID
# and stapled (run ./release-notarized.sh first to produce that bundle).
#
# Usage: ./build-dmg.sh <version>   e.g. ./build-dmg.sh 1.3.2

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>    (e.g. 1.3.2)"
    exit 1
fi

cd "$(dirname "$0")"

APP="MemorAI.app"
VOLNAME="MemorAI"
DMG="MemorAI-$VERSION.dmg"
BG2X="resources/dmg-background@2x.png"
SIGN_IDENTITY="Developer ID Application: NEO, OOO (Z97S2HH3V5)"
KEYCHAIN_PROFILE="memorai-notary"

if [[ ! -d "$APP" ]]; then
    echo "❌ $APP not found. Run ./release-notarized.sh first."
    exit 1
fi

if ! command -v create-dmg >/dev/null; then
    echo "❌ create-dmg not installed. brew install create-dmg"
    exit 1
fi

rm -f "$DMG"

echo "[1/4] Building DMG with styled background…"
# Background rectangle centers in 1x points (measured from the background image via
# horizontal-variance rows and column-mean columns, excluding vignette edges):
#   left zone:  (128, 144)
#   right zone: (562, 144)
# create-dmg positions icons by their top-left corner, so offset by icon_size/2 = 64.
# Window size 688×384 matches the 1376×768 @2x background.
create-dmg \
    --volname "$VOLNAME" \
    --background "$BG2X" \
    --window-pos 200 120 \
    --window-size 688 384 \
    --icon-size 128 \
    --icon "$APP" 64 80 \
    --app-drop-link 498 80 \
    --hide-extension "$APP" \
    --no-internet-enable \
    "$DMG" \
    "$APP"

echo "[2/4] Signing DMG with Developer ID…"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

echo "[3/4] Notarizing DMG (waits for verdict)…"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "[4/4] Stapling ticket to DMG…"
xcrun stapler staple "$DMG"

echo ""
echo "✅ Done. $DMG is signed, notarized, and stapled."
spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
echo ""
echo "Upload:"
echo "  gh release upload v$VERSION $DMG --clobber"
