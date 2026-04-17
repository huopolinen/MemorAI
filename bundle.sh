#!/bin/bash
set -e
cd "$(dirname "$0")"

# Pick a stable codesign identity so TCC keeps the permissions between rebuilds.
# Override via SIGN_IDENTITY env, otherwise prefer "Developer ID Application",
# then "Apple Development", and finally fall back to ad-hoc.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F '"' '/Developer ID Application/{print $2; exit}')
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F '"' '/Apple Development/{print $2; exit}')
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "⚠️  No Apple codesign identity found — falling back to ad-hoc (TCC will reset on every rebuild)"
    SIGN_IDENTITY="-"
fi

echo "Building MemorAI..."
swift build -c release 2>&1

rm -rf MemorAI.app
mkdir -p MemorAI.app/Contents/MacOS
mkdir -p MemorAI.app/Contents/Resources
cp .build/release/MemorAI MemorAI.app/Contents/MacOS/
cp Info.plist MemorAI.app/Contents/
cp MemorAI.icns MemorAI.app/Contents/Resources/ 2>/dev/null || true

cat > /tmp/memorai-entitlements.plist << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

echo "Signing with: $SIGN_IDENTITY"
codesign --force --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements /tmp/memorai-entitlements.plist \
    MemorAI.app

echo ""
echo "Built: MemorAI.app"
echo "  open MemorAI.app"
