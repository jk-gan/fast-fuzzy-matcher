#!/bin/bash
set -e

SCAN_DIR="${1:-$HOME/Developer}"
QUERIES=("smith_waterman" "main" "sw")
FILE_LIST=$(mktemp)

trap "rm -f '$FILE_LIST'" EXIT

echo "=== Building with -o:speed ==="
mkdir -p build
odin build src/ -out:build/ffm -o:speed

echo ""
echo "=== Caching file list from $SCAN_DIR ==="
find "$SCAN_DIR" -type f > "$FILE_LIST" 2>/dev/null
FILE_COUNT=$(wc -l < "$FILE_LIST" | tr -d ' ')
echo "$FILE_COUNT files"

HAS_FZF=$(command -v fzf >/dev/null 2>&1 && echo 1 || echo 0)
HAS_SK=$(command -v sk >/dev/null 2>&1 && echo 1 || echo 0)
HAS_RG=$(command -v rg >/dev/null 2>&1 && echo 1 || echo 0)

detect_hw_threads() {
    local n=""

    if command -v getconf >/dev/null 2>&1; then
        n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    fi

    if [ -z "$n" ] && command -v sysctl >/dev/null 2>&1; then
        n=$(sysctl -n hw.logicalcpu 2>/dev/null || true)
        if [ -z "$n" ]; then
            n=$(sysctl -n hw.ncpu 2>/dev/null || true)
        fi
    fi

    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -le 0 ]; then
        n=8
    fi

    echo "$n"
}

HW_THREADS=$(detect_hw_threads)
THREAD_COUNTS=(1)
THREAD_LABELS=("ffm-1")

if [ "$HW_THREADS" -eq 4 ]; then
    THREAD_COUNTS+=(4)
    THREAD_LABELS+=("ffm-4/hw")
else
    THREAD_COUNTS+=(4 "$HW_THREADS")
    THREAD_LABELS+=("ffm-4" "ffm-hw")
fi

echo "Hardware threads detected: $HW_THREADS"

# Convert time string (e.g. "0m1.234s") to milliseconds
to_ms() {
    echo "$1" | sed 's/[ms]/ /g' | awk '{printf "%.0f", ($1 * 60000) + ($2 * 1000)}'
}

# Format comparison: how much faster/slower the other tool is vs baseline
# Usage: compare baseline_ms candidate_ms
compare() {
    local baseline_ms=$1 candidate_ms=$2
    if [ "$candidate_ms" -eq 0 ]; then echo "—"; return; fi
    awk -v a="$baseline_ms" -v b="$candidate_ms" 'BEGIN {
        ratio = a / b
        if (ratio >= 1) printf "%.1fx faster\n", ratio
        else printf "%.1fx slower\n", 1 / ratio
    }'
}

echo ""
echo "=== Benchmarking ==="

for q in "${QUERIES[@]}"; do
    echo ""
    echo "query: \"$q\""
    printf "  %-12s %10s %10s %18s\n" "Tool" "Real" "User" "vs ffm-1"
    printf "  %-12s %10s %10s %18s\n" "----" "----" "----" "--------"

    ffm1_ms=0
    for i in "${!THREAD_COUNTS[@]}"; do
        threads="${THREAD_COUNTS[$i]}"
        label="${THREAD_LABELS[$i]}"
        times=$( { time build/ffm "$q" "$threads" < "$FILE_LIST" > /dev/null; } 2>&1 )
        real=$(echo "$times" | grep real | awk '{print $2}')
        user=$(echo "$times" | grep user | awk '{print $2}')
        real_ms=$(to_ms "$real")

        if [ "$i" -eq 0 ]; then
            ffm1_ms="$real_ms"
            printf "  %-12s %10s %10s\n" "$label" "$real" "$user"
        else
            cmp=$(compare "$ffm1_ms" "$real_ms")
            printf "  %-12s %10s %10s %18s\n" "$label" "$real" "$user" "$cmp"
        fi
    done

    if [ "$HAS_FZF" = "1" ]; then
        times=$( { time fzf --filter="$q" < "$FILE_LIST" > /dev/null; } 2>&1 )
        real=$(echo "$times" | grep real | awk '{print $2}')
        user=$(echo "$times" | grep user | awk '{print $2}')
        cmp=$(compare "$ffm1_ms" "$(to_ms "$real")")
        printf "  %-12s %10s %10s %18s\n" "fzf" "$real" "$user" "$cmp"
    fi

    if [ "$HAS_SK" = "1" ]; then
        # Closer apples-to-apples with fzf: use fzy-style algo and disable typo tolerance
        times=$( { time sk --algo fzy --no-typos --filter="$q" < "$FILE_LIST" > /dev/null; } 2>&1 )
        real=$(echo "$times" | grep real | awk '{print $2}')
        user=$(echo "$times" | grep user | awk '{print $2}')
        cmp=$(compare "$ffm1_ms" "$(to_ms "$real")")
        printf "  %-12s %10s %10s %18s\n" "sk-fzy" "$real" "$user" "$cmp"
    fi

    if [ "$HAS_RG" = "1" ]; then
        times=$( { time rg --no-filename "$q" "$FILE_LIST" > /dev/null; } 2>&1 )
        real=$(echo "$times" | grep real | awk '{print $2}')
        user=$(echo "$times" | grep user | awk '{print $2}')
        cmp=$(compare "$ffm1_ms" "$(to_ms "$real")")
        printf "  %-12s %10s %10s %18s\n" "rg" "$real" "$user" "$cmp"
    fi
done
