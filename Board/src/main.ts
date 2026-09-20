import "./styles.css";
import { Board, type BoardContact } from "@board.fun/web-sdk";
import {
  initial,
  places,
  julias,
  palettes,
  validateLocation,
  loadLocation,
  loadBookmarks,
  type Location,
  type Bookmark,
  type Palette,
} from "./state";
import {
  GestureTracker,
  rotationDelta,
  type Gesture,
  type TouchPoint,
} from "./input";
import type { Frame, Mutation, RenderRequest } from "./renderer.worker";
import type { Point } from "./planner";

const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;
let storage: Pick<Storage, "getItem" | "setItem">;
try {
  storage = window.localStorage;
} catch {
  storage = {
    getItem: () => null,
    setItem: () => {
      throw Error("Storage unavailable");
    },
  };
}
let location = loadLocation(storage, "luma.location.v1"),
  bookmarks = loadBookmarks(storage, "luma.bookmarks.v1");
let history: Location[] = [],
  worker: Worker | null = null,
  serial = 0,
  activeId = 0,
  busy = false,
  watchdog = 0;
let displayed: Frame | null = null,
  image: HTMLCanvasElement | null = null,
  pending: Mutation[] = [],
  portal = false;
let flight = false,
  flightSpeed = 1,
  flightPixels = 180000,
  recoveries = 0,
  queued: Frame | null = null,
  flightAction: Mutation | null = null;
let transition: {
  old: HTMLCanvasElement;
  next: HTMLCanvasElement;
  start: number;
  duration: number;
  action: Mutation;
} | null = null;
let colorCycle = false,
  lastCycle = 0,
  colorDirty = false,
  picking = false,
  exportWorker: Worker | null = null,
  exportTimer = 0;
let gesture: Gesture | null = null,
  gestureTracker = new GestureTracker(),
  gesturePoints: TouchPoint[] = [],
  piece: Point | null = null;
let lastTap = { time: 0, x: 0, y: 0 },
  toastTimer = 0,
  saveWarning = false,
  hasField = false,
  raf = 0;
const moduleURL = new URL("./wasm/luma.js", document.baseURI).href,
  startedAt = Date.now();
let previewURL = "";

$("app").innerHTML = `
<header><div class="brand"><img src="./icon.png" alt=""><div><strong>LUMA</strong><small>WORLDS WITHIN WORLDS</small></div></div>
<div class="header-actions"><span id="status" role="status">Preparing the precision engine</span><button id="save" title="Save this location">＋ Save view</button><button id="capture">Capture</button><button id="autopilot" class="primary" aria-pressed="false">▶ Autopilot</button></div></header>
<main><section class="viewport" aria-label="Fractal explorer"><canvas id="fractal" tabindex="0" aria-label="Fractal view. Drag to pan, pinch or scroll to zoom."></canvas>
<div class="navigation"><button id="back" aria-label="Previous view">‹</button><button id="home" aria-label="Whole set">⌂</button><button id="zoom-out" aria-label="Zoom out">−</button><button id="zoom-in" aria-label="Zoom in">＋</button></div>
<div class="mode-badge" id="mode-badge">MANDELBROT</div><div class="magnification"><span class="eyebrow">Magnification</span><strong id="zoom">1×</strong></div><div id="reticle" class="reticle" hidden></div><div id="pick-hint" hidden>Touch a point to open its Julia world</div><div id="loading"><strong>A world is taking shape</strong><span>Loading Luma’s precision engine</span></div></section>
<aside><nav class="tabs" aria-label="Explorer panels"><button class="active" data-tab="explore" aria-selected="true">Explore</button><button data-tab="color" aria-selected="false">Color</button><button data-tab="library" aria-selected="false">Library</button></nav>
<section class="panel" id="panel-explore"><h2>Follow your curiosity.</h2><p class="subline">Every coastline holds another world.</p><div class="choice-row" id="modes"><button data-mode="mandelbrot">Mandelbrot</button><button data-mode="julia">Julia</button></div>
<div class="section" id="destinations"><div class="eyebrow">Somewhere to begin</div>${places.map((p, i) => `<button class="place" data-place="${i}"><strong>${p.name}</strong><small>${p.description}</small></button>`).join("")}</div>
<div class="section" id="julia-places" hidden><div class="eyebrow">Julia worlds</div><div class="choice-row">${julias.map((p, i) => `<button data-julia="${i}">${p.name}</button>`).join("")}</div></div>
<div class="section"><button id="portal" class="wide">Open a Julia portal</button><button id="coordinates" class="wide" style="margin-top:9px">Exact coordinates</button></div>
<div class="section"><div class="eyebrow">Rendering</div><div class="field-label"><span>Detail</span><output id="detail-value"></output></div><div class="choice-row" id="detail">${[900, 2000, 8000, 50000].map((n) => `<button data-detail="${n}">${n >= 1000 ? n / 1000 + "k" : n}</button>`).join("")}</div><div class="field-label">Image quality</div><div class="choice-row" id="qualities">${["draft", "balanced", "fine"].map((q) => `<button data-quality="${q}">${q[0].toUpperCase() + q.slice(1)}</button>`).join("")}</div><label class="field-label" for="speed">Flight speed <output id="speed-value">1.0×</output></label><input id="speed" type="range" min="0.4" max="2" step="0.1" value="1"><p class="explanation">Autopilot follows textured edges and adjusts its image size to keep moving. Place a Piece to steer; turn it while touching it to zoom.</p></div></section>
<section class="panel" id="panel-color" hidden><h2>Light, your way.</h2><p class="subline">Color that stays alive as you go deeper.</p><div class="eyebrow" style="margin-bottom:18px">Palette</div><div class="palettes">${Object.entries(
  palettes,
)
  .map(
    ([name, stops]) =>
      `<button class="swatch" data-palette="${name}" aria-label="${name}" title="${name}" style="background:linear-gradient(135deg,${stops
        .filter((_, i) => i % 2 === 0)
        .map((c) => `rgb(${c.join(",")})`)
        .join(",")})"></button>`,
  )
  .join("")}</div>
