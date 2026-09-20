export interface TouchPoint {
  id: number;
  x: number;
  y: number;
}
export interface Gesture {
  scale: number;
  dx: number;
  dy: number;
  anchorX: number;
  anchorY: number;
}
export class GestureTracker {
  private start: TouchPoint[] = [];
  private last: Gesture = { scale: 1, dx: 0, dy: 0, anchorX: 0, anchorY: 0 };
  reset(points: TouchPoint[]) {
    this.start = points.slice(0, 2).map((p) => ({ ...p }));
    this.last = {
      scale: 1,
      dx: 0,
      dy: 0,
      anchorX: points[0]?.x ?? 0,
      anchorY: points[0]?.y ?? 0,
    };
  }
  update(points: TouchPoint[]): Gesture {
    const active = points.slice(0, 2);
    if (!active.length) return this.last;
    if (
      active.length !== this.start.length ||
      active.some((p, i) => p.id !== this.start[i]?.id)
    ) {
      this.reset(active);
      return this.last;
    }
    const a = this.start[0],
      b = active[0];
    if (active.length === 1)
      this.last = {
        scale: 1,
        dx: b.x - a.x,
        dy: b.y - a.y,
        anchorX: a.x,
        anchorY: a.y,
      };
    else {
      const c = this.start[1],
        d = active[1],
        distance = Math.hypot(c.x - a.x, c.y - a.y);
      this.last = {
        scale: Math.max(
          0.1,
          Math.min(
            10,
            Math.hypot(d.x - b.x, d.y - b.y) / Math.max(1, distance),
          ),
        ),
        dx: (b.x + d.x - a.x - c.x) / 2,
        dy: (b.y + d.y - a.y - c.y) / 2,
        anchorX: (a.x + c.x) / 2,
        anchorY: (a.y + c.y) / 2,
      };
    }
    return this.last;
  }
}
export function rotationDelta(before: number, after: number) {
  return ((after - before + 540) % 360) - 180;
}
