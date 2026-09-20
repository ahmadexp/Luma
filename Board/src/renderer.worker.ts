import {
  colorize,
  estimateMapping,
  smoothMapping,
  type Mapping,
} from "./color";
import { findTarget, type Point } from "./planner";
import { type Location, type Style } from "./state";
interface Module {
  ccall: (
    name: string,
    result: string | null,
    types: string[],
    values: unknown[],
  ) => any;
  _malloc: (n: number) => number;
  _free: (p: number) => void;
  HEAPF32: Float32Array;
  UTF8ToString: (p: number) => string;
}
export interface Mutation {
  kind: "zoom" | "pan";
  factor?: number;
  x: number;
  y: number;
  aspect: number;
}
export interface RenderRequest {
  id: number;
  kind: "render";
  moduleURL: string;
  location: Location;
  width: number;
  height: number;
  mutations?: Mutation[];
  mapping?: Mapping;
  previousTarget?: Point | null;
  flight?: boolean;
  portal?: boolean;
}
export interface Frame {
  id: number;
  kind: "frame";
  location: Location;
  width: number;
  height: number;
  pixels: Uint8ClampedArray;
  mapping: Mapping;
  target: Point | null;
  milliseconds: number;
  heapBytes: number;
  zoom: number;
  precision: number;
}
let engine: Module | null = null,
  engineURL = "",
  viewport = 0,
  control = 0,
  field: Float32Array | null = null,
  width = 0,
  height = 0,
  current: Frame | null = null;
async function render(request: RenderRequest) {
  if (!engine) {
    engineURL = request.moduleURL;
    const imported = await import(/* @vite-ignore */ engineURL);
    engine = await imported.default();
  }
  const m = engine!,
    call = (name: string, types: string[] = [], args: unknown[] = []) =>
      m.ccall(name, "number", types, args);
  if (viewport) call("mb_viewport_destroy", ["number"], [viewport]);
  viewport = call("mb_viewport_create");
  if (!viewport) throw Error("Could not allocate the precision camera.");
  let loc = request.location;
  const valid = loc.bits
    ? call(
        "mb_viewport_restore",
        ["number", "string", "string", "string", "number"],
        [viewport, loc.real, loc.imag, loc.span, loc.bits],
      )
    : call(
        "mb_viewport_set",
        ["number", "string", "string", "string"],
        [viewport, loc.real, loc.imag, loc.span],
      );
  if (valid !== 1)
    throw Error(
      "This location exceeds the available precision or has invalid coordinates.",
    );
  for (const action of request.mutations ?? [])
    if (action.kind === "zoom")
      call(
        "mb_viewport_zoom",
        ["number", "number", "number", "number", "number"],
        [viewport, action.factor, action.x, action.y, action.aspect],
      );
    else
      call(
        "mb_viewport_pan",
        ["number", "number", "number", "number"],
        [viewport, action.x, action.y, action.aspect],
      );
  const text = call("mb_viewport_describe", ["number"], [viewport]);
  if (!text) throw Error("Could not read the precision camera.");
  let camera = JSON.parse(m.UTF8ToString(text));
  call("mb_string_free", ["number"], [text]);
  if (request.portal) {
    loc = {
      ...loc,
      mode: "julia",
      juliaReal: camera.real,
      juliaImag: camera.imag,
    };
    call(
      "mb_viewport_set",
      ["number", "string", "string", "string"],
      [viewport, "0", "0", "3.5"],
    );
    const p = call("mb_viewport_describe", ["number"], [viewport]);
    camera = JSON.parse(m.UTF8ToString(p));
    call("mb_string_free", ["number"], [p]);
  }
  if (!control) control = call("mb_render_control_create");
  width = request.width;
  height = request.height;
  const count = width * height,
    pointer = m._malloc(count * 4);
  if (!pointer)
    throw Error("Not enough memory for this image. Choose Draft quality.");
  const started = performance.now();
  try {
    const result =
      loc.mode === "julia"
        ? call(
            "mb_render_julia",
            [
              "number",
              "string",
              "string",
              "number",
              "number",
              "number",
              "number",
              "number",
            ],
            [
              viewport,
              loc.juliaReal,
              loc.juliaImag,
              width,
              height,
              loc.iterations,
              pointer,
              control,
            ],
          )
        : call(
            "mb_render",
            ["number", "number", "number", "number", "number", "number"],
            [viewport, width, height, loc.iterations, pointer, control],
          );
    if (result !== 1)
      throw Error("Rendering failed. Try a lower detail setting.");
    field = m.HEAPF32.slice(pointer / 4, pointer / 4 + count);
  } finally {
    m._free(pointer);
  }
  const estimate = estimateMapping(field, width, height),
    mapping =
      request.flight && request.mapping
        ? smoothMapping(request.mapping, estimate)
        : estimate;
  const pixels = colorize(field, width, height, loc, mapping);
  const frame: Frame = {
    kind: "frame",
    id: request.id,
    location: { ...loc, ...camera },
    width,
    height,
    pixels,
    mapping,
    target: findTarget(field, width, height, request.previousTarget),
    milliseconds: performance.now() - started,
    heapBytes: m.HEAPF32.buffer.byteLength,
    zoom: call("mb_viewport_log_zoom", ["number"], [viewport]),
    precision: call("mb_viewport_precision", ["number"], [viewport]),
  };
  current = { ...frame, pixels: new Uint8ClampedArray(0) };
  postMessage(frame, { transfer: [pixels.buffer] });
}
let queue = Promise.resolve();
onmessage = (
  event: MessageEvent<
    RenderRequest | { id: number; kind: "recolor"; style: Style }
  >,
) => {
  const message = event.data;
  queue = queue
    .then(async () => {
      if (message.kind === "render") await render(message);
      else if (field && current) {
        const pixels = colorize(
          field,
          width,
          height,
          message.style,
          current.mapping,
        );
        const frame = {
          ...current,
          id: message.id,
          location: { ...current.location, ...message.style },
          pixels,
        };
        current = { ...frame, pixels: new Uint8ClampedArray(0) };
        postMessage(frame, { transfer: [pixels.buffer] });
      }
    })
    .catch((error) =>
      postMessage({
        kind: "error",
        id: message.id,
        message: error instanceof Error ? error.message : String(error),
      }),
    );
};
