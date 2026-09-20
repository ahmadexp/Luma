#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 \
  -module-cache-path build/module-cache Sources/Mandelbrot/FlightTransition.swift \
  Tests/flight_transition_tests.swift -o build/flight_transition_tests
build/flight_transition_tests
