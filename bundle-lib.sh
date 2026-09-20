#!/bin/bash
# Shared bundle assembly for bundle.sh (local) and release-notarized.sh (ship).
# Sourced, not executed.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="$REPO_DIR/MemorAI.entitlements"

# Copy the CTranscribe binary framework (GigaAM runtime) into the bundle.
#
# SwiftPM leaves binary-target artifacts under .build/artifacts/<checkout-name>/,
# and that first path component is the *directory* the checkout lives in, not
# the package name — it differs between a normal clone and a git worktree. So
# the framework is located by search, never by a hardcoded path.
embed_ctranscribe() {
    local app="$1"
    local fw
    fw=$(find "$REPO_DIR/.build/artifacts" -type d -name CTranscribe.framework \
         -path '*macos-arm64_x86_64*' 2>/dev/null | head -1)
    if [ -z "$fw" ]; then
        echo "❌ CTranscribe.framework not found — run 'swift build' first" >&2
        return 1
    fi

    mkdir -p "$app/Contents/Frameworks"
    rm -rf "$app/Contents/Frameworks/CTranscribe.framework"
    cp -R "$fw" "$app/Contents/Frameworks/"

    # transcribe.cpp 0.2.0 ships the macOS framework with its top-level entries
    # and Versions/Current as real copies instead of symlinks. codesign rejects
    # that as an ambiguous bundle, so restore the canonical layout before
    # signing. The app's binary links @rpath/CTranscribe.framework/Versions/
    # Current/CTranscribe, so the Current symlink is load-bearing at runtime too.
    local root="$app/Contents/Frameworks/CTranscribe.framework"
    rm -rf "$root/Versions/Current" "$root/CTranscribe" "$root/Headers" \
           "$root/Modules" "$root/Resources"
    ln -s A "$root/Versions/Current"
    ln -s Versions/Current/CTranscribe "$root/CTranscribe"
    ln -s Versions/Current/Headers "$root/Headers"
    ln -s Versions/Current/Modules "$root/Modules"
    ln -s Versions/Current/Resources "$root/Resources"
    [ -L "$root/Versions/Current" ] || { echo "❌ framework relink failed" >&2; return 1; }
}

# Sign the bundle from the inside out.
#
# This ordering is not a style preference. codesign seals whatever it finds at
# the moment it runs, so signing the app first and the framework afterwards
# invalidates the app's own seal — and the failure does not show up on the
# machine that built it (the signature is still in the keychain's good graces
# locally); it shows up as a Gatekeeper rejection on someone else's Mac, after
# the release is published. Apple deprecated `--deep` for exactly this reason:
# it signs nested code with the *outer* target's entitlements and papers over
# the ordering question instead of answering it.
sign_bundle() {
    local app="$1" identity="$2"
    shift 2
    local extra=("$@")   # e.g. --timestamp

    codesign --force --sign "$identity" --options runtime "${extra[@]}" \
        "$app/Contents/Frameworks/CTranscribe.framework"

    codesign --force --sign "$identity" --options runtime "${extra[@]}" \
        --entitlements "$ENTITLEMENTS" \
        "$app"

    codesign --verify --strict --verbose=2 "$app"
}

# Report the architectures actually in the bundle. The app binary is whatever
# `swift build` produced (arm64-only on Apple Silicon unless --arch is passed);
# CTranscribe ships universal, so it is never the thing that limits us.
report_archs() {
    local app="$1"
    echo "  app:        $(lipo -archs "$app/Contents/MacOS/MemorAI")"
    echo "  CTranscribe:$(lipo -archs "$app/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe")"
}
