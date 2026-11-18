// Consumption analytics keep their filters and selection while the dashboard refreshes.
import { get } from "js/api.js";
import { el } from "js/ui.js";
import { state } from "js/state.js";

const PARTS = [
  ["input", "Uncached input"], ["cacheRead", "Cache read"],
  ["cacheWrite", "Cache write"], ["output", "Output"],
];
const WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const number = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const exact = new Intl.NumberFormat("en");
const filters = { days: "30", provider: "", project: "", metric: "total" };
let root, controls, content, status, report, displayedFilters, controller, fetched = 0;
const active = () => !state.route.conversation && !state.route.node && state.route.tab === "usage" && !document.hidden;
export const tokenValue = (tokens, metric = "total") => metric === "total"
  ? PARTS.reduce((sum, [key]) => sum + (tokens?.[key] || 0), 0) : tokens?.[metric] || 0;
const value = (tokens) => tokenValue(tokens, filters.metric);
const metricLabel = () => filters.metric === "total" ? "tokens" : PARTS.find(([key]) => key === filters.metric)[1].toLowerCase() + " tokens";
const detail = (tokens) => PARTS.map(([key, label]) => `${label}: ${exact.format(tokens?.[key] || 0)}`).join(" · ");

function plainButton(className) {
  const button = document.createElement("button"); button.type = "button"; button.className = className; return button;
}
function section(title, subtitle) {
  const box = el("section", "usage-card");
  box.append(el("h2", "", title));
  if (subtitle) box.append(el("p", "usage-caption", subtitle));
  return box;
}
function select(label, options, key) {
  const wrapper = el("label", "usage-select");
  wrapper.append(el("span", "", label));
  const input = el("select"); input.setAttribute("aria-label", label);
  for (const [id, title] of options) {
    const option = el("option", "", title); option.value = id; option.selected = filters[key] === id; input.append(option);
  }
  input.onchange = () => { filters[key] = input.value; if (key === "metric") draw(); else load(true); };
  wrapper.append(input); return wrapper;
}
function drawControls() {
  controls.replaceChildren(
    select("Period", [["7", "7 days"], ["30", "30 days"], ["90", "90 days"]], "days"),
    select("Measure", [["total", "All tokens"], ...PARTS], "metric"),
    select("Agent", [["", "All agents"], ...(report?.providerOptions || []).map((x) => [x, x])], "provider"),
    select("Project", [["", "All projects"], ...(report?.projectOptions || []).map((x) => [x, x])], "project"),
  );
}
function stack(tokens, maximum) {
  const track = el("span", "usage-stack"); track.setAttribute("aria-hidden", "true");
  const parts = filters.metric === "total" ? PARTS : PARTS.filter(([key]) => key === filters.metric);
  for (const [key] of parts) {
    const part = el("span", "usage-part usage-part-" + key);
    part.style.width = `${maximum ? Math.min(100, (tokens?.[key] || 0) / maximum * 100) : 0}%`;
    track.append(part);
  }
  return track;
}
function legend() {
  const box = el("div", "usage-legend");
  for (const [key, label] of PARTS) {
    if (filters.metric !== "total" && filters.metric !== key) continue;
    const item = el("span", "", label); item.prepend(el("i", "usage-part-" + key)); box.append(item);
  }
  return box;
}
function summary() {
  const box = section("Consumption", `${report.days} days including today · ${report.timezone}`);
  box.append(el("div", "usage-total", number.format(value(report.total.tokens))),
    el("p", "usage-caption", `${metricLabel()} · ${report.total.sessions} sessions · ${report.projects.length} projects`),
    stack(report.total.tokens, value(report.total.tokens)), legend());
  const prev = value(report.previous);
  box.append(el("p", "usage-caption", `Previous period: ${number.format(prev)} ${metricLabel()}. Available logs only; today is partial.`));
  return box;
}
function trend() {
  const box = section("Daily consumption", "Tap a day to inspect its token breakdown.");
  const chart = el("div", "usage-trend"); chart.setAttribute("aria-label", "Daily consumption chart");
  const max = Math.max(1, ...report.daily.map((x) => value(x.tokens)));
  const selected = el("p", "usage-inspect"); selected.setAttribute("aria-live", "polite");
  const inspect = (entry, button) => {
    for (const item of chart.children) item.setAttribute("aria-pressed", String(item === button));
    selected.textContent = `${entry.key} · ${exact.format(value(entry.tokens))} ${metricLabel()} · ${entry.sessions} sessions. ${detail(entry.tokens)}`;
  };
  report.daily.forEach((entry, index) => {
    const button = plainButton("usage-day"); button.type = "button";
    button.setAttribute("aria-label", `${entry.key}: ${exact.format(value(entry.tokens))} ${metricLabel()}`);
    const column = el("span", "usage-column"); column.style.height = `${value(entry.tokens) / max * 100}%`;
    const parts = filters.metric === "total" ? PARTS : PARTS.filter(([key]) => key === filters.metric);
    for (const [key] of parts) {
      const part = el("span", "usage-part-" + key); part.style.height = `${value(entry.tokens) ? (entry.tokens[key] || 0) / value(entry.tokens) * 100 : 0}%`; column.append(part);
    }
    button.append(column); button.onclick = () => inspect(entry, button); chart.append(button);
    if (index === report.daily.length - 1) inspect(entry, button);
  });
  const axis = el("div", "usage-axis");
  axis.append(el("span", "", report.daily[0]?.key || ""), el("span", "", `${number.format(max)} peak`), el("span", "", report.daily.at(-1)?.key || ""));
  box.append(chart, axis, selected); return box;
}
function heatmap() {
  const box = section("When you use agents", "Average per weekday and 2-hour slot. Completed days only; tap a cell for details.");
  const grid = el("div", "usage-heat");
  const selected = el("p", "usage-inspect"); selected.setAttribute("aria-live", "polite");
  grid.append(el("span"));
  for (let hour = 0; hour < 24; hour += 2) grid.append(el("span", "usage-heat-hour", hour % 4 === 0 ? String(hour).padStart(2, "0") : ""));
  const average = (cell) => cell.days ? value(cell.tokens) / cell.days : 0;
  const max = Math.max(1, ...report.heat.map(average));
  WEEK.forEach((name, weekday) => {
    grid.append(el("span", "usage-heat-day", name));
    for (const cell of report.heat.filter((x) => x.weekday === weekday)) {
      const avg = average(cell);
      const level = avg > 0 ? Math.max(1, Math.ceil(avg / max * 4)) : 0;
      const button = plainButton("usage-cell usage-heat-" + level); button.type = "button";
      const time = `${String(cell.hour).padStart(2, "0")}–${String(cell.hour + 2).padStart(2, "0")}`;
      const label = `${name} ${time}: ${cell.activeDays ? number.format(avg) + " " + metricLabel() + "/day" : "no recorded consumption"}`;
      button.setAttribute("aria-label", label); button.title = label;
      button.onclick = () => {
        for (const item of grid.querySelectorAll("button")) item.setAttribute("aria-pressed", String(item === button));
        selected.textContent = `${label} · ${cell.activeDays} active / ${cell.days} calendar days. Total: ${exact.format(value(cell.tokens))}.`;
      };
      grid.append(button);
    }
  });
  const scale = el("div", "usage-heat-scale"); scale.append(el("span", "", "No records"));
  for (let i = 0; i <= 4; i++) scale.append(el("i", "usage-heat-" + i));
  scale.append(el("span", "", "More"));
  selected.textContent = "Blank cells mean no consumption was found in available logs; they do not prove zero usage.";
  box.append(grid, scale, selected); return box;
}
function ranking(title, entries, key) {
  const box = section(title, key ? "Tap to filter all charts. Bars show token composition." : "Sessions remain here after they are closed.");
  if (!entries.length) { box.append(el("p", "usage-caption", "No records in this period.")); return box; }
  const max = Math.max(1, ...entries.map((x) => value(x.tokens)));
  const sorted = [...entries].sort((a, b) => value(b.tokens) - value(a.tokens) || a.key.localeCompare(b.key));
  const rows = el("div", "usage-ranks");
  const fill = (all) => {
    rows.replaceChildren();
    for (const entry of sorted.slice(0, all ? sorted.length : 5)) {
      const item = key ? plainButton("usage-rank") : el("div", "usage-rank");
      if (key) { item.type = "button"; item.onclick = () => { filters[key] = entry.key; load(true); }; }
      const heading = el("span", "usage-rank-heading");
      heading.append(el("span", "usage-rank-name", entry.label), el("span", "usage-rank-value", number.format(value(entry.tokens))));
      const description = el("span", "usage-caption", `${entry.sessions} sessions · ${metricLabel()}`);
      item.append(heading, stack(entry.tokens, max), description);
      item.title = detail(entry.tokens);
      if (!key) { const more = el("details", "usage-session-detail"); more.append(el("summary", "", "Token breakdown"), el("p", "usage-caption", detail(entry.tokens))); item.append(more); }
      rows.append(item);
    }
  };
  fill(false); box.append(rows);
  if (entries.length > 5) {
    const more = el("button", "link usage-more", `Show all ${entries.length}`); more.type = "button";
    let all = false; more.onclick = () => { all = !all; fill(all); more.textContent = all ? "Show less" : `Show all ${entries.length}`; }; box.append(more);
  }
  return box;
}
function draw() {
  drawControls();
  if (!report) return;
  if (!report.ready && !report.total?.events) {
    content.replaceChildren(el("p", "usage-caption", report.warning || "Importing local consumption history…")); return;
  }
  if (!report.total.events) {
    content.replaceChildren(el("p", "usage-caption", "No consumption records match this period and these filters.")); return;
  }
  content.replaceChildren(summary(), trend(), heatmap(), ranking("By agent", report.providers, "provider"),
    ranking("By project", report.projects, "project"), ranking("By session", report.sessions));
  const first = report.first ? new Date(report.first).toLocaleDateString("en") : "—";
  content.append(el("p", "usage-footnote", `Sources: ${report.sources.join(", ")}. Earliest matching record: ${first}. Tokens measure workload, not subscription charges or efficiency. Cache reads are counted once; reasoning is included in output. Log timestamps determine the time slot. Other agents and other Macs are not included.`));
}
const displayedDescription = () => displayedFilters
  ? `${displayedFilters.days} days · ${displayedFilters.provider || "all agents"} · ${displayedFilters.project || "all projects"}` : "";
