# Releasing Luma

Created by Ahmad Byagowi. The app's native About window includes the author credit from `Resources/Credits.rtf`.

## Build an installer

On an Apple silicon Mac with macOS 26, Xcode command line tools, Python 3, MPFR, and GMP:

```sh
./scripts/package.sh
```

This builds an ad hoc signed app and generates a versioned DMG, ZIP, and SHA-256 checksum file in `build/`. The DMG opens in Finder with Luma and an Applications shortcut. The packaging tool, dmgbuild 1.6.7, is installed in `build/dmg-tools`, separate from the app. Layout settings are in `scripts/dmg-settings.py`.

To sign the app, its embedded libraries, and the DMG with a certificate already available in the keychain:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/package.sh
```

Developer ID builds enable the hardened runtime and request a secure signing timestamp. No signing credentials or private keys belong in the repository. `--no-build` packages a previously built, verified app; its version must match `Resources/Info.plist`.

## Optional notarization

If an authorized `notarytool` keychain profile has already been configured:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-profile-name' ./scripts/package.sh
```

An existing App Store Connect API key can be used directly instead of a keychain profile:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_KEY='/path/to/AuthKey_KEYID.p8' NOTARY_KEY_ID='KEYID' \
NOTARY_ISSUER='your-team-issuer-uuid' ./scripts/package.sh
```

Omit `NOTARY_ISSUER` only for individual API keys. The key file stays outside the project and is read by Apple's notarytool; it is never packaged or uploaded as a release asset.

The script submits the app archive, staples its ticket, creates the DMG, then submits and staples the DMG. Any failed step stops packaging. A normal release without notarization credentials is signed but not notarized; describe that accurately in the release notes. Apple's notarization service requires separate credentials in addition to the signing certificate.

## Verify and publish

1. Update the version and build number in `Resources/Info.plist` and the download link in `README.md`.
2. Run the relevant checks listed in the README. The packaging script verifies the mounted application signature, Applications shortcut, render pipeline, and disk image integrity. For a notarized release, also check `xcrun stapler validate` and `spctl --assess --type execute` on the app.
3. Mount the DMG and check its Finder layout, Applications shortcut, app launch, and About credit. Eject the image after checking.
4. Commit the source, tag the matching version, and attach the DMG, ZIP, checksum file, and corresponding MPFR/GMP source archives to a GitHub release.

The bundled dependencies currently require macOS 26. Do not advertise compatibility with earlier macOS versions or Intel hardware without rebuilding and testing the dependencies for those targets.
