#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
mkdir -p build
FLAGS=(-std=c++17 -O2)
if [[ "${1:-}" == "--sanitize" ]]; then
  FLAGS=(-std=c++17 -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined)
fi
for SUITE in engine_tests acceleration_tests julia_tests; do
  xcrun clang++ "${FLAGS[@]}" -I"$BREW_PREFIX/include" -ISources/FractalCore \
    Sources/FractalCore/FractalCore.cpp "Tests/$SUITE.cpp" -L"$BREW_PREFIX/lib" \
    -lmpfr -lgmp -o "build/$SUITE"
  "build/$SUITE"
done
