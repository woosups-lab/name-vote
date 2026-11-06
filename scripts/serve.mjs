#!/usr/bin/env node
/* 개발용 정적 서버. 서비스 워커는 localhost에서도 동작한다. 사용법: node scripts/serve.mjs [포트] */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, extname, join, normalize } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PORT = +process.argv[2] || 8123;
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".json": "application/json",
  ".webmanifest": "application/manifest+json", ".png": "image/png", ".svg": "image/svg+xml" };

createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^[/\\]+/, "");
  try {
    /* 개발할 때는 저장소에 올리지 않는 config.local.json을 config.json 대신 씀 */
    const file = path === "" || path === "." ? "index.html" : path === "config.json" ? await readFile(join(ROOT, "config.local.json")).then(() => "config.local.json", () => path) : path;
    const body = await readFile(join(ROOT, file));
    res.writeHead(200, { "Content-Type": TYPES[extname(path) || ".html"] || "application/octet-stream", "Cache-Control": "no-cache" });
    res.end(body);
  } catch {
    res.writeHead(404); res.end("not found");
  }
}).listen(PORT, () => console.log(`http://localhost:${PORT}/`));
