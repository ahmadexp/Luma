#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
VARIANT="${1:-optimized}"
WIDTH="${2:-800}"
HEIGHT="${3:-600}"
REPETITIONS="${4:-3}"
SELECTION="${5:-presets}"
case "$VARIANT" in
  baseline) SOURCE="build/baseline"; EXTRA_FLAGS=(-UMB_BENCH_ACCELERATION) ;;
  optimized) SOURCE="Sources/FractalCore"; EXTRA_FLAGS=(-DMB_BENCH_ACCELERATION) ;;
  *) echo "Usage: $0 [baseline|optimized] [width] [height] [repetitions] [presets|wide|scene]" >&2; exit 1 ;;
esac
OUTPUT="build/performance/$VARIANT"
mkdir -p "$OUTPUT"
xcrun clang++ -std=c++17 -O3 -DNDEBUG -mmacosx-version-min=26.0 \
  "${EXTRA_FLAGS[@]}" \
  -I"$BREW_PREFIX/include" -I"$SOURCE" "$SOURCE/FractalCore.cpp" Tests/performance_benchmark.cpp \
  -L"$BREW_PREFIX/lib" -lmpfr -lgmp -o "$OUTPUT/benchmark"
"$OUTPUT/benchmark" "$WIDTH" "$HEIGHT" "$REPETITIONS" "$SELECTION" "$OUTPUT" \
  > "$OUTPUT/${SELECTION}_${WIDTH}x${HEIGHT}.csv" \
  2> "$OUTPUT/${SELECTION}_${WIDTH}x${HEIGHT}.runs.log"
cat "$OUTPUT/${SELECTION}_${WIDTH}x${HEIGHT}.csv"
