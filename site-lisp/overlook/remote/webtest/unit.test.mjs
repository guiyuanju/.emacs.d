// Unit tests for the page's pure logic: run with node --import ./register.mjs --test.
import test from "node:test";
import assert from "node:assert/strict";
import * as model from "js/model.js";
import { SSEParser } from "js/sse.js";
import { state, remember, draft, holdConversation } from "js/state.js";
import { Stream, backoff } from "js/stream.js";

const node = (id, extra = {}) => ({ id, hash: "h" + id, kind: "text", title: id, ...extra });

test("expandNodes replaces same references and fails on unknown hashes", () => {
  const first = [node("a", { children: [node("b"), node("c")] })];
  const known = model.indexNodes(first);
  const delta = [{ ...node("a", { hash: "h2" }), children: [{ same: "hb" }, node("c", { hash: "hc2", title: "C" })] }];
  const expanded = model.expandNodes(delta, known);
  assert.equal(expanded[0].children[0], first[0].children[0]);
  assert.equal(expanded[0].children[1].title, "C");
  assert.throws(() => model.expandNodes([{ same: "missing" }], known), model.Stale);
  assert.deepEqual(model.expandNodes([{ same: "ha" }], known), [first[0]]);
});

test("nodePath and findNodes count each conversation once", () => {
  const tree = [node("p", { children: [node("r", { children: [node("x")] })] })];
  assert.deepEqual(model.nodePath("x", tree).map((item) => item.id), ["p", "r", "x"]);
  assert.equal(model.nodePath("gone", tree), null);
  const project = { children: [
    { kind: "agent", conversation: "a", status: "working" },
    { kind: "group", children: [{ kind: "agent", conversation: "b", status: "working" },
      { kind: "agent", conversation: "a", status: "working" }, { kind: "agent", conversation: "c", status: "waiting" }] },
    { kind: "saved", status: "working" }, { kind: "agent", conversation: "d", status: "idle" }] };
  assert.deepEqual(model.agentSummary(project), [["working", 2], ["waiting", 1]]);
  assert.deepEqual(model.agentSummary({ children: [] }), []);
});

test("dashboard helpers order, date and label", () => {
  assert.deepEqual([{ children: [{ kind: "usage" }] }, { children: [{ kind: "project" }] }, { children: [{ kind: "persona" }] },
    { children: [{ kind: "tasks" }] }].map(model.sectionTab), ["usage", "projects", "personas", "inbox"]);
  assert.deepEqual(model.stableProjects([{ id: "z", title: "Zulu", kind: "project" }, { id: "r", title: "R", kind: "text" },
    { id: "a", title: "Alpha", kind: "project" }]).map((item) => item.id), ["a", "r", "z"]);
  assert.equal(model.dueLabel("2026-11-12", new Date(2026, 10, 12)).label, "Due today");
  assert.equal(model.dueLabel("2026-11-11", new Date(2026, 10, 12)).overdue, true);
  assert.equal(model.dueLabel("2026-11-20", new Date(2026, 10, 12)).label, "Due 2026-11-20");
  const now = Date.UTC(2026, 10, 13);
  assert.equal(model.resetLabel(now / 1000 + 90 * 60, now), "1h 30m");
  assert.equal(model.resetLabel(now / 1000 + 26 * 3600, now), "1d 2h");
  assert.equal(model.resetLabel("2h 10m", now), "2h 10m");
  assert.equal(model.shownBranch({ kind: "repo", title: "main", branch: "main" }), null);
  assert.equal(model.shownBranch({ kind: "repo", title: "api", branch: "fix" }, "fix"), null);
  assert.equal(model.shownBranch({ kind: "repo", title: "web", branch: "hotfix" }, "fix"), "hotfix");
  const sections = [{ id: "p", title: "Personas", children: [{ kind: "persona", persona: "S" }] },
    { id: "j", title: "Projects", children: [{ kind: "project" }] }, { id: "u", title: "Usage", children: [{ kind: "usage" }] }];
  assert.deepEqual(model.orderSections(sections).map((section) => section.id), ["u", "j", "p"]);
  assert.equal(model.attentionNodes([{ children: [{ conversation: "a", status: "waiting" }, { conversation: "b", choices: [{}] },
    { conversation: "c", status: "idle" }, { status: "failed" }] }]).length, 2);
  assert.equal(model.personaStatus({ children: [{ conversation: "a", status: "done" }, { conversation: "b", status: "working" }] }), "working");
  assert.equal(model.personaStatus({ children: [] }), "offline");
  assert.equal(model.unreadOf({ children: [{ conversation: "a", unreadCount: 2 }, { conversation: "b", unreadCount: 3 }] }), 5);
});