${[
  ["phase", "Color phase", 0, 1, 0.005],
  ["density", "Color density", 0.2, 3, 0.05],
  ["relief", "Sculpted relief", 0, 1, 0.05],
]
  .map(
    ([key, label, min, max, step]) =>
      `<label class="field-label" for="${key}">${label}<output id="${key}-value"></output></label><input id="${key}" type="range" min="${min}" max="${max}" step="${step}">`,
  )
  .join("")}
<div class="section"><label class="toggle" for="adaptive">Adaptive color range<input id="adaptive" type="checkbox"></label><p class="explanation">Keeps subtle differences visible at deep magnifications, without amplifying a flat image.</p><label class="toggle" for="cycle">Animate colors<input id="cycle" type="checkbox"></label></div></section>
<section class="panel" id="panel-library" hidden><h2>Keep the discovery.</h2><p class="subline">Exact coordinates, every digit preserved.</p><div class="library-actions"><button id="save-library" class="primary">＋ Save current view</button><button id="export-location">Export location</button><button id="import-location">Import location</button><button id="board-saves" hidden>Board saved views</button></div><div id="bookmarks"></div><p id="empty-library" class="explanation">Save a place and find your way back here.</p></section></aside></main>
<footer class="footer"><span class="help-text" id="help">Drag to explore · Pinch or scroll to zoom · Space for autopilot</span><span id="metrics">Arbitrary precision</span><button id="about">By Ahmad Byagowi · About Luma</button></footer>
<div id="toast" role="status" hidden></div><input id="import-file" type="file" accept=".json,application/json" hidden>
<dialog id="coordinate-dialog"><h2>Exact coordinates</h2><p>Decimal coordinates stay precise far beyond ordinary floating point.</p><form id="coordinate-form">${[
  ["real", "Center real"],
  ["imag", "Center imaginary"],
  ["span", "View width"],
  ["juliaReal", "Julia parameter real"],
  ["juliaImag", "Julia parameter imaginary"],
]
  .map(
    ([id, label]) =>
      `<label class="coordinate-${id}">${label}<input type="text" id="coordinate-${id}" autocomplete="off" spellcheck="false" maxlength="10000" inputmode="decimal"></label>`,
  )
  .join(
    "",
  )}<div id="keypad" class="keypad">${["7", "8", "9", "4", "5", "6", "⌫", "1", "2", "3", "0", ".", "−", "e"].map((v) => `<button type="button" data-key="${v}">${v}</button>`).join("")}</div><p id="coordinate-error" class="dialog-error" role="alert"></p><div class="dialog-actions"><button type="button" data-close="coordinate-dialog">Cancel</button><button type="submit" class="primary">Travel here</button></div></form></dialog>
