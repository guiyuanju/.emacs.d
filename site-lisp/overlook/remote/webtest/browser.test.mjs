// End-to-end page tests in emulated phones against the fake daemon (server.mjs).
import nodeTest, { before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { start, TOKEN } from "./server.mjs";

const require = createRequire(import.meta.url);
const { launch, unavailable } = require("./browser.cjs");
const skip = unavailable();
const test = (name, fn) => nodeTest(name, { skip: skip ?? false }, fn);
const shots = process.env.OVERLOOK_SCREENSHOTS || path.join(os.tmpdir(), "overlook-webtest");
const ALPHA = "conversation-06f8144e9a2601385f737f5cb6540bf9f5df039c802afaa355a3296461e4b160";
const SCOUT = "conversation-349c8502002011158b3153878ac92b09a436c595bccf86abb64a4b8c49b85d65";
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7X8AAAAASUVORK5CYII=", "base64");

let browser, devices;
before(async () => { if (!skip) ({ browser, devices } = await launch()); });
after(async () => { await browser?.close(); });

// A fresh fake daemon and page in an emulated device; problems collects page errors and CSP violations.
async function open(t, { device = "iPhone 13", theme = "light", route = "", token = TOKEN, reducedMotion = "no-preference" } = {}) {
  const server = await start(0, { coalesceMs: 40 });
  const context = await browser.newContext({ ...devices[device], colorScheme: theme, reducedMotion });
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: server.url.replace(/\/overlook\/$/, "") });
  const page = await context.newPage();
  page.setDefaultTimeout(8000);
  const problems = [];
  page.on("pageerror", (error) => problems.push("pageerror: " + error.message));
  page.on("console", (message) => { if (message.type() === "error" && !message.text().startsWith("Failed to load resource")) problems.push("console: " + message.text()); });
  await page.addInitScript(() => document.addEventListener("securitypolicyviolation",
    (event) => console.error(`CSP ${event.violatedDirective} ${event.blockedURI}`)));
  const base = server.url.replace(/\/overlook\/$/, "");
  const ctl = async (name, body = {}) => (await fetch(base + "/__test/" + name, { method: "POST", body: JSON.stringify(body) })).json();
  const log = async () => (await fetch(base + "/__test/log")).json();
  t.after(async () => { await context.close(); await server.close(); });
  await page.goto(server.url + route + (token ? "#" + token : ""));
  const settled = () => page.waitForFunction(() => !document.querySelector(".page-snapshot"));
  const shot = (name) => page.screenshot({ path: `${shots}/${device.replaceAll(" ", "-")}-${theme}-${name}.png` });
  return { page, server, ctl, log, problems, settled, shot, device: devices[device] };
}

const textEvent = (conversation, text, type = "text", extra = {}) => ({ method: "agent.event",
  params: { conversation, at: new Date().toISOString(), type, text, ...extra } });