test("group sections split conversations, tasks, code and resources", () => {
  const project = { kind: "project", children: [{ kind: "agent" }, { kind: "saved" }, { kind: "todo" }, { kind: "repo" },
    { kind: "text", children: [{ kind: "x", diff: true }] }, { kind: "text" }] };
  assert.deepEqual(model.groupSections(project).map(([title, nodes]) => [title, nodes.length]),
    [["Conversations", 2], ["To do", 1], ["Code & changes", 2], ["Resources", 1]]);
  assert.deepEqual(model.groupSections({ kind: "persona", children: [{ kind: "agent" }, { kind: "saved" }] }).map(([title]) => title),
    ["Conversations", "Saved conversations"]);
});

test("routes keep the old query strings", () => {
  assert.deepEqual(model.parseRoute("?agent=conversation-1"), { conversation: "conversation-1", node: null, tab: null });
  assert.deepEqual(model.parseRoute("?node=abc"), { conversation: null, node: "abc", tab: null });
  assert.deepEqual(model.parseRoute("?conversation=c"), { conversation: "c", node: null, tab: null });
  assert.equal(model.parseRoute("?tab=inbox").tab, "inbox");
  assert.equal(model.parseRoute("?tab=bogus").tab, null);
  assert.equal(model.formatRoute({ tab: "agents" }), "");
  assert.equal(model.formatRoute({ node: "abc", tab: "projects" }), "?node=abc&tab=projects");
  assert.equal(model.formatRoute({ node: "abc", conversation: "c d" }), "?node=abc&agent=c+d");
  assert.equal(model.formatRoute({}), "");
  assert.equal(model.streamQuery({ dashboard: "" }), "dashboard=");
  assert.equal(model.streamQuery({ conversation: "c", after: 4, known: "k", epoch: "e" }), "conversation=c&after=4&known=k&epoch=e");
});

const snapshot = (items, extra = {}) => ({ epoch: "e1", seq: 5, known: "k1", conversation: { id: "c", status: "idle", controls: { actions: ["close"] } },
  items, history: { hasMore: false }, ...extra });

test("deltas append text suffixes at UTF-16 offsets", () => {
  const held = model.conversationFromSnapshot(snapshot([{ item: 1, seq: 5, type: "text", text: "Hi 🎉" }]));
  assert.equal("Hi 🎉".length, 5);
  let touched = model.applyDelta(held, { epoch: "e1", seq: 6, known: "k1", items: [{ item: 1, seq: 6, type: "text", text: " 中文", offset: 5 }] });
  assert.deepEqual(touched, [1]);
  assert.equal(held.items.get(1).text, "Hi 🎉 中文");
  assert.equal(held.seq, 6);
  touched = model.applyDelta(held, { epoch: "e1", seq: 7, known: "k2", conversation: { id: "c", status: "working" },
    items: [{ item: 2, seq: 7, type: "tool", status: "pending", title: "Read" }] });
  assert.deepEqual(touched, [2]);
  assert.equal(held.conversation.status, "working");
  model.applyDelta(held, { epoch: "e1", seq: 8, known: "k2", items: [{ item: 2, seq: 8, type: "tool", status: "completed" }] });
  assert.equal(held.items.get(2).status, "completed");
  assert.equal(held.items.get(2).title, undefined, "tool items arrive whole");
  assert.equal(model.applyDelta(held, { epoch: "e1", seq: 9, known: "k2", items: [{ item: 1, seq: 9, type: "text", text: "x", offset: 3 }] }), null);
  assert.equal(model.applyDelta(held, { epoch: "e2", seq: 1, known: "k" }), null);
  const fresh = model.conversationFromSnapshot(snapshot([]));
  assert.equal(model.applyDelta(fresh, { epoch: "e1", seq: 6, known: "k", items: [{ item: 9, seq: 6, type: "text", text: "tail", offset: 4 }] }), null);
});

