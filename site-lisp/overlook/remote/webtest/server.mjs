// A stand-in for overlook-remoted for page tests: serves web/ like internal/assets and fakes the protocol 3 API from the fixtures.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const WEB = path.resolve(here, "../web");
export const FIXTURES = path.resolve(here, "../testdata/fixtures");
export const TOKEN = "test-token";

const sha = (data, length = 16) => crypto.createHash("sha256").update(data).digest("hex").slice(0, length);
const types = { ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".html": "text/html; charset=utf-8",
  ".svg": "image/svg+xml", ".png": "image/png", ".webmanifest": "application/manifest+json", ".json": "application/json" };
const stable = { "/overlook/manifest.webmanifest": "remote.webmanifest", "/overlook/icon.svg": "icon.svg",
  "/overlook/apple-touch-icon.png": "icon-180.png", "/overlook/icon-192.png": "icon-192.png", "/overlook/icon-512.png": "icon-512.png" };

// The page files with hashed URLs, the import map and index.html as contract-changes.md describes.
export function buildAssets(web = WEB) {
  const files = new Map();
  const walk = (dir) => {
    for (const entry of fs.readdirSync(path.join(web, dir), { withFileTypes: true })) {
      const name = dir ? `${dir}/${entry.name}` : entry.name;
      if (entry.name.startsWith(".") || entry.name === "node_modules" || name.endsWith(".go")) continue;
      if (entry.isDirectory()) walk(name);
      else {
        const data = fs.readFileSync(path.join(web, name));
        const ext = path.extname(name);
        const url = `/overlook/assets/${name.slice(0, name.length - ext.length)}.${sha(data, 8)}${ext}`;
        files.set(name, { data, url, type: types[ext] || "application/octet-stream" });
      }
    }
  };
  walk("");
  const imports = {};
  for (const [name, file] of files) if (name.endsWith(".js")) imports[name] = file.url;
  const mapText = JSON.stringify({ imports });
  const script = `<script type="importmap">${mapText}</script>`;
  const html = files.get("index.html").data.toString()
    .replace("<!-- overlook:importmap -->", script)
    .replace(/(src|href)="assets\/([^"]+)"/g, (whole, attr, name) => files.has(name) ? `${attr}="${files.get(name).url}"` : whole);
  const csp = `default-src 'self'; script-src 'self' 'sha256-${crypto.createHash("sha256").update(mapText).digest("base64")}'; `
    + "style-src 'self'; img-src 'self' blob: data:; font-src 'self' data:; connect-src 'self'; manifest-src 'self'; "
    + "object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
  const byUrl = new Map([...files.values()].map((file) => [file.url, file]));
  return { files, byUrl, html, csp };
}

function loadFixtures(dir) {
  const read = (name) => fs.readFileSync(path.join(dir, name), "utf8").replaceAll("${FIXTURES}", dir);
  return {
    sync: JSON.parse(read("sync.json")).params,
    events: read("events.ndjson").trim().split("\n").map((line) => JSON.parse(line).params),
    live: read("live.ndjson").trim().split("\n").map((line) => JSON.parse(line)),
    responses: JSON.parse(read("responses.json")),
  };
}

const matches = (rule, params) => !rule.match || Object.entries(rule.match).every(([key, value]) => JSON.stringify(params[key]) === JSON.stringify(value));

function unifiedDiff({ file, old, new: next }) {
  const a = old ? old.split("\n") : [], b = next ? next.split("\n") : [];
  if (a.at(-1) === "") a.pop();
  if (b.at(-1) === "") b.pop();
  return [`--- ${file}`, `+++ ${file}`, `@@ -1,${a.length} +1,${b.length} @@`, ...a.map((line) => "-" + line), ...b.map((line) => "+" + line)].join("\n");
}

