# Luma 1.1 performance

Measured September 20, 2026 on this Apple Silicon Mac, macOS 26.6.2, 18 logical CPUs. All comparisons keep the same coordinates, pixel dimensions, and iteration budgets.

## Rendering benchmarks

| View | Pixels | Iteration budget | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: | ---: |
| Deep Julia, approximately 10²¹× | 800 × 600 | 50,000 | 1,395.6 ms | 293.6 ms | 4.75× |
| Deep Julia, approximately 10²¹× | 1250 × 839 | 50,000 | 3,112.3 ms | 656.6 ms | 4.74× |
| Left tip, width 1e-400 | 800 × 600 | 4,000 | 500.9 ms | 57.1 ms | 8.78× |
| Left tip, width 1e-1000 | 800 × 600 | 4,000 | 1,317.7 ms | 56.9 ms | 23.18× |

These are median engine times from three runs after a warmup. Every run creates a fresh render control, so reference orbit and approximation preparation are included. Scenes ran sequentially without competing test or app rendering. Color mapping, PNG encoding, UI scheduling, and frame cache hits are excluded. Shallow scenes have broadly unchanged engine times; speedups depend on location.

At 1250 × 839, a separate color mapping benchmark improved from 6.34 ms to 0.43 ms, approximately 15×. The lookup palette differs from the continuous palette by at most one 8-bit channel value in the tested million-pixel data set across all five palettes.

## Changes

- A degree-32 initial series shares the first 6,369 Deep Julia iterations across the image. The prefix must pass a discarded-tail bound and an escape check over a disk containing every pixel.
- Hierarchical bivariate linear approximation (BLA) skips subsequent valid iteration blocks. The extended exponent implementation preserves acceleration beyond double underflow.
- Ordinary BLA avoids short blocks when checking them would cost more than directly iterating.
- Preview and final passes share prepared references and approximation tables.
- Color mapping uses a shared palette table, parallel CPU workers, and a directly allocated output buffer. Palette changes run off the UI thread.
- Up to three recent completed views are retained within a 64 MiB frame cache. Returning to a cached view avoids recalculation. Navigation history also retains its iteration budget.
- Gesture render scheduling begins after 35 ms instead of 90 ms. Resolution and iteration counts are unchanged.

## Numerical validation and limits

The original numerical suite, new acceleration suite, AddressSanitizer, and UndefinedBehaviorSanitizer pass. Checks cover direct MPFR samples, series prefix and BLA iteration boundaries, ordinary and extended exponents, cancellation during preparation and rendering, and cache invalidation. A separate review checked 1,872 points across 16 views against direct MPFR; all matched at float output precision.

Full-frame before/after comparisons covered 8,603,750 pixels. Escape/interior classifications were identical throughout. The four shallow presets and both extreme tip views were bitwise identical.

Deep Julia had 490 changed float values among 1,528,750 pixels at the two tested resolutions. Of these, 70 differed enough to require direct MPFR evaluation. Among those 70 points, the original perturbation renderer exceeded the existing numerical tolerance at 58 points, and the accelerated version did so at 52. Fourteen points improved enough to pass; eight previously passing points exceeded the tolerance. Rare chaotic pixels can accumulate substantial escape-count error in either implementation, so this is not a promise of exact agreement at every boundary pixel. Most changes are small, but isolated color differences can be visible. The series bound covers discarded polynomial terms, not all floating-point rounding.

The camera precision and extended exponent path remain adaptive. There is no new zoom cutoff. Series acceleration is used only in its suitable numerical range; other views retain perturbation and extended exponent BLA.

## Reproduce

```sh
./scripts/test.sh
./scripts/test.sh --sanitize
./scripts/test-colorizer.sh
./scripts/build.sh
./build/Luma.app/Contents/MacOS/Luma --pipeline-check
./scripts/benchmark.sh optimized 800 600 3 presets
./scripts/benchmark.sh optimized 800 600 3 wide
```

The original source snapshot is retained locally in `build/baseline`. With it present, replace `optimized` by `baseline` to reproduce the previous renderer. Raw measurements, source hashes, per-run timings, floating-point output, and MPFR dispute audits are retained in `build/performance`. The summary is `build/performance/summary.json` and the full-grid audit summary is `build/performance/comparison.json`.

A headless app image check also supports `--render-check --no-acceleration` to disable the new approximation paths while keeping the current app pipeline.

## Version 2.1 continuous flight

Autopilot and center flight now use adaptive-resolution keyframes, render ahead during animation, and present registered motion using a display link targeting 60 Hz. They avoid the 35 ms gesture debounce, the second render pass, and full-frame cache writes on every step. Pausing restores the selected full image quality. The numerical engine and its deep-zoom arithmetic are unchanged in this update.

A 90-second Mandelbrot autopilot run published 557 computed views (6.19 per second), reached approximately 10²⁵× magnification, and had a largest publication gap of 190 ms. A separate 30-second Julia run published 183 views (6.10 per second), reached approximately 10⁸×, and had a largest publication gap of 234 ms. Both completed without stalls, errors, or recovery jumps on these particular paths. Median compute times were 71 ms and 102 ms respectively. These are calculated keyframes, not display refresh frames.

The interest planner took about 0.48 ms to analyze a 1250 × 839 field. It uses bounded grid sampling and is independent of image palette.

Adaptive flight trades working resolution for latency. Its performance must not be described as an equivalent speedup of full-resolution fractal arithmetic. Reproduce the full-quality versus flight comparison with `scripts/test-autopilot-integration.sh`; it prints both pixel counts and measured times. See [AUTOPILOT.md](AUTOPILOT.md) for the scheduling, recovery behavior, and limits. Development logs are in `build/autopilot-integration.log`, `build/autopilot-planner-tests.log`, and `build/autopilot-soak.log`.
