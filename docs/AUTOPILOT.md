# Autopilot and continuous flight

Start **Autopilot** in the header or Studio, or press Command-Shift-A. It selects detailed regions from the current Mandelbrot or Julia view and follows them inward. The Studio speed slider controls zoom velocity. Escape, the Stop button, or manual pan/zoom returns control to you. A starts or stops autopilot when the canvas has keyboard focus; Space controls center flight.

## Choosing a path

The planner analyzes smooth escape values, independent of the color palette. It measures local escape/interior boundaries, log-iteration variation, gradients, and curvature. Robust sampling and neighborhood support suppress isolated noisy pixels. Nearby candidates receive a modest preference to reduce abrupt changes of direction. Analysis samples at most a 96 × 64 grid with nine probes per cell, and typically takes about 0.5 ms on the development Mac.

A flat view is not treated as an interesting target. Autopilot can increase its iteration budget, widen the search, or move to a fresh preset trail after repeated unsuccessful searches. Difficult renders have a cooperative timeout; retries lower the working resolution, and autopilot can choose another trail. Consequently, a long exploration may include zooming out or starting elsewhere. The planner is a visual heuristic, not a proof that every chosen point contains infinite interesting detail.

## Keeping motion smooth

Flight computes one adaptive-resolution keyframe at a time instead of a preview plus a full-resolution frame for every step. Its pixel budget targets approximately 100 ms of computation, with normal working budgets from 24,000 to 600,000 pixels. Extreme window aspect ratios may require a slightly larger minimum to preserve the aspect ratio. The iteration budget and arbitrary-precision engine remain active.

As soon as a keyframe is published, the next view is calculated in the background. The canvas uses an AppKit display link targeting 60 Hz to animate registered logarithmic zoom and crossfade between adjacent frames. Display frames are therefore distinct from newly calculated fractal views. Performance measurements count these separately. This follows the general [fractal keyframe interpolation approach documented by mathr](https://mathr.co.uk/zoom/), using [AppKit's display-synchronized callback](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)).

Flight avoids the normal 35 ms gesture debounce, redundant preview passes, and full-frame cache writes. It keeps at most one future view in flight and rejects stale results after a stop or navigation change. Pausing restores the last published camera and computes the selected Draft, Balanced, or Fine resolution. Explicit iteration edits remain in effect. Bookmarks and exports retain their usual precision and quality behavior.

This does not promise full-resolution fractal calculation at 60 frames per second. Extremely costly orbits and reference construction can still cause pauses. Adaptive resolution, look-ahead calculation, and automatic recovery make continued exploration practical without imposing a fixed zoom-depth limit.

## Verification

- `scripts/test-autopilot.sh`: synthetic interest fields, noise rejection, coordinate orientation, target stability, and real Mandelbrot/Julia fields.
- `scripts/test-flight-transition.sh`: 5,490 point-registration comparisons across zoom factors, anchors, and animation times, plus endpoint and invalid-input checks.
- `scripts/test-autopilot-integration.sh`: continuous flight, adaptive timing measurements, automatic steering, empty-region recovery, manual takeover, full-quality pause, Julia exploration, and explicit iteration edits.
- The existing numerical, colorizer, session, bookmark, and 4K export suites remain applicable.