// The fake daemon state: dashboard versions, conversations, items, read positions and receipts.
export class FakeDaemon {
  constructor({ fixtures = FIXTURES, coalesceMs = 60 } = {}) {
    this.fx = loadFixtures(fixtures);
    this.coalesceMs = coalesceMs;
    this.epoch = "e1";
    this.emacs = "online";
    this.seq = 0;
    this.itemId = 0;
    this.versions = new Map();
    this.conversations = new Map();
    this.images = new Map();
    this.receipts = new Map();
    this.failures = [];
    this.log = [];
    this.streams = new Set();
    this.delays = [];
    this.setTree(this.fx.sync.dashboard);
    for (const conversation of this.fx.sync.conversations) this.setConversation(conversation, false);
    for (const event of this.fx.events) this.event(event, false);
    this.publishDashboard(false);
  }

  setTree(sections) { this.tree = structuredClone(sections); }

  setConversation(conversation, notify = true) {
    const { root, ...state } = conversation;
    const held = this.conversations.get(state.id) || { items: [], readThrough: 0, root };
    Object.assign(held, { state, root: root || held.root });
    held.seq = ++this.seq;
    this.conversations.set(state.id, held);
    if (notify) this.changed();
  }

  image(bytes) {
    const id = sha(bytes);
    this.images.set(id, bytes);
    return id;
  }

  imagesOf(held, list = [], text = "") {
    const ids = [];
    for (const image of list) {
      if (image.data) ids.push(this.image(Buffer.from(image.data, "base64")));
      else if (image.file && fs.existsSync(image.file)) ids.push(this.image(fs.readFileSync(image.file)));
    }
    for (const [, name] of (text || "").matchAll(/@?([\w./-]+\.(?:png|jpe?g|gif|webp))/g)) {
      const file = path.resolve(held.root || "/", name);
      if (held.root && fs.existsSync(file)) ids.push(this.image(fs.readFileSync(file)));
    }
    return ids;
  }

  event(event, notify = true) {
    const held = this.conversations.get(event.conversation);
    if (!held) return;
    const seq = ++this.seq;
    held.seq = seq;
    const items = held.items;
    const last = items.at(-1);
    const add = (fields) => {
      const item = { item: ++this.itemId, seq, createdAt: event.at, updatedAt: event.at, marks: [], ...fields };
      items.push(item);
      return item;
    };
    if (event.type === "text") {
      let item = last?.type === "text" && !last.closed ? last : null;
      if (!item) item = add({ type: "text", text: "" });
      item.text += event.text || "";
      item.seq = seq;
      item.updatedAt = event.at;
      item.marks.push([seq, item.text.length]);
      const images = this.imagesOf(held, event.images);
      if (images.length) item.images = [...(item.images || []), ...images];
    } else {
      if (last?.type === "text") last.closed = true;
      if (event.type === "tool") {
        let item = items.find((candidate) => candidate.type === "tool" && candidate.toolId === event.id);
        if (!item) item = add({ type: "tool", toolId: event.id });
        for (const key of ["title", "status", "kind"]) if (event[key]) item[key] = event[key];
        if (event.diffs) item.diff = event.diffs.map(unifiedDiff).join("\n");
        const images = this.imagesOf(held, event.images, event.output);
        if (images.length) item.images = images;
        item.seq = seq;
        item.updatedAt = event.at;
      } else if (event.type === "prompt") {
        const item = add({ type: "prompt", text: event.text });
        const images = this.imagesOf(held, [], event.text);
        if (images.length) item.images = images;
      } else if (event.type === "error") add({ type: "error", text: event.text });
      else if (event.type === "end") add({ type: "end" });
    }
    if (notify) this.changed();
  }

  unread(held) {
    return held.items.filter((item) => item.type === "text" && item.seq > held.readThrough).length;
  }

  wireConversation(held) {
    const unread = this.unread(held);
    return { ...held.state, ...(unread ? { unreadCount: unread } : {}), ...(held.readThrough ? { readThrough: held.readThrough } : {}) };
  }

  conversationHash(held) { return sha(JSON.stringify(this.wireConversation(held))); }

