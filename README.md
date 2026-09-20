# Luma

A native macOS Mandelbrot and Julia explorer with animated color, precise navigation, and adaptive precision for deep zooms.

Created by **Ahmad Byagowi**.

## Install

[Download Luma for Apple silicon](https://github.com/ahmadexp/Luma/releases/download/v2.2.1/Luma-2.2.1-macOS-arm64.dmg), or browse [all releases](https://github.com/ahmadexp/Luma/releases).

1. Open the downloaded DMG.
2. Drag **Luma** onto **Applications**.
3. Eject the disk image and launch Luma from Applications.

Requires an Apple silicon Mac and **macOS 26 or later**. MPFR and GMP are included; Homebrew is not needed to run the downloaded app. A ZIP download and SHA-256 checksums are also available with each release.

Version 2.2.1 is signed with Ahmad Byagowi's Developer ID certificate and notarized by Apple. Notarization tickets are stapled to both the app and the DMG.

When building from source, open **build/Luma.app**, or double-click **Run.command** after installing the build dependencies.

## Explore

- Scroll or pinch to zoom around the pointer.
- Drag to move. Double-click to zoom in, Option-double-click to zoom out.
- Use the destination cards for interesting starting points. Follow the colored boundary to keep finding structure.
- Switch between five color palettes without recalculating the fractal.
- Increase Detail if a view appears solid. A dark pixel means it has not escaped within the current iteration budget.
- Choose Draft, Balanced, or Fine for the image resolution.
- Use Coordinates (Command-L) to enter full decimal coordinates and a width such as `1e-100`. The width is measured across the complex plane.
- Export the current rendered image as PNG with Command-Shift-S. Copy exact coordinates with Command-Shift-C.
- Command-0 resets, Command-[ goes back, and Command-plus/minus zooms.

The image responds immediately to gestures, then is replaced by freshly calculated preview and full detail passes. A render in progress can be interrupted by navigating elsewhere. The last three completed views are cached within a 64 MiB budget, and palette changes are colored in the background. Export saves the latest rendered image at the chosen quality, so wait for Ready for a completed image.

## Explore, Studio, and Library

- **Autopilot:** Click Autopilot in the header or Studio (Command-Shift-A). It steers toward intricate boundaries and filaments, recovers from empty views, and keeps exploring. Adjust Flight speed to change the pace. Escape or manual navigation stops it and restores your chosen full image quality. See [how autonomous exploration works](docs/AUTOPILOT.md).

- **Julia portals:** In Explore, choose **Pick a Julia set** (Command-J), then click a point on the Mandelbrot image. That exact complex coordinate becomes the fixed Julia parameter. Switch back to Mandelbrot to return to the source view, or use Back. Julia mode includes four starting worlds and editable real/imaginary parameters. Its Coordinates panel controls the initial-z camera; the fixed parameter is separate.
- **Zoom flight:** Center an interesting feature, open Studio, and start flight (Command-Shift-F, or Space while the canvas is focused). Speed adjusts the zoom step. Flight renders ahead at adaptive resolution and animates between views for smooth motion. Demanding regions can still advance more slowly. Escape stops flight and color animation. Dragging or manually zooming also stops flight.
- **Color studio:** Adaptive color range keeps deep views colorful when their escape values occupy only a small part of the palette. It is enabled by default, adjusts smoothly during flight, and can be switched off in Studio. Shift color phase, change band density, animate the palette, and add shaded relief. These controls reuse the completed escape field instead of recomputing orbits. Relief is a screen-space lighting effect on the escape field, not a 3D distance estimator.
- **Discovery library:** Save named bookmarks (Command-D) with exact coordinates, fractal mode, Julia parameter, colors, iterations, and quality. Import/export JSON location files for sharing and archival. Decimal coordinates are stored as strings without passing through Double. The last completed or paused location is restored on launch; animations never restart automatically.
- **4K exports:** Render a fresh PNG with a 3,840-pixel longest edge from Export image or Library. It preserves the canvas aspect ratio, captures the current camera and colors, and runs separately from interactive navigation. Progress and Cancel remain in the header. A cancelled export does not write a partial file. The regular PNG command saves the currently displayed image.

## Deep zoom

The camera and reference orbit use MPFR numbers whose precision grows automatically. Mandelbrot pixels are computed through perturbation, conservative hierarchical iteration skipping (BLA), a degree-32 initial series, rebasing, and extended exponent arithmetic when needed. There is no fixed decimal-depth cutoff in the app. This avoids the usual double-precision coordinate wall and, at still deeper scales, the double exponent underflow wall.

Finite computers cannot zoom literally forever. Available memory, iteration count, and calculation time eventually become limiting. The renderer uses CPU workers and reuses reference calculations between preview and final passes. Metal GPU computation is not used; difficult deep locations can still be slow. The "Deep Julia" destination renders an embedded Julia structure at approximately 10²¹× magnification, already past the coordinate precision of a double. Engine checks also compare separate pixels against direct MPFR calculations at 10⁴⁰⁰× and 10¹⁰⁰⁰× near the left tip.

True Julia rendering uses a fast ordinary-scale path, adaptive-precision reference perturbation for deep views, extended exponent arithmetic, and direct MPFR fallback when error estimates become large. Julia does not use Mandelbrot-specific rebasing or the Mandelbrot iteration-skipping cache. Highly chaotic Julia parameters can therefore be slower. The mathematical relation between a Mandelbrot parameter and its Julia set is described by [Wolfram](https://reference.wolfram.com/language/ref/MandelbrotSetPlot.html).

See [performance measurements](docs/PERFORMANCE.md) for measured speedups and validation, and [the research notes](docs/DEEP_ZOOM.md) for the leading techniques, primary sources, and further exact deep locations.

## Build and verify

Build tools: Xcode command line tools, MPFR, and GMP. On Apple Silicon with Homebrew:

```sh
brew install mpfr gmp
./scripts/build.sh
./scripts/test.sh
./scripts/test-colorizer.sh
./scripts/test-color-pipeline.sh
./scripts/test-advanced.sh
./scripts/test-autopilot.sh
./scripts/test-flight-transition.sh
./scripts/test-autopilot-integration.sh
./build/Luma.app/Contents/MacOS/Luma --pipeline-check
./build/Luma.app/Contents/MacOS/Luma --render-check
open build/Luma.app
```

The build creates a locally signed, self-contained app bundle. No Xcode project or network connection is needed for subsequent builds. `BREW_PREFIX` may override the dependency location. The script targets Apple Silicon; distributing an Intel build would need Intel dependency builds and a different Swift target.

To create a DMG and ZIP, run `./scripts/package.sh`. Packaging installs [dmgbuild](https://dmgbuild.readthedocs.io/en/latest/) into an isolated environment under `build/`. For Developer ID signing and optional notarization, see [RELEASING.md](docs/RELEASING.md).

Source layout:

- `Sources/FractalCore`: C++ numerical engine and C interface.
- `Sources/Mandelbrot`: SwiftUI interface, AppKit gesture canvas, asynchronous rendering, palettes, and export.
- `Tests`: numerical comparisons against direct MPFR evaluation and camera/cancellation checks.
- `docs`: research and third-party license information.

MPFR and GMP are dynamically linked. License texts are included inside the app, and source links and replacement instructions are in [THIRD_PARTY.md](docs/THIRD_PARTY.md).