async function load(force = false) {
  if (!force && (controller || Date.now() - fetched < 60000)) return;
  controller?.abort(); const current = new AbortController(); controller = current;
  status.textContent = report ? `Updating… Still showing: ${displayedDescription()}.` : "Loading consumption history…";
  const requestedFilters = { days: filters.days, provider: filters.provider, project: filters.project };
  const query = new URLSearchParams(requestedFilters);
  root.setAttribute("aria-busy", "true");
  try {
    const next = await get("usage?" + query, { signal: current.signal });
    if (controller !== current) return;
    report = next; displayedFilters = requestedFilters; fetched = Date.now(); draw();
    status.textContent = next.warning || (next.ready ? `Updated ${new Date(next.updated).toLocaleTimeString("en", { hour: "2-digit", minute: "2-digit" })} · checks every minute` : "Importing local history…");
    if (next.scanErrors) status.textContent += ` · ${next.scanErrors} sources could not be fully read`;
  } catch (error) {
    if (current.signal.aborted) return;
    const previous = displayedFilters ? ` Still showing: ${displayedDescription()}.` : "";
    status.replaceChildren(el("span", "", `Consumption unavailable: ${error.message}.${previous} `));
    const retry = el("button", "link", "Retry"); retry.type = "button"; retry.onclick = () => load(true); status.append(retry);
  } finally {
    if (controller === current) { controller = null; root.setAttribute("aria-busy", "false"); }
  }
}
export function usageAnalytics() {
  if (!root) {
    root = el("section", "usage-analytics"); root.setAttribute("aria-label", "Consumption analytics");
    controls = el("div", "usage-filters"); content = el("div", "usage-charts"); status = el("p", "usage-footnote"); status.setAttribute("role", "status");
    root.append(controls, status, content); drawControls();
    setInterval(() => { if (active()) load(); }, 60000);
    document.addEventListener("visibilitychange", () => { if (active()) load(); });
  }
  load(); return root;
}
