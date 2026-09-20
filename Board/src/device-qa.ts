import { Board, type BoardContact } from "@board.fun/web-sdk";
import type { Location } from "./state";
type Harness = {
  locationKey: string;
  contacts: (c: ReadonlyArray<BoardContact>) => void;
  read: () => Location;
  suspend: () => void;
};
const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const $ = (id: string) => document.getElementById(id)!;
const click = (selector: string) =>
  (document.querySelector(selector) as HTMLElement).click();
const assert = (test: unknown, message: string) => {
  if (!test) throw Error(message);
};
async function until(test: () => boolean, label: string, timeout = 60000) {
  const start = performance.now();
  while (!test()) {
    if (performance.now() - start > timeout) throw Error("Timed out: " + label);
    await wait(100);
  }
}
const ready = () =>
  until(() => $("status").textContent === "Ready", "render ready");
export async function runDeviceQA(harness: Harness) {
  const report = (data: unknown) =>
    console.log("[Luma QA report] " + JSON.stringify(data));
  const results: unknown[] = [],
    frames: unknown[] = [],
    errors: string[] = [];
  const original = console.info.bind(console);
  console.info = (...args) => {
    if (typeof args[0] === "string" && args[0].startsWith("[Luma frame] "))
      frames.push(JSON.parse(args[0].slice(13)));
    if (String(args[0]).startsWith("[Luma")) report({ log: args[0] });
    original(...args);
  };
  window.addEventListener("error", (e) => errors.push(e.message));
  window.addEventListener("unhandledrejection", (e) =>
    errors.push(String(e.reason)),
  );
  const badge = document.createElement("div");
  badge.style.cssText =
    "position:fixed;bottom:45px;right:400px;padding:12px 20px;background:#152839;color:#b4fff4;border:1px solid #73e5d5;border-radius:12px;z-index:100;pointer-events:none;font:14px sans-serif";
  document.body.append(badge);
  const stage = async (name: string, run: () => Promise<void>) => {
    badge.textContent = "Luma QA · " + name;
    report({ stage: name, started: true });
    const t = performance.now();
    try {
      await run();
      const result = {
        name,
        pass: true,
        ms: Math.round(performance.now() - t),
      };
      results.push(result);
      original("[Luma QA] " + JSON.stringify(result));
      report(result);
    } catch (e) {
      const result = { name, pass: false, error: String(e) };
      results.push(result);
      original("[Luma QA] " + JSON.stringify(result));
      report(result);
      throw e;
    }
  };
  report({
    visibility: document.visibilityState,
    wakeLockAvailable: "wakeLock" in navigator,
  });
  if (document.hidden) {
    badge.textContent = "Luma QA · Waiting for the display to wake";
    await new Promise<void>((resolve) => {
      const onVisible = () => {
        if (!document.hidden) {
          document.removeEventListener("visibilitychange", onVisible);
          resolve();
        }
      };
      document.addEventListener("visibilitychange", onVisible);
    });
  }
  try {
    await stage("device startup", async () => {
      assert(Board.isOnDevice, "Expected Board native bridge");
      await ready();
      await until(() => Board.input.isSubscribed, "touch bridge");
      assert($("fractal").clientWidth > 900, "Unexpected viewport");
    });
    for (const n of [1, 2, 3])
      await stage("destination " + n, async () => {
        click(`[data-place="${n}"]`);
        await ready();
      });
    await stage("Julia worlds", async () => {
      click('[data-mode="julia"]');
      await ready();
      for (const n of [1, 2, 3]) {
        click(`[data-julia="${n}"]`);
        await ready();
      }
      assert(harness.read().mode === "julia", "Julia mode was lost");
    });
    await stage("exact deep coordinates", async () => {
      click('[data-mode="mandelbrot"]');
      await ready();
      click('[data-detail="2000"]');
      await ready();
      click("#coordinates");
      for (const [key, value] of [
        ["real", "-2"],
        ["imag", "0"],
        ["span", "1e-400"],
      ])
        ($("coordinate-" + key) as HTMLInputElement).value = value;
      ($("coordinate-form") as HTMLFormElement).requestSubmit();
      await ready();
      assert((harness.read().bits ?? 0) > 1300, "Precision did not grow");
      assert(Number(harness.read().span) === 0, "Lost deep exponent");
      click("#zoom-in");
      await ready();
      assert(harness.read().span.includes("e-401"), "Deep zoom camera stopped");
    });
    await stage(
      "finger gestures and Piece controls (injected contacts)",
      async () => {
        click("#home");
        await ready();
        Board.input.unsubscribe(harness.contacts);
        try {
          const r = $("fractal").getBoundingClientRect();
          const finger = (id: number, x: number, y: number): BoardContact => ({
            contactId: id,
            x: r.left + x,
            y: r.top + y,
            type: 0,
            phase: 2,
            glyphId: 0,
            isTouched: true,
            orientation: 0,
          });
          const before = harness.read().real;
          harness.contacts([finger(9101, 400, 400)]);
          harness.contacts([finger(9101, 500, 430)]);
          harness.contacts([]);
          await ready();
          assert(harness.read().real !== before, "Finger drag did not pan");
          const span = Number(harness.read().span);
          harness.contacts([finger(9102, 400, 400), finger(9103, 600, 400)]);
          harness.contacts([finger(9102, 300, 400), finger(9103, 700, 400)]);
          harness.contacts([]);
          await ready();
          assert(
            Math.abs(Number(harness.read().span) / span - 0.5) < 1e-10,
            "Pinch did not halve span",
          );
          const p = {
            ...finger(9200, 650, 420),
            glyphId: 1,
            type: 1,
            orientation: 359,
          };
          harness.contacts([p]);
          assert(!$("reticle").hidden, "Piece marker is hidden");
          const pieceSpan = Number(harness.read().span);
          harness.contacts([{ ...p, orientation: 14 }]);
          await wait(150);
          await ready();
          assert(
            Number(harness.read().span) < pieceSpan,
            "Touched Piece rotation did not zoom",
          );
          harness.contacts([]);
          assert($("reticle").hidden, "Removed Piece left a marker");
          const button = $("zoom-in").getBoundingClientRect(),
            center = {
              ...finger(9300, 0, 0),
              x: button.x + button.width / 2,
              y: button.y + button.height / 2,
            };
          const tapSpan = Number(harness.read().span);
          harness.contacts([center]);
          harness.contacts([]);
          await ready();
          assert(
            Number(harness.read().span) < tapSpan,
            "Board button tap failed",
          );
        } finally {
          harness.contacts([]);
          Board.input.subscribe(harness.contacts);
        }
      },
    );
    await stage("colors and saved views", async () => {
      click('[data-tab="color"]');
      click('[data-palette="lagoon"]');
      await ready();
      const slider = $("relief") as HTMLInputElement;
      slider.value = ".7";
      slider.dispatchEvent(new Event("input"));
      await ready();
      click("#save");
      await wait(500);
      click('[data-tab="library"]');
      assert(
        document.querySelectorAll(".bookmark").length > 0,
        "Local bookmark missing",
      );
      assert(
        JSON.parse(localStorage.getItem(harness.locationKey)!).palette ===
          "lagoon",
        "Palette persistence failed",
      );
      click('[data-tab="explore"]');
    });
    await stage("120 second autopilot soak", async () => {
      click('[data-place="1"]');
      await ready();
      const startFrames = frames.length,
        zoom = harness.read().span;
      let previous = performance.now();
      const gaps: number[] = [];
      const timer = setInterval(() => {
        const now = performance.now();
        gaps.push(now - previous);
        previous = now;
      }, 50);
      click("#autopilot");
      await wait(120000);
      clearInterval(timer);
      assert(
        $("autopilot").getAttribute("aria-pressed") === "true",
        "Autopilot stopped",
      );
      assert(frames.length - startFrames >= 20, "Too few flight frames");
      assert(harness.read().span !== zoom, "Autopilot did not move");
      gaps.sort((a, b) => a - b);
      original(
        "[Luma QA performance] " +
          JSON.stringify({
            frames: frames.length - startFrames,
            timerGapP95: gaps[Math.floor(gaps.length * 0.95)],
            timerGapMax: Math.max(...gaps),
          }),
      );
      assert(
        gaps[Math.floor(gaps.length * 0.95)] < 150,
        "Interface frequently stalled",
      );
      click("#autopilot");
      await ready();
    });
    await stage("4K capture and cancellation", async () => {
      click("#home");
      await ready();
      click("#capture");
      click("#capture-4k");
      await until(() => !$("capture-preview").hidden, "4K capture", 120000);
      const img = $("capture-preview") as HTMLImageElement;
      await until(() => img.naturalWidth > 0, "PNG decode");
      assert(img.naturalWidth === 3840, "Incorrect capture width");
      click('[data-close="capture-dialog"]');
      click('[data-place="4"]');
      await wait(100);
      click("#home");
      await ready();
      assert(
        Number(harness.read().span) === 3.5,
        "Canceled frame replaced home",
      );
    });
    await stage("lifecycle resume and persistence", async () => {
      const before = harness.read();
      harness.suspend();
      assert(
        $("autopilot").getAttribute("aria-pressed") === "false",
        "Flight survived suspend",
      );
      assert(
        JSON.parse(localStorage.getItem(harness.locationKey)!).span ===
          before.span,
        "Session save failed",
      );
      document.dispatchEvent(new Event("visibilitychange"));
      await ready();
      assert(errors.length === 0, "Unhandled errors: " + errors.join("; "));
    });
    report({
      complete: true,
      pass: true,
      results,
      frames,
      errors,
      servicesReady: Board.session.areServicesReady(),
      touchSubscribed: Board.input.isSubscribed,
      userAgent: navigator.userAgent,
    });
    original(
      "[Luma QA COMPLETE] " +
        JSON.stringify({
          pass: true,
          results,
          frames,
          errors,
          servicesReady: Board.session.areServicesReady(),
          touchSubscribed: Board.input.isSubscribed,
          userAgent: navigator.userAgent,
          screen: [screen.width, screen.height],
          viewport: [innerWidth, innerHeight],
        }),
    );
    click('[data-place="1"]');
    await ready();
    badge.textContent =
      "Luma QA passed · Physical touch and Piece check remains";
  } catch (e) {
    report({
      complete: true,
      pass: false,
      results,
      errors,
      error: String(e),
      frames,
    });
    original(
      "[Luma QA COMPLETE] " +
        JSON.stringify({
          pass: false,
          results,
          errors,
          error: String(e),
          frames,
        }),
    );
    badge.textContent = "Luma QA failed · " + String(e);
    badge.style.background = "#5e2222";
  }
}