  // Nodes with ids, hashes and unread counts; records the version.
  publishDashboard(notify = true) {
    const build = (nodes, parentId) => nodes.map((node) => {
      const { key, children = [], ...fields } = node;
      const id = sha(parentId + "/" + key);
      const out = { id, ...fields };
      if (fields.conversation && this.conversations.has(fields.conversation)) {
        const unread = this.unread(this.conversations.get(fields.conversation));
        if (unread) out.unreadCount = unread;
      }
      const kids = build(children, id);
      if (kids.length) out.children = kids;
      out.hash = sha(JSON.stringify({ ...out, children: kids.map((kid) => kid.hash) }));
      return out;
    });
    const sections = build(this.tree, "");
    const known = sha(sections.map((section) => section.hash).join(","));
    const hashes = new Set();
    const visit = (nodes) => nodes.forEach((node) => { hashes.add(node.hash); visit(node.children || []); });
    visit(sections);
    this.versions.set(known, hashes);
    this.dashboard = { known, sections };
    if (notify) this.changed();
  }

  dashboardFor(known) {
    const held = this.versions.get(known);
    const strip = (nodes) => nodes.map((node) => held?.has(node.hash) ? { same: node.hash } : { ...node, ...(node.children ? { children: strip(node.children) } : {}) });
    return { known: this.dashboard.known, sections: strip(this.dashboard.sections) };
  }

  wireItem(item, after = 0) {
    const { marks, closed, toolId, ...wire } = item;
    if (item.type === "text") {
      const held = after ? [...marks].reverse().find(([seq]) => seq <= after)?.[1] || 0 : 0;
      wire.text = item.text.slice(held);
      if (held) wire.offset = held; else delete wire.offset;
    }
    return wire;
  }

  snapshot(held) {
    const items = held.items.slice(-50);
    const first = items[0];
    const hasMore = held.items.length > items.length;
    return { epoch: this.epoch, seq: held.seq, known: this.conversationHash(held), emacs: this.emacs,
      conversation: this.wireConversation(held), items: items.map((item) => this.wireItem(item)),
      history: hasMore ? { hasMore: true, before: first.item } : { hasMore: false } };
  }

  changed() {
    this.publishDashboardQuiet();
    for (const client of this.streams) client.dirty();
  }

  publishDashboardQuiet() { this.publishDashboard(false); }

  setEmacs(emacs) {
    this.emacs = emacs;
    for (const client of this.streams) client.send("status", { emacs });
  }

  respond(method, params) {
    const rules = this.fx.responses[method] || [];
    const rule = rules.find((candidate) => matches(candidate, params));
    if (!rule) return { result: {} };
    return rule;
  }
}

class Problem extends Error {
  constructor(status, code, detail) { super(detail); Object.assign(this, { status, code, detail }); }
}

function problem(res, status, code, detail) {
  res.writeHead(status, { "Content-Type": "application/problem+json", "Overlook-Protocol": "3",
    ...(status === 401 ? { "WWW-Authenticate": "Bearer" } : {}) });
  res.end(JSON.stringify({ type: "urn:overlook:problem:" + code, title: code, status, code, detail }));
}

function json(res, status, body, extra = {}) {
  res.writeHead(status, { "Content-Type": "application/json", "Overlook-Protocol": "3", "Cache-Control": "no-store", ...extra });
  res.end(body === null ? undefined : JSON.stringify(body));
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks);
}

// One SSE subscriber with cursors; sends only what changed since them.
class StreamClient {
  constructor(daemon, res, query) {
    Object.assign(this, { daemon, res, timer: null });
    this.dashboard = query.has("dashboard") ? query.get("dashboard") : null;
    this.conversation = query.get("conversation");
    this.after = Number(query.get("after") || 0);
    this.known = query.get("known") || "";
    this.epoch = query.get("epoch") || "";
  }

