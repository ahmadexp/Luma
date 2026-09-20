import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve, extname, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";
import assert from "node:assert/strict";
const root = resolve(fileURLToPath(new URL("../", import.meta.url)));
const server = createServer(async (req, res) => {
  const pathname = new URL(req.url, "http://localhost").pathname;
  const qa = pathname.startsWith("/qa/"),
    base = qa
      ? resolve(root, "../build/board/device-qa")
      : resolve(root, "dist");
  const relative = pathname.replace(/^\/(qa|app)\//, "") || "index.html";
  const path = resolve(
    base,
    relative.endsWith("/") ? relative + "index.html" : relative,
  );
  if (!path.startsWith(base + sep)) {
    res.writeHead(403);
    res.end();
    return;
  }
  try {
    const bytes = await readFile(path);
    res.setHeader(
      "Content-Type",
      {
        ".html": "text/html",
        ".js": "text/javascript",
        ".css": "text/css",
        ".wasm": "application/wasm",
        ".png": "image/png",
      }[extname(path)] ?? "application/octet-stream",
    );
    res.end(bytes);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = "http://127.0.0.1:" + server.address().port;
const browser = await chromium.launch({ channel: "chrome", headless: true });
try {
  const page = await browser.newPage({
    viewport: { width: 1920, height: 1080 },
  });
  await page.goto(origin + "/app/");
  await page.waitForFunction(
    () => document.getElementById("status")?.textContent === "Ready",
    {},
    { timeout: 45000 },
  );
  await page.locator("#save").click();
  const production = await page.evaluate(() => [
    localStorage.getItem("luma.location.v1"),
    localStorage.getItem("luma.bookmarks.v1"),
  ]);
  assert.ok(production[0] && production[1]);
  await page.goto(origin + "/qa/");
  await page.waitForFunction(
    () => document.getElementById("status")?.textContent === "Ready",
    {},
    { timeout: 45000 },
  );
  await page.locator("#save").click();
  const after = await page.evaluate(() => [
    localStorage.getItem("luma.location.v1"),
    localStorage.getItem("luma.bookmarks.v1"),
  ]);
  assert.deepEqual(after, production);
  const qa = await page.evaluate(() => [
    localStorage.getItem("luma.qa.location.v1"),
    JSON.parse(localStorage.getItem("luma.qa.bookmarks.v1") ?? "[]").length,
  ]);
  assert.ok(qa[0]);
  assert.equal(qa[1], 1);
  console.log(
    "Shared-origin QA storage isolation and subdirectory Wasm loading: passed",
  );
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
