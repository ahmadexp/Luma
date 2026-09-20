# Validation

Verified locally on an Apple Silicon Mac running macOS 26.6.2 on September 20, 2026.

- `scripts/build.sh`: builds the SwiftUI app, bundles MPFR/GMP, and signs the app locally.
- `scripts/test.sh`: camera import, pan, zoom, clone, invalid inputs, cancellation, and pixel-by-pixel comparisons against direct MPFR calculations passed.
- Numerical grids include ordinary views, wide zoom-out views, and widths `1e-24`, `1e-280`, `1e-400`, and `1e-1000`. In the committed test grids all smooth output values matched the direct evaluator exactly at float output precision, including both escaping and unescaped pixels.
- A separate review compared 4,211 pixels, including the published embedded Julia location. No escape classifications disagreed. The largest smooth-count difference was about 0.0073 iterations in a shallow chaotic region. This is empirical validation, not a rigorous bound for every possible orbit.
- AddressSanitizer and UndefinedBehaviorSanitizer found no failures in the engine test suite.
- Headless image export rendered all five built-in destinations. The 800 × 600 Deep Julia view at width `1.6e-21` and 50,000 iterations took about 2.8 seconds. A 1250 × 839 progressive interactive render took about 8.5 seconds. Timings vary with location, resolution, and system load.
- Native UI checks verified destination selection, increasing magnification using the plus button, completed deep rendering, and PNG export through the Save dialog. The exported image was 1250 × 839.
- `codesign --verify --deep --strict build/Luma.app` passed. MPFR and GMP use app-relative dynamic library paths.

The bundled Homebrew libraries require macOS 26. The UI source uses APIs available in macOS 14, but supporting older systems requires compatible builds of the dependencies and an adjusted deployment target.

## Version 1.1 update

Performance and expanded correctness checks are recorded in [PERFORMANCE.md](PERFORMANCE.md), including full-frame comparisons, rare unstable-pixel limitations, and reproducible benchmark commands. The new app pipeline check exercises background recoloring, cached view restoration, saved iteration budgets, and rapid superseding navigation.

The final 1.1 native UI check rendered Deep Julia at 1250 × 839 in 0.69 seconds including its preview, then restored the previous view with a cache hit. The user's exact decimal location, Monochrome palette, Fine quality, and 900-iteration budget were restored after restarting the updated app. The final signed app and ZIP were rebuilt and verified.

## Version 2.0 update

The app now includes true Julia dynamics, parameter picking from Mandelbrot, continuous zoom flight, animated colors, color phase/density controls, shaded relief, bookmarks, location JSON files, session restoration, and independent cancellable 4K export.

- `Tests/julia_tests.cpp` compares the four Julia presets, critical orbits, large parameters, tangent boundaries, and initial-z widths through `1e-1000` against direct MPFR evaluation. The tested output values match at float precision. Cancellation and row-progress reporting pass.
- `scripts/test-advanced.sh` uses isolated preferences to verify deep coordinates containing hundreds of decimal digits, rejected imports without partial state changes, bookmark persistence/deletion, Julia portals and history, color animation, and render-paced flight. Repeated session restoration preserves both coordinate strings and camera precision. Legacy files without precision metadata remain readable.
- The advanced suite renders and decodes an actual 3840 × 2880 PNG. Cancellation leaves no output file. Export uses an independent camera snapshot and render control.
- Colorizer tests cover default-color compatibility, phase wrapping, density bounds, invalid values, relief lighting direction, interior protection, parallel determinism, and small images. Color controls do not rerun fractal iterations.
- The original Mandelbrot and acceleration regression suites pass. AddressSanitizer and UndefinedBehaviorSanitizer checks pass for the numerical engine; the colorizer also passes AddressSanitizer.
- Native UI checks exercised the Julia mode, color animation, relief adjustment, zoom flight, location import, and automatic session restoration. Offscreen layout checks covered all three inspector tabs, Julia parameters, bookmarks, export progress, and the flight overlay at 1280 × 820 and the 980 × 650 minimum window size.