  send(event, data, id) {
    this.res.write(`event: ${event}\n${id ? `id: ${id}\n` : ""}data: ${JSON.stringify(data)}\n\n`);
  }

  id() {
    const params = new URLSearchParams();
    if (this.dashboard !== null) params.set("dashboard", this.dashboard);
    if (this.conversation) {
      params.set("conversation", this.conversation);
      params.set("after", String(this.after));
      params.set("known", this.known);
      params.set("epoch", this.epoch);
    }
    return params.toString();
  }

  dirty() {
    this.timer ??= setTimeout(() => { this.timer = null; this.flush(); }, this.daemon.coalesceMs);
  }

  flush() {
    const daemon = this.daemon;
    if (this.dashboard !== null && this.dashboard !== daemon.dashboard.known) {
      const delta = daemon.dashboardFor(this.dashboard);
      this.dashboard = delta.known;
      this.send("dashboard", delta, this.id());
    }
    if (this.conversation) {
      const held = daemon.conversations.get(this.conversation);
      if (!held) { this.send("gone", { conversation: this.conversation }); this.conversation = null; return; }
      const hash = daemon.conversationHash(held);
      if (this.epoch !== daemon.epoch || this.after > held.seq) {
        const snapshot = daemon.snapshot(held);
        Object.assign(this, { after: snapshot.seq, known: snapshot.known, epoch: snapshot.epoch });
        this.send("conversation", { ...snapshot, reset: true }, this.id());
        return;
      }
      const items = held.items.filter((item) => item.seq > this.after).map((item) => daemon.wireItem(item, this.after));
      if (!items.length && hash === this.known) { this.after = held.seq; return; }
      const delta = { epoch: daemon.epoch, seq: held.seq, known: hash };
      if (hash !== this.known) delta.conversation = daemon.wireConversation(held);
      if (items.length) delta.items = items;
      this.after = held.seq;
      this.known = hash;
      this.send("conversation", delta, this.id());
    }
  }
}

