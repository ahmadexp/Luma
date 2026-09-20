export interface Point {
  x: number;
  y: number;
}
export function findTarget(
  field: Float32Array,
  width: number,
  height: number,
  previous: Point | null = null,
): Point | null {
  const cols = Math.min(72, width),
    rows = Math.min(48, height),
    n = cols * rows,
    heights = new Float64Array(n),
    escaped = new Uint8Array(n);
  const values: number[] = [];
  for (let y = 0; y < rows; y++)
    for (let x = 0; x < cols; x++) {
      const i = y * cols + x,
        v =
          field[
            Math.min(height - 1, Math.floor(((y + 0.5) * height) / rows)) *
              width +
              Math.min(width - 1, Math.floor(((x + 0.5) * width) / cols))
          ];
      if (v >= 0 && Number.isFinite(v)) {
        escaped[i] = 1;
        heights[i] = Math.log1p(v);
        values.push(heights[i]);
      }
    }
  values.sort((a, b) => a - b);
  const low = values[Math.floor(values.length * 0.01)] ?? 0,
    high = values[Math.floor(values.length * 0.99)] ?? low,
    range = high - low;
  if (!values.length) return null;
  if (range > 1.5e-5 && new Set(values).size >= 64)
    for (let i = 0; i < n; i++)
      heights[i] = Math.max(-0.5, Math.min(1.5, (heights[i] - low) / range));
  else heights.fill(0);
  const signals = new Float64Array(n);
  let best = 0,
    target: Point | null = null;
  for (let y = 1; y < rows - 1; y++)
    for (let x = 1; x < cols - 1; x++) {
      const i = y * cols + x;
      let edge = 0,
        lap = 0;
      for (const j of [i - 1, i + 1, i - cols, i + cols]) {
        edge += Math.abs(escaped[i] - escaped[j]);
        lap += escaped[j] - escaped[i];
        if (escaped[i] && escaped[j]) {
          edge += Math.abs(heights[i] - heights[j]);
          lap += heights[j] - heights[i];
        }
      }
      signals[i] = Math.min(1, edge) * Math.min(1, Math.abs(lap) * 2);
    }
  for (let y = 5; y < rows - 5; y += 2)
    for (let x = 5; x < cols - 5; x += 2) {
      let sum = 0,
        support = 0;
      for (let dy = -4; dy <= 4; dy++)
        for (let dx = -4; dx <= 4; dx++) {
          const s = signals[(y + dy) * cols + x + dx];
          sum += s;
          if (s > 0.06) support++;
        }
      if (support < 12) continue;
      const px = (x + 0.5) / cols - 0.5,
        py = 0.5 - (y + 0.5) / rows,
        rank =
          (sum / 81) *
          (previous
            ? 1 +
              0.2 *
                Math.exp(
                  -((px - previous.x) ** 2 + (py - previous.y) ** 2) / 0.025,
                )
            : 1);
      if (rank > best) {
        best = rank;
        let strongest = -1,
          bx = x,
          by = y;
        for (let dy = -3; dy <= 3; dy++)
          for (let dx = -3; dx <= 3; dx++) {
            const score =
              signals[(y + dy) * cols + x + dx] /
              (1 + 0.04 * (dx * dx + dy * dy));
            if (score > strongest) {
              strongest = score;
              bx = x + dx;
              by = y + dy;
            }
          }
        target = { x: (bx + 0.5) / cols - 0.5, y: 0.5 - (by + 0.5) / rows };
      }
    }
  return best > 0.055 ? target : null;
}
