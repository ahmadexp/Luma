export const palettes = {
  aurora: [
    [9, 14, 39],
    [30, 28, 93],
    [105, 57, 154],
    [49, 153, 218],
    [125, 236, 224],
    [249, 238, 172],
    [240, 143, 79],
    [85, 36, 112],
  ],
  ember: [
    [13, 8, 25],
    [65, 18, 58],
    [163, 39, 66],
    [240, 100, 52],
    [255, 190, 101],
    [255, 242, 195],
    [173, 72, 92],
    [45, 17, 55],
  ],
  lagoon: [
    [4, 17, 37],
    [10, 55, 98],
    [13, 126, 159],
    [57, 215, 206],
    [194, 255, 219],
    [228, 236, 159],
    [30, 153, 152],
    [11, 52, 85],
  ],
  violet: [
    [12, 9, 38],
    [42, 25, 91],
    [112, 54, 178],
    [204, 110, 226],
    [255, 203, 230],
    [232, 235, 255],
    [117, 155, 235],
    [47, 36, 109],
  ],
  monochrome: [
    [7, 11, 18],
    [39, 49, 67],
    [105, 123, 144],
    [201, 215, 225],
    [249, 246, 230],
    [142, 153, 164],
    [45, 58, 77],
  ],
} as const;
export type Palette = keyof typeof palettes;
export interface Style {
  palette: Palette;
  phase: number;
  density: number;
  relief: number;
  adaptive: boolean;
}
export interface Camera {
  real: string;
  imag: string;
  span: string;
  bits?: number;
}
export interface Location extends Camera, Style {
  version: 1;
  mode: "mandelbrot" | "julia";
  juliaReal: string;
  juliaImag: string;
  iterations: number;
  quality: "draft" | "balanced" | "fine";
}
export interface Bookmark {
  id: string;
  name: string;
  location: Location;
}
export const initial: Location = {
  version: 1,
  mode: "mandelbrot",
  real: "-0.65",
  imag: "0",
  span: "3.5",
  juliaReal: "-0.8",
  juliaImag: "0.156",
  iterations: 900,
  quality: "balanced",
  palette: "aurora",
  phase: 0,
  density: 1,
  relief: 0,
  adaptive: true,
};
export const places = [
  {
    name: "The whole set",
    description: "Where every journey begins",
    real: "-0.65",
    imag: "0",
    span: "3.5",
  },
  {
    name: "Seahorse Valley",
    description: "Braided filaments and tiny worlds",
    real: "-0.7435",
    imag: "0.1314",
    span: "0.006",
  },
  {
    name: "Spiral garden",
    description: "An intricate, curling coastline",
    real: "-0.743643887037151",
    imag: "0.131825904205330",
    span: "0.000025",
  },
  {
    name: "Elephant Valley",
    description: "Golden trunks on the eastern edge",
    real: "0.273",
    imag: "0.008",
    span: "0.008",
  },
  {
    name: "Deep Julia",
    description: "An embedded world at 10²¹×",
    real: "-1.768667862837488812627419470",
    imag: "0.001645580546820209430325900",
    span: "1.6e-21",
    iterations: 50000,
  },
];
export const julias = [
  { name: "Dragon", real: "-0.8", imag: "0.156" },
  { name: "Dendrite", real: "0", imag: "1" },
  { name: "Spiral", real: "-0.7269", imag: "0.1889" },
  { name: "Galaxy", real: "0.285", imag: "0.01" },
];
const decimal = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d{1,7})?$/;
export function isDecimal(value: unknown): value is string {
  return (
    typeof value === "string" && value.length <= 10000 && decimal.test(value)
  );
}
export function validateLocation(input: unknown): Location {
  if (!input || typeof input !== "object")
    throw Error("Choose a valid Luma location file.");
  const s = input as Record<string, unknown>;
  const v = {
    ...initial,
    ...s,
    phase: s.phase ?? s.colorPhase ?? 0,
    density: s.density ?? s.colorDensity ?? 1,
    adaptive: s.adaptive ?? s.adaptiveColorRange ?? true,
    bits: s.bits ?? s.cameraBits,
  } as Location;
  if (
    v.version !== 1 ||
    !["mandelbrot", "julia"].includes(v.mode) ||
    typeof v.palette !== "string" ||
    !Object.hasOwn(palettes, v.palette) ||
    !["draft", "balanced", "fine"].includes(v.quality)
  )
    throw Error("This location has unsupported settings.");
  if (
    ![v.real, v.imag, v.span, v.juliaReal, v.juliaImag].every(isDecimal) ||
    v.span.startsWith("-") ||
    !/[1-9]/.test(v.span.split(/[eE]/)[0])
  )
    throw Error("The coordinates or view width are invalid.");
  for (const [value, min, max] of [
    [v.iterations, 256, 1000000],
    [v.phase, 0, 1],
    [v.density, 0.2, 3],
    [v.relief, 0, 1],
  ])
    if (!Number.isFinite(value) || value < min || value > max)
      throw Error("A color or detail setting is out of range.");
  if (
    typeof v.adaptive !== "boolean" ||
    (v.bits !== undefined &&
      (!Number.isInteger(v.bits) || v.bits < 128 || v.bits > 2147483647))
  )
    throw Error("Invalid precision or color settings.");
  return {
    version: 1,
    real: v.real,
    imag: v.imag,
    span: v.span,
    bits: v.bits,
    mode: v.mode,
    juliaReal: v.juliaReal,
    juliaImag: v.juliaImag,
    iterations: Math.round(v.iterations),
    quality: v.quality,
    palette: v.palette,
    phase: v.phase,
    density: v.density,
    relief: v.relief,
    adaptive: v.adaptive,
  };
}
export function loadLocation(
  storage: Pick<Storage, "getItem">,
  key: string,
): Location {
  try {
    return validateLocation(JSON.parse(storage.getItem(key) ?? "null"));
  } catch {
    return { ...initial };
  }
}
export function loadBookmarks(
  storage: Pick<Storage, "getItem">,
  key: string,
): Bookmark[] {
  try {
    const items = JSON.parse(storage.getItem(key) ?? "[]");
    if (!Array.isArray(items)) return [];
    return items.slice(0, 100).flatMap((item) => {
      try {
        return [
          {
            id: String(item.id).slice(0, 100),
            name: String(item.name).slice(0, 80),
            location: validateLocation(item.location),
          },
        ];
      } catch {
        return [];
      }
    });
  } catch {
    return [];
  }
}
