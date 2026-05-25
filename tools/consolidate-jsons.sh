#!/usr/bin/env bash
# Consolidate per-screenshot *.json files into a single index.jsonl per day.
# Source layout: ~/dev/claude/data/calls/screen/YYYY-MM-DD/HH-mm-ss.json
# Output:        ~/dev/claude/data/calls/screen/YYYY-MM-DD/index.jsonl  (one record per line)
#
# Usage:
#   tools/consolidate-jsons.sh                # dry-run summary
#   tools/consolidate-jsons.sh --go           # actually consolidate and delete originals
#
# Per-day flow:
#   1. iterate *.json sorted by name (chronological)
#   2. compact each to a single line, append to index.jsonl
#   3. on success, delete the source *.json files

set -euo pipefail
export LC_ALL=C

SCREEN_DIR="${SCREEN_DIR:-$HOME/dev/claude/data/calls/screen}"
GO="${1:-}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 required" >&2
    exit 1
fi

cd "$SCREEN_DIR" || { echo "dir not found: $SCREEN_DIR" >&2; exit 1; }

shopt -s nullglob
days=( */ )
shopt -u nullglob

if [[ ${#days[@]} -eq 0 ]]; then
    echo "no day folders under $SCREEN_DIR"
    exit 0
fi

total_jsons=0
total_bytes=0
for d in "${days[@]}"; do
    count=$(find "$d" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
    total_jsons=$(( total_jsons + count ))
done

printf "found %d day folders, %d standalone .json files\n" "${#days[@]}" "$total_jsons"

if [[ "$GO" != "--go" ]]; then
    echo
    echo "dry-run. re-run with --go to consolidate (will DELETE source .json files)."
    exit 0
fi

processed_days=0
processed_files=0
freed_bytes=0
for d in "${days[@]}"; do
    out="${d%/}/index.jsonl"
    tmp="${out}.tmp"

    # Gather sorted .json paths into a list (bash 3 compatible)
    files=()
    while IFS= read -r line; do
        files+=("$line")
    done < <(find "${d%/}" -maxdepth 1 -name '*.json' | sort)
    if [[ ${#files[@]} -eq 0 ]]; then
        continue
    fi

    # Compute size before
    before=0
    for f in "${files[@]}"; do
        sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
        before=$(( before + sz ))
    done

    # Use python to read each json (pretty-printed multi-line) and append as one compact line
    if python3 -c '
import json, sys, os
out_path = sys.argv[1]
files = sys.argv[2:]
appended = 0
with open(out_path, "a", encoding="utf-8") as out:
    for p in files:
        try:
            with open(p, "r", encoding="utf-8") as fh:
                obj = json.load(fh)
        except Exception as e:
            print(f"skip {p}: {e}", file=sys.stderr)
            continue
        out.write(json.dumps(obj, ensure_ascii=False, sort_keys=True))
        out.write("\n")
        appended += 1
print(appended)
' "$out" "${files[@]}"; then
        for f in "${files[@]}"; do rm -f "$f"; done
        processed_files=$(( processed_files + ${#files[@]} ))
        freed_bytes=$(( freed_bytes + before ))
        processed_days=$(( processed_days + 1 ))
        printf "ok: %s -> %d records merged into index.jsonl\n" "${d%/}" "${#files[@]}"
    else
        echo "FAIL: ${d%/}, keeping originals"
        rm -f "$tmp"
    fi
done

echo
printf "done: %d days, %d files merged, freed ~%.1f MB of .json overhead\n" \
    "$processed_days" "$processed_files" \
    "$(echo "scale=1; $freed_bytes/1048576" | bc)"