test("deltas skip items below the loaded history floor and history pages prepend", () => {
  const held = model.conversationFromSnapshot(snapshot([{ item: 10, seq: 5, type: "prompt", text: "q" }], { history: { hasMore: true, before: 10 } }));
  assert.deepEqual(model.applyDelta(held, { epoch: "e1", seq: 6, known: "k", items: [{ item: 3, seq: 6, type: "tool", status: "completed" }] }), []);
  assert.equal(held.items.has(3), false);
  const added = model.applyHistory(held, { epoch: "e1", hasMore: false, items: [{ item: 3, seq: 6, type: "tool" }, { item: 10, seq: 5, type: "prompt" }] });
  assert.deepEqual(added, [3]);
  assert.equal(held.history, null);
  assert.deepEqual(model.sortedItems(held).map((item) => item.item), [3, 10]);
  assert.equal(model.latestItemSeq(held), 6);
});

test("earlier is dropped once items arrive", () => {
  const held = model.conversationFromSnapshot(snapshot([], { earlier: { reply: "r", transcript: "t" } }));
  assert.equal(held.earlier.reply, "r");
  model.applyDelta(held, { epoch: "e1", seq: 6, known: "k", items: [{ item: 1, seq: 6, type: "prompt", text: "p" }] });
  assert.equal(held.earlier, null);
});

test("toolRuns finds runs of three or more completed tools", () => {
  const tool = (status) => ({ type: "tool", status });
  assert.deepEqual(model.toolRuns([tool("completed"), tool("completed"), tool("completed"), { type: "text" },
    tool("completed"), tool("completed"), tool("failed"), tool("completed"), tool("completed"), tool("completed"), tool("completed")]), [[0, 3], [7, 4]]);
  assert.deepEqual(model.toolRuns([tool("completed"), tool("completed")]), []);
});

test("slash commands, drafts and labels", () => {
  const slash = [{ name: "/compact" }, { name: "/clear" }, { name: "help" }, { name: "$find-skills" }];
  assert.deepEqual(model.slashMatches("/", slash).length, 4);
  assert.deepEqual(model.slashMatches("/c", slash).map((item) => item.name), ["/compact", "/clear"]);
  assert.deepEqual(model.slashMatches("/find", slash).map((item) => item.name), ["$find-skills"]);
  assert.deepEqual(model.slashMatches("/c x", slash), []);
  assert.equal(model.slashText({ name: "/compact" }), "/compact ");
  assert.equal(model.slashText({ name: "$find-skills" }), "/$find-skills ");
  assert.equal(model.appendDraft("", "@a.png"), "@a.png ");
  assert.equal(model.appendDraft("Look  ", "@a.png"), "Look @a.png ");
  assert.deepEqual(model.confirmStyle("Delete <file>?"), { label: "Delete", danger: true });
  assert.deepEqual(model.confirmStyle("Close agent X?"), { label: "Close", danger: false });
  assert.deepEqual(model.confirmStyle("Proceed?", "Go", true), { label: "Go", danger: true });
  const settings = [{ id: "model", label: "Model", value: "opus", choices: [{ value: "opus", name: "Opus" }] }];
  assert.equal(model.actionLabel("model", settings), "Model · Opus");
  assert.equal(model.actionLabel("close", settings), "Close agent");
  assert.equal(model.actionLabel("custom", settings), "custom");
  assert.match(model.randomKey(), /^[0-9a-f]{32}$/);
  assert.equal(model.longContent("x\n".repeat(19)), true);
  assert.equal(model.longContent("short"), false);
});

test("SSE parser handles split chunks, CRLF, comments and multi-line data", () => {
  const events = [];
  const parser = new SSEParser((event) => events.push(event));
  parser.push("event: hel");
  parser.push("lo\ndata: {\"a\":1}\n");
  parser.push("\n: heartbeat\n\n");
  parser.push("event: dashboard\r\nid: dashboard=k2\r\ndata: line1\r");
  parser.push("\ndata: line2\r\n\r\n");
  parser.push("data:no-space\n\nevent: x\n\n");
  assert.deepEqual(events, [
    { event: "hello", data: "{\"a\":1}", id: null },
    { event: "dashboard", data: "line1\nline2", id: "dashboard=k2" },
    { event: "message", data: "no-space", id: null },
  ]);
});

test("state remembers with a bound and keeps drafts", () => {
  const map = new Map();
  for (let i = 0; i < 5; i++) remember(map, i, i, 3);
  assert.deepEqual([...map.keys()], [2, 3, 4]);
  remember(map, 2, "again", 3);
  assert.deepEqual([...map.keys()], [3, 4, 2]);
  const a = draft("a");
  a.text = "hello";
  assert.equal(draft("a").text, "hello");
  assert.equal(draft("b").text, "");
  for (let i = 0; i < 10; i++) holdConversation({ id: "c" + i });
  assert.equal(state.conversations.size, 8);
  assert.equal(state.conversations.has("c0"), false);
});