// The HTTP server; control endpoints under /__test/ drive the fake from tests.
export function createServer(daemon = new FakeDaemon(), { web = WEB } = {}) {
  let assets = buildAssets(web);
  let confirmations = 0;
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://localhost");
      const route = url.pathname;
      if (route.startsWith("/__test/")) return control(route, req, res, url);
      if (route === "/overlook" || route === "/overlook/") {
        if (process.env.OVERLOOK_WEB_RELOAD !== "0") assets = buildAssets(web);
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache",
          "Content-Security-Policy": assets.csp, "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer" });
        return res.end(assets.html);
      }
      if (stable[route]) {
        const file = assets.files.get(stable[route]);
        res.writeHead(200, { "Content-Type": file.type });
        return res.end(file.data);
      }
      if (route.startsWith("/overlook/assets/")) {
        const file = assets.byUrl.get(route);
        if (!file) return problem(res, 404, "route_missing", "No such asset");
        res.writeHead(200, { "Content-Type": file.type, "Cache-Control": "public, max-age=31536000, immutable", "X-Content-Type-Options": "nosniff" });
        return res.end(file.data);
      }
      if (route === "/overlook/healthz") return json(res, 200, { status: "ok", emacs: daemon.emacs });
      if (req.method === "GET" && route.startsWith("/overlook/files/t-")) {
        const name = decodeURIComponent(route.split("/").pop());
        res.writeHead(200, { "Content-Type": "application/octet-stream", "Content-Disposition": `attachment; filename*=utf-8''${encodeURIComponent(name)}` });
        return res.end(Buffer.alloc(2048, 120));
      }
      if (!route.startsWith("/overlook/api/")) return problem(res, 404, "route_missing", "No such route");
      if (req.headers.authorization !== "Bearer " + TOKEN) return problem(res, 401, "unauthorized", "Missing or wrong token");
      const body = ["POST", "PUT"].includes(req.method) ? await readBody(req) : null;
      const entry = { method: req.method, path: route.slice("/overlook/api".length), query: Object.fromEntries(url.searchParams),
        key: req.headers["idempotency-key"] || "", protocol: req.headers["overlook-protocol"] || "",
        type: req.headers["content-type"] || "", body: body && req.headers["content-type"]?.startsWith("application/json") ? JSON.parse(body.toString()) : body?.length };
      daemon.log.push(entry);
      const failure = daemon.failures.find((rule) => rule.method === req.method && new RegExp(rule.path).test(entry.path));
      if (failure) {
        if (--failure.times <= 0) daemon.failures.splice(daemon.failures.indexOf(failure), 1);
        if (failure.delayMs) await new Promise((resolve) => setTimeout(resolve, failure.delayMs));
        if (failure.status) return problem(res, failure.status, failure.code || "internal_error", failure.detail || "Injected failure");
      }
      await api(req, res, url, entry, body);
    } catch (error) {
      if (error instanceof Problem) return problem(res, error.status, error.code, error.detail);
      console.error(error);
      problem(res, 500, "internal_error", String(error.message));
    }
  });

  function needConversation(id) {
    const held = daemon.conversations.get(id);
    if (!held) throw new Problem(404, "conversation_missing", "That conversation is gone");
    return held;
  }

  function bridge(method, params) {
    if (daemon.emacs !== "online") throw new Problem(503, "emacs_offline", "Emacs is not connected");
    const rule = daemon.respond(method, params);
    if (rule.error) throw new Problem(rule.error.code, rule.error.data?.problem || "bridge_error", rule.error.message);
    return structuredClone(rule.result || {});
  }

  // A write with an idempotency receipt; confirm outcomes are not stored.
  async function write(res, entry, status, run) {
    const payload = JSON.stringify({ path: entry.path, body: typeof entry.body === "object" && entry.body
      ? { ...entry.body, confirmations: undefined, confirmationToken: undefined } : entry.body });
    if (entry.key && daemon.receipts.has(entry.key)) {
      const receipt = daemon.receipts.get(entry.key);
      if (receipt.payload !== payload) throw new Problem(409, "idempotency_conflict", "Key reused with another payload");
      entry.replayed = true;
      return json(res, receipt.status, receipt.body);
    }
    const result = await run();
    const code = result === null ? 204 : status;
    if (entry.key && result?.outcome !== "confirm") daemon.receipts.set(entry.key, { payload, status: code, body: result });
    return json(res, code, result);
  }

  function confirmable(result, body) {
    if (result.outcome !== "confirm") return result;
    return { outcome: "confirm", question: result.question, confirmations: [...(body.confirmations || []), result.question],
      confirmationToken: "token-" + ++confirmations };
  }

  async function api(req, res, url, entry, raw) {
    const parts = entry.path.split("/").filter(Boolean).map(decodeURIComponent);
    const body = entry.body && typeof entry.body === "object" ? entry.body : {};
    const [head, id, sub, extra] = parts;
    if (req.method === "GET" && head === "dashboard") {
      const data = daemon.dashboardFor(url.searchParams.get("known") || "");
      return json(res, 200, { emacs: daemon.emacs, ...data }, { ETag: `"${data.known}"` });
    }
    if (req.method === "GET" && head === "stream") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", "Overlook-Protocol": "3" });
      const client = new StreamClient(daemon, res, url.searchParams);
      daemon.streams.add(client);
      client.send("hello", { protocol: 3, epoch: daemon.epoch, emacs: daemon.emacs });
      client.flush();
      const heartbeat = setInterval(() => res.write(":\n\n"), 25000);
      req.on("close", () => { clearInterval(heartbeat); clearTimeout(client.timer); daemon.streams.delete(client); });
      return;
    }
    if (req.method === "GET" && head === "conversations" && !id) {
      return json(res, 200, { epoch: daemon.epoch, emacs: daemon.emacs, conversations: [...daemon.conversations.values()].map((held) => daemon.wireConversation(held)) });
    }
    if (req.method === "POST" && head === "conversations" && sub === "files") {
      needConversation(id);
      const name = String(body.path || "").split("/").pop();
      if (!name || name.startsWith("missing")) throw new Problem(404, "file_missing", "That file is not in this conversation or no longer exists");
      return json(res, 200, { name, size: 2048, url: "/overlook/files/t-1/" + encodeURIComponent(name) });
    }
    if (req.method === "GET" && head === "images") {
      const bytes = daemon.images.get(id);
      if (!bytes) throw new Problem(404, "image_missing", "No such image");
      res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "private, max-age=31536000, immutable", ETag: `"${id}"` });
      return res.end(bytes);
    }
    if (head === "nodes") {
      const path = findNodePath(id);
      if (!path) throw new Problem(404, "node_missing", "That row is gone");
      if (req.method === "GET" && sub === "diff") return json(res, 200, bridge("node.diff", { path }));
      if (req.method === "POST" && sub === "commands") {
        return write(res, entry, 200, () => {
          const confirmed = body.confirmationToken ? body.confirmations || [] : [];
          return confirmable(bridge("node.command", { path, name: extra, text: body.text, option: body.option, confirmed }), body);
        });
      }
    }
    if (head !== "conversations") throw new Problem(404, "route_missing", "No such route");
    if (req.method === "GET" && !sub) {
      const held = needConversation(id);
      const snapshot = daemon.snapshot(held);
      if (!held.items.length) {
        const earlier = bridge("conversation.earlier", { conversation: id });
        if (earlier.reply || earlier.transcript) snapshot.earlier = earlier;
      }
      return json(res, 200, snapshot, { ETag: `"${daemon.epoch}.${held.seq}.${snapshot.known}"` });
    }
    if (req.method === "GET" && sub === "history") {
      const held = needConversation(id);
      if (url.searchParams.get("epoch") !== daemon.epoch) throw new Problem(409, "history_expired", "History expired");
      const before = Number(url.searchParams.get("before"));
      const limit = Number(url.searchParams.get("limit") || 50);
      const older = held.items.filter((item) => item.item < before);
      const page = older.slice(-limit);
      return json(res, 200, { epoch: daemon.epoch, items: page.map((item) => daemon.wireItem(item)),
        hasMore: older.length > page.length, ...(older.length > page.length ? { before: page[0].item } : {}) });
    }
    if (req.method === "PUT" && sub === "read") {
      const held = needConversation(id);
      if (body.epoch !== daemon.epoch) throw new Problem(409, "state_conflict", "Another epoch");
      held.readThrough = Math.max(held.readThrough, Math.min(body.through, held.seq));
      daemon.changed();
      return json(res, 200, { readThrough: held.readThrough, unreadCount: daemon.unread(held) });
    }
    const held = needConversation(id);
    if (req.method === "POST" && sub === "prompts" && extra === "retry") {
      return write(res, entry, 204, () => { bridge("conversation.retry", { conversation: id }); delete held.state.queueError; daemon.changed(); return null; });
    }
    if (req.method === "POST" && sub === "prompts") {
      if (!body.text?.trim()) throw new Problem(400, "empty_text", "Type something first");
      return write(res, entry, 200, () => {
        const result = bridge("conversation.prompt", { conversation: id, text: body.text.trim() });
        if (result.delivery === "queued") held.state.queue = [...(held.state.queue || []), { id: result.queueId, text: body.text.trim() }];
        else daemon.event({ conversation: id, at: new Date().toISOString(), type: "prompt", text: body.text.trim() }, false);
        daemon.changed();
        return result;
      });
    }
    if (req.method === "DELETE" && sub === "prompts") {
      return write(res, entry, 204, () => {
        bridge("conversation.unqueue", { conversation: id, queueId: extra });
        held.state.queue = (held.state.queue || []).filter((item) => item.id !== extra);
        if (!held.state.queue.length) delete held.state.queue;
        daemon.changed();
        return null;
      });
    }
    if (req.method === "POST" && sub === "actions") {
      return write(res, entry, 200, () => {
        const confirmed = body.confirmationToken ? body.confirmations || [] : [];
        const result = confirmable(bridge("conversation.action", { conversation: id, action: body.action, text: body.text, confirmed }), body);
        if (result.closed) { daemon.conversations.delete(id); daemon.changed(); }
        return result;
      });
    }
    if (req.method === "POST" && sub === "choice") {
      return write(res, entry, 204, () => {
        bridge("conversation.choose", { conversation: id, key: body.key });
        delete held.state.choices;
        held.seq = ++daemon.seq;
        daemon.changed();
        return null;
      });
    }
    if (req.method === "POST" && sub === "forms") {
      return write(res, entry, 204, () => {
        bridge("conversation.answer", { conversation: id, form: extra, action: body.action, values: body.values });
        delete held.state.form;
        held.seq = ++daemon.seq;
        daemon.changed();
        return null;
      });
    }
    if (req.method === "POST" && sub === "attachments") {
      if (!/^image\/(png|jpeg|gif|webp)$/.test(entry.type)) throw new Problem(415, "unsupported_media_type", "Send PNG, JPEG, GIF or WebP");
      entry.bytes = raw.length;
      return write(res, entry, 200, () => bridge("conversation.attach", { conversation: id, type: entry.type }));
    }
    throw new Problem(404, "route_missing", "No such route");
  }

  function findNodePath(id) {
    const visit = (nodes, parentId, keys) => {
      for (const node of nodes) {
        const nodeId = sha(parentId + "/" + node.key);
        if (nodeId === id) return [...keys, node.key];
        const found = visit(node.children || [], nodeId, [...keys, node.key]);
        if (found) return found;
      }
      return null;
    };
    return visit(daemon.tree, "", []);
  }

  async function control(route, req, res, url) {
    const body = req.method === "POST" ? JSON.parse((await readBody(req)).toString() || "{}") : {};
    switch (route) {
      case "/__test/log": return json(res, 200, daemon.log);
      case "/__test/fail": daemon.failures.push({ times: 1, ...body }); return json(res, 200, {});
      case "/__test/emacs": daemon.setEmacs(body.emacs); return json(res, 200, {});
      case "/__test/message": message(body); return json(res, 200, {});
      case "/__test/live":
        for (const { delayMs, message: item } of daemon.fx.live) {
          await new Promise((resolve) => setTimeout(resolve, (delayMs || 0) * (body.speed ?? 1)));
          message(item);
        }
        return json(res, 200, {});
      case "/__test/epoch": daemon.epoch = body.epoch; for (const client of daemon.streams) client.dirty(); return json(res, 200, {});
      case "/__test/state": return json(res, 200, { dashboard: daemon.dashboard, conversations: [...daemon.conversations.keys()] });
      default: return json(res, 404, {});
    }
  }

  // Applies one bridge notification as Emacs would send it.
  function message({ method, params }) {
    if (method === "agent.event") daemon.event(params);
    else if (method === "conversation.set") daemon.setConversation(params.conversation);
    else if (method === "conversation.remove") { daemon.conversations.delete(params.conversation); daemon.changed(); }
    else if (method === "dashboard.set") { daemon.setTree(params.sections); daemon.changed(); }
  }

  return server;
}

export async function start(port = 0, options = {}) {
  const daemon = new FakeDaemon(options);
  const server = createServer(daemon, options);
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  const { port: bound } = server.address();
  return { daemon, server, url: `http://127.0.0.1:${bound}/overlook/`, port: bound,
    close: () => new Promise((resolve) => { for (const client of daemon.streams) client.res.destroy(); server.close(resolve); server.closeAllConnections?.(); }) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.argv[2] || 8767);
  const running = await start(port);
  console.log(`fake overlook-remoted on ${running.url}#${TOKEN}`);
}
