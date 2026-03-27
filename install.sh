#!/bin/bash
set -e

echo "=== MemorAI Installer ==="
echo ""

# Stop running instances
if pgrep -f "MemorAI" > /dev/null 2>&1; then
    echo "Stopping running MemorAI..."
    pkill -f "MemorAI" 2>/dev/null
    sleep 1
fi

# Reset permissions to avoid stale TCC entries
echo "Resetting permissions..."
tccutil reset ScreenCapture com.local.memorai 2>/dev/null
tccutil reset Microphone com.local.memorai 2>/dev/null
tccutil reset Accessibility com.local.memorai 2>/dev/null
tccutil reset ListenEvent com.local.memorai 2>/dev/null
echo "  Permissions cleared"

# Build
echo ""
echo "Building..."
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -1

# Create app bundle
rm -rf MemorAI.app
mkdir -p MemorAI.app/Contents/MacOS
mkdir -p MemorAI.app/Contents/Resources
cp .build/release/MemorAI MemorAI.app/Contents/MacOS/
cp Info.plist MemorAI.app/Contents/
cp MemorAI.icns MemorAI.app/Contents/Resources/ 2>/dev/null || true
codesign --force --sign - MemorAI.app 2>/dev/null

# Install to /Applications
echo ""
if [ -d "/Applications/MemorAI.app" ]; then
    echo "Removing old /Applications/MemorAI.app..."
    rm -rf "/Applications/MemorAI.app"
fi
cp -r MemorAI.app /Applications/
echo "Installed to /Applications/MemorAI.app"

# Install CLI
echo ""
if [ -L /usr/local/bin/memorai ] || [ -f /usr/local/bin/memorai ]; then
    rm -f /usr/local/bin/memorai
fi
ln -s "$(pwd)/memorai" /usr/local/bin/memorai 2>/dev/null || true
echo "CLI: memorai (linked to /usr/local/bin/memorai)"

# Launch
echo ""
echo "Launching MemorAI..."
open /Applications/MemorAI.app

echo ""
echo "=== Installation complete ==="
echo ""
echo "On first launch, macOS will ask for permissions:"
echo "  1. Screen Recording — allow to capture screen content"
echo "  2. Microphone — allow to record calls"
echo "  3. Accessibility — allow to read window titles"
echo ""
echo "Grant all three, then restart the app:"
echo "  memorai restart"
