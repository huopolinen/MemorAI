#!/bin/bash
# Fails if the app sources contain any way to switch recording off or spoil it
# from outside the settings UI: environment variables, DEBUG-only branches,
# hidden defaults keys, launch flags read deep in the code, "simulate/fake
# dropout" helpers.
#
# Why: on 2026-11-17 a test hook (MEMORAI_TEST_SYSTEM_DROPOUT) was left set on
# the working app and a real 38-minute call was recorded without the far end.
# Owner's rule: the app has no modes that turn recording off or spoil it, in
# any form; the recovery logic is checked by unit tests with synthetic levels.
#
# Usage: tools/check-no-recording-sabotage.sh [source-dir ...]
#   default dirs: AutoRec MemorAICore ObjCSupport (relative to the repo root)
# Exit 0 = clean, 1 = violations found (printed), 2 = usage error.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -gt 0 ]]; then
    DIRS=("$@")
else
    DIRS=("$ROOT/AutoRec" "$ROOT/MemorAICore" "$ROOT/ObjCSupport")
fi

for d in "${DIRS[@]}"; do
    if [[ ! -d "$d" ]]; then
        echo "check-no-recording-sabotage: no such directory: $d" >&2
        exit 2
    fi
done

# Settings the user can see and change in the app. A new key is a conscious
# change of this list, reviewed in the same PR as the setting itself.
ALLOWED_DEFAULTS_KEYS=" autoDetect autoTranscribe captureInterval excludedBundleIds extraDictationApps geminiApiKey geminiModel gigaamModelPath groqApiKey micVoiceProcessing modelPath outputPath polishTranscripts recordScreen saveClipboard screenMemoryEnabled screenshotChangeThreshold screenshotQuality systemAudioSource tapCallAppOnly transcriptionEngine whisperLanguage whisperPath "

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
    find "${DIRS[@]}" -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.c' -o -name '*.cpp' \) | sort
)

FAILED=0
report() {
    # $1 = rule, $2 = grep -n output lines
    echo "❌ $1"
    echo "$2" | sed 's/^/    /'
    FAILED=1
}

[[ ${#FILES[@]} -eq 0 ]] && exit 0

# 1. Any MEMORAI_TEST* name, anywhere.
hits=$(grep -HnE 'MEMORAI_TEST' "${FILES[@]}" 2>/dev/null)
[[ -n "$hits" ]] && report "MEMORAI_TEST* in app sources" "$hits"

# 2. Reading the process environment.
hits=$(grep -HnE 'processInfo\.environment|ProcessInfo\(\)\.environment|[^A-Za-z_]getenv[[:space:]]*\(|[^A-Za-z_]secure_getenv[[:space:]]*\(|NSProcessInfo.*environment' "${FILES[@]}" 2>/dev/null)
[[ -n "$hits" ]] && report "reads the process environment" "$hits"

# 3. DEBUG-only branches: a debug build must record exactly like release.
hits=$(grep -HnE '^[[:space:]]*#[[:space:]]*(if|ifdef|elseif|elif)[[:space:]].*DEBUG' "${FILES[@]}" 2>/dev/null)
[[ -n "$hits" ]] && report "#if DEBUG branch in app sources" "$hits"

# 4. Helpers that simulate a broken capture.
hits=$(grep -HniE '(simulat|fake|inject|force)[A-Za-z_]*(silence|dropout|zero|mute|outage|gap)' "${FILES[@]}" 2>/dev/null)
[[ -n "$hits" ]] && report "simulated silence/dropout helper" "$hits"

# 5. Launch arguments are read only in main.swift (CLI modes that exit
#    before any recording starts), never inside the recording code.
hits=$(grep -HnE 'CommandLine\.arguments|CommandLine\.argc|NSProcessInfo.*arguments|ProcessInfo\.processInfo\.arguments' "${FILES[@]}" 2>/dev/null | grep -vE '/main\.swift:')
[[ -n "$hits" ]] && report "launch arguments read outside main.swift" "$hits"

# 6. UserDefaults only through SettingsManager, and only for known settings.
hits=$(grep -HnE 'UserDefaults|NSUserDefaults|CFPreferences' "${FILES[@]}" 2>/dev/null | grep -vE '/SettingsManager\.swift:')
[[ -n "$hits" ]] && report "UserDefaults read outside SettingsManager.swift" "$hits"
for f in "${FILES[@]}"; do
    case "$f" in */SettingsManager.swift) ;; *) continue ;; esac
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        case "$ALLOWED_DEFAULTS_KEYS" in
            *" $key "*) ;;
            *) report "defaults key not in the allowlist: $key" "$(grep -HnE "forKey: *\"$key\"" "$f")" ;;
        esac
    done < <(grep -oE 'forKey: *"[A-Za-z0-9_.-]+"' "$f" | sed -E 's/.*"(.*)"/\1/' | sort -u)
done

if [[ $FAILED -ne 0 ]]; then
    echo ""
    echo "The app must have no way to turn recording off or spoil it outside the"
    echo "settings UI (docs/decisions.md, 2026-11-17). Test recovery logic with unit"
    echo "tests on synthetic levels instead."
    exit 1
fi
echo "check-no-recording-sabotage: OK (${#FILES[@]} files)"
exit 0
