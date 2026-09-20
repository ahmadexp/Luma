#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/Board"
npx tsc --noEmit
VITE_DEVICE_QA=1 npx vite build --outDir "$ROOT/build/board/device-qa" --emptyOutDir
cd qa
../node_modules/.bin/web-pack "$ROOT/build/board/device-qa" --name 'Luma QA' --icon icon.png \
  --sdk-version 1.0.0-beta.6 -o "$ROOT/build/board/luma-qa.webapp.zip"
