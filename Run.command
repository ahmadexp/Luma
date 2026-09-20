#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -d "$ROOT/build/Luma.app" ]]; then "$ROOT/scripts/build.sh"; fi
if ! open "$ROOT/build/Luma.app" 2>/dev/null; then
  exec "$ROOT/build/Luma.app/Contents/MacOS/Luma"
fi
