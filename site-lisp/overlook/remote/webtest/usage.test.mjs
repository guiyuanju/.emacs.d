import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { start, TOKEN } from "./server.mjs";
const require = createRequire(import.meta.url);
const { launch, unavailable } = require("./browser.cjs");
let browser, devices;
const skip = unavailable() || false;
before(async () => { if (!skip) ({ browser, devices } = await launch()); });
after(async () => { await browser?.close(); });
const tokens = (n) => ({ input: n, cacheRead: n * 3, cacheWrite: n, output: n * 2 });
const bucket = (key, n) => ({ key, label: key, tokens: tokens(n), sessions: 2, events: 3 });
function fixture(days = 30) {
  return { ready: true, updated: "2026-11-17T04:00:00Z", first: "2026-10-01T00:00:00Z", days,
    timezone: "Asia/Tokyo", sources: ["Claude CLI", "Codex CLI"], scanErrors: 0,
    total: bucket("", 30000), previous: tokens(20000),
    daily: Array.from({ length: days }, (_, i) => bucket(`day-${i + 1}`, i * 100)),
    heat: Array.from({ length: 84 }, (_, i) => ({ weekday: Math.floor(i / 12), hour: (i % 12) * 2, tokens: tokens(i * 10), days: 4, activeDays: i ? 2 : 0 })),
    providers: [bucket("claude", 1000), bucket("codex", 3000)],
    projects: Array.from({ length: 8 }, (_, i) => bucket(`project-${i}-with-a-long-name`, (8 - i) * 1000)),
    sessions: [bucket("session-one", 3000)], providerOptions: ["claude", "codex"],
    projectOptions: Array.from({ length: 8 }, (_, i) => `project-${i}-with-a-long-name`) };
}
for (const theme of ["light", "dark"]) test(`consumption charts, filters and retry (${theme})`, { skip }, async (t) => {
  const server = await start(0, { coalesceMs: 40 });
  const context = await browser.newContext({ ...devices["iPhone SE"], colorScheme: theme });
  const page = await context.newPage(); page.setDefaultTimeout(10000);
  const errors = [], queries = []; let fail = false;
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().startsWith("Failed to load resource")) errors.push(m.text()); });
  await page.addInitScript(() => document.addEventListener("securitypolicyviolation", (e) => console.error(`CSP ${e.violatedDirective}`)));
  await page.route("**/overlook/api/usage?*", async (route) => {
    const q = new URL(route.request().url()).searchParams; queries.push(Object.fromEntries(q));
    await route.fulfill({ status: fail ? 503 : 200, contentType: "application/json", body: JSON.stringify(fail ? { detail: "Try again" } : fixture(Number(q.get("days")))) });
  });
  t.after(async () => { await context.close(); await server.close(); });
  await page.goto(server.url + "?tab=usage#" + TOKEN);
  await page.locator(".usage-total").waitFor();
  assert.equal(await page.locator(".usage-day").count(), 30);
  assert.equal(await page.locator(".usage-cell").count(), 84);
  await page.locator(".usage-day").nth(10).click();
  assert.match(await page.locator(".usage-inspect").first().innerText(), /day-11/);
  await page.getByRole("button", { name: /^Tue 08/ }).click();
  assert.match(await page.locator(".usage-inspect").nth(1).innerText(), /2 active \/ 4 calendar days/);
  await page.getByLabel("Measure", { exact: true }).selectOption("output");
  assert.equal(await page.locator(".usage-total").innerText(), "60K");
  const agents = page.locator(".usage-card").filter({ has: page.getByRole("heading", { name: "By agent", exact: true }) });
  assert.equal(await agents.locator(".usage-rank-name").first().innerText(), "codex");
  await agents.locator("button.usage-rank").first().click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Agent"]').value === "codex");
  assert.equal(queries.at(-1).provider, "codex");
  await page.getByLabel("Period", { exact: true }).selectOption("7");
  await page.waitForFunction(() => document.querySelectorAll(".usage-day").length === 7);
  const projects = page.locator(".usage-card").filter({ has: page.getByRole("heading", { name: "By project", exact: true }) });
  assert.equal(await projects.locator(".usage-rank").count(), 5);
  await projects.getByRole("button", { name: "Show all 8" }).click();
  assert.equal(await projects.locator(".usage-rank").count(), 8);
  await projects.locator("button.usage-rank").first().click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Project"]').value.startsWith("project-0"));
  assert(queries.at(-1).project.startsWith("project-0"));
  fail = true; await page.getByLabel("Period", { exact: true }).selectOption("90");
  await page.getByRole("button", { name: "Retry", exact: true }).waitFor();
  assert.equal(await page.locator(".usage-total").innerText(), "60K");
  assert.equal(await page.getByLabel("Period", { exact: true }).inputValue(), "90");
  assert.match(await page.locator(".usage-analytics > [role=status]").innerText(), /Still showing: 7 days · codex · project-0/);
  assert.match(await page.locator(".usage-card").first().innerText(), /7 days including today/);
  await page.getByLabel("Measure", { exact: true }).selectOption("input");
  assert.equal(await page.locator(".usage-total").innerText(), "30K");
  assert.match(await page.locator(".usage-analytics > [role=status]").innerText(), /Still showing: 7 days/);
  fail = false; await page.getByRole("button", { name: "Retry", exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll(".usage-day").length === 90);
  assert.doesNotMatch(await page.locator(".usage-analytics > [role=status]").innerText(), /Still showing/);
  const overflows = await page.locator(".usage-analytics, .usage-card, .usage-heat").evaluateAll((nodes) => nodes.filter((n) => n.scrollWidth > n.clientWidth + 1).map((n) => n.className));

  assert.deepEqual(overflows, []);
  await page.screenshot({ path: `/private/tmp/overlook-usage-${theme}.png`, fullPage: true });
  await page.getByRole("heading", { name: "When you use agents" }).scrollIntoViewIfNeeded();
  await page.screenshot({ path: `/private/tmp/overlook-usage-heat-${theme}.png` });
  assert.deepEqual(errors, []);
});
