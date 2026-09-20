import { test } from "node:test";
import assert from "node:assert/strict";
import {
  initial,
  validateLocation,
  loadLocation,
  loadBookmarks,
} from "../src/state";
import { estimateMapping, colorize, fixed, smoothMapping } from "../src/color";
import { findTarget } from "../src/planner";
import { GestureTracker, rotationDelta } from "../src/input";

test("exact decimal locations and legacy color fields survive round trip", () => {
  const v = validateLocation({
    ...initial,
    real: "-1.999999999999999999999999999999999999999999",
    span: "1e-400",
    bits: 1500,
  });
  assert.deepEqual(validateLocation(JSON.parse(JSON.stringify(v))), v);
  assert.equal(
    validateLocation({
      colorPhase: 0.3,
      colorDensity: 1.5,
      adaptiveColorRange: false,
    }).phase,
    0.3,
  );
});
test("rejects malformed, nonfinite, unsupported and prototype palette inputs", () => {
  for (const value of [
    { palette: "constructor" },
    { palette: "__proto__" },
    { palette: {} },
    { real: "NaN" },
    { imag: "Infinity" },
    { span: "0e-400" },
    { span: "-1" },
    { iterations: Infinity },
    { quality: "secret" },
    { version: 2 },
    { adaptive: "yes" },
    { bits: 1 },
  ])
    assert.throws(() => validateLocation({ ...initial, ...value }));
  const unavailable = {
    getItem: () => {
      throw Error("denied");
    },
  };
  assert.deepEqual(loadLocation(unavailable, "x"), initial);
  assert.deepEqual(loadBookmarks(unavailable, "x"), []);
  const corrupt = { getItem: () => "{broken" };
  assert.deepEqual(loadLocation(corrupt, "x"), initial);
});
test("adaptive colors expand narrow but real detail without exaggerating float noise", () => {
  const field = Float32Array.from(
    { length: 16384 },
    (_, i) => 10000 + (i / 16384) * 3,
  );
  const m = estimateMapping(field, 128, 128);
  assert.ok(m.scale > 10);
  const colors = (b: Uint8ClampedArray) =>
    new Set(
      Array.from({ length: b.length / 4 }, (_, i) =>
        b.slice(i * 4, i * 4 + 3).join(","),
      ),
    ).size;
  assert.ok(
    colors(colorize(field, 128, 128, initial, m)) >
      colors(colorize(field, 128, 128, { ...initial, adaptive: false }, m)) * 5,
  );
  for (const field of [
    new Float32Array(16384).fill(-1),
    new Float32Array(16384).fill(1),
    Float32Array.from({ length: 16384 }, (_, i) => 10000 + (i % 2) * 0.001),
  ])
    assert.deepEqual(estimateMapping(field, 128, 128), fixed);
  assert.deepEqual(
    estimateMapping(new Float32Array([NaN, Infinity, -Infinity, 0]), 2, 2),
    fixed,
  );
  const bytes = colorize(
    new Float32Array([-1, NaN, Infinity, 12]),
    2,
    2,
    { ...initial, relief: 1 },
    fixed,
  );
  assert.deepEqual(Array.from(bytes.slice(0, 4)), [6, 9, 18, 255]);
  assert.ok(bytes.every(Number.isFinite));
  assert.ok(smoothMapping(fixed, { origin: 1, scale: 1e6 }).scale <= 1.8);
});
test("planner rejects flat views and isolated noise, identifies a supported boundary", () => {
  for (const value of [-1, 4, NaN])
    assert.equal(
      findTarget(new Float32Array(128 * 96).fill(value), 128, 96),
      null,
    );
  const isolated = new Float32Array(128 * 96).fill(10);
  isolated[48 * 128 + 64] = 10000;
  assert.equal(findTarget(isolated, 128, 96), null);
  const field = Float32Array.from({ length: 128 * 96 }, (_, i) => {
    const x = i % 128,
      y = Math.floor(i / 128);
    return x < 64 + 20 * Math.sin(y * 0.22) ? -1 : 40 + x + y;
  });
  const p = findTarget(field, 128, 96);
  assert.ok(p && Math.abs(p.x) < 0.35 && Math.abs(p.y) < 0.5);
});
test("gestures preserve a pinch anchor, pan direction and reset contact identities", () => {
  const g = new GestureTracker();
  g.reset([{ id: 1, x: 10, y: 30 }]);
  assert.equal(g.update([{ id: 1, x: 40, y: 60 }]).dx, 30);
  g.reset([
    { id: 1, x: 10, y: 20 },
    { id: 2, x: 110, y: 20 },
  ]);
  const pinch = g.update([
    { id: 1, x: -30, y: 40 },
    { id: 2, x: 170, y: 40 },
  ]);
  assert.equal(pinch.scale, 2);
  assert.equal(pinch.dx, 10);
  assert.equal(pinch.dy, 20);
  assert.equal(pinch.anchorX, 60);
  assert.equal(g.update([{ id: 7, x: 20, y: 20 }]).scale, 1);
  assert.equal(rotationDelta(359, 1), 2);
  assert.equal(rotationDelta(1, 359), -2);
});

test("malicious bookmark names remain data and invalid entries are isolated", () => {
  const list = loadBookmarks(
    {
      getItem: () =>
        JSON.stringify([
          { id: "1", name: "<img src=x onerror=alert(1)>", location: initial },
          { id: "2", name: "bad", location: { ...initial, span: "NaN" } },
        ]),
    },
    "views",
  );
  assert.equal(list.length, 1);
  assert.equal(list[0].name, "<img src=x onerror=alert(1)>");
});

test("autopilot rejects float quantization texture in an otherwise flat view", () => {
  const field = Float32Array.from(
    { length: 128 * 96 },
    (_, i) => 10000 + ((i * 17) % 13) * 0.0009765625,
  );
  assert.equal(findTarget(field, 128, 96), null);
});
