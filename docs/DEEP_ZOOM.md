# Deep zoom: the research and Luma's implementation

Research checked September 20, 2026 against the projects' own documentation.

Luma computes the Mandelbrot set again at each new view. It does not enlarge a stored picture. The useful goal is to keep increasing numerical precision as the view gets smaller, so ordinary floating point does not impose a visible resolution ceiling. Literal infinity is impossible on finite hardware: computation time, memory, exponent representation, and iteration limits still matter.

## What the leading implementations do

| Project | Relevant techniques | Implication for Luma |
| --- | --- | --- |
| [Fraktaler 3.1](https://fraktaler.mathr.co.uk/download/3.1/fraktaler-3-3.1.pdf), released December 15, 2025 | High precision references, perturbation, rebasing, bivariate linear approximation (BLA), CPU/OpenCL backends, and double precision extended exponent numbers. | A strong practical model for a portable deep zoom engine. BLA skips groups of iterations rather than only making each iteration cheaper. |
| [Fractalshades](https://gbillotey.github.io/Fractalshades-doc/API/arbitrary_models.html) | Arbitrary precision reference orbits, perturbation, chained BLA, period search, and Newton refinement. | Shows how the same numerical foundation supports detailed still images and feature finding. |
| [FractalShark](https://github.com/mattsaccount364/FractalShark), including its June 2026 development | NVIDIA CUDA perturbation and linear approximation; experimental GPU arbitrary precision reference computation using number theoretic transforms; GPU Newton refinement. | The frontier includes accelerating the expensive reference itself. These CUDA implementations would need substantial replacement to run on Apple GPUs. The author's performance reports are not Luma benchmarks. |

This is a comparison of documented methods, not a universal speed ranking. Location, iteration count, hardware, approximation tolerance, and image size change the result.

## The numerical trick

The Mandelbrot recurrence is `z = z*z + c`, starting with `z = 0`. Directly storing every pixel's absolute coordinate as a machine `double` eventually makes neighboring pixels indistinguishable. Increasing the image size cannot recover those lost coordinate bits.

Compute a reference orbit at a nearby center `C`, with enough precision:

```text
Z[0] = 0
Z[n+1] = Z[n]^2 + C
```

For each pixel use the small offset `dc = c - C`. Algebra gives the exact difference recurrence:

```text
dz[0] = 0
dz[n+1] = 2*Z[n]*dz[n] + dz[n]^2 + dc
```

Expensive high precision work is shared by the image. Small differences can usually use much faster arithmetic. This is perturbation rendering. Cancellation can still create false shapes; when `|Z + dz| < |dz|`, rebasing can replace `dz` by `Z + dz` and reset the reference index while retaining the pixel's total iteration count. [Claude Heiland-Allen's current deep zoom description](https://www.mathr.co.uk/web/deep-zoom.html)

Precision and numeric range are separate. Even a well-resolved difference can become too small for a `double` exponent. An extended exponent representation stores `mantissa * 2^exponent` separately. A further optimization rescales many ordinary operations together and uses full extended range operations when needed. [Deep zoom theory and practice, rescaling](https://mathr.co.uk/blog/2021-05-14_deep_zoom_theory_and_practice.html#Rescaling)

## What this version implements

Luma's native CPU engine uses:

- MPFR values for the camera and reference orbit, with precision increasing as the view narrows.
- Ordinary double perturbation where the exponent range is sufficient.
- Normalized double mantissas with separate 64-bit exponents for very small residuals.
- Perturbation rebasing and direct MPFR recalculation for detected severe cancellation.
- Conservative hierarchical BLA blocks in ordinary and extended exponent arithmetic.
- Degree-32 normalized initial series in a suitable ordinary exponent range, with a propagated discarded-tail bound and escape checks for the skipped prefix.
- Reuse of prepared reference orbits, series, and BLA tables between preview and full resolution.
- Multiple CPU workers, analytic main cardioid/period-two bulb tests, and parallel smooth escape coloring.

The current engine does not use GPU fractal computation or Newton feature finding. BLA and series skipping are enabled automatically where their validity checks permit them. Difficult views with long orbits can still take substantial time. Recalculation after a gesture progressively replaces the temporary enlarged preview with newly evaluated pixels. See [performance measurements](PERFORMANCE.md).

The polynomial error estimate bounds discarded terms over a disk containing the view. It does not certify all floating-point rounding error. Empirical comparisons with plain perturbation and direct MPFR evaluation remain necessary, especially at rare unstable boundary pixels.

## Acceleration and future improvements

BLA replaces a valid block of iterations with `dz' = A*dz + B*dc`. A hierarchy stores coefficients and a validity radius for each block. At a pixel, the renderer selects a valid large skip or falls back to an ordinary perturbation step. This reduces per-pixel iteration work while preserving fallback behavior. Luma now implements this hierarchy, including an extended exponent version. Ordinary arithmetic avoids very short skips whose lookup costs more than the iterations saved. [BLA construction and lookup](https://www.mathr.co.uk/web/deep-zoom.html#Bivariate-Linear-Approximation)

Luma also uses initial series approximation to skip a validated prefix, with the parameter normalized to the size of the view. Coefficients stay close to the scale of the perturbations. Reference reuse reduces overhead. Future work could add reference compression, better reference selection, and GPU execution. Rescaled double arithmetic can improve the cost of the extended range path. These optimizations require comparisons against direct high precision calculations; a plausible-looking fractal alone is not a correctness test. [Perturbation and series discussion](https://mathr.co.uk/blog/2021-05-14_deep_zoom_theory_and_practice.html)

## What “no resolution ceiling” means

As an engineering estimate, resolving pixels across a span near `10^-D` needs roughly `D*log2(10) + log2(imageWidth)` bits, plus guard bits for the orbit calculation. Luma grows its precision instead of fixing a maximum number of coordinate digits. This estimate is not a rigorous error bound for every orbit.

MPFR supports per-variable precision and correctly rounded operations, within finite implementation limits. Available memory is usually the practical precision limit. Its exponent range is also finite. Extended exponent residuals avoid ordinary floating point underflow, but their integer exponents likewise are not mathematical infinity. [GNU MPFR manual, numeric types and limits](https://mpfr.loria.fr/mpfr-current/mpfr.html#Nomenclature-and-Types)

Deep views also need sufficient iterations. A dark pixel that has not escaped within the selected budget is not generally a proof of set membership. If a region becomes unexpectedly solid, increasing the iteration budget can reveal detail. [Fraktaler 3.1, bailout controls](https://fraktaler.mathr.co.uk/download/3.1/fraktaler-3-3.1.pdf)

## Reproducible deep locations

Coordinates must be parsed from the complete decimal strings. Converting them to `Double` first destroys the extra information. Widths below are complex-plane widths, not screen pixels. These are reference locations for exploration and validation; they are not all guaranteed interactive at the published iteration budgets.

**Double embedded Julia, about `10^21` magnification.** Robert P. Munafo's location, reproduced in the [Fractalshades perturbation example](https://gbillotey.github.io/Fractalshades-doc/examples/batch_mode/08-run_perturb_DEM.html) and [double embedded Julia example](https://gbillotey.github.io/Fractalshades-doc/examples/batch_mode/10-double_embedded_julia.html). The former uses 50,000 iterations.

```text
real  = -1.768667862837488812627419470
imag  = 0.001645580546820209430325900
width = 1.6e-21
```

**Beyond 23, about `9.4e83` magnification.** A period-3325 location published by [Claude Heiland-Allen](https://www.mathr.co.uk/web/m-analytical-design.html). The source uses `zoom = 4 / width`; its zoom value is `9.39887739382545e83`.

```text
real = -1.74633633100731203448693540296700774092315436581254611803325193168381308728011150208513167019595429158355305443112947196533853088
imag = 2.07770992931759947498950604201187608484918690124222766722007389279534979028185356123800225021156175232502789685337340415867851975e-3
width = 4 / 9.39887739382545e83
```

**Dinkidau flake, width `1.7e-157`.** A demanding numerical reliability example from [Fractalshades](https://gbillotey.github.io/Fractalshades-doc/examples/batch_mode/09-run_flake_DEM.html), published with one million iterations and BLA. Even with iteration skipping, this remains a demanding CPU workload.

```text
real = -1.99996619445037030418434688506350579675531241540724851511761922944801584242342684381376129778868913812287046406560949864353810575744772166485672496092803920095332
imag = -0.00000000000000000000000000000000030013824367909383240724973039775924987346831190773335270174257280120474975614823581185647299288414075519224186504978181625478529
width = 1.7e-157
```