Julia preview timing on this machine was approximately 60–90 ms at 640 × 400 with 900 iterations. An interactive Julia overview at 1250 × 839 took about 0.22 seconds including its preview. Performance depends strongly on the parameter and MPFR fallback frequency; the Julia renderer does not use the Mandelbrot BLA/series acceleration.

## Version 2.1 update

- Autopilot planner checks cover coherent texture, interior/exterior boundaries, all-escaped detail, isolated-noise rejection, flat regions, nonfinite input, image orientation, and spatial target stability. Four actual Mandelbrot and Julia renders produce valid targets.
- Flight-transform tests check 5,490 point registrations, interpolation endpoints, zoom-in/out geometry, crossfade, and invalid input.
- Integration checks exercise repeated keyframe publication, reduced working resolution, autonomous steering, recovery from empty views, Julia mode, manual override, cancellation of an unpublished future camera, preservation of explicit iteration edits, and full-quality rendering on pause.
- A separate 90-second Mandelbrot and 30-second Julia soak published 557 and 183 computed frames respectively. It verified exact restoration of the last published camera/mode/Julia parameter on stop, refinement after pause, and cancellation of prefetched navigation.
- The existing advanced suite still passes, including exact session restoration, bookmarks, animated colors/relief, actual 4K output, and export cancellation.
- Native UI checks use a separately identified preview app, leaving the user's saved session unchanged. Autopilot controls and automatic navigation were exercised from ordinary scale through magnifications beyond 10²⁷×.

## Version 2.2 update

Deep views can contain many distinct escape values while the original square-root color formula compresses them into a tiny part of the palette. Adaptive color range estimates robust quantiles from at most 3,072 samples and expands compressed distributions. It preserves already broad color distributions, excludes invalid and unescaped pixels, and rejects fields with too few distinct values or insufficient variation above Float precision. Flight smooths contrast changes while following the midpoint of the current robust range to limit hue drift.

- The actual Mandelbrot view centered at `-2 + 0i`, width `1e-400`, and 2,200 iterations has 5 distinct exterior RGB colors with fixed mapping and 1,388 with adaptive mapping at 640 × 480. Comparison PNGs are generated in `build/color-range-checks`.
- `scripts/test-color-pipeline.sh` verifies deterministic recoloring, reuse of cached exposure, a PNG export matching the displayed mapping at the same geometry, session/bookmark persistence, compatibility with older settings, and retained color variation through twelve flight frames.
- Colorizer checks cover robust outlier handling, flat and quantized fields, narrow valid distributions, temporal smoothing, bimodal fields, invalid mappings, and legacy fixed-color compatibility. A synthetic field near 50,000 iterations with a four-iteration spread improves from 4 to 762 RGB colors. Default 1250 × 839 colorization including mapping estimation measured approximately 0.54 ms on this machine.
- The existing advanced and app-pipeline checks pass, including 4K export and cancellation. The rebuilt app passes signature verification. A native relaunch preserved the user's location, color settings, Fine quality, and 900-iteration budget; Studio shows Adaptive color range enabled.

Color calibration does not rerun fractal iterations. Recoloring, cached views, and exports reuse the mapping for their field. A completely uniform field or a view with no escaped pixels still needs a different location or iteration budget to reveal detail.

## Version 2.2.1 distribution

- The native About window shows "Created by Ahmad Byagowi" and the 2026 copyright credit.
- The app, embedded libraries, and installer are signed with Ahmad Byagowi's Developer ID certificate. The app enables the hardened runtime and includes a secure timestamp.
- Apple accepted the app archive (`db820c4e-90a5-42b5-9e62-f2fcf1fc0380`) and DMG (`37f1ec12-eacc-48db-bde9-d2b74fb1d551`) for notarization. Both tickets are stapled and validate successfully.
- Gatekeeper assessment reports `accepted` with source `Notarized Developer ID` for the app. The mounted app's strict signature check and render/recolor/cache/history pipeline checks pass. The installer image checksum and Applications shortcut also pass verification.
- The DMG and ZIP include their numerical libraries and license notices. The release supplies SHA-256 checksums and the matching MPFR 4.2.2 and GMP 6.3.0 source archives, verified against Homebrew's source checksums.
