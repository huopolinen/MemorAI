#!/bin/bash
set -e

APP_NAME="AutoRec"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
APP_DIR="$APP_BUNDLE/Contents/MacOS"

# No way to switch recording off or spoil it may ship (docs/decisions.md, 2026-11-17).
"$(dirname "$0")/tools/check-no-recording-sabotage.sh"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_DIR"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/"
cp Info.plist "$APP_BUNDLE/Contents/"
cp AutoRec.icns "$APP_BUNDLE/Contents/Resources/"

# Create entitlements
cat > /tmp/autorec-entitlements.plist << 'ENTITLEMENTS'
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
ENTITLEMENTS

echo "Signing app bundle..."
codesign --force --deep --sign - \
    --entitlements /tmp/autorec-entitlements.plist \
    "$APP_BUNDLE"

echo ""
echo "Done! Created $APP_BUNDLE (ad-hoc signed)"
echo ""
echo "To install:"
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
echo "If Screen Recording permission loops, run:"
echo "  tccutil reset ScreenCapture com.local.autorec"