// A fetch double serving scripted SSE bodies.
function sseResponse(chunks, { status = 200, hold = false } = {}) {
  const encoder = new TextEncoder();
  let controller;
  const body = new ReadableStream({
    start(c) { controller = c; for (const chunk of chunks) c.enqueue(encoder.encode(chunk)); if (!hold) c.close(); },
  });
  return { ok: status < 300, status, statusText: "", body, headers: new Headers({ "Content-Type": "text/event-stream", "Overlook-Protocol": "3" }),
    json: async () => ({}), close: () => controller.close() };
}

test("stream resumes from the last event id and backs off", async () => {
  assert.equal(backoff(0), 1000);
  assert.equal(backoff(10), 30000);
  const requests = [];
  const responses = [
    () => sseResponse(["event: hello\ndata: {\"protocol\":3}\n\n", "event: dashboard\nid: dashboard=k2\ndata: {\"known\":\"k2\"}\n\n"]),
    () => sseResponse([], { hold: true }),
  ];
  globalThis.fetch = async (url, options) => {
    requests.push([url, options.headers]);
    const response = responses.shift()();
    options.signal.addEventListener("abort", () => { try { response.close(); } catch (_) { /* closed */ } });
    return response;
  };
  const events = [];
  const errors = [];
  const stream = new Stream({ onEvent: (name, data) => events.push([name, data]), onError: (error) => { errors.push(error.code); return false; }, hidden: () => false });
  stream.open("dashboard=k1");
  await new Promise((resolve) => setTimeout(resolve, 1300));
  stream.close();
  assert.equal(requests[0][0], "/overlook/api/stream?dashboard=k1");
  assert.equal(requests[0][1]["Overlook-Protocol"], "3");
  assert.match(requests[0][1].Authorization, /^Bearer /);
  assert.equal(requests[1][0], "/overlook/api/stream?dashboard=k2");
  assert.deepEqual(events.map(([name]) => name), ["hello", "dashboard"]);
  assert.deepEqual(errors, ["stream_ended"]);
});

test("stream stops retrying when onError says so, and pause and resume reconnect", async () => {
  let calls = 0;
  globalThis.fetch = async () => { calls++; return { ok: false, status: 401, statusText: "", headers: new Headers(), json: async () => ({ code: "unauthorized", detail: "no" }) }; };
  const codes = [];
  const stream = new Stream({ onEvent() {}, onError: (error) => { codes.push(error.status); return true; }, hidden: () => false });
  stream.open("dashboard=");
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(calls, 1);
  assert.deepEqual(codes, [401]);
  let opened = 0;
  globalThis.fetch = async (url, options) => {
    opened++;
    const response = sseResponse(["event: hello\ndata: {}\n\n"], { hold: true });
    options.signal.addEventListener("abort", () => response.close());
    return response;
  };
  const live = new Stream({ onEvent() {}, hidden: () => false });
  live.open("dashboard=");
  await new Promise((resolve) => setTimeout(resolve, 30));
  live.pause();
  live.resume();
  live.resume();
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(opened, 2);
  live.close();
});

test("file links and sizes", () => {
  assert.equal(model.fileRef("docs/a.pdf#L2"), "docs/a.pdf");
  assert.equal(model.fileRef("/Users/me/a%20b.txt"), "/Users/me/a%20b.txt");
  assert.equal(model.fileRef("file:///tmp/x.log"), "/tmp/x.log");
  assert.equal(model.fileRef("file://localhost/tmp/x.log"), "/tmp/x.log");
  assert.equal(model.fileRef("~/notes.md"), "~/notes.md");
  for (const href of ["https://example.com/a.pdf", "mailto:a@b.c", "#top", "//cdn.example/x.js", "", null]) assert.equal(model.fileRef(href), null, href);
  assert.equal(model.fileSize(1), "1 byte");
  assert.equal(model.fileSize(999), "999 bytes");
  assert.equal(model.fileSize(2048), "2.0 KB");
  assert.equal(model.fileSize(35_400_000), "35 MB");
  assert.equal(model.fileSize(1.5e9), "1.5 GB");
});
