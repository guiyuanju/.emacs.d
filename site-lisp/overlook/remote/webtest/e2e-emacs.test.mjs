// The page in an emulated iPhone against a real overlook-remoted and a dev Emacs running the bridge (e2e-emacs.el).
import nodeTest, { before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { setup, missing, until } from "./e2e.mjs";

const require = createRequire(import.meta.url);
const { launch, unavailable } = require("./browser.cjs");
const skip = missing() || unavailable();
const test = (name, fn) => nodeTest(name, { skip: skip ?? false }, fn);
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7X8AAAAASUVORK5CYII=", "base64");

let env, browser, devices, context, page, alpha, beta;
const problems = [];

before(async () => {
  if (skip) return;
  env = await setup();
  await env.startDaemon();
  await env.startEmacs();
  await until(async () => (await env.health()).emacs === "online", { what: "Emacs online" });
  alpha = await env.el('(e2e-id "alpha")');
  beta = await env.el('(e2e-id "beta")');
  ({ browser, devices } = await launch());
  context = await browser.newContext({ ...devices["iPhone 13"] });
  page = await context.newPage();
  page.setDefaultTimeout(10000);
  page.on("pageerror", (error) => problems.push("pageerror: " + error.message));
  page.on("console", (message) => { if (message.type() === "error" && !message.text().startsWith("Failed to load resource")) problems.push(message.text()); });
  await page.addInitScript(() => document.addEventListener("securitypolicyviolation", (event) => console.error(`CSP ${event.violatedDirective} ${event.blockedURI}`)));
});

after(async () => {
  await browser?.close();
  await env?.close();
});

const log = () => env.el("(e2e-take-log)");
const settled = () => page.waitForFunction(() => !document.querySelector(".page-snapshot"));
const feed = () => page.locator("#d-feed");
const openConversation = async (id) => {
  await page.goto(`${env.base}/overlook/?agent=${id}#${env.token}`);
  await page.locator("#heading .navigation-title").waitFor();
  await settled();
};
const lisp = (value) => JSON.stringify(value);

test("dashboard, and a change in Emacs reaches it", async () => {
  await page.goto(`${env.base}/overlook/#${env.token}`);
  await page.locator("#dashboard-content").getByText("shop", { exact: true }).click();
  await settled();
  await page.getByRole("heading", { name: "Conversations", exact: true }).waitFor();
  assert.deepEqual(await page.locator(".conversation-row .row-title").allInnerTexts(), ["Work on alpha", "Work on beta"]);
  await env.el('(progn (e2e-make-agent "gamma") t)');
  await page.locator(".conversation-row").getByText("Work on gamma", { exact: true }).waitFor();
  await env.el('(progn (kill-buffer (e2e-agent "gamma")) t)');
  await page.locator(".conversation-row").getByText("Work on gamma", { exact: true }).waitFor({ state: "detached" });
});

test("streaming reply, unread count and read position", async () => {
  await env.el(`(progn (e2e-event "alpha" 'prompt :text "Say hello") (e2e-report "alpha" 'working) t)`);
  await env.el(`(e2e-stream "alpha" ${lisp("Hello from the **real** Emacs, streamed in small chunks. ".repeat(4))} 7 0.02)`);
  await env.el(`(progn (run-at-time 1 nil (lambda () (e2e-event "alpha" 'end) (e2e-report "alpha" 'finished))) t)`);
  await page.locator(".conversation-row").filter({ hasText: "Work on alpha" }).locator(".unread-badge").waitFor();
  await until(async () => (await env.el(`(symbol-name (buffer-local-value 'overlook-agent-status (e2e-agent "alpha")))`)) === "done", { what: "alpha done" });
  await page.locator(".conversation-row .remote-row").filter({ hasText: "Work on alpha" }).click();
  await page.waitForURL((url) => url.searchParams.get("agent") === alpha);
  await feed().locator("strong").getByText("real").first().waitFor();
  await until(async () => (await feed().innerText()).includes("streamed in small chunks. Hello from the"), { what: "the whole reply" });
  // Reading it marks it seen in Emacs, which resets done.
  await until(async () => (await env.el(`(symbol-name (buffer-local-value 'overlook-agent-status (e2e-agent "alpha")))`)) === "idle", { what: "alpha seen" });
  await env.el(`(e2e-stream "alpha" ${lisp("Live suffix one 🚀. Live 后缀 two.")} 5 0.02)`);
  await feed().getByText("Live suffix one 🚀. Live 后缀 two.").waitFor();
  // Images named in the reply resolve against the root Emacs publishes; tool diffs are computed by the daemon.
  fs.writeFileSync(path.join(env.root, "shot.png"), PNG);
  await env.el(`(e2e-event "alpha" 'text :text " See shot.png for the result.")`);
  await page.waitForFunction(() => document.querySelectorAll("#d-feed img[src^='blob:']").length >= 1);
  await env.el(`(e2e-event "alpha" 'tool :id "t1" :title "Edit a.el" :kind "edit" :status "completed"
                 :diffs (list (list :file "a.el" :old "one\ntwo\n" :new "one\nthree\n")))`);
  await feed().locator(".tool").filter({ hasText: "Edit a.el" }).locator("summary").first().click();
  await feed().locator("pre.diff .add").getByText("three").waitFor();
  await page.locator("#back").click();
  await settled();
  assert.equal(await page.locator(".conversation-row").filter({ hasText: "Work on alpha" }).locator(".unread-badge").count(), 0);
});

test("send, and queue while busy until the agent is ready", async () => {
  await openConversation(alpha);
  await page.locator("#text").fill("Right away 你好 🎉");
  await page.locator("#send").click();
  await page.locator(".toast").getByText("Sent").waitFor();
  await feed().getByText("Right away 你好 🎉").waitFor();
  assert.deepEqual((await log()).filter((e) => e.op === "submit").map((e) => e.text), ["Right away 你好 🎉"]);
  await env.el(`(e2e-set "alpha" :ready nil :status 'working)`);
  await page.locator("#compose-status").getByText("Busy · messages will queue").waitFor();
  await page.locator("#text").fill("Later please");
  await page.locator("#send").click();
  await page.locator(".toast").getByText("Message queued").waitFor();
  await page.locator(".queued").filter({ hasText: "Later please" }).waitFor();
  await page.locator("#text").fill("Withdraw me");
  await page.locator("#send").click();
  await page.locator(".queued").filter({ hasText: "Withdraw me" }).getByRole("button", { name: "Remove", exact: true }).click();
  await page.locator(".queued").filter({ hasText: "Withdraw me" }).waitFor({ state: "detached" });
  assert.deepEqual(await log(), []);
  await env.el(`(e2e-set "alpha" :ready t :status 'idle)`);
  await page.locator(".queued").filter({ hasText: "Later please" }).waitFor({ state: "detached" });
  await feed().locator(".prompt").getByText("Later please").waitFor();
  assert.deepEqual((await log()).map((e) => [e.op, e.text]), [["submit", "Later please"]]);
});

test("permission choice and question form", async () => {
  await env.el(`(e2e-set "alpha" :status 'waiting :choices '(("allow" "Allow once") ("deny" "Reject")))`);
  const choices = page.locator(".permission-card:not(.question-form) .choices");
  await choices.getByRole("button", { name: "Allow once", exact: true }).click();
  await choices.waitFor({ state: "detached" });
  assert.deepEqual((await log()).map((e) => [e.op, e.key]), [["choose", "allow"]]);
  const form = { id: "q-1", message: "Which layout?", answerable: true,
    fields: [{ key: "layout", type: "single", title: "Layout", required: true, options: [{ value: "split", title: "Split by concern" }, { value: "one", title: "One file" }] },
      { key: "note", type: "text", title: "Anything else?" }] };
  await env.el(`(e2e-set "alpha" :status 'waiting :form (json-parse-string ${lisp(JSON.stringify(form))} :object-type 'plist :array-type 'list))`);
  const card = page.locator(".question-form");
  await card.getByText("Split by concern").click();
  await card.getByRole("textbox", { name: "Anything else?" }).fill("keep it small");
  await card.getByRole("button", { name: "Submit", exact: true }).click();
  await card.locator(".inline-feedback").getByText("Response sent. Waiting for the agent…").waitFor();
  const [answer] = await log();
  assert.equal(answer.op, "answer");
  assert.equal(answer.form, "q-1");
  assert.equal(answer.action, "accept");
  assert.deepEqual(JSON.parse(answer.values), { layout: "split", note: "keep it small" });
  await card.waitFor({ state: "detached" });
});

test("session action asks each confirmation Emacs raises", async () => {
  await page.getByRole("button", { name: "Conversation actions", exact: true }).click();
  await page.locator(".actions-modal.modal-in .actions-button").filter({ hasText: "New conversation" }).click();
  const dialog = page.locator(".dialog.modal-in");
  await dialog.getByText("Start a fresh conversation? Unsent prompts may be lost.").waitFor();
  await dialog.locator(".dialog-button").last().click();
  await page.locator(".dialog.modal-in").getByText("Agent is busy. Restart anyway?").waitFor();
  assert.deepEqual(await log(), [], "nothing runs before the last confirmation");
  await page.locator(".dialog.modal-in .dialog-button").last().click();
  await page.locator(".toast").getByText("New conversation: done").waitFor();
  assert.deepEqual((await log()).map((e) => [e.op, e.action]), [["action", "restart"]]);
});

test("upload an image into the prompt", async () => {
  await page.locator("#files").setInputFiles({ name: "pixel.png", mimeType: "image/png", buffer: PNG });
  await page.locator(".attachment").getByText("Attached", { exact: true }).waitFor();
  assert.match(await page.locator("#text").inputValue(), /@phone-\d{8}-\d{6}-\d{3}\.png/);
  const [attach] = await log();
  assert.deepEqual([attach.op, attach.bytes], ["attach", PNG.length]);
  await page.getByRole("button", { name: "Remove pixel.png", exact: true }).click();
  await page.locator("#text").fill("");
});

test("history pages in older items", async () => {
  await env.el('(e2e-history "beta" 40)');
  await openConversation(beta);
  const more = page.getByRole("button", { name: "Load earlier messages", exact: true });
  await more.waitFor();
  assert.equal(await feed().locator(".prompt").getByText("Question 1", { exact: true }).count(), 0);
  await until(async () => {
    if (await more.isVisible()) await more.click();
    return await feed().locator(".prompt").count() === 40;
  }, { interval: 200, what: "all history pages" });
  assert.equal((await feed().locator(".prompt").first().innerText()).split("\n")[0], "Question 1");
});

test("node command with confirmation, and one that opens a conversation", async () => {
  await env.el('(progn (e2e-make-agent "doomed") t)');
  await page.goto(`${env.base}/overlook/#${env.token}`);
  await page.locator("#dashboard-content").getByText("shop", { exact: true }).click();
  await settled();
  const row = page.locator(".conversation-row").filter({ hasText: "Work on doomed" });
  await row.getByRole("button", { name: /^Actions for/ }).click();
  await page.locator(".actions-button").filter({ hasText: "Kill" }).click();
  await page.locator(".dialog.modal-in").getByText(/Kill agent doomed@shop/).waitFor();
  await page.locator(".dialog.modal-in .dialog-button").last().click();
  await row.waitFor({ state: "detached" });
  assert.equal(await env.el('(buffer-live-p (e2e-agent "doomed"))'), null);

  await page.getByRole("button", { name: "New conversation in shop", exact: true }).click();
  await page.locator(".remote-sheet textarea").fill("Write the README");
  await page.locator(".remote-sheet select").selectOption("codex");
  await page.locator(".remote-sheet").getByRole("button", { name: "New agent", exact: true }).click();
  await page.waitForURL((url) => url.searchParams.has("agent"));
  await page.locator("#heading .navigation-title").getByText(/Work on agent/).waitFor();
  assert.match(await page.locator("#text").inputValue(), /Write the README/);
  assert.deepEqual((await log()).map((e) => [e.op, e.task, e.provider]), [["new", "Write the README", "codex"]]);
});

test("Emacs disconnecting shows the offline banner until it is back", async () => {
  await openConversation(alpha);
  await env.el("(progn (overlook-remote-bridge-mode -1) t)");
  await page.locator("#connection").getByText(/Emacs is not connected/).waitFor();
  await env.el("(progn (overlook-remote-bridge-mode 1) t)");
  await page.locator("#connection").waitFor({ state: "hidden" });
  await env.el(`(e2e-stream "alpha" "After reconnecting." 100 0.01)`);
  await feed().getByText("After reconnecting.").waitFor();
});

test("daemon restart: the bridge reconnects and the page catches up", async () => {
  await env.stopDaemon();
  await page.locator("#connection").getByText(/Reconnecting|not connected|offline/i).waitFor();
  await env.el(`(e2e-stream "alpha" "Written while the daemon was down." 100 0.01)`);
  await env.startDaemon();
  await until(async () => (await env.health()).emacs === "online", { what: "the bridge to reconnect" });
  await page.locator("#connection").waitFor({ state: "hidden", timeout: 40000 });
  await feed().getByText("Written while the daemon was down.").waitFor();
  await env.el(`(e2e-stream "alpha" "And live again." 100 0.01)`);
  await feed().getByText("And live again.").waitFor();
  // A conversation without retained history shows its last reply, asked of Emacs.
  await openConversation(await env.el("(overlook-data-agent-id (cdar e2e-agents))"));
  await page.locator("#d-earlier").getByText("Earlier reply.").waitFor();
  assert.deepEqual(problems, []);
});
