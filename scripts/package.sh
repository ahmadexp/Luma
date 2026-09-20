#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/Luma.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
BASE="Luma-$VERSION-macOS-arm64"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" ]]; then
  : "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID for the existing App Store Connect API key}"
  [[ -f "$NOTARY_KEY" ]] || { echo 'NOTARY_KEY must name an existing private key file.' >&2; exit 1; }
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
  if [[ -n "${NOTARY_ISSUER:-}" ]]; then NOTARY_ARGS+=(--issuer "$NOTARY_ISSUER"); fi
fi
if [[ ${#NOTARY_ARGS[@]} -gt 0 && "$SIGNING_IDENTITY" == "-" ]]; then
  echo 'Set SIGNING_IDENTITY to a Developer ID certificate before notarizing.' >&2
  exit 1
fi

# Build by default. Use --no-build only after verifying an existing build.
if [[ "${1:-}" != "--no-build" ]]; then ./scripts/build.sh; fi
codesign --verify --deep --strict "$APP"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$APP_VERSION" == "$VERSION" ]] || { echo 'App and source versions differ; rebuild first.' >&2; exit 1; }

# Packaging tools live in an isolated environment, never in the app bundle.
if [[ ! -x "$BUILD/dmg-tools/bin/dmgbuild" ]]; then
  python3 -m venv "$BUILD/dmg-tools"
  "$BUILD/dmg-tools/bin/pip" install 'dmgbuild==1.6.7'
fi
xcrun swift scripts/make-dmg-background.swift "$BUILD/dmg-background.png"

if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/$BASE-notary.zip"
  xcrun notarytool submit "$BUILD/$BASE-notary.zip" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

"$BUILD/dmg-tools/bin/dmgbuild" -D root="$ROOT" -s scripts/dmg-settings.py "Luma" "$BUILD/$BASE.dmg"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$BUILD/$BASE.dmg"
  codesign --verify --strict "$BUILD/$BASE.dmg"
fi
if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  xcrun notarytool submit "$BUILD/$BASE.dmg" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$BUILD/$BASE.dmg"
  xcrun stapler validate "$BUILD/$BASE.dmg"
fi
hdiutil verify "$BUILD/$BASE.dmg"
MOUNT_POINT=$(mktemp -d "$BUILD/dmg-check.XXXXXX")
cleanup_mount() {
  if mount | grep -Fq " on $MOUNT_POINT ("; then hdiutil detach -quiet "$MOUNT_POINT"; fi
  rmdir "$MOUNT_POINT"
}
trap cleanup_mount EXIT
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$MOUNT_POINT" "$BUILD/$BASE.dmg"
codesign --verify --deep --strict "$MOUNT_POINT/Luma.app"
[[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]]
"$MOUNT_POINT/Luma.app/Contents/MacOS/Luma" --pipeline-check
hdiutil detach -quiet "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
trap - EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/$BASE.zip"
cd "$BUILD"
shasum -a 256 "$BASE.dmg" "$BASE.zip" > "$BASE-SHA256SUMS.txt"
echo "Packaged $BUILD/$BASE.dmg"