for (const [device, theme] of [["iPhone 13", "light"], ["iPhone 13", "dark"], ["iPhone SE", "light"], ["Pixel 5", "dark"]]) {
  test(`dashboard layout on ${device} ${theme}`, async (t) => {
    const { page, problems, shot, device: spec } = await open(t, { device, theme });
    await page.locator("#dashboard-content .usage-row").first().waitFor();
    const sections = await page.locator("#dashboard-content > .dashboard-section > h2").allTextContents();
    assert.deepEqual(sections, ["Agents", "Usage", "Projects", "Personas"]);
    const agents = page.locator("#dashboard-content > .dashboard-section").first();
    assert.equal(await agents.locator(".dashboard-show-more").count(), 0);
    assert(await agents.locator(".conversation-row").count() >= 2);
    assert.match(await agents.locator(".row-subtitle").first().innerText(), /overlook/);
    const ids = await agents.locator(".conversation-row").evaluateAll((rows) => rows.map((row) => row.dataset.nodeId));
    assert.equal(new Set(ids).size, ids.length);
    assert.equal(await page.locator("html.ios").count(), 1);
    assert.equal(await page.locator("html.dark").count(), theme === "dark" ? 1 : 0);
    assert.equal(await page.locator("body").evaluate((el) => getComputedStyle(el).fontSize), "17px");
    const rings = page.locator(".usage-window .usage-ring");
    assert.equal(await rings.count(), 6);
    assert.equal(await rings.first().getAttribute("aria-valuenow"), "42.5");
    assert.match(await rings.first().getAttribute("style"), /42\.5%/);
    assert.equal(await page.locator(".usage-window.warning").count(), 1);
    assert.equal(await page.getByText("2h 10m", { exact: true }).count(), 1);
    const boxes = await rings.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().toJSON()));
    assert(boxes.every((box) => box.width === 16 && box.height === 16 && box.right < spec.viewport.width));
    assert.equal(boxes[3].left, boxes[0].left, "first columns line up across accounts");
    if (spec.viewport.width >= 360) {
      assert.equal(boxes[1].top, boxes[0].top);
      assert.equal(boxes[4].left, boxes[1].left, "second columns line up across accounts");
    } else assert(boxes[1].left === boxes[0].left && boxes[1].top > boxes[0].top);
    assert.equal(await page.locator(".usage-row .usage-icon").nth(1).getAttribute("aria-label"), "Claude · work");
    const persona = page.locator(".persona-row").first();
    assert.equal(await persona.locator(".more").count(), 0);
    assert.equal(await persona.locator(".persona-count").innerText(), "1 conversation");
    assert.equal(await persona.locator(".agent-state").innerText(), "Completed");
    assert.equal(await page.locator(".persona-row .row-subtitle").count(), 0);
    assert.equal(await page.locator(".persona-row").nth(1).locator(".agent-state").innerText(), "Not started");
    assert(await persona.evaluate((el) => el.getBoundingClientRect().height >= 76));
    assert(await page.evaluate(() => document.body.scrollWidth <= innerWidth));
    await shot("dashboard");
    assert.deepEqual(problems, []);
  });
}

