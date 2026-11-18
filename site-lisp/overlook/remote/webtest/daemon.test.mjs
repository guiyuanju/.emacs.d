// The page against the real overlook-remoted with its in-process fake Emacs, on a random loopback port.
import test, { before, after } from "node:test";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { FIXTURES } from "./server.mjs";

const require = createRequire(import.meta.url);
const { launch, unavailable } = require("./browser.cjs");
const skip = spawnSync("go", ["version"]).status === 0 ? unavailable() : "go not found";
const remote = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const ALPHA = "conversation-06f8144e9a2601385f737f5cb6540bf9f5df039c802afaa355a3296461e4b160";
const TOKEN = "daemon-test-token";

let browser, devices, daemon, base, dir, binary, port;

const freePort = () => new Promise((resolve) => {
  const server = net.createServer().listen(0, "127.0.0.1", () => { const { port } = server.address(); server.close(() => resolve(port)); });
});

before(async () => {
  if (skip) return;
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "overlook-daemon-"));
  fs.chmodSync(dir, 0o700);
  binary = path.join(dir, "overlook-remoted");
  execFileSync("go", ["build", "-o", binary, "./cmd/overlook-remoted"], { cwd: remote, stdio: "inherit" });
  fs.writeFileSync(path.join(dir, "token"), TOKEN + "\n", { mode: 0o600 });
  port = await freePort();
  base = `http://127.0.0.1:${port}`;
  await startDaemon();
  ({ browser, devices } = await launch());
});

