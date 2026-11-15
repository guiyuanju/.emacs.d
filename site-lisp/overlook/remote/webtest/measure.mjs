// Wire bytes of the page served by the daemon, driven by the dev Emacs (e2e-emacs.el).
// node measure.mjs [new]...   Prints a Markdown table; needs Playwright, go and emacs.
import { createRequire } from "node:module";
import net from "node:net";
import { setup, until } from "./e2e.mjs";

const require = createRequire(import.meta.url);
const { launch } = require("./browser.cjs");
const QUIET = 1500;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A TCP proxy counting bytes in each direction and connections opened.
function countingProxy(target) {
  const counts = { down: 0, up: 0, connections: 0 };
  const server = net.createServer((client) => {
    counts.connections++;
    const upstream = net.createConnection(target, "127.0.0.1");
    client.on("data", (chunk) => { counts.up += chunk.length; upstream.write(chunk); });
    upstream.on("data", (chunk) => { counts.down += chunk.length; client.write(chunk); });
    const close = () => { client.destroy(); upstream.destroy(); };
    client.on("close", close); upstream.on("close", close);
    client.on("error", close); upstream.on("error", close);
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({
    port: server.address().port, counts,
    reset() { counts.down = counts.up = counts.connections = 0; },
    close: () => server.close(),
  })));
}

async function measure(kind) {
  const env = await setup();
  const results = [];
  try {
    let port;
    await env.startDaemon();
    await env.startEmacs();
    await until(async () => (await env.health()).emacs === "online", { what: "Emacs online" });
    port = env.port;
    // Fifty items: 25 prompts and replies.
    await env.el(`(dotimes (i 25) (e2e-event "alpha" 'prompt :text (format "Question %d about the remote" (1+ i)))
                   (e2e-event "alpha" 'text :text (format "Answer %d: %s" (1+ i) (make-string 200 ?x))))`);
    await wait(500);
    const proxy = await countingProxy(port);
    const base = `http://127.0.0.1:${proxy.port}/overlook/`;
    const { browser, devices } = await launch();
    const context = await browser.newContext({ ...devices["iPhone 13"] });
    let requests = 0;
    context.on("request", (request) => {
      requests++;
      if (process.env.OVERLOOK_MEASURE_VERBOSE) console.error(kind, request.method(), request.url().replace(/^http:\/\/[^/]+/, ""));
    });
    const step = async (name, run) => {
      proxy.reset(); requests = 0;
      if (process.env.OVERLOOK_MEASURE_VERBOSE) console.error("--", kind, name);
      await run();
      results.push({ name, down: proxy.counts.down, up: proxy.counts.up, requests, connections: proxy.counts.connections });
    };
    const text = (page, value, timeout = 20000) => page.waitForFunction((v) => document.body.innerText.includes(v), value, { timeout });

    let page = await context.newPage();
    await step("Cold page load", async () => {
      await page.goto(base + "#" + env.token);
      await text(page, "shop");
      await wait(QUIET);
    });
    await page.locator("#dashboard-content").getByText("shop", { exact: true }).click();
    await text(page, "Work on beta");
    await wait(QUIET);
    await step("Dashboard change (agent starts working)", async () => {
      const row = page.locator(".conversation-row").filter({ hasText: "Work on beta" });
      const before = await row.innerText();
      await env.el(`(e2e-set "beta" :status 'working)`);
      await until(async () => (await row.innerText()) !== before, { what: "the row to change" });
      await wait(QUIET);
    });
    await step("Open a conversation with 50 items", async () => {
      await page.locator(".conversation-row .remote-row").filter({ hasText: "Work on alpha" }).click();
      await text(page, "Answer 25:");
      await wait(QUIET);
    });
    const reply = ("Streaming reply text, in small chunks as agents send it. ".repeat(100)).slice(0, 5000 - 12) + "END-OF-REPLY";
    await step("Stream a 5 KB reply in 20-character chunks", async () => {
      await env.el(`(e2e-stream "alpha" ${JSON.stringify(reply)} 20 0.02)`);
      await text(page, "END-OF-REPLY");
      await wait(QUIET);
    });
    await step("Idle minute in a conversation", async () => { await wait(Number(process.env.OVERLOOK_MEASURE_IDLE_MS || 60000)); });
    await page.close();
    page = await context.newPage();
    await step("Warm launch (Home Screen reopen)", async () => {
      await page.goto(base + "#" + env.token);
      await text(page, "shop");
      await wait(QUIET);
    });
    await browser.close();
    proxy.close();
  } finally {
    await env.close();
  }
  return results;
}

const kinds = process.argv.slice(2).length ? process.argv.slice(2) : ["new"];
const all = {};
for (const kind of kinds) all[kind] = await measure(kind);
const kb = (bytes) => (bytes / 1024).toFixed(1);
console.log(`| Scenario | ${kinds.map((k) => `${k} ↓ KB | ${k} ↑ KB | ${k} req/conn`).join(" | ")} |`);
console.log(`|---|${kinds.map(() => "--:|--:|--:").join("|")}|`);
for (let i = 0; i < all[kinds[0]].length; i++) {
  console.log(`| ${all[kinds[0]][i].name} | ${kinds.map((k) => { const r = all[k][i]; return `${kb(r.down)} | ${kb(r.up)} | ${r.requests}/${r.connections}`; }).join(" | ")} |`);
}
