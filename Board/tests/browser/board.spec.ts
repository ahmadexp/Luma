import { test, expect } from "@playwright/test";
async function ready(page: any) {
  await expect(page.locator("#status")).toHaveText("Ready", { timeout: 45000 });
}
test("Board bridge drives controls, captured fingers, pinch, Piece rotation and late startup", async ({
  page,
}) => {
  await page.addInitScript(() => {
    (window as any).BoardSDK = {
      areServicesReady: () => false,
      setPauseContext: () => {},
      getPlayers: () => JSON.stringify([]),
    };
    setTimeout(() => {
      (window as any).boardTouch = { onmessage: null, postMessage: () => {} };
    }, 300);
  });
  await page.goto("/");
  await ready(page);
  await expect
    .poll(() =>
      page.evaluate(() => typeof (window as any).boardTouch.onmessage),
    )
    .toBe("function");
  const frame = async (c: any[]) =>
    page.evaluate(
      (c) =>
        (window as any).boardTouch.onmessage({ data: JSON.stringify({ c }) }),
      c,
    );
  const c = (
    id: number,
    x: number,
    y: number,
    p = 2,
    g = 0,
    o = 0,
    touched = 1,
  ) => ({ id, x, y, p, g, o, t: g ? 1 : 0, touched });
  const r = (await page.locator("#fractal").boundingBox())!;
  const view = () =>
    page.evaluate(() => JSON.parse(localStorage.getItem("luma.location.v1")!));
  let before = await view();
  await frame([c(1, r.x + 300, r.y + 350, 1)]);
  await frame([c(1, r.x + 450, r.y + 380)]);
  await frame([c(1, r.x + 450, r.y + 380, 3)]);
  await ready(page);
  expect((await view()).real).not.toBe(before.real);
  before = await view();
  await frame([c(2, r.x + 400, r.y + 400, 1), c(3, r.x + 600, r.y + 400, 1)]);
  await frame([c(2, r.x + 300, r.y + 400), c(3, r.x + 700, r.y + 400)]);
  await frame([c(2, r.x + 300, r.y + 400, 3), c(3, r.x + 700, r.y + 400, 3)]);
  await ready(page);
  expect(Number((await view()).span) / Number(before.span)).toBeCloseTo(
    0.5,
    10,
  );
  await frame([c(4, r.x + 500, r.y + 350, 1, 1, 359)]);
  await expect(page.locator("#reticle")).toBeVisible();
  before = await view();
  await frame([c(4, r.x + 500, r.y + 350, 2, 1, 14)]);
  await page.waitForTimeout(150);
  await ready(page);
  expect(Number((await view()).span)).toBeLessThan(Number(before.span));
  await frame([c(4, r.x + 500, r.y + 350, 3, 1, 14)]);
  await expect(page.locator("#reticle")).toBeHidden();
  // A Piece not touched by a hand must not zoom.
  before = await view();
  await frame([c(5, r.x + 600, r.y + 350, 1, 2, 0, 0)]);
  await frame([c(5, r.x + 600, r.y + 350, 2, 2, 90, 0)]);
  await frame([c(5, r.x + 600, r.y + 350, 3, 2, 90, 0)]);
  await page.waitForTimeout(200);
  expect((await view()).span).toBe(before.span);
  const button = (await page.locator("#zoom-in").boundingBox())!;
  before = await view();
  await frame([c(6, button.x + 20, button.y + 20, 1)]);
  await frame([c(6, button.x + 20, button.y + 20, 3)]);
  await ready(page);
  expect(Number((await view()).span) / Number(before.span)).toBeCloseTo(
    0.5,
    10,
  );
  before = await view();
  await frame([{ ...c(9, r.x + 600, r.y + 300, 1), t: 2 }]);
  await frame([{ ...c(9, r.x + 800, r.y + 300, 2), t: 2 }]);
  await frame([{ ...c(9, r.x + 800, r.y + 300, 3), t: 2 }]);
  expect((await view()).span).toBe(before.span);
  expect((await view()).real).toBe(before.real);
  await page.evaluate(() =>
    (window as any).__board.onPauseResult(JSON.stringify({ action: "resume" })),
  );
  await ready(page);
  await expect(page.locator("#board-saves")).toBeHidden();
  await page.locator('[data-tab="library"]').click();
  await expect(page.locator("#board-saves")).toBeVisible();
  await page.locator("#board-saves").click();
  await expect(page.locator("#board-save-status")).toContainText("unavailable");
});
test("rapid palette changes preserve the latest choice while rendering", async ({
  page,
}) => {
  await page.goto("/");
  await ready(page);
  await page.locator('[data-tab="color"]').click();
  await page.evaluate(() => {
    for (const name of ["ember", "violet", "lagoon"])
      (
        document.querySelector(`[data-palette="${name}"]`) as HTMLElement
      ).click();
  });
  await ready(page);
  await expect
    .poll(() =>
      page.evaluate(
        () => JSON.parse(localStorage.getItem("luma.location.v1")!).palette,
      ),
    )
    .toBe("lagoon");
  await expect(page.locator('[data-palette="lagoon"]')).toHaveClass(/active/);
});
