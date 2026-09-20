import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
const file = process.argv[2] ?? "luma-board.webapp.zip";
const members = execFileSync("unzip", ["-Z1", file], { encoding: "utf8" })
  .trim()
  .split("\n");
for (const name of [
  "index.html",
  "harness-config.json",
  "model.tflite",
  "wasm/luma.js",
  "wasm/luma.wasm",
  "icon.png",
  "licenses/THIRD_PARTY.txt",
])
  if (!members.includes(name)) throw Error("Missing " + name);
if (
  members.some(
    (n) =>
      n.startsWith("/") ||
      n.split("/").includes("..") ||
      /\.map$|\.p8$|node_modules|qa-results|device-qa/i.test(n),
  )
)
  throw Error("Unexpected private or development files");
const read = (name) =>
  execFileSync("unzip", ["-p", file, name], { maxBuffer: 16 * 1024 * 1024 });
const manifest = JSON.parse(read("harness-config.json"));
const config = JSON.parse(readFileSync("board.config.json", "utf8"));
if (manifest.appId !== config.appId)
  throw Error("Package identity does not match board.config.json");
if (/(?:src|href)=["']\/assets\//.test(read("index.html").toString()))
  throw Error("Root-relative assets will fail on Board");
if (read("model.tflite").length < 10000)
  throw Error("Recognition model is missing or truncated");
console.log(
  JSON.stringify(
    {
      file,
      appId: config.appId,
      entries: members.length,
      bytes: readFileSync(file).length,
      sha256: createHash("sha256").update(readFileSync(file)).digest("hex"),
    },
    null,
    2,
  ),
);

const wasm = read("wasm/luma.wasm");
if (
  wasm.includes(Buffer.from("/Users/")) ||
  wasm.includes(Buffer.from("/home/"))
)
  throw Error("Wasm contains a private build path");
