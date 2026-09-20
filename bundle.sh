#!/bin/bash
set -e
cd "$(dirname "$0")"
source ./bundle-lib.sh

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

echo "Embedding CTranscribe.framework (GigaAM runtime)..."
embed_ctranscribe MemorAI.app

echo "Signing with: $SIGN_IDENTITY  (framework first, then the app)"
sign_bundle MemorAI.app "$SIGN_IDENTITY"

echo ""
echo "Built: MemorAI.app"
report_archs MemorAI.app
echo "  open MemorAI.app"