test("dashboard menus, attention, project pages, commands and diffs", async (t) => {
  const { page, log, problems, settled, shot } = await open(t);
  await page.locator(".usage-row").first().waitFor();
  assert.equal(await page.title(), "(1) Overlook", "the title counts rows waiting for a choice");
  await page.locator(".usage-row .usage-content").first().dispatchEvent("contextmenu");
  await page.locator(".actions-modal.modal-in").getByText("Use for new agents", { exact: true }).waitFor();
  await page.locator(".actions-button").filter({ hasText: "Cancel" }).click();
  await page.locator(".actions-modal").waitFor({ state: "detached" });
  await page.locator(".persona-row button").first().dispatchEvent("contextmenu");
  await page.locator(".actions-modal.modal-in").waitFor();
  assert.equal(await page.locator(".actions-button").filter({ hasText: "New conversation" }).count(), 1);
  await page.locator(".actions-button").filter({ hasText: "Cancel" }).click();
  await page.locator(".actions-modal").waitFor({ state: "detached" });

  assert.equal(await page.locator(".dashboard-attention, .attention-shortcut").count(), 0);
  const agents = page.locator("#dashboard-content > .dashboard-section").first();
  assert.equal(await agents.locator(".choices button").count(), 4);
  assert.equal(await agents.getByText("Brotli vs gzip for SSE", { exact: true }).count(), 0);

  await page.locator("#dashboard-content").getByText("overlook", { exact: true }).click();
  await settled();
  await page.getByRole("heading", { name: "Conversations", exact: true }).waitFor();
  assert.match(page.url(), /\?node=[0-9a-f]{16}#test-token$/);
  assert.equal(await page.getByRole("heading", { name: "To do", exact: true }).count(), 1);
  assert.equal(await page.getByRole("heading", { name: "Code & changes", exact: true }).count(), 1);
  assert.equal(await page.locator(".overview-facts").innerText(), "2 conversations\n3 tasks\n3 changed files");
  assert.equal(await page.locator(".conversation-row .remote-row.item-link").count(), 0);
  assert(Number(await page.locator(".conversation-row .unread-badge").innerText()) > 0);
  const centering = await page.locator(".agent-icon").first().evaluate((el) => {
    const a = el.getBoundingClientRect(), b = el.firstElementChild.getBoundingClientRect();
    return Math.abs((a.top + a.bottom - b.top - b.bottom) / 2);
  });
  assert(centering < 1);
  await shot("project");

  await page.locator("#dashboard-content").getByText("Tasks", { exact: true }).click();
  await settled();
  assert.equal(await page.locator(".task-check").count(), 3);
  assert.equal(await page.locator(".task-row input").count(), 0);
  const today = new Date().toLocaleDateString("sv");
  assert.equal(await page.locator(".task-due.overdue").count(), ["2026-11-13", "2026-11-10"].filter((due) => due < today).length);
  await page.getByRole("button", { name: "Complete: Measure bytes vs. the old server", exact: true }).click();
  await page.locator(".toast").getByText("Done: done").waitFor();
  const done = (await log()).find((entry) => entry.path.endsWith("/commands/done"));
  assert.match(done.key, /^[0-9a-f]{32}$/);
  assert.equal(done.protocol, "3");
  await page.locator("#back").click();
  await settled();

  await page.locator("#session-menu").click();
  await page.locator(".actions-button").filter({ hasText: "New conversation" }).click();
  await page.locator(".remote-sheet textarea").fill("Port the page");
  await page.locator(".remote-sheet select").selectOption("codex");
  await page.locator(".remote-sheet").getByRole("button", { name: "Cancel", exact: true }).click();
  await page.locator(".sheet-modal").waitFor({ state: "detached" });
  await page.getByRole("button", { name: "New conversation in overlook", exact: true }).click();
  assert.equal(await page.locator(".remote-sheet textarea").inputValue(), "Port the page");
  assert.equal(await page.locator(".remote-sheet select").inputValue(), "codex");
  await page.locator(".remote-sheet").getByRole("button", { name: "Cancel", exact: true }).click();
  await page.locator(".sheet-modal").waitFor({ state: "detached" });

  await page.locator("#session-menu").click();
  await page.locator(".actions-button").filter({ hasText: "Close project" }).click();
  await page.locator(".dialog.modal-in").getByText("Close project overlook? Its agents keep running.").waitFor();
  await page.locator(".dialog-button").filter({ hasText: "Cancel" }).click();
  await page.locator(".dialog").waitFor({ state: "detached" });
  await page.locator("#session-menu").click();
  await page.locator(".actions-button").filter({ hasText: "Close project" }).click();
  await page.locator(".dialog-button").filter({ hasText: "Close project" }).click();
  await page.locator(".toast").getByText("Close project: done").waitFor();
  const closes = (await log()).filter((entry) => entry.path.endsWith("/commands/close"));
  assert.equal(closes.length, 3);
  assert.notEqual(closes[0].key, closes[1].key, "a cancelled attempt is forgotten");
  assert.equal(closes[1].key, closes[2].key, "confirmation re-sends with the same key");
  assert.deepEqual(closes[2].body.confirmations, ["Close project overlook? Its agents keep running."]);
  assert.match(closes[2].body.confirmationToken, /^token-/);

  await page.locator("#dashboard-content").getByText("overlook-remote-go", { exact: true }).click();
  await settled();
  await page.locator("#dashboard-content").getByText("README.md", { exact: true }).click();
  await page.locator(".remote-sheet pre.diff .add").first().waitFor();
  assert.match(await page.locator(".remote-sheet pre.diff").innerText(), /overlook-remoted/);
  await page.getByRole("button", { name: "Close sheet", exact: true }).click();
  await page.locator(".sheet-modal").waitFor({ state: "detached" });
  await page.locator("#back").click();
  await settled();
  await page.getByRole("button", { name: "New conversation in overlook", exact: true }).click();
  await page.locator(".remote-sheet").getByRole("button", { name: "New conversation", exact: true }).click();
  await page.waitForURL((url) => url.searchParams.get("agent") === ALPHA);
  await page.locator("#d-feed .markdown").first().waitFor();
  const created = (await log()).find((entry) => entry.path.endsWith("/commands/new"));
  assert.deepEqual(created.body, { text: "Port the page", option: "codex" });
  assert.deepEqual(problems, []);
});

test("conversation reading: feed, folding, copy, tools, images, info, history and read position", async (t) => {
  const { page, ctl, log, problems, settled, shot, server } = await open(t, { route: "?agent=" + ALPHA });
  await page.locator("#d-feed .markdown").first().waitFor();
  await settled();
  assert.equal(await page.locator("#heading .navigation-title").innerText(), "Rewrite remote as a Go daemon");
  assert.equal(await page.locator("#heading .navigation-subtitle").innerText(), "claude · Needs attention");
  assert.equal(await page.locator("#context").innerText(), "64%");
  assert(await page.locator("#d-feed .message-time").count() > 5);
  assert.equal(await page.locator("#d-feed .tool.failed").count(), 1);
  assert.equal(await page.locator("#d-feed .end").count(), 1);
  await page.locator("#d-feed .tool details summary").first().click();
  await page.locator("#d-feed pre.diff .add").first().waitFor();
  await page.locator("#d-feed .code-copy").first().click();
  await page.locator("#d-feed").getByRole("button", { name: "Copied", exact: true }).waitFor();
  assert.match(await page.evaluate(() => navigator.clipboard.readText()), /type Store struct/);

  await page.waitForFunction(() => document.querySelectorAll("#d-feed img[src^='blob:']").length >= 2);
  await page.locator("#d-feed .markdown img").first().click();
  await page.locator(".photo-browser").waitFor();
  await page.locator(".photo-browser .popup-close").click();
  await page.locator(".photo-browser").waitFor({ state: "detached" });

  await page.locator("#heading .navigation-info").click();
  await page.locator(".conversation-info").waitFor();
  assert.match(await page.locator(".conversation-info").innerText(), /64% used/);
  assert.match(await page.locator(".conversation-info").innerText(), /overlook-remote-go/);
  await page.getByRole("button", { name: "Close sheet", exact: true }).click();
  await page.locator(".sheet-modal").waitFor({ state: "detached" });

  await ctl("message", textEvent(ALPHA, "", "end"));
  await ctl("message", textEvent(ALPHA, "Files: [report](docs/report.pdf#L2), [gone](file:///tmp/missing.txt) and [site](https://example.com)."));
  await ctl("message", textEvent(ALPHA, "", "end"));
  const files = page.locator("#d-feed .markdown").filter({ hasText: "Files:" });
  await files.waitFor();
  assert.equal(await files.locator("a[href^='https:']").getAttribute("target"), "_blank");
  assert.equal(await files.locator("a.file-link[data-file='/tmp/missing.txt']").count(), 1);
  await files.getByText("report", { exact: true }).click();
  await page.locator(".dialog").getByText("report.pdf · 2.0 KB").waitFor();
  const download = page.waitForEvent("download");
  await page.locator(".dialog-button").filter({ hasText: "Download" }).click();
  assert.equal((await download).suggestedFilename(), "report.pdf");
  assert.deepEqual((await log()).filter((entry) => entry.path.endsWith("/files")).map((entry) => entry.body), [{ path: "docs/report.pdf" }]);
  await files.getByText("gone", { exact: true }).click();
  await page.locator(".toast").getByText("That file is not in this conversation or no longer exists").waitFor();
  assert.equal(await page.locator(".dialog").count(), 0);

  await ctl("message", textEvent(ALPHA, "Long response ".repeat(250) + "\n\n```js\n" + "const value = 1;\n".repeat(30) + "```"));
  for (let i = 0; i < 3; i++) await ctl("message", textEvent(ALPHA, undefined, "tool", { id: "t" + i, title: "Read file " + i, status: "completed", kind: "read" }));
  await page.locator(".tool-group summary").getByText("3 completed actions").waitFor();
  const long = page.locator("#d-feed .markdown").filter({ hasText: "Long response" });
  assert(await long.locator(".content-preview").evaluate((el) => el.getBoundingClientRect().height <= 340));
  await long.getByRole("button", { name: "Show full message", exact: true }).click();
  await long.getByRole("button", { name: "Show full code", exact: true }).click();
  await ctl("message", textEvent(ALPHA, "", "end"));
  await ctl("message", textEvent(ALPHA, undefined, "tool", { id: "t1", title: "Read file 1", status: "completed", kind: "read" }));
  await page.locator(".tool-group summary").click();
  assert.equal(await page.locator(".tool-group[open] .tool").count(), 3);
  assert.equal(await long.locator(".content-preview").count(), 0, "expanded replies stay expanded");
  assert.equal(await long.locator(".code-preview").count(), 0, "expanded code stays expanded");
  await long.getByRole("button", { name: "Copy full text", exact: true }).click();
  await long.getByRole("button", { name: "Copied", exact: true }).waitFor();

  await page.evaluate(() => { const detail = document.getElementById("detail"); detail.scrollTop = 0; detail.dispatchEvent(new Event("scroll")); });
  await page.getByRole("button", { name: "Jump to latest message" }).click();
  await page.waitForFunction(() => document.getElementById("latest").hidden);
  await page.waitForFunction(() => { const d = document.getElementById("detail"); return d.scrollTop + d.clientHeight >= d.scrollHeight - 80; });
  await shot("conversation");

  const reads = (await log()).filter((entry) => entry.method === "PUT" && entry.path.endsWith("/read"));
  assert(reads.length > 0);
  assert.equal(reads.at(-1).body.epoch, "e1");
  const latest = Math.max(...server.daemon.conversations.get(ALPHA).items.map((item) => item.seq));
  await page.waitForFunction(async (seq) => true, latest);
  assert.equal(server.daemon.conversations.get(ALPHA).readThrough > 0, true);

  for (let i = 0; i < 60; i++) await ctl("message", textEvent(SCOUT, "Question " + i, "prompt"));
  await page.locator("#back").click();
  await settled();
  await page.goto(server.url + "?agent=" + SCOUT + "#" + TOKEN);
  await page.getByRole("button", { name: "Load earlier messages", exact: true }).waitFor();
  await page.waitForTimeout(300);
  await page.getByRole("button", { name: "Load earlier messages", exact: true }).scrollIntoViewIfNeeded();
  const firstPrompt = page.locator("#d-feed > .prompt").first();
  const [anchor, before] = await firstPrompt.evaluate((el) => [el.itemId, el.getBoundingClientRect().top]);
  await page.getByRole("button", { name: "Load earlier messages", exact: true }).click();
  await page.locator("#history-controls").waitFor({ state: "hidden" });
  const moved = await page.evaluate((id) => [...document.querySelectorAll("#d-feed .item")].find((el) => el.itemId === id).getBoundingClientRect().top, anchor);
  assert(Math.abs(before - moved) < 2, `history moved the reading position ${before} -> ${moved}`);
  assert.equal(await page.locator("#d-feed > .prompt").first().innerText().then((text) => text.split("\n")[0]), "Is brotli worth it for an SSE stream of small JSON deltas?");
  assert.equal(await page.locator("#persona-profile h2").innerText(), "Scout");
  assert.equal(await page.locator("#text").getAttribute("placeholder"), "Message Scout");
  assert.deepEqual(problems, []);
});

test("composer: drafts, send, retry, queue, uploads, settings, steer and stop", async (t) => {
  const { page, ctl, log, problems, settled } = await open(t, { route: "?agent=" + ALPHA });
  await page.locator("#d-feed .markdown").first().waitFor();
  assert.equal(await page.locator("#send").isDisabled(), true);
  await page.locator("#text").fill("保留这个草稿");
  await page.locator("#back").click();
  await settled();
  await page.locator("#dashboard-content").getByText("Scout", { exact: true }).click();
  await settled();
  await page.locator("#dashboard-content").getByText("Brotli vs gzip for SSE", { exact: true }).click();
  await settled();
  await page.locator("#d-feed .markdown").first().waitFor();
  assert.equal(await page.locator("#text").inputValue(), "", "drafts are per conversation");
  await page.locator("#text").fill("Scout draft");
  await page.locator("#back").click();
  await settled();
  await page.locator("#back").click();
  await settled();
  await page.locator("#dashboard-content > .dashboard-section").first().locator(".conversation-row .remote-row").first().click();
  await settled();
  assert.equal(await page.locator("#text").inputValue(), "保留这个草稿");
  await page.locator("#send").click();
  await page.waitForFunction(() => document.getElementById("text").value === "");
  await page.locator(".toast").getByText("Message queued").waitFor();
  const sent = (await log()).filter((entry) => entry.path.endsWith("/prompts") && entry.method === "POST");
  assert.equal(sent.at(-1).body.text, "保留这个草稿");
  await page.locator(".queued").filter({ hasText: "保留这个草稿" }).waitFor();

  await ctl("fail", { method: "POST", path: "/prompts$", status: 503, code: "emacs_offline", detail: "Emacs is not connected" });
  await page.locator("#text").fill("Keep this retry draft");
  await page.locator("#send").click();
  await page.getByText("Not sent · Emacs is not connected", { exact: true }).waitFor();
  assert.equal(await page.locator("#text").inputValue(), "Keep this retry draft");
  await page.getByRole("button", { name: "Retry send", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("text").value === "");
  const retried = (await log()).filter((entry) => entry.path.endsWith("/prompts") && entry.method === "POST").slice(-2);
  assert.equal(retried[0].key, retried[1].key, "a retry reuses the Idempotency-Key");

  await page.locator("#text").fill("Existing draft");
  await ctl("fail", { method: "DELETE", path: "/prompts/queued-1$", status: 409, code: "already_sent", detail: "That prompt was sent already" });
  const queued = page.locator(".queued").filter({ hasText: "After that, run go vet." });
  await queued.getByRole("button", { name: "Edit", exact: true }).click();
  await page.getByText("Already sent · That prompt was sent already", { exact: true }).waitFor();
  assert.equal(await page.locator("#text").inputValue(), "Existing draft");
  await queued.getByRole("button", { name: "Edit", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("text").value === "Existing draft\n\nAfter that, run go vet.");
  await page.locator(".queued").filter({ hasText: "After that, run go vet." }).waitFor({ state: "detached" });
  await page.locator(".queued").filter({ hasText: "Then summarize the diff." }).getByRole("button", { name: "Remove", exact: true }).click();
  await page.locator(".queued").filter({ hasText: "Then summarize the diff." }).waitFor({ state: "detached" });
  assert.equal(await page.locator("#text").inputValue(), "Existing draft\n\nAfter that, run go vet.");

  await ctl("fail", { method: "POST", path: "/attachments$", status: 503, code: "emacs_offline", detail: "Upload interrupted" });
  await page.locator("#files").setInputFiles({ name: "pixel.png", mimeType: "image/png", buffer: PNG });
  await page.locator(".attachment").getByText("Upload interrupted", { exact: true }).waitFor();
  assert.equal(await page.locator("#send").isDisabled(), true);
  await page.locator(".attachment").getByRole("button", { name: "Retry", exact: true }).click();
  await page.locator(".attachment").getByText("Attached", { exact: true }).waitFor();
  assert.match(await page.locator("#text").inputValue(), /phone-20261113-081500-123\.png/);
  const uploads = (await log()).filter((entry) => entry.path.endsWith("/attachments"));
  assert.equal(uploads.length, 2);
  assert.equal(uploads[1].type, "image/png");
  assert.equal(uploads[1].body, PNG.length, "raw bytes, not base64 JSON");
  assert.equal(uploads[0].key, uploads[1].key);
  await page.getByRole("button", { name: "Remove pixel.png", exact: true }).click();
  assert.doesNotMatch(await page.locator("#text").inputValue(), /phone-/);

  await page.getByRole("button", { name: "Conversation actions" }).click();
  const labels = await page.locator(".actions-modal.modal-in .actions-button").allInnerTexts();
  for (const label of ["Steer with current draft", "Model · Opus", "Effort · High", "Stop current task", "Close agent"]) assert(labels.includes(label), label);
  await page.locator(".actions-button").filter({ hasText: "Model · Opus" }).click();
  await page.locator(".actions-modal.modal-in .actions-label").getByText("Choose model").waitFor();
  await page.locator(".actions-modal.modal-in .actions-button").filter({ hasText: "Sonnet" }).click();
  await page.locator(".toast").getByText("Model change requested").waitFor();
  const model = (await log()).filter((entry) => entry.path.endsWith("/actions")).at(-1);
  assert.deepEqual(model.body, { action: "model", text: "sonnet" });

  const working = structuredClone((await (await fetch(page.url().split("?")[0] + "api/conversations/" + ALPHA, { headers: { Authorization: "Bearer " + TOKEN } })).json()).conversation);
  working.status = "working";
  delete working.choices; delete working.form; delete working.unreadCount; delete working.readThrough;
  await ctl("message", { method: "conversation.set", params: { conversation: working } });
  await page.locator("#compose-status").getByText("Busy · messages will queue").waitFor();
  await page.locator("#d-live .working .preloader").waitFor();
  await page.locator("#compose-status").getByRole("button", { name: "Adjust now", exact: true }).click();
  await page.waitForFunction(() => document.getElementById("text").value === "");
  await page.locator(".toast").getByText("Steer sent").waitFor();
  const steer = (await log()).filter((entry) => entry.path.endsWith("/actions")).at(-1);
  assert.deepEqual(steer.body, { action: "steer", text: "Existing draft\n\nAfter that, run go vet." });
  await page.locator("#compose-status").getByRole("button", { name: "Stop", exact: true }).click();
  await page.locator(".toast").getByText("Stop requested").waitFor();

  await page.locator("#text").fill("/");
  assert.deepEqual(await page.locator("#slash-commands .command-name").allInnerTexts(), ["/compact", "/review", "/clear"]);
  await page.locator("#text").fill("/re");
  await page.locator("#slash-commands button").click();
  assert.equal(await page.locator("#text").inputValue(), "/review ");
  await page.locator("#text").press("Control+Enter");
  await page.waitForFunction(() => document.getElementById("text").value === "");
  assert.deepEqual(problems, []);
});

test("answers: question form, then permission choices", async (t) => {
  const { page, log, problems } = await open(t, { route: "?agent=" + ALPHA });
  const form = page.locator(".question-form");
  await form.waitFor();
  await form.getByText("Split by concern").click();
  await form.getByText("Table tests").click();
  await form.getByRole("textbox", { name: "Store layout: other" }).fill("keep it small");
  await form.getByRole("textbox", { name: "Anything else?" }).fill("no");
  await form.locator("label.option").filter({ hasText: "Fail on unknown fields" }).click();
  await form.getByRole("spinbutton", { name: "Items retained" }).fill("300");
  await form.getByRole("button", { name: "Submit", exact: true }).click();
  const choices = page.locator(".permission-card:not(.question-form) .choices");
  await choices.waitFor();
  const answer = (await log()).find((entry) => entry.path.includes("/forms/form-17"));
  assert.deepEqual(answer.body, { action: "accept", values: { layout: "split", layout_note: "keep it small", extras: ["tests"], note: "no", strict: true, limit: 300 } });
  await choices.getByRole("button", { name: "Allow once", exact: true }).click();
  await choices.waitFor({ state: "detached" });
  await page.locator(".permission-card").getByText("Your attention is needed").waitFor();
  const choice = (await log()).find((entry) => entry.path.endsWith("/choice"));
  assert.deepEqual(choice.body, { key: "allow_once" });
  assert.match(choice.key, /^[0-9a-f]{32}$/);
  assert.deepEqual(problems, []);
});

test("live updates, Emacs offline, gone, missing and credentials", async (t) => {
  const { page, ctl, problems, server } = await open(t, { route: "?agent=" + ALPHA });
  await page.locator("#d-feed .markdown").first().waitFor();
  await ctl("live", { speed: 0.2 });
  await page.locator("#d-feed").getByText("Done. Items are now kept per conversation, and the test passes. 🎉").waitFor();
  await page.locator("#d-feed").getByText("Run go vet ./...").waitFor();
  await ctl("emacs", { emacs: "offline" });
  await page.locator("#connection").getByText(/Emacs is not connected/).waitFor();
  assert.equal(await page.locator("#reconnect").isVisible(), false);
  await ctl("emacs", { emacs: "online" });
  await page.locator("#connection").waitFor({ state: "hidden" });
  await ctl("message", { method: "conversation.remove", params: { conversation: ALPHA } });
  await page.locator("#connection").getByText(/This conversation has ended/).waitFor();
  await page.locator("#return-dashboard").click();
  await page.locator(".usage-row").first().waitFor();
  await page.goto(server.url + "?agent=nope#" + TOKEN);
  await page.locator("#d-feed .view-state").getByText("Conversation ended").waitFor();
  await page.goto(server.url + "#wrong");
  await page.locator("#dashboard-content .view-state").getByText("Open your personal link").waitFor();
  assert.deepEqual(problems.filter((text) => !/401|404/.test(text)), []);
});

test("stream reconnects with its cursors after a drop", async (t) => {
  const { page, ctl, log, server } = await open(t);
  await page.locator(".usage-row").first().waitFor();
  for (const client of server.daemon.streams) client.res.destroy();
  await page.locator("#connection").getByText(/Reconnecting/).waitFor();
  await page.locator("#connection").waitFor({ state: "hidden", timeout: 5000 });
  const streams = (await log()).filter((entry) => entry.path === "/stream");
  assert.equal(streams.length, 2);
  assert.equal(streams[1].query.dashboard, streams[0].query.dashboard, "unchanged cursor, nothing resent");
  await ctl("message", { method: "dashboard.set", params: { sections: server.daemon.fx.sync.dashboard.slice(0, 2) } });
  await page.locator(".persona-row").first().waitFor({ state: "detached" });
});

test("Close agent confirms, then returns to the group; deep links and reduced motion", async (t) => {
  const { page, log, server, settled } = await open(t, { reducedMotion: "reduce" });
  await page.locator(".usage-row").first().waitFor();
  await page.locator("#dashboard-content").getByText("overlook", { exact: true }).click();
  assert.equal(await page.locator(".page-snapshot").count(), 0);
  const node = new URL(page.url()).searchParams.get("node");
  await page.locator(".conversation-row .remote-row").first().click();
  await page.locator("#d-feed .markdown").first().waitFor();
  await page.getByRole("button", { name: "Conversation actions", exact: true }).click();
  await page.locator(".actions-button").filter({ hasText: "Close agent" }).click();
  await page.locator(".dialog.modal-in").waitFor();
  await page.locator(".dialog-button").filter({ hasText: "Close agent" }).click();
  await page.waitForURL((url) => !url.searchParams.has("agent"));
  assert.equal(new URL(page.url()).searchParams.get("node"), node);
  await page.locator(".toast").getByText("Agent closed").waitFor();
  const closes = (await log()).filter((entry) => entry.path.endsWith("/actions"));
  assert.equal(closes.length, 2);
  assert.equal(closes[0].key, closes[1].key);
  assert.match(closes[1].body.confirmationToken, /^token-/);
  await page.goto(server.url + "?node=" + node + "#" + TOKEN);
  await page.getByRole("heading", { name: "To do", exact: true }).waitFor();
  await page.locator("#back").click();
  await settled();
  await page.locator(".usage-row").first().waitFor();
  assert.equal(new URL(page.url()).search, "");
});

test("layout around the composer and header", async (t) => {
  const { page } = await open(t, { route: "?agent=" + SCOUT });
  await page.locator("#d-feed .markdown").first().waitFor();
  const layout = await page.evaluate(() => {
    const rect = (id) => document.getElementById(id).getBoundingClientRect().toJSON();
    return { compose: rect("compose"), detail: rect("detail"), text: rect("text"), title: rect("heading"), back: rect("back"), menu: rect("session-menu"),
      height: innerHeight, width: innerWidth, body: document.body.scrollWidth };
  });
  assert(layout.compose.bottom <= layout.height + 1);
  assert(layout.detail.bottom <= layout.compose.top + 1);
  assert(layout.text.width > 70);
  assert(layout.body <= layout.width);
  assert(layout.title.left >= layout.back.right - 1);
  assert(layout.title.right <= layout.menu.left + 1);
});
