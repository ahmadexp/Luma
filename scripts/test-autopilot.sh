#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
mkdir -p build/module-cache
xcrun clang++ -std=c++17 -O3 -I"$BREW_PREFIX/include" -c Sources/FractalCore/FractalCore.cpp -o build/autopilot-core.o
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 \
  -module-cache-path build/module-cache -import-objc-header Sources/FractalCore/FractalCore.h \
  Sources/Mandelbrot/AutopilotPlanner.swift Tests/autopilot_planner_tests.swift \
  build/autopilot-core.o -L"$BREW_PREFIX/lib" -lmpfr -lgmp -lc++ -o build/autopilot_planner_tests
build/autopilot_planner_tests
