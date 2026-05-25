#!/usr/bin/env bash
# Recompress all *_screen.mp4 files in ~/dev/claude/data/calls using h264_videotoolbox
# at 800 kbit/s. hevc_videotoolbox returns -12908 on this Mac (this static ffmpeg build,
# even with no contenders), so we fall back to hardware H.264 which is universally fast
# on Apple Silicon (~5x real-time). Audio is copied through. Expected ~1.8x compression.
#
# Usage:
#   tools/recompress-mp4.sh                # dry-run summary
#   tools/recompress-mp4.sh --go           # recompress (in-place, replaces originals)
#   PARALLEL=N tools/recompress-mp4.sh --go    # override parallelism (default 2; hw is serial)

set -euo pipefail
export LC_ALL=C

DIR="${CALLS_DIR:-$HOME/dev/claude/data/calls}"
GO="${1:-}"
PARALLEL="${PARALLEL:-2}"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg not found. Install: brew install ffmpeg" >&2
    exit 1
fi

cd "$DIR" || { echo "dir not found: $DIR" >&2; exit 1; }

shopt -s nullglob
mp4s=( *_screen.mp4 )
shopt -u nullglob

if [[ ${#mp4s[@]} -eq 0 ]]; then
    echo "no *_screen.mp4 files in $DIR"
    exit 0
fi

total_before=0
for f in "${mp4s[@]}"; do
    size=$(stat -f%z "$f" 2>/dev/null || echo 0)
    total_before=$(( total_before + size ))
done

printf "found %d files, total %.2f GB\n" "${#mp4s[@]}" "$(echo "scale=2; $total_before / 1073741824" | bc)"

if [[ "$GO" != "--go" ]]; then
    echo
    echo "dry-run. re-run with --go to recompress. PARALLEL=$PARALLEL workers will run."
    exit 0
fi

# Worker for a single file. Invoked via xargs in parallel.
recompress_one() {
    local f="$1"
    local out="${f%.mp4}.hevc.mp4"

    # Skip if already recompressed (heuristic: bitrate already low)
    local before
    before=$(stat -f%z "$f")
    local dur
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | awk -F. '{print $1+0}')
    if [[ -n "$dur" ]] && [[ "$dur" -gt 0 ]]; then
        # bytes per second; ~150 KB/s ≈ ~1.2 Mb/s already-recompressed threshold
        local bps=$(( before / dur ))
        if [[ "$bps" -lt 160000 ]]; then
            echo "skip (already small): $f"
            return 0
        fi
    fi

    if ffmpeg -y -nostdin -i "$f" \
            -c:v h264_videotoolbox -b:v 800k \
            -c:a copy -movflags +faststart \
            "$out" -hide_banner -loglevel error </dev/null; then
        local after
        after=$(stat -f%z "$out")
        if [[ "$after" -gt 0 ]] && [[ "$after" -lt "$before" ]]; then
            mv -f "$out" "$f"
            printf "ok: %s  %.1f -> %.1f MB (-%.1f MB)\n" \
                "$f" \
                "$(echo "scale=1; $before/1048576" | bc)" \
                "$(echo "scale=1; $after/1048576" | bc)" \
                "$(echo "scale=1; ($before - $after)/1048576" | bc)"
        else
            echo "skip (not smaller): $f"
            rm -f "$out"
        fi
    else
        echo "FAIL: $f"
        rm -f "$out"
        return 1
    fi
}
export -f recompress_one
export LC_ALL

# Pipe filenames to xargs and run N workers in parallel
printf '%s\0' "${mp4s[@]}" | xargs -0 -n1 -P "$PARALLEL" bash -c 'recompress_one "$0"'

# Tally
total_after=0
for f in "${mp4s[@]}"; do
    if [[ -f "$f" ]]; then
        size=$(stat -f%z "$f" 2>/dev/null || echo 0)
        total_after=$(( total_after + size ))
    fi
done
saved=$(( total_before - total_after ))

echo
printf "done. before %.2f GB, after %.2f GB, saved %.2f GB\n" \
    "$(echo "scale=2; $total_before/1073741824" | bc)" \
    "$(echo "scale=2; $total_after/1073741824" | bc)" \
    "$(echo "scale=2; $saved/1073741824" | bc)"
