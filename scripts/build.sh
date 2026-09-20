#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/Luma.app"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD/objects" "$BUILD/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
if [[ ! -f "$BREW_PREFIX/include/mpfr.h" ]]; then
  echo 'MPFR and GMP are needed to build. Install with: brew install mpfr gmp' >&2
  exit 1
fi
xcrun clang++ -std=c++17 -O3 -DNDEBUG -mmacosx-version-min=26.0 -I"$BREW_PREFIX/include" -c Sources/FractalCore/FractalCore.cpp -o "$BUILD/objects/FractalCore.o"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos26.0 -module-cache-path "$BUILD/module-cache" -import-objc-header Sources/FractalCore/FractalCore.h Sources/Mandelbrot/*.swift "$BUILD/objects/FractalCore.o" -L"$BREW_PREFIX/lib" -lmpfr -lgmp -lc++ -framework SwiftUI -framework AppKit -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$APP/Contents/MacOS/Luma"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Credits.rtf "$APP/Contents/Resources/Credits.rtf"
cp "$BREW_PREFIX/lib/libmpfr.6.dylib" "$APP/Contents/Frameworks/"
cp "$BREW_PREFIX/lib/libgmp.10.dylib" "$APP/Contents/Frameworks/"
chmod u+w "$APP/Contents/Frameworks/"*.dylib
install_name_tool -id @rpath/libmpfr.6.dylib "$APP/Contents/Frameworks/libmpfr.6.dylib"
install_name_tool -id @rpath/libgmp.10.dylib "$APP/Contents/Frameworks/libgmp.10.dylib"
install_name_tool -change "$BREW_PREFIX/opt/gmp/lib/libgmp.10.dylib" @rpath/libgmp.10.dylib "$APP/Contents/Frameworks/libmpfr.6.dylib"
install_name_tool -change "$BREW_PREFIX/opt/mpfr/lib/libmpfr.6.dylib" @rpath/libmpfr.6.dylib "$APP/Contents/MacOS/Luma"
install_name_tool -change "$BREW_PREFIX/opt/gmp/lib/libgmp.10.dylib" @rpath/libgmp.10.dylib "$APP/Contents/MacOS/Luma"
cp "$BREW_PREFIX/opt/mpfr/COPYING" "$APP/Contents/Resources/Licenses/MPFR-COPYING"
cp "$BREW_PREFIX/opt/mpfr/COPYING.LESSER" "$APP/Contents/Resources/Licenses/MPFR-LGPL"
cp "$BREW_PREFIX/opt/gmp/COPYING" "$APP/Contents/Resources/Licenses/GMP-COPYING"
cp "$BREW_PREFIX/opt/gmp/COPYING.LESSERv3" "$APP/Contents/Resources/Licenses/GMP-LGPL"
cp docs/THIRD_PARTY.md "$APP/Contents/Resources/Licenses/THIRD_PARTY.md"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGN_OPTIONS+=(--timestamp --options runtime); fi
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Frameworks/libgmp.10.dylib"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Frameworks/libmpfr.6.dylib"
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
