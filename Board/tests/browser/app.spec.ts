import { test, expect } from "@playwright/test";
async function ready(page: any) {
  await expect(page.locator("#status")).toHaveText("Ready", { timeout: 45000 });
  await expect(page.locator("#loading")).toBeHidden();
}
test("offline explorer, exact coordinates, Julia portal, colors, history, library and capture", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  const external: string[] = [];
  page.on("request", (r) => {
    if (
      !r.url().startsWith("http://127.0.0.1") &&
      !r.url().startsWith("blob:") &&
      !r.url().startsWith("data:")
    )
      external.push(r.url());
  });
  await page.goto("/");
  await ready(page);
  await page.screenshot({ path: "qa-results/overview.png" });
  await page.locator('[data-place="1"]').click();
  await ready(page);
  await expect(page.locator("#zoom")).not.toHaveText("1×");
  await page.locator('[data-tab="color"]').click();
  await page.locator('[data-palette="ember"]').click();
  await ready(page);
  await expect(page.locator('[data-palette="ember"]')).toHaveClass(/active/);
  await page.locator("#save").click();
  await page.locator('[data-tab="library"]').click();
  await expect(page.locator(".bookmark")).toHaveCount(1);
  await page.reload();
  await ready(page);
  await page.locator('[data-tab="library"]').click();
  await expect(page.locator(".bookmark")).toHaveCount(1);
  const stored = await page.evaluate(() =>
    localStorage.getItem("luma.location.v1"),
  );
  await page.locator("#import-file").setInputFiles({
    name: "bad.json",
    mimeType: "application/json",
    buffer: Buffer.from('{"span":"0"}'),
  });
  await expect(page.locator("#toast")).toContainText("invalid");
  expect(
    await page.evaluate(() => localStorage.getItem("luma.location.v1")),
  ).toBe(stored);
  await page.locator('[data-tab="explore"]').click();
  await page.locator("#portal").click();
  await page.locator("#fractal").click({ position: { x: 500, y: 350 } });
  await ready(page);
  await expect(page.locator("#mode-badge")).toHaveText("JULIA");
  await expect(page.locator("#julia-places")).toBeVisible();
  await page.locator("#back").click();
  await ready(page);
  await expect(page.locator("#mode-badge")).toHaveText("MANDELBROT");
  await page.locator("#capture").click();
  await page.locator("#capture-screen").click();
  await expect(page.locator("#capture-download")).toBeVisible({
    timeout: 45000,
  });
  const size = await page
    .locator("#capture-preview")
    .evaluate((img: HTMLImageElement) => [img.naturalWidth, img.naturalHeight]);
  expect(size[0]).toBe(1540);
  expect(size[1]).toBe(962);
  await page.locator('[data-close="capture-dialog"]').click();
  await page.locator("#coordinates").click();
  await page.locator("#coordinate-real").fill("-2");
  await page.locator("#coordinate-imag").fill("0");
  await page.locator("#coordinate-span").fill("1e-400");
  await page.getByRole("button", { name: "Travel here" }).click();
  await ready(page);
  await expect(page.locator("#metrics")).toContainText("bits");
  const deep = JSON.parse(
    (await page.evaluate(() =>
      localStorage.getItem("luma.location.v1"),
    )) as string,
  );
  expect(deep.bits).toBeGreaterThan(1300);
  expect(Number(deep.span)).toBe(0);
  await page.screenshot({ path: "qa-results/deep.png" });
  expect(errors).toEqual([]);
  expect(external).toEqual([]);
});
test("continuous flight remains responsive, steers, pauses and cancels heavy rendering", async ({
  page,
}) => {
  const frames: any[] = [];
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => {
    if (m.text().startsWith("[Luma frame] "))
      frames.push(JSON.parse(m.text().slice(13)));
  });
  await page.goto("/");
  await ready(page);
  await page.locator('[data-place="1"]').click();
  await ready(page);
  await page.locator("#autopilot").click();
  await expect
    .poll(() => frames.filter((f) => f.flight).length, { timeout: 30000 })
    .toBeGreaterThan(8);
  await expect(page.locator("#reticle")).toBeVisible();
  await page.locator('[data-tab="color"]').click();
  await page.locator('[data-tab="explore"]').click();
  await page.screenshot({ path: "qa-results/autopilot.png" });
  await page.locator("#autopilot").click();
  await ready(page);
  await expect(page.locator("#autopilot")).toHaveAttribute(
    "aria-pressed",
    "false",
  );
  await page.locator('[data-place="4"]').click();
  await page.locator("#home").click();
  await ready(page);
  await expect(page.locator("#zoom")).toHaveText("1×");
  expect(errors).toEqual([]);
});
test("minimum window retains accessible panels and coordinate validation", async ({
  page,
}) => {
  await page.setViewportSize({ width: 980, height: 650 });
  await page.goto("/");
  await ready(page);
  await page.locator("#coordinates").click();
  await page.locator("#coordinate-span").fill("-1");
  await page.getByRole("button", { name: "Travel here" }).click();
  await expect(page.locator("#coordinate-error")).toContainText("invalid");
  await page.locator('[data-close="coordinate-dialog"]').click();
  await page.locator('[data-tab="color"]').click();
  await expect(page.locator("#adaptive")).toBeVisible();
  await page.screenshot({ path: "qa-results/minimum.png" });
});

test("Julia presets, deep destination, and a decoded 4K image", async ({
  page,
}) => {
  test.setTimeout(180000);
  const frames: any[] = [];
  page.on("console", (m) => {
    if (m.text().startsWith("[Luma frame] "))
      frames.push(JSON.parse(m.text().slice(13)));
  });
  await page.goto("/");
  await ready(page);
  await page.locator('[data-mode="julia"]').click();
  await ready(page);
  for (const n of [1, 2, 3]) {
    await page.locator(`[data-julia="${n}"]`).click();
    await ready(page);
    await expect(page.locator("#mode-badge")).toHaveText("JULIA");
  }
  await page.locator("#home").click();
  await ready(page);
  await page.locator('[data-place="4"]').click();
  await ready(page);
  await expect(page.locator("#zoom")).toContainText("10");
  await page.locator("#home").click();
  await ready(page);
  await page.locator("#capture").click();
  await page.locator("#capture-4k").click();
  await expect(page.locator("#capture-preview")).toBeVisible({
    timeout: 120000,
  });
  await expect
    .poll(() =>
      page
        .locator("#capture-preview")
        .evaluate((img: HTMLImageElement) => img.naturalWidth),
    )
    .toBe(3840);
  await page.screenshot({ path: "qa-results/capture-4k.png" });
  console.log("Scene metrics: " + JSON.stringify(frames));
});
