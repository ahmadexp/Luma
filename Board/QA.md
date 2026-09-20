# Board port QA

Test date: September 20, 2026. Board build: 1.0.0 release candidate.
Owner and author: Ahmad Byagowi.

## Release status

The Board package installs and renders on the target console. Seven unit tests, six browser scenarios, and the native and Wasm numerical
suites pass. Hardware acceptance is incomplete: the console's screen went black
during the device suite, which then timed out waiting for a rendered Julia view.
A subsequent launch logged startup and touch bridge connection, but the screen
remained black. Sleep and a rendering failure have not yet been distinguished.
Do not describe this build as fully hardware qualified until that is resolved.

## Verified

| Area | Result |
| --- | --- |
| Native macOS baseline | Numerical, acceleration, Julia, color, persistence, export, flight registration, autopilot and integration suites passed. |
| Native engine after the port | AddressSanitizer and UndefinedBehaviorSanitizer suites passed. |
| WebAssembly engine | Mandelbrot, acceleration and Julia numerical suites passed, including MPFR oracle comparisons at widths of 1e-400 and 1e-1000, invalid camera input, clone, restore, pan, anchor zoom and reference reuse. Reported oracle errors were zero in these cases. |
| Colors and validation | Adaptive range, float noise protection, flat fields, unsupported imports, legacy fields, storage failures and palette prototype rejection passed. |
| Browser UI | Exact deep coordinates, Julia portal, history, bookmarks, invalid import, decoded screen-size and 3840 × 2399 PNG capture, all four Julia presets, the
  10²¹× destination, resize, render cancellation and continuous flight passed. |
| Board input adapter | Simulated native bridge: late connection, captured finger drag, pinch, touched Piece rotation, untouched Piece rejection, Piece removal, button taps and unavailable profile services passed. |
| Current dependency audit | No reported vulnerabilities after updating Vite to 6.4.3. |
| Package | Required model, Wasm, icon and licenses included; relative asset URLs; separate permanent Luma identity; no QA module or source maps in production. |
| Actual Board | Installed successfully, touch bridge connected, overview and three Mandelbrot destinations rendered. |

The standalone Wasm suite uses the native test scenes compiled for Wasm and runs
on the host. That establishes numerical compatibility; it is not a substitute
for the same device's sustained performance and physical input tests.

## Initial hardware measurements

Target: Board OS 2.5.2, 1920 × 1080 display. The working image was 980 × 612,
with 900 iterations. These are render plus color/planner times from the first
completed instrumented run, not display frame rates or final performance claims.

| Scene | Render time |
| --- | ---: |
| Overview | 511 ms |
| Seahorse Valley | 1,129 ms |
| Spiral garden | 3,082 ms |
| Elephant Valley | 2,174 ms |

Subsequent changes retain the worker between views, avoid redundant idle redraws,
reserve room for the Board system menu, and request a foreground screen wake
lock when supported. Their final device performance remains to be measured.

## Remaining hardware acceptance

1. Wake the display if asleep, then rerun the isolated device suite through its
   `[Luma QA COMPLETE]` report. Resolve any actual Julia rendering timeout.
2. Confirm two minutes of uninterrupted autopilot, reasonable UI latency and
   stable memory. Verify 4K capture, cancellation and lifecycle checks on Board.
3. Use real fingers for drag, pinch, double tap, panel scrolling and the numeric
   keypad. Place, rotate, move and lift a recognized Piece. Confirm the reticle
   and its focus agree with the touch surface.
4. Use the native pause menu, save and quit, cold relaunch, and restore a saved
   view under a Board profile. Check updates retain the same local library.
5. Disconnect Wi-Fi and repeat ordinary exploration and local saves. Asset
   bundling and browser network isolation are already checked; this is the
   physical device acceptance step.

The Board store makes its own acceptance decision. This explorer's installable
web app package is separate from a Board store submission.

Raw logs and screenshots for this run are in the repository's ignored
`build/board`, `build/qa-board-baseline`, and `Board/qa-results` directories.
No credentials are included in this report or the distribution package.