<dialog id="about-dialog"><h2>Luma for Board</h2><p class="credit">Created by Ahmad Byagowi</p><p>A tactile explorer for Mandelbrot and Julia worlds. Drag and pinch with your fingers. Place a recognized Board Piece to choose the zoom focus, then turn it while touching it. Autopilot follows intricate boundaries.</p><p>The MPFR precision camera, perturbation renderer, series approximation and bilinear acceleration run locally in a WebAssembly worker. Precision grows with depth, subject to the device’s memory and time.</p><p>Version 1.0.0-rc.1 · Offline after installation.<br>Uses GMP 6.3.0, MPFR 4.2.2 and the Board Web SDK.</p><p><a href="./licenses/THIRD_PARTY.txt" target="_blank" rel="noopener">Third-party licenses and source</a></p><div class="dialog-actions"><button data-close="about-dialog" class="primary">Keep exploring</button></div></dialog>
<dialog id="capture-dialog"><h2>A window into infinity.</h2><p id="capture-description">Choose a capture size. Rendering stays in the background.</p><img id="capture-preview" alt="Captured fractal" hidden><div class="dialog-actions"><button data-close="capture-dialog">Close</button><button id="capture-screen">Screen size</button><button id="capture-4k" class="primary">4K image</button><button id="capture-download" hidden>Download PNG</button></div></dialog>
<dialog id="board-save-dialog"><h2>Board saved views</h2><p id="board-save-status"></p><div id="board-save-list"></div><div class="dialog-actions"><button data-close="board-save-dialog">Close</button></div></dialog>`;

const canvas = $<HTMLCanvasElement>("fractal"),
  ctx = canvas.getContext("2d", { alpha: false })!;
const rect = () => canvas.getBoundingClientRect();
const aspect = () => rect().height / rect().width;
function toast(message: string) {
  $("toast").textContent = message;
  $("toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => ($("toast").hidden = true), 4500);
}
function persist() {
  try {
    storage.setItem("luma.location.v1", JSON.stringify(location));
    storage.setItem("luma.bookmarks.v1", JSON.stringify(bookmarks));
  } catch {
    if (!saveWarning) {
      toast("Local storage is unavailable. Export a location to keep it.");
      saveWarning = true;
    }
  }
}
function checkpoint() {
  history.push({ ...location });
  if (history.length > 80) history.shift();
}
function sync() {
  document
    .querySelectorAll<HTMLElement>("[data-mode]")
    .forEach((b) =>
      b.classList.toggle("active", b.dataset.mode === location.mode),
    );
  document.querySelectorAll<HTMLElement>("[data-palette]").forEach((b) => {
    b.classList.toggle("active", b.dataset.palette === location.palette);
    b.setAttribute(
      "aria-pressed",
      String(b.dataset.palette === location.palette),
    );
  });
  document
    .querySelectorAll<HTMLElement>("[data-detail]")
    .forEach((b) =>
      b.classList.toggle(
        "active",
        Number(b.dataset.detail) === location.iterations,
      ),
    );
  document
    .querySelectorAll<HTMLElement>("[data-quality]")
    .forEach((b) =>
      b.classList.toggle("active", b.dataset.quality === location.quality),
    );
  for (const key of ["phase", "density", "relief"] as const) {
    $<HTMLInputElement>(key).value = String(location[key]);
    $(key + "-value").textContent = location[key].toFixed(2);
  }
  $<HTMLInputElement>("adaptive").checked = location.adaptive;
  $<HTMLInputElement>("cycle").checked = colorCycle;
  $("detail-value").textContent =
    location.iterations.toLocaleString() + " iterations";
  $("mode-badge").textContent = location.mode.toUpperCase();
  $("julia-places").hidden = location.mode !== "julia";
  $("destinations").hidden = location.mode === "julia";
  $("portal").hidden = location.mode === "julia";
  $("autopilot").textContent = flight ? "Ⅱ Pause" : "▶ Autopilot";
  $("autopilot").setAttribute("aria-pressed", String(flight));
  $<HTMLButtonElement>("back").disabled = history.length === 0;
  $("pick-hint").hidden = !picking;
}
function showLibrary() {
  $("bookmarks").replaceChildren();
  $("empty-library").hidden = bookmarks.length > 0;
  for (const b of bookmarks) {
    const row = document.createElement("div");
    row.className = "bookmark";
    const open = document.createElement("button");
    open.className = "place";
    const name = document.createElement("strong");
    name.textContent = b.name;
    const desc = document.createElement("small");
    desc.textContent =
      (b.location.mode === "julia" ? "Julia" : "Mandelbrot") +
      " · " +
      b.location.palette;
    open.append(name, desc);
    open.onclick = () => travel(b.location);
    const remove = document.createElement("button");
    remove.className = "remove";
    remove.textContent = "×";
    remove.setAttribute("aria-label", "Delete " + b.name);
    remove.onclick = () => {
      bookmarks = bookmarks.filter((x) => x.id !== b.id);
      persist();
      showLibrary();
    };
    row.append(open, remove);
    $("bookmarks").append(row);
  }
}
function setStatus(message: string) {
  $("status").textContent = message;
}
function resetWorker() {
  if (worker) worker.terminate();
  worker = null;
  hasField = false;
  busy = false;
  activeId = ++serial;
  clearTimeout(watchdog);
}
function newWorker() {
  const w = new Worker(new URL("./renderer.worker.ts", import.meta.url), {
    type: "module",
  });
  w.onmessage = (e) => receive(e.data);
  w.onerror = () =>
    fail(
      "The rendering worker stopped. Try Draft quality or a lower detail setting.",
    );
  return w;
}
function dimensions() {
  const r = rect(),
    budget = flight
      ? flightPixels
      : { draft: 180000, balanced: 600000, fine: 1500000 }[location.quality];
  const scale = Math.min(
    devicePixelRatio || 1,
    Math.sqrt(budget / (r.width * r.height)),
  );
  return {
    width: Math.max(48, Math.round(r.width * scale)),
    height: Math.max(32, Math.round(r.height * scale)),
  };
}
function render(mutations: Mutation[] = pending) {
  if (document.hidden) return;
  if (busy) resetWorker();
  worker ??= newWorker();
  const id = ++serial;
  activeId = id;
  busy = true;
  hasField = false;
  const request: RenderRequest = {
    kind: "render",
    id,
    moduleURL,
    location: { ...location },
    ...dimensions(),
    mutations: [...mutations],
    portal,
    mapping: displayed?.mapping,
    previousTarget: displayed?.target,
    flight,
  };
  worker.postMessage(request);
  setStatus(flight ? "Following the detail…" : "Rendering…");
  clearTimeout(watchdog);
  watchdog = window.setTimeout(
    () => {
      resetWorker();
      if (flight) {
        flightPixels = Math.max(40000, flightPixels * 0.65);
        recoveries++;
        if (recoveries >= 4) {
          stopFlight();
          toast("This region needs more time. Autopilot is paused.");
        } else {
          flightAction = {
            kind: "zoom",
            factor: 1.6,
            x: 0,
            y: 0,
            aspect: aspect(),
          };
          render([flightAction]);
        }
      } else {
        pending = [];
        portal = false;
        setStatus("Render paused");
        $("loading").hidden = true;
        if (displayed) {
          location = { ...displayed.location };
          sync();
          persist();
        }
        toast(
          "This view needs more time. Choose lower detail or Draft quality, or try another location.",
        );
      }
    },
    flight ? 7000 : 45000,
  );
}
function fail(message: string) {
  resetWorker();
  stopFlight();
  pending = [];
  portal = false;
  if (displayed) {
    location = { ...displayed.location };
    sync();
    persist();
  }
  setStatus("Could not render");
  $("loading").hidden = true;
  toast(message);
  console.error("[Luma] " + message);
}
function frameCanvas(frame: Frame) {
  const c = document.createElement("canvas");
  c.width = frame.width;
  c.height = frame.height;
  c.getContext("2d")!.putImageData(
    new ImageData(frame.pixels, frame.width, frame.height),
    0,
    0,
  );
  return c;
}
function receive(
  message: Frame | { kind: "error"; id: number; message: string },
) {
  if (message.id !== activeId) return;
  clearTimeout(watchdog);
  busy = false;
  if (message.kind === "error") {
    fail(message.message);
    return;
  }
  hasField = true;
  pending = [];
  portal = false;
  for (const key of [
    "palette",
    "phase",
    "density",
    "relief",
    "adaptive",
  ] as const)
    if (message.location[key] !== location[key]) colorDirty = true;
  message.location = {
    ...message.location,
    palette: location.palette,
    phase: location.phase,
    density: location.density,
    relief: location.relief,
    adaptive: location.adaptive,
  };
  if (flight && transition) {
    queued = message;
    return;
  }
  publish(message, flightAction);
  flightAction = null;
  if (flight) nextFlight();
  else if (colorDirty) recolor();
}
function publish(frame: Frame, action: Mutation | null) {
  const next = frameCanvas(frame);
  if (flight && image && action) {
    transition = {
      old: image,
      next,
      start: performance.now(),
      duration: Math.max(
        600 / flightSpeed,
        Math.min(3000, frame.milliseconds * 1.25),
      ),
      action,
    };
  }
  image = next;
  displayed = { ...frame, pixels: new Uint8ClampedArray(0) };
  location = { ...frame.location };
  $("loading").hidden = true;
  const z = frame.zoom;
  $("zoom").textContent =
    z < 6
      ? (10 ** z).toLocaleString(undefined, { maximumFractionDigits: 1 }) + "×"
      : "10" + superscript(z.toFixed(1)) + "×";
  $("metrics").textContent =
    `${frame.precision.toLocaleString()} bits · ${frame.width} × ${frame.height} · ${Math.round(frame.milliseconds)} ms`;
  setStatus(flight ? "Exploring" : "Ready");
  sync();
  persist();
  draw();
  console.info(
    "[Luma frame] " +
      JSON.stringify({
        mode: location.mode,
        width: frame.width,
        height: frame.height,
        ms: Math.round(frame.milliseconds),
        heapBytes: frame.heapBytes,
        bits: frame.precision,
        logZoom: frame.zoom,
        target: !!frame.target,
        flight,
      }),
  );
}
function superscript(s: string) {
  return [...s]
    .map(
      (c) => "⁰¹²³⁴⁵⁶⁷⁸⁹"[Number(c)] ?? (c === "." ? "·" : c === "-" ? "⁻" : c),
    )
    .join("");
}
function draw() {
  const r = rect(),
    dpr = Math.min(2, devicePixelRatio || 1),
    w = Math.max(1, Math.round(r.width * dpr)),
    h = Math.max(1, Math.round(r.height * dpr));
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = "#060912";
  ctx.fillRect(0, 0, r.width, r.height);
  const drawImage = (
    img: HTMLCanvasElement,
    scale = 1,
    x = 0,
    y = 0,
    alpha = 1,
  ) => {
    ctx.globalAlpha = alpha;
    ctx.drawImage(img, x, y, r.width * scale, r.height * scale);
    ctx.globalAlpha = 1;
  };
  if (transition) {
    const t = Math.min(
        1,
        (performance.now() - transition.start) / transition.duration,
      ),
      f = transition.action.factor ?? 1,
      ax = transition.action.x,
      ay = transition.action.y,
      k = f ** t;
    drawImage(
      transition.old,
      1 / k,
      r.width * (0.5 - (0.5 + (1 - k) * ax) / k),
      r.height * (0.5 + (-0.5 + (1 - k) * ay) / k),
    );
    const fade = t * t * (3 - 2 * t);
    drawImage(
      transition.next,
      f / k,
      r.width * (0.5 + ((k - f) * ax - 0.5 * f) / k),
      r.height * (0.5 + (-(k - f) * ay - 0.5 * f) / k),
      fade,
    );
    if (t === 1) {
      transition = null;
      if (queued) {
        const frame = queued;
        queued = null;
        publish(frame, flightAction);
        flightAction = null;
        if (flight) nextFlight();
      }
    }
  } else if (image) {
    if (gesture)
      drawImage(
        image,
        gesture.scale,
        gesture.anchorX * (1 - gesture.scale) + gesture.dx,
        gesture.anchorY * (1 - gesture.scale) + gesture.dy,
      );
    else drawImage(image);
  }
  updateMarker();
}
function updateMarker() {
  const r = rect();
  const target = piece ?? (flight ? displayed?.target : null);
  $("reticle").hidden = !target;
  if (target) {
    $("reticle").style.left = (target.x + 0.5) * r.width + "px";
    $("reticle").style.top = (0.5 - target.y) * r.height + "px";
  }
}
function animate(now: number) {
  if (transition || gesture) draw();
  if (colorCycle && !flight && !busy && now - lastCycle > 90) {
    location.phase = (location.phase + 0.006) % 1;
    lastCycle = now;
    recolor();
  }
  raf = requestAnimationFrame(animate);
}
function stopFlight() {
  const wasFlight = flight;
  flight = false;
  queued = null;
  transition = null;
  flightAction = null;
  if (wasFlight) {
    if (busy) resetWorker();
    hasField = false;
  }
  sync();
  draw();
}
function nextFlight() {
  if (!flight || busy || queued || document.hidden) return;
  if (displayed) {
    const desired = 900 / flightSpeed;
    flightPixels = Math.max(
      40000,
      Math.min(
        500000,
        flightPixels *
          Math.max(
            0.65,
            Math.min(1.2, desired / Math.max(1, displayed.milliseconds)),
          ),
      ),
    );
  }
  const target = piece ?? displayed?.target;
  if (target) recoveries = 0;
  else recoveries++;
  if (recoveries > 7) {
    location = {
      ...location,
      ...places[1],
      mode: "mandelbrot",
      bits: undefined,
    };
    recoveries = 0;
    flightAction = null;
    render([]);
    return;
  }
  flightAction = {
    kind: "zoom",
    factor: target ? 0.78 : 1.6,
    x: target?.x ?? 0,
    y: target?.y ?? 0,
    aspect: aspect(),
  };
  render([flightAction]);
}
function toggleFlight() {
  if (flight) {
    stopFlight();
    render([]);
    return;
  }
  checkpoint();
  picking = false;
  colorCycle = false;
  pending = [];
  if (busy) resetWorker();
  flight = true;
  recoveries = 0;
  sync();
  nextFlight();
}
function travel(next: Location) {
  stopFlight();
  checkpoint();
  location = validateLocation(next);
  pending = [];
  picking = false;
  sync();
  render([]);
}
function navigate(action: Mutation) {
  if (flight) stopFlight();
  if (!pending.length) checkpoint();
  pending.push(action);
  render();
}
function zoom(factor: number, point: Point = piece ?? { x: 0, y: 0 }) {
  navigate({ kind: "zoom", factor, x: point.x, y: point.y, aspect: aspect() });
}
function recolor() {
  colorDirty = true;
  if (flight) {
    stopFlight();
    render([]);
    return;
  }
  if (busy) return;
  if (!hasField || !worker) {
    colorDirty = false;
    render([]);
    return;
  }
  colorDirty = false;
  busy = true;
  activeId = ++serial;
  worker.postMessage({
    kind: "recolor",
    id: activeId,
    style: {
      palette: location.palette,
      phase: location.phase,
      density: location.density,
      relief: location.relief,
      adaptive: location.adaptive,
    },
  });
  sync();
}
function stopForDialog() {
  if (flight) stopFlight();
  colorCycle = false;
  sync();
}
function openDialog(id: string) {
  stopForDialog();
  $<HTMLDialogElement>(id).showModal();
}
function closeDialog(id: string) {
  $<HTMLDialogElement>(id).close();
  if (id === "capture-dialog") cancelCapture();
}
function changeTab(tab: string) {
  for (const name of ["explore", "color", "library"])
    $("panel-" + name).hidden = tab !== name;
  document.querySelectorAll<HTMLElement>("[data-tab]").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === tab);
    b.setAttribute("aria-selected", String(b.dataset.tab === tab));
  });
}
function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob),
    a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
async function saveView() {
  if (bookmarks.length >= 100) {
    toast("Your library has 100 views. Remove one before saving another.");
    return;
  }
  const saved = { ...location };
  bookmarks.push({
    id: crypto.randomUUID(),
    name: "Discovery " + (bookmarks.length + 1),
    location: saved,
  });
  persist();
  showLibrary();
  toast("Exact location saved to your library.");
  if (Board.isOnDevice && Board.session.areServicesReady())
    try {
      await Board.save.create(
        "Luma discovery",
        new TextEncoder().encode(JSON.stringify(saved)),
        Date.now() - startedAt,
        "1.0.0-rc.1",
      );
    } catch {
      toast("Saved locally. Board profile storage was unavailable.");
    }
}

$("autopilot").onclick = toggleFlight;
$("save").onclick = saveView;
$("save-library").onclick = saveView;
$("back").onclick = () => {
  const previous = history.pop();
  if (previous) {
    stopFlight();
    location = previous;
    pending = [];
    sync();
    render([]);
  }
};
$("home").onclick = () =>
  travel({
    ...location,
    ...initial,
    bits: undefined,
    palette: location.palette,
    phase: location.phase,
    relief: location.relief,
    adaptive: location.adaptive,
  });
$("zoom-in").onclick = () => zoom(0.5);
$("zoom-out").onclick = () => zoom(2);
$("portal").onclick = () => {
  stopFlight();
  picking = !picking;
  sync();
};
$("about").onclick = () => openDialog("about-dialog");
$("capture").onclick = () => openDialog("capture-dialog");
$("capture-screen").onclick = () => capture(false);
$("capture-4k").onclick = () => capture(true);
$("capture-download").onclick = () => {
  if (previewURL) {
    const a = document.createElement("a");
    a.href = previewURL;
    a.download = "Luma.png";
    a.click();
  }
};
$("export-location").onclick = () =>
  download(
    new Blob([JSON.stringify(location, null, 2)], { type: "application/json" }),
    "Luma-location.json",
  );
$("import-location").onclick = () => {
  stopForDialog();
  $<HTMLInputElement>("import-file").click();
};
$("import-file").onchange = async () => {
  const input = $<HTMLInputElement>("import-file"),
    file = input.files?.[0];
  if (!file) return;
  try {
    if (file.size > 200000) throw Error("This location file is too large.");
    const next = validateLocation(JSON.parse(await file.text()));
    travel(next);
    toast("Location imported.");
  } catch (e) {
    toast(e instanceof Error ? e.message : "Could not read this location.");
  } finally {
    input.value = "";
  }
};
$("speed").oninput = () => {
  flightSpeed = Number($<HTMLInputElement>("speed").value);
  $("speed-value").textContent = flightSpeed.toFixed(1) + "×";
};
for (const key of ["phase", "density", "relief"] as const)
  $(key).oninput = () => {
    location[key] = Number($<HTMLInputElement>(key).value);
    $(key + "-value").textContent = location[key].toFixed(2);
    recolor();
  };
$("adaptive").onchange = () => {
  location.adaptive = $<HTMLInputElement>("adaptive").checked;
  recolor();
};
$("cycle").onchange = () => {
  colorCycle = $<HTMLInputElement>("cycle").checked;
  if (flight) stopFlight();
};
document.addEventListener("click", (event) => {
  const b = (event.target as Element).closest<HTMLElement>("button");
  if (!b) return;
  if (b.dataset.tab) changeTab(b.dataset.tab);
  if (b.dataset.close) closeDialog(b.dataset.close);
  if (b.dataset.place)
    travel({
      ...location,
      ...places[Number(b.dataset.place)],
      mode: "mandelbrot",
      bits: undefined,
      iterations:
        places[Number(b.dataset.place)].iterations ??
        Math.min(location.iterations, 8000),
    });
  if (b.dataset.julia) {
    const p = julias[Number(b.dataset.julia)];
    travel({
      ...location,
      mode: "julia",
      real: "0",
      imag: "0",
      span: "3.5",
      bits: undefined,
      juliaReal: p.real,
      juliaImag: p.imag,
      iterations: Math.min(location.iterations, 8000),
    });
  }
  if (b.dataset.mode && b.dataset.mode !== location.mode)
    travel({
      ...location,
      mode: b.dataset.mode as Location["mode"],
      real: b.dataset.mode === "julia" ? "0" : "-0.65",
      imag: "0",
      span: "3.5",
      bits: undefined,
    });
  if (b.dataset.detail) {
    location.iterations = Number(b.dataset.detail);
    if (flight) stopFlight();
    sync();
    render();
  }
  if (b.dataset.quality) {
    location.quality = b.dataset.quality as Location["quality"];
    if (flight) stopFlight();
    sync();
    render();
  }
  if (b.dataset.palette) {
    location.palette = b.dataset.palette as Palette;
    sync();
    recolor();
  }
});
let activeCoordinate: HTMLInputElement | null = null;
$("coordinates").onclick = () => {
  for (const key of [
    "real",
    "imag",
    "span",
    "juliaReal",
    "juliaImag",
  ] as const) {
    $<HTMLInputElement>("coordinate-" + key).value = location[key];
    document.querySelector<HTMLElement>(".coordinate-" + key)!.hidden =
      key.startsWith("julia") && location.mode !== "julia";
  }
  $("coordinate-error").textContent = "";
  openDialog("coordinate-dialog");
  activeCoordinate = $<HTMLInputElement>("coordinate-real");
};
$("coordinate-form").addEventListener("focusin", (e) => {
  if (e.target instanceof HTMLInputElement) activeCoordinate = e.target;
});
$("keypad").onclick = (e) => {
  const b = (e.target as Element).closest<HTMLElement>("[data-key]");
  if (!b || !activeCoordinate) return;
  const input = activeCoordinate,
    key = b.dataset.key!,
    start = input.selectionStart ?? input.value.length,
    end = input.selectionEnd ?? start;
  if (key === "⌫") {
    input.value =
      input.value.slice(0, start === end ? Math.max(0, start - 1) : start) +
      input.value.slice(end);
    input.focus();
    input.setSelectionRange(Math.max(0, start - 1), Math.max(0, start - 1));
  } else {
    const char = key === "−" ? "-" : key;
    input.value = input.value.slice(0, start) + char + input.value.slice(end);
    input.focus();
    input.setSelectionRange(start + 1, start + 1);
  }
};
$("coordinate-form").onsubmit = (e) => {
  e.preventDefault();
  try {
    const next = { ...location, bits: undefined };
    for (const key of [
      "real",
      "imag",
      "span",
      "juliaReal",
      "juliaImag",
    ] as const)
      next[key] = $<HTMLInputElement>("coordinate-" + key).value.trim();
    const valid = validateLocation(next);
    closeDialog("coordinate-dialog");
    travel(valid);
  } catch (error) {
    $("coordinate-error").textContent =
      error instanceof Error ? error.message : "Invalid coordinates.";
  }
};

function localPoint(x: number, y: number) {
  const r = rect();
  return { x: x - r.left, y: y - r.top };
}
function touchPoints(points: TouchPoint[]) {
  const previous = gesturePoints;
  if (!points.length && !previous.length) return;
  if (
    points.length !== previous.length ||
    points.some((p, i) => p.id !== previous[i]?.id)
  ) {
    if (gesture) commitGesture();
    if (points.length) {
      if (flight) stopFlight();
      gestureTracker.reset(points);
      gesture = gestureTracker.update(points);
    } else gesture = null;
  } else if (points.length) gesture = gestureTracker.update(points);
  gesturePoints = points;
  draw();
}
function commitGesture() {
  if (!gesture) return;
  const g = gesture;
  gesture = null;
  if (Math.abs(g.scale - 1) < 0.002 && Math.hypot(g.dx, g.dy) < 2) return;
  const r = rect();
  if (!pending.length) checkpoint();
  if (Math.abs(g.scale - 1) >= 0.002)
    pending.push({
      kind: "zoom",
      factor: 1 / g.scale,
      x: g.anchorX / r.width - 0.5,
      y: 0.5 - g.anchorY / r.height,
      aspect: aspect(),
    });
  if (Math.hypot(g.dx, g.dy) >= 2)
    pending.push({
      kind: "pan",
      x: -g.dx / r.width,
      y: g.dy / r.height,
      aspect: aspect(),
    });
  render();
}
function tap(x: number, y: number) {
  const p = localPoint(x, y),
    r = rect();
  if (picking) {
    checkpoint();
    picking = false;
    portal = true;
    pending = [
      {
        kind: "pan",
        x: p.x / r.width - 0.5,
        y: 0.5 - p.y / r.height,
        aspect: aspect(),
      },
    ];
    sync();
    render();
    return;
  }
  const now = performance.now();
  if (
    now - lastTap.time < 350 &&
    Math.hypot(x - lastTap.x, y - lastTap.y) < 35
  ) {
    zoom(0.4, { x: p.x / r.width - 0.5, y: 0.5 - p.y / r.height });
    lastTap.time = 0;
  } else lastTap = { time: now, x, y };
}
const pointers = new Map<
  number,
  { point: TouchPoint; startX: number; startY: number; distance: number }
>();
canvas.addEventListener("pointerdown", (e) => {
  if (Board.isOnDevice || e.button > 0) return;
  e.preventDefault();
  canvas.setPointerCapture(e.pointerId);
  const p = localPoint(e.clientX, e.clientY);
  if (pointers.size) for (const p of pointers.values()) p.distance = Infinity;
  pointers.set(e.pointerId, {
    point: { id: e.pointerId, ...p },
    startX: e.clientX,
    startY: e.clientY,
    distance: pointers.size ? Infinity : 0,
  });
  touchPoints([...pointers.values()].map((v) => v.point));
});
canvas.addEventListener("pointermove", (e) => {
  const p = pointers.get(e.pointerId);
  if (!p) return;
  p.point = { id: e.pointerId, ...localPoint(e.clientX, e.clientY) };
  p.distance = Math.max(
    p.distance,
    Math.hypot(e.clientX - p.startX, e.clientY - p.startY),
  );
  touchPoints([...pointers.values()].map((v) => v.point));
});
function pointerEnd(e: PointerEvent) {
  const p = pointers.get(e.pointerId);
  if (!p) return;
  const wasSingle = pointers.size === 1;
  pointers.delete(e.pointerId);
  touchPoints([...pointers.values()].map((v) => v.point));
  if (e.type === "pointerup" && wasSingle && p.distance < 8)
    tap(e.clientX, e.clientY);
}
canvas.addEventListener("pointerup", pointerEnd);
canvas.addEventListener("pointercancel", pointerEnd);
canvas.addEventListener("lostpointercapture", pointerEnd);
let wheelTimer = 0,
  wheelFactor = 1,
  wheelAnchor: Point = { x: 0, y: 0 };
canvas.addEventListener(
  "wheel",
  (e) => {
    if (Board.isOnDevice) return;
    e.preventDefault();
    const r = rect();
    wheelAnchor = {
      x: (e.clientX - r.left) / r.width - 0.5,
      y: 0.5 - (e.clientY - r.top) / r.height,
    };
    wheelFactor *= Math.exp(Math.max(-100, Math.min(100, e.deltaY)) * 0.003);
    clearTimeout(wheelTimer);
    wheelTimer = window.setTimeout(() => {
      zoom(wheelFactor, wheelAnchor);
      wheelFactor = 1;
    }, 80);
  },
  { passive: false },
);
document.addEventListener("keydown", (e) => {
  if (
    e.target instanceof HTMLInputElement ||
    document.querySelector("dialog[open]")
  )
    return;
  if (e.key === " ") {
    e.preventDefault();
    toggleFlight();
  }
  if (e.key === "+" || e.key === "=") zoom(0.5);
  if (e.key === "-") zoom(2);
  if (e.key === "Escape") {
    stopFlight();
    resetWorker();
    pending = [];
    picking = false;
    colorCycle = false;
    sync();
    setStatus("Paused");
  }
  if (e.key === "h") $("home").click();
});

function cancelCapture() {
  exportWorker?.terminate();
  exportWorker = null;
  clearTimeout(exportTimer);
  $("capture-screen").removeAttribute("disabled");
  $("capture-4k").removeAttribute("disabled");
}
function capture(full: boolean) {
  cancelCapture();
  const width = full ? 3840 : Math.round(rect().width),
    height = Math.round(width * aspect());
  const w = (exportWorker = new Worker(
    new URL("./renderer.worker.ts", import.meta.url),
    { type: "module" },
  ));
  $("capture-description").textContent =
    `Rendering ${width} × ${height}. Close this window to cancel.`;
  $("capture-screen").setAttribute("disabled", "");
  $("capture-4k").setAttribute("disabled", "");
  w.onmessage = (e) => {
    if (w !== exportWorker) return;
    const frame = e.data as Frame | { kind: "error"; message: string };
    if (frame.kind === "error") {
      toast(frame.message);
      cancelCapture();
      return;
    }
    const c = frameCanvas(frame);
    c.toBlob((blob) => {
      if (!blob || w !== exportWorker) return;
      if (previewURL) URL.revokeObjectURL(previewURL);
      previewURL = URL.createObjectURL(blob);
      $<HTMLImageElement>("capture-preview").src = previewURL;
      $("capture-preview").hidden = false;
      $("capture-download").hidden = Board.isOnDevice;
      $("capture-description").textContent = Board.isOnDevice
        ? `${width} × ${height} preview. Save a view in Library to keep its exact coordinates.`
        : `${width} × ${height} PNG, ready to download.`;
      cancelCapture();
    }, "image/png");
  };
  w.onerror = () => {
    toast("Capture could not finish. Try screen size or lower detail.");
    cancelCapture();
  };
  w.postMessage({
    kind: "render",
    id: 1,
    moduleURL,
    location: { ...location },
    width,
    height,
  } satisfies RenderRequest);
  exportTimer = window.setTimeout(() => {
    cancelCapture();
    $("capture-description").textContent =
      "Capture paused after two minutes. Try screen size or lower detail.";
  }, 120000);
}

// Board sends whole active-contact snapshots; contacts that disappear must be released.
type OwnedContact = {
  x: number;
  y: number;
  startX: number;
  startY: number;
  distance: number;
  target: HTMLElement;
  canvas: boolean;
  orientation: number;
  glyph: number;
};
const owned = new Map<number, OwnedContact>();
let pieceRotation = 0,
  pieceTimer = 0;
function boardContacts(contacts: ReadonlyArray<BoardContact>) {
  if (document.hidden) return;
  const active = new Set(contacts.map((c) => c.contactId));
  let foundPiece = false;
  for (const c of contacts) {
    if (c.glyphId === 0 && c.type !== 0) continue;
    let p = owned.get(c.contactId);
    if (!p) {
      const target = document.elementFromPoint(c.x, c.y) as HTMLElement | null;
      if (!target) continue;
      p = {
        x: c.x,
        y: c.y,
        startX: c.x,
        startY: c.y,
        distance: 0,
        target,
        canvas: target === canvas,
        orientation: c.orientation,
        glyph: c.glyphId,
      };
      owned.set(c.contactId, p);
    }
    const dy = c.y - p.y;
    p.distance = Math.max(
      p.distance,
      Math.hypot(c.x - p.startX, c.y - p.startY),
    );
    if (c.glyphId > 0) {
      if (p.canvas) {
        const r = rect();
        piece = {
          x: Math.max(-0.48, Math.min(0.48, (c.x - r.left) / r.width - 0.5)),
          y: Math.max(-0.48, Math.min(0.48, 0.5 - (c.y - r.top) / r.height)),
        };
        foundPiece = true;
        if (c.isTouched) {
          const delta = rotationDelta(p.orientation, c.orientation);
          if (Math.abs(delta) > 0.05 && Math.abs(delta) < 45) {
            pieceRotation += delta;
            clearTimeout(pieceTimer);
            const focus = { ...piece };
            pieceTimer = window.setTimeout(() => {
              if (Math.abs(pieceRotation) > 1) {
                zoom(Math.exp(-pieceRotation * 0.018), focus);
                pieceRotation = 0;
              }
            }, 100);
          }
        }
      }
    } else if (
      p.target instanceof HTMLInputElement &&
      p.target.type === "range"
    ) {
      const r = p.target.getBoundingClientRect();
      const oldValue = p.target.value;
      p.target.value = String(
        Number(p.target.min) +
          (Number(p.target.max) - Number(p.target.min)) *
            Math.max(0, Math.min(1, (c.x - r.left) / r.width)),
      );
      if (p.target.value !== oldValue)
        p.target.dispatchEvent(new Event("input", { bubbles: true }));
    } else if (!p.canvas && p.distance > 12) {
      const panel = p.target.closest<HTMLElement>(".panel,dialog");
      if (panel) panel.scrollTop -= dy;
    }
    p.x = c.x;
    p.y = c.y;
    p.orientation = c.orientation;
  }
  for (const [id, p] of owned)
    if (!active.has(id)) {
      owned.delete(id);
      if (p.glyph === 0 && p.distance < 12) {
        if (p.canvas) tap(p.x, p.y);
        else {
          const target = p.target.closest<HTMLElement>("button,input,a");
          if (target instanceof HTMLInputElement && target.type === "text") {
            target.focus();
            target.setSelectionRange(target.value.length, target.value.length);
          } else target?.click();
        }
      }
    }
  if ([...owned.values()].filter((p) => p.canvas && p.glyph === 0).length > 1)
    for (const p of owned.values())
      if (p.canvas && p.glyph === 0) p.distance = Infinity;
  if (!foundPiece) piece = null;
  touchPoints(
    [...owned.entries()]
      .filter(([, p]) => p.canvas && p.glyph === 0)
      .map(([id, p]) => ({ id, ...localPoint(p.x, p.y) })),
  );
  updateMarker();
}
async function listBoardSaves() {
  openDialog("board-save-dialog");
  $("board-save-list").replaceChildren();
  if (!Board.isOnDevice || !Board.session.areServicesReady()) {
    $("board-save-status").textContent =
      "Board profile storage is unavailable. Your local library is still available.";
    return;
  }
  $("board-save-status").textContent = "Loading saved views…";
  try {
    const saves = await Board.save.list();
    $("board-save-status").textContent = saves.length
      ? "Choose a view to restore."
      : "No Board saved views yet.";
    for (const save of saves) {
      const b = document.createElement("button");
      b.className = "place";
      b.textContent =
        save.description + " · " + new Date(save.updatedAt).toLocaleString();
      b.onclick = async () => {
        b.disabled = true;
        try {
          const data = await Board.save.load(save.id);
          const next = validateLocation(
            JSON.parse(new TextDecoder().decode(data)),
          );
          closeDialog("board-save-dialog");
          travel(next);
        } catch {
          toast("This saved view could not be opened.");
        } finally {
          b.disabled = false;
        }
      };
      $("board-save-list").append(b);
    }
  } catch {
    $("board-save-status").textContent =
      "Could not access Board saved views. Try again after signing in.";
  }
}
$("board-saves").onclick = listBoardSaves;
let boardReady = false;
let screenLock: WakeLockSentinel | null = null;
async function keepScreenAwake() {
  if (Board.isOnDevice && !document.hidden && "wakeLock" in navigator)
    try {
      screenLock = await navigator.wakeLock.request("screen");
    } catch {
      /* The host can decline a screen lock. */
    }
}
function connectBoard(attempt = 0) {
  if (!Board.isOnDevice) {
    if (attempt < 80) setTimeout(() => connectBoard(attempt + 1), 50);
    return;
  }
  if (!boardReady) {
    boardReady = true;
    void keepScreenAwake();
    document.body.classList.add("on-board");
    $("board-saves").hidden = false;
    $("help").textContent =
      "Pinch to explore · Place a Piece to steer · Touch and turn it to zoom";
    try {
      Board.pause.setContext({
        gameName: "Luma",
        offerSaveOption: true,
        customButtons: [
          { id: "home", title: "Whole set", icon: "circulararrow" },
        ],
      });
      Board.pause.onResult(async (result) => {
        stopFlight();
        resetWorker();
        persist();
        if (result.action === "save_and_quit") {
          try {
            if (Board.session.areServicesReady())
              await Board.save.create(
                "Luma last view",
                new TextEncoder().encode(JSON.stringify(location)),
                Date.now() - startedAt,
                "1.0.0-rc.1",
              );
            Board.application.quit();
          } catch {
            toast(
              "Board save failed. Your last view is saved on this device; try Save & Quit again.",
            );
          }
        } else if (result.action === "resume") {
          void keepScreenAwake();
          render([]);
        } else if (result.action === "quit") Board.application.quit();
        else if (
          result.action === "custom_button" &&
          result.customButtonId === "home"
        )
          $("home").click();
      });
    } catch (error) {
      console.warn("[Luma] Pause integration unavailable", String(error));
    }
  }
  if ((window as unknown as { boardTouch?: unknown }).boardTouch) {
    Board.input.subscribe(boardContacts);
    console.info("[Luma] Board touch connected");
  } else if (attempt < 80) setTimeout(() => connectBoard(attempt + 1), 50);
  else toast("Board touch is unavailable. Relaunch Luma from the launcher.");
}
function suspend() {
  if (screenLock) {
    void screenLock.release().catch(() => {});
    screenLock = null;
  }
  stopFlight();
  resetWorker();
  colorCycle = false;
  pending = [];
  cancelCapture();
  pointers.clear();
  owned.clear();
  gesture = null;
  gesturePoints = [];
  piece = null;
  clearTimeout(pieceTimer);
  pieceRotation = 0;
  clearTimeout(wheelTimer);
  wheelFactor = 1;
  persist();
  cancelAnimationFrame(raf);
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden) suspend();
  else {
    void keepScreenAwake();
    raf = requestAnimationFrame(animate);
    render([]);
  }
});
window.addEventListener("pagehide", suspend);
let resizeTimer = 0;
new ResizeObserver(() => {
  draw();
  clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(() => {
    if (image && !flight && !gesture) render();
  }, 200);
}).observe(canvas);
showLibrary();
sync();
connectBoard();
render([]);
raf = requestAnimationFrame(animate);
console.info("[Luma] Started 1.0.0-rc.1");

if (import.meta.env.VITE_DEVICE_QA === "1")
  void import("./device-qa").then((m) =>
    m.runDeviceQA({
      contacts: boardContacts,
      read: () => ({ ...location }),
      suspend,
    }),
  );