// The state file defaults to state.json beside the socket, so a restart resumes where the last run stopped.
async function startDaemon(extra = []) {
  daemon = spawn(binary, ["-listen", `127.0.0.1:${port}`, "-token-file", path.join(dir, "token"), "-socket", path.join(dir, "bridge.sock"),
    "-cache-dir", path.join(dir, "cache"), "-fake-emacs", FIXTURES, "-fake-live-delay", "-1s", "-fake-speed", "5", ...extra],
  { stdio: ["ignore", "inherit", "inherit"] });
  for (let i = 0; i < 100; i++) {
    try { if ((await (await fetch(base + "/overlook/healthz")).json()).emacs === "online") return; } catch (_) { /* starting */ }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("the daemon did not come online");
}

async function stopDaemon() {
  const exited = new Promise((resolve) => daemon.once("exit", resolve));
  daemon.kill("SIGTERM");
  await exited;
}

after(async () => {
  await browser?.close();
  if (daemon?.exitCode === null) await stopDaemon();
  if (dir) fs.rmSync(dir, { recursive: true, force: true });
});

test("page served by the daemon: dashboard, conversation, writes and live streaming", { skip: skip ?? false }, async (t) => {
  const context = await browser.newContext({ ...devices["iPhone 13"] });
  t.after(() => context.close());
  const page = await context.newPage();
  page.setDefaultTimeout(8000);
  const problems = [];
  page.on("pageerror", (error) => problems.push("pageerror: " + error.message));
  page.on("console", (message) => { if (message.type() === "error" && !message.text().startsWith("Failed to load resource")) problems.push(message.text()); });
  await page.addInitScript(() => document.addEventListener("securitypolicyviolation", (event) => console.error(`CSP ${event.violatedDirective} ${event.blockedURI}`)));
  const index = await fetch(base + "/overlook/");
  assert.match(index.headers.get("content-security-policy"), /script-src 'self' 'sha256-/);
  await page.goto(base + "/overlook/#" + TOKEN);
  await page.locator("#dashboard-content .conversation-row").first().waitFor();
  assert.deepEqual(await page.locator("#tabs .remote-tab-label").allTextContents(), ["Agents", "Projects", "Personas", "Inbox", "Usage"]);
  await page.locator("#tabs .remote-tab").filter({ has: page.getByText("Projects", { exact: true }) }).click();
  await page.locator("#dashboard-content").getByText("overlook", { exact: true }).click();
  await page.getByRole("heading", { name: "Conversations", exact: true }).waitFor();
  await page.locator(".conversation-row .remote-row").first().click();
  await page.waitForURL((url) => url.searchParams.get("agent") === ALPHA);
  await page.locator("#d-feed .markdown").first().waitFor();
  await page.waitForFunction(() => document.querySelectorAll("#d-feed img[src^='blob:']").length >= 1);
  await page.locator(".question-form").getByText("One file").click();
  await page.locator(".question-form").getByRole("button", { name: "Submit", exact: true }).click();
  await page.locator(".question-form .inline-feedback").getByText("Response sent. Waiting for the agent…").waitFor();
  await page.locator("#text").fill("From the daemon test");
  await page.locator("#send").click();
  await page.waitForFunction(() => document.getElementById("text").value === "");
  assert.equal(await page.locator(".toast").count(), 0);
  daemon.kill("SIGUSR1");
  await page.locator("#d-feed").getByText("and the test passes. 🎉", { exact: false }).waitFor({ timeout: 15000 });
  await page.locator("#back").click();
  await page.locator("#dashboard-content").getByText("Tasks", { exact: true }).waitFor();
  assert.deepEqual(problems, []);
});

test("daemon restart: the page resumes its stream with its cursors, without a reset", { skip: skip ?? false }, async (t) => {
  const context = await browser.newContext({ ...devices["iPhone 13"] });
  t.after(() => context.close());
  const page = await context.newPage();
  page.setDefaultTimeout(8000);
  const problems = [];
  page.on("pageerror", (error) => problems.push("pageerror: " + error.message));
  // Keeps a copy of every stream's text, as the page received it.
  await page.addInitScript(() => {
    window.streams = [];
    const original = window.fetch;
    window.fetch = async (...args) => {
      const response = await original(...args);
      if (String(args[0]).includes("/api/stream")) {
        const record = { url: String(args[0]), text: "" };
        window.streams.push(record);
        const reader = response.clone().body.pipeThrough(new TextDecoderStream()).getReader();
        (async () => { for (;;) { const { value, done } = await reader.read(); if (done) return; record.text += value; } })().catch(() => {});
      }
      return response;
    };
  });
  const snapshots = [];
  page.on("request", (request) => { if (new URL(request.url()).pathname.startsWith("/overlook/api/conversations")) snapshots.push(request.url()); });
  await page.goto(base + "/overlook/?agent=" + ALPHA + "#" + TOKEN);
  await page.locator("#d-feed .markdown").first().waitFor();
  await page.waitForFunction(() => window.streams.some((s) => s.text.includes("event: hello")));
  const replies = page.locator("#d-feed").getByText("and the test passes. 🎉", { exact: false });
  const before = await replies.count();
  const fetchedBefore = snapshots.length;
  const streamsBefore = await page.evaluate(() => window.streams.length);

  await stopDaemon();
  await startDaemon(["-fake-resume"]);
  await page.waitForFunction((n) => window.streams.length > n && window.streams.at(-1).text.includes("event: hello"), streamsBefore, { timeout: 15000 });
  const resumed = await page.evaluate(() => window.streams.at(-1).url);
  assert.match(resumed, /conversation=[^&]+&after=\d+&known=\w+&epoch=/, "the page resumed with its cursors");
  daemon.kill("SIGUSR1");
  await page.waitForFunction(([selector, n]) => [...document.querySelectorAll(selector)].filter((e) => e.textContent.includes("and the test passes. 🎉")).length > n,
    ["#d-feed .markdown", before], { timeout: 15000 });
  const streams = await page.evaluate(() => window.streams.map((s) => s.text));
  assert.ok(!streams.some((text) => text.includes('"reset":true')), "no stream event reset the page");
  assert.equal(snapshots.length, fetchedBefore, "the page fetched no snapshot again");
  assert.deepEqual(problems, []);
});
