#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX="$ROOT/build/board/wasm-deps-v2"
mkdir -p "$ROOT/build/board/tests"
for suite in engine_tests acceleration_tests julia_tests; do
  em++ -std=c++17 -O2 -fexceptions -DMB_SINGLE_THREADED \
    "$ROOT/Sources/FractalCore/FractalCore.cpp" "$ROOT/Tests/$suite.cpp" \
    -I"$ROOT/Sources/FractalCore" -I"$PREFIX/include" "$PREFIX/lib/libmpfr.a" "$PREFIX/lib/libgmp.a" \
    -s ENVIRONMENT=node -s ALLOW_MEMORY_GROWTH=1 -s DISABLE_EXCEPTION_CATCHING=0 \
    -o "$ROOT/build/board/tests/$suite.cjs"
  node "$ROOT/build/board/tests/$suite.cjs"
done
