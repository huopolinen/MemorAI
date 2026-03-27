#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building MemorAI..."
swift build -c release 2>&1

rm -rf MemorAI.app
mkdir -p MemorAI.app/Contents/MacOS
mkdir -p MemorAI.app/Contents/Resources
cp .build/release/MemorAI MemorAI.app/Contents/MacOS/
cp Info.plist MemorAI.app/Contents/
cp MemorAI.icns MemorAI.app/Contents/Resources/ 2>/dev/null || true
codesign --force --sign - MemorAI.app

echo ""
echo "Built: MemorAI.app"
echo "  open MemorAI.app"
