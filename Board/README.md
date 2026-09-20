# Luma for Board

A touch and Piece controlled Mandelbrot and Julia explorer by **Ahmad Byagowi**.
The macOS app and Board app share the C++ arbitrary precision engine.

## Install on Board

Use the prepared `Luma-Board-1.0.0-rc1.webapp.zip` candidate, or build the
bundle below. Hardware qualification is still in progress; see `QA.md`. Pair Board Connect with the console, then install:

```sh
board-connect pair BOARD_ADDRESS
board-connect install Luma-Board-1.0.0-rc1.webapp.zip --launch
```

You can also drop the ZIP into Board Connect's Apps page on your local network.
This is a Board web app, not a macOS DMG or Android APK.

The production identity is `b0b1ad74-8842-4227-a10a-1ddc60ff55f4`, package ID
`com.ahmadbyagowi.luma.board`. Keep `board.config.json` when rebuilding so updates
retain saved views. The separate Luma QA identity never replaces PC110 Atlas.

## Explore

- Drag to pan; pinch or double tap to zoom. Mouse wheel and keyboard also work
  in a desktop browser. Space toggles autopilot; Escape cancels rendering.
- Autopilot seeks textured boundaries, prefetches the next image, and blends
  registered images while zooming. Its target marker stays visible.
- Put any recognized Board Piece on the image to steer the zoom focus. Touch
  and rotate it to zoom. More than one Piece is allowed; the last tracked Piece
  over the image supplies the focus. Lifting a Piece removes its marker.
- Open a Julia portal, then touch a Mandelbrot point. The Julia parameter is
  calculated with the precision camera, including at deep magnification.
- Choose five palettes, color density, phase, relief and adaptive dynamic range.
- Save exact decimal locations in Library. Board profile saves are also created
  when the native storage service is available. JSON location files can be
  imported and exported in a desktop browser.
- Capture screen size or 4K images. A desktop browser can download the PNG.
  On Board, capture displays a preview; use Library to retain the coordinates.
- The Board pause menu supports return to the whole set, quit, and save and quit.

Coordinates do not hit the usual double-precision zoom wall. Precision grows with
the camera depth; device memory, finite iteration budgets, and computation time
still limit practical exploration. Draft quality reduces image size, not camera
precision. Difficult regions can take longer. Rendering runs off the UI thread
and can be canceled; a watchdog recovers or pauses an expensive flight.

## Build

Requirements: Node 22 or later, npm, Emscripten, make, a native C compiler,
`curl`, `tar`, `shasum`, and `unzip`. The tested compiler is Emscripten 6.0.8.
On macOS, Xcode Command Line Tools supply `/usr/bin/clang` for GMP's host tools.

1. Obtain the Piece Set Model for your Board from the developer portal and put
   it at `Board/public/model.tflite`. It is intentionally excluded from Git.
   The tested model SHA-256 is
   `32fb80482b974e09e142985cf0210c712726f1ad289a532b21d2edcd84fbc8a5`.
2. From this directory:

```sh
npm ci
npm run build:wasm
npm run pack
```

The result is `Board/luma-board.webapp.zip`. Packaging verifies its stable
identity, required assets, relative URLs, and absence of QA or private files.
`build:wasm` downloads pinned GMP 6.3.0 and MPFR 4.2.2 sources, verifies SHA-256,
and builds the same precision engine used by macOS. Build products and source
archives live in the repository's ignored `build/board` directory.

Use `npm run dev` for local development. The production app requires no network
requests after installation. All fonts, palettes, icons, recognition data,
precision code, and license texts are bundled.

## Architecture

- `Sources/FractalCore`: MPFR camera, perturbation, BLA, series acceleration,
  rebasing, wide-exponent arithmetic and direct MPFR fallback.
- `src/renderer.worker.ts`: serialized rendering and cached recoloring in an
  isolated worker. Terminating the worker cancels expensive work without
  blocking input. No SharedArrayBuffer or cross-origin isolation is required.
- `src/main.ts`: interface, geometric flight transitions, adaptive image sizes,
  bounded history, local persistence, Board input and lifecycle.
- `src/color.ts`: robust color-range estimation with float-noise protection.
- `src/planner.ts`: supported edge and curvature scoring for flight targets.

`MB_SINGLE_THREADED` removes native thread creation inside the worker. Native
macOS builds continue to use their existing parallel renderer. A foreground
screen wake lock is requested on Board when the WebView supports it; the OS
can decline the request.

## QA

```sh
npm test
bash scripts/test-wasm.sh
npm run build
npm run test:browser
npm audit
bash scripts/pack-qa.sh
```

The Wasm test command runs the existing numerical suites against independent
MPFR evaluations, including view widths of `1e-1000`. Native cancellation tests
stay enabled on macOS. Browser tests cover worker termination on single-threaded
hosts, UI flows, exact-coordinate persistence, gestures, Piece events and colors.

`pack-qa.sh` creates an isolated Luma QA package in `build/board`. Its extra test
module runs only in that build and is removed from the production bundle.
Install it and read verbose logs:

```sh
board-connect install ../build/board/luma-qa.webapp.zip --launch
board-connect logs 4f50d619-6cce-40be-922e-03a7ed40a53f --level V
```

Look for `[Luma QA COMPLETE]`. If the app is hidden when launched, the suite
waits for the display to become visible before starting its timed checks. The device suite exercises rendering, exact deep
zoom, injected Board contacts, persistence, a two-minute autopilot soak, 4K
capture, cancellation and lifecycle. Injected contacts validate the application
path; they do not replace a physical sensor and Piece acceptance check.

Before public release, also verify fingers, a real Piece, the native pause menu,
profile save and restore, a cold relaunch, and operation with Wi-Fi disconnected
on the target hardware. See `QA.md` for measured results and remaining gates.

Third-party notices are bundled in `public/licenses/THIRD_PARTY.txt`. Rebuilding
and replacing the Wasm module with modified GMP or MPFR is supported. The model
and Board SDK are governed by Board's terms.

References: [Board build and deployment](https://docs.dev.board.fun/web/getting-started/build-and-deploy),
[Board Connect](https://docs.dev.board.fun/tools/board-connect).
