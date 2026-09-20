import { palettes, type Style, type Palette } from "./state";
export interface Mapping {
  origin: number;
  scale: number;
}
export const fixed: Mapping = { origin: 0, scale: 1 };
const phase = (v: number) => Math.sqrt(v) * 0.075 + v * 0.00045;
export function estimateMapping(
  samples: Float32Array,
  w: number,
  h: number,
): Mapping {
  if (w * h !== samples.length || w < 1 || h < 1) return fixed;
  const values: number[] = [],
    cols = Math.min(64, w),
    rows = Math.min(48, h);
  for (let y = 0; y < rows; y++)
    for (let x = 0; x < cols; x++) {
      const n =
        samples[
          Math.floor(((y + 0.5) * h) / rows) * w +
            Math.floor(((x + 0.5) * w) / cols)
        ];
      if (n >= 0 && Number.isFinite(n)) values.push(n);
    }
  if (values.length < 128) return fixed;
  values.sort((a, b) => a - b);
  const lo = values[Math.floor((values.length - 1) * 0.02)],
    hi = values[Math.floor((values.length - 1) * 0.98)];
  const ulp = Math.max(
    2 ** -149,
    2 ** (Math.floor(Math.log2(Math.max(lo, hi))) - 23),
  );
  if (
    hi - lo < 128 * ulp ||
    new Set(
      values.slice(
        Math.floor((values.length - 1) * 0.02),
        Math.floor((values.length - 1) * 0.98) + 1,
      ),
    ).size < 64
  )
    return fixed;
  const lowPhase = phase(lo),
    span = phase(hi) - lowPhase;
  if (!(span > 0 && span < 0.75)) return fixed;
  const blend = Math.min(1, Math.max(0, (0.75 - span) / 0.55)),
    gain = 1 + (0.9 / span - 1) * blend * blend * (3 - 2 * blend);
  return gain > 1.001
    ? { origin: lowPhase + span * 0.5, scale: Math.min(1e6, gain) }
    : fixed;
}
export function smoothMapping(previous: Mapping, next: Mapping): Mapping {
  if (next.scale === 1) return next;
  return {
    origin: next.origin,
    scale: Math.min(
      Math.exp(
        Math.log(previous.scale) +
          (Math.log(next.scale) - Math.log(previous.scale)) * 0.25,
      ),
      previous.scale * 1.8,
      next.scale * 1.5,
    ),
  };
}
const tables = new Map<Palette, Uint8ClampedArray>();
function table(palette: Palette) {
  let t = tables.get(palette);
  if (t) return t;
  t = new Uint8ClampedArray(65536 * 4);
  const stops = palettes[palette];
  for (let i = 0; i < 65536; i++) {
    const p = ((i + 0.5) / 65536) * stops.length,
      b = Math.floor(p),
      v = p - b,
      f = v * v * (3 - 2 * v);
    for (let c = 0; c < 3; c++)
      t[i * 4 + c] = Math.floor(
        stops[b][c] + (stops[(b + 1) % stops.length][c] - stops[b][c]) * f,
      );
    t[i * 4 + 3] = 255;
  }
  tables.set(palette, t);
  return t;
}
export function colorize(
  samples: Float32Array,
  w: number,
  h: number,
  style: Style,
  mapping: Mapping,
): Uint8ClampedArray {
  const bytes = new Uint8ClampedArray(samples.length * 4),
    lut = table(style.palette),
    m = style.adaptive ? mapping : fixed;
  const heights =
    style.relief > 0
      ? Float32Array.from(samples, (v) =>
          v >= 0 && Number.isFinite(v) ? Math.log1p(v) : -1,
        )
      : null;
  for (let i = 0; i < samples.length; i++) {
    const n = samples[i],
      out = i * 4;
    bytes[out + 3] = 255;
    if (n < 0 || !Number.isFinite(n)) {
      bytes[out] = 6;
      bytes[out + 1] = 9;
      bytes[out + 2] = 18;
      continue;
    }
    const original = phase(n),
      adjusted = m.origin + (original - m.origin) * m.scale,
      cycle = adjusted * style.density + style.phase,
      bin =
        Math.min(65535, Math.floor((cycle - Math.floor(cycle)) * 65536)) * 4;
    let brightness = 1;
    if (heights) {
      const center = heights[i],
        x = i % w,
        y = Math.floor(i / w),
        at = (j: number) => (heights[j] >= 0 ? heights[j] : center);
      const dx =
          ((x < w - 1 ? at(i + 1) : center) - (x > 0 ? at(i - 1) : center)) *
          0.5,
        dy =
          ((y < h - 1 ? at(i + w) : center) - (y > 0 ? at(i - w) : center)) *
          0.5;
      if (dx || dy) {
        const sx = (14 * dx) / (1 + 4 * Math.abs(dx)),
          sy = (14 * dy) / (1 + 4 * Math.abs(dy)),
          light = 0.7035623639735145,
          diffuse = Math.max(
            0,
            (0.45 * sx + 0.55 * sy + light) / Math.sqrt(1 + sx * sx + sy * sy),
          );
        brightness = 1 + style.relief * (0.32 + (0.68 * diffuse) / light - 1);
      }
    }
    for (let c = 0; c < 3; c++)
      bytes[out + c] = Math.floor(
        Math.max(0, Math.min(255, lut[bin + c] * brightness)),
      );
  }
  return bytes;
}
