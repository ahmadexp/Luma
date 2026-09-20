#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
mkdir -p build/module-cache
xcrun clang++ -std=c++17 -O3 -I"$BREW_PREFIX/include" -c Sources/FractalCore/FractalCore.cpp -o build/autopilot-integration-core.o
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 \
  -module-cache-path build/module-cache -import-objc-header Sources/FractalCore/FractalCore.h \
  Sources/Mandelbrot/ExplorationState.swift Sources/Mandelbrot/AutopilotPlanner.swift \
  Sources/Mandelbrot/FlightTransition.swift Sources/Mandelbrot/ExplorerModel.swift \
  Sources/Mandelbrot/FractalColorizer.swift Tests/autopilot_integration_tests.swift \
  build/autopilot-integration-core.o -L"$BREW_PREFIX/lib" -lmpfr -lgmp -lc++ -o build/autopilot_integration_tests
build/autopilot_integration_tests
