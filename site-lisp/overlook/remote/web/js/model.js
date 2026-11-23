// Pure data logic shared by the views and unit tests: no DOM, no network.

export class Stale extends Error {}

// Dashboard sections with every {same: hash} replaced by the held node; throws Stale when one is unknown.
export function expandNodes(nodes, known) {
  return (nodes || []).map((node) => {
    if (node.same !== undefined) {
      const held = known.get(node.same);
      if (!held) throw new Stale("unknown node " + node.same);
      return held;
    }
    return { ...node, children: expandNodes(node.children, known) };
  });
}

export function indexNodes(nodes, known = new Map()) {
  for (const node of nodes || []) {
    known.set(node.hash, node);
    indexNodes(node.children, known);
  }
  return known;
}

export function nodePath(id, nodes, parents = []) {
  for (const node of nodes || []) {
    const path = [...parents, node];
    if (node.id === id) return path;
    const nested = nodePath(id, node.children, path);
    if (nested) return nested;
  }
  return null;
}

// Nodes matching predicate anywhere below, each conversation counted once.
export function findNodes(nodes, predicate) {
  const found = new Map();
  const visit = (items) => {
    for (const node of items || []) {
      if (predicate(node)) found.set(node.conversation || node.id, node);
      visit(node.children);
    }
  };
  visit(nodes);
  return [...found.values()];
}

export const nodeTitle = (node) => node?.title || "Untitled";

// What the banner says about the supervised Emacs process (GET /emacs), and the button it offers:
// {message, action} with action "" | "restart" | "start", or null when there is nothing to say.
export function processBanner(process, emacs) {
  if (!process) return null;
  const restart = process.canRestart ? "restart" : "";
  const start = process.canRestart ? "start" : "";
  const why = process.error ? ` (${process.error})` : "";
  switch (process.state) {
    case "unresponsive": return { message: "Emacs is not responding. It may be busy; restart it if it stays stuck.", action: restart };
    case "restarting": return { message: "Restarting Emacs…", action: "" };
    case "crashed": return { message: `Emacs crashed and was not restarted${why}.`, action: start };
    case "stopped": return { message: `Emacs has quit${why}.`, action: start };
  }
  if (emacs !== "offline") return null;
  return { message: `Emacs is not connected${why}. Showing the last update; sending resumes when Emacs is back.`, action: restart };
}

// The question asked before restarting Emacs; sections is the dashboard, to count working agents.
export function restartQuestion(sections) {
  const working = findNodes(sections, (node) => node.kind === "agent" && node.status === "working").length;
  return "Modified files are saved, then Emacs quits and starts again. Agents running in Emacs stop"
    + (working ? `, including ${unit(working, "working agent")}.` : ".");
}

export function statusLabel(status) {
  return ({ working: "Working", waiting: "Needs attention", failed: "Failed", done: "Completed",
    idle: "Ready", saved: "Saved", offline: "Not started", open: "To do" })[status] || status || "";
}

export function unit(count, name) {
  return `${count} ${name}${count === 1 ? "" : "s"}`;
}

export function nodeCounts(node) {
  const nodes = node.children || [];
  return {
    conversations: findNodes(nodes, (child) => child.kind === "agent" || child.kind === "saved").length,
    tasks: findNodes(nodes, (child) => child.kind === "todo").length,
    files: findNodes(nodes, (child) => child.kind === "file").length,
  };
}

// [status, count] for working, waiting, failed and done conversations below node.
export function agentSummary(node) {
  const agents = findNodes(node.children, (child) => child.kind === "agent");
  return ["working", "waiting", "failed", "done"]
    .map((status) => [status, agents.filter((agent) => agent.status === status).length])
    .filter(([, count]) => count > 0);
}

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

// Projects sorted by name in the slots projects held; other nodes keep their place.
export function stableProjects(nodes) {
  const projects = nodes.filter((node) => node.kind === "project").sort((a, b) =>
    collator.compare(nodeTitle(a), nodeTitle(b)) || String(a.id).localeCompare(String(b.id)));
  let index = 0;
  return nodes.map((node) => node.kind === "project" ? projects[index++] : node);
}

export function isPersonaSection(section) {
  return (section.children || []).some((node) => node.kind === "persona" || !!node.persona);
}

export function sectionRank(section) {
  if (findNodes([section], (node) => node.kind === "project").length) return 0;
  if (isPersonaSection(section)) return 1;
  if (findNodes([section], (node) => node.kind === "usage").length) return -1;
  return 2;
}

// Dashboard tabs; a section goes to the tab of what it holds, anything unrecognised to the inbox.
export const TABS = [{ id: "agents", title: "Agents" }, { id: "projects", title: "Projects" },
  { id: "personas", title: "Personas" }, { id: "inbox", title: "Inbox" }, { id: "usage", title: "Usage" }];

export function sectionTab(section) {
  const rank = sectionRank(section);
  return rank === -1 ? "usage" : rank === 0 ? "projects" : rank === 1 ? "personas" : "inbox";
}

export function orderSections(sections) {
  return sections.map((section, index) => ({ section, index }))
    .sort((a, b) => sectionRank(a.section) - sectionRank(b.section) || a.index - b.index)
    .map(({ section }) => section);
}

export function attentionNodes(sections) {
  return findNodes(sections, (node) => !!node.conversation &&
    (node.attention || node.choices?.length > 0 || ["waiting", "failed"].includes(node.status)));
}

export function dueLabel(value, now = new Date()) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return { label: "Due " + value, overdue: false };
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(year, month - 1, day);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  if (date.getTime() === today.getTime()) return { label: "Due today", overdue: false };
  if (date < today) return { label: "Overdue · " + value, overdue: true };
  return { label: "Due " + value, overdue: false };
}

// Remaining time until a Unix-seconds reset, or the server's display text.
export function resetLabel(reset, now = Date.now()) {
  if (typeof reset !== "number") return reset;
  const minutes = Math.max(0, Math.ceil((reset * 1000 - now) / 60000));
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor(minutes % 1440 / 60);
  const rest = minutes % 60;
  return days ? `${days}d ${hours}h` : hours ? `${hours}h ${rest}m` : `${rest}m`;
}

// A repo's branch, unless its title or the row above already names it.
export function shownBranch(node, parentBranch) {
  return node.kind === "repo" && node.branch && ![node.title, parentBranch].includes(node.branch) ? node.branch : null;
}

// Sections of a group page: [title, nodes] in display order.
export function groupSections(selected) {
  const conversations = [], saved = [], tasks = [], code = [], resources = [];
  const containsDiff = (node) => node.diff || (node.children || []).some(containsDiff);
  for (const node of selected.children || []) {
    if (node.kind === "agent") conversations.push(node);
    else if (node.kind === "saved") saved.push(node);
    else if (node.kind === "todo" || node.kind === "tasks") tasks.push(node);
    else if (["repo", "folder", "file"].includes(node.kind) || containsDiff(node)) code.push(node);
    else resources.push(node);
  }
  const sections = selected.kind === "persona"
    ? [["Conversations", conversations], ["Saved conversations", saved], ["To do", tasks], ["Code & changes", code], ["Resources", resources]]
    : [["Conversations", [...conversations, ...saved]], ["To do", tasks], ["Code & changes", code], ["Resources", resources]];
  return sections.filter(([, nodes]) => nodes.length);
}

export function personaStatus(node) {
  const conversations = (node.children || []).filter((child) => child.conversation);
  if (node.conversation) return node.status;
  return ["waiting", "failed", "working", "done"].find((status) => conversations.some((child) => child.status === status))
    || (conversations.length ? "idle" : "offline");
}

export function unreadOf(node) {
  return Number(node.unreadCount) || (node.children || [])
    .filter((child) => child.conversation).reduce((sum, child) => sum + (Number(child.unreadCount) || 0), 0);
}

// Routes are the old query strings: ?agent=<conversation> or ?node=<id>, the token stays in the hash.
export function parseRoute(search) {
  const params = new URLSearchParams(search);
  return { conversation: params.get("agent") || params.get("conversation") || null, node: params.get("node") || null,
    tab: TABS.some((tab) => tab.id === params.get("tab")) ? params.get("tab") : null };
}

export function formatRoute(route) {
  const params = new URLSearchParams();
  if (route.node) params.set("node", route.node);
  if (route.conversation) params.set("agent", route.conversation);
  if (route.tab && route.tab !== TABS[0].id) params.set("tab", route.tab);
  const query = params.toString();
  return query ? "?" + query : "";
}

export function streamQuery({ dashboard, conversation, after, known, epoch }) {
  const params = new URLSearchParams();
  if (dashboard !== undefined) params.set("dashboard", dashboard || "");
  if (conversation) {
    params.set("conversation", conversation);
    params.set("after", String(after || 0));
    if (known) params.set("known", known);
    if (epoch) params.set("epoch", epoch);
  }
  return params.toString();
}

// A held conversation: state plus items with their whole text.
export function conversationFromSnapshot(snapshot) {
  const held = {
    id: snapshot.conversation.id, epoch: snapshot.epoch, seq: snapshot.seq, known: snapshot.known,
    conversation: snapshot.conversation, items: new Map(), earlier: snapshot.earlier || null,
    history: snapshot.history?.hasMore ? { hasMore: true, before: snapshot.history.before } : null,
  };
  for (const item of snapshot.items || []) held.items.set(item.item, { ...item, offset: 0 });
  return held;
}

// Merges one item into held, false when a text suffix does not follow what is held.
export function mergeItem(held, item) {
  const previous = held.items.get(item.item);
  if (item.type === "text") {
    const offset = item.offset || 0;
    const text = offset === 0 ? "" : previous?.text ?? null;
    if (text === null || text.length !== offset) return false;
    held.items.set(item.item, { ...item, offset: 0, text: text + (item.text || "") });
    return true;
  }
  held.items.set(item.item, { ...item });
  return true;
}

// Applies a ConversationDelta; returns the touched item ids, or null when held must be refetched.
export function applyDelta(held, delta) {
  if (delta.epoch !== held.epoch) return null;
  if (delta.conversation) held.conversation = delta.conversation;
  const floor = held.history?.hasMore ? held.history.before : 0;
  const touched = [];
  for (const item of delta.items || []) {
    if (floor && item.item < floor) continue;
    if (!mergeItem(held, item)) return null;
    touched.push(item.item);
  }
  held.seq = delta.seq;
  held.known = delta.known;
  if (held.items.size) held.earlier = null;
  return touched;
}

// Adds an older history page; returns the new item ids.
export function applyHistory(held, page) {
  const added = [];
  for (const item of page.items || []) {
    if (held.items.has(item.item)) continue;
    held.items.set(item.item, { ...item, offset: 0 });
    added.push(item.item);
  }
  held.history = page.hasMore ? { hasMore: true, before: page.before } : null;
  return added;
}

export function sortedItems(held) {
  return [...held.items.values()].sort((a, b) => a.item - b.item);
}

export const latestItemSeq = (held) => Math.max(0, ...[...held.items.values()].map((item) => item.seq || 0));

// Runs of three or more adjacent completed tools, as [firstIndex, length] over items.
export function toolRuns(items) {
  const runs = [];
  let start = -1;
  const flush = (end) => { if (start >= 0 && end - start >= 3) runs.push([start, end - start]); start = -1; };
  items.forEach((item, index) => {
    if (item.type === "tool" && item.status === "completed") { if (start < 0) start = index; }
    else flush(index);
  });
  flush(items.length);
  return runs;
}

export function longContent(text) {
  return (text || "").length > 1800 || (text || "").split("\n").length > 18;
}

// The slash commands offered for a draft that is one word starting with "/".
export function slashMatches(text, slash) {
  if (!text.startsWith("/") || /\s/.test(text)) return [];
  const typed = text.slice(1).replace(/^\$/, "");
  return (slash || []).filter((command) => command.name.replace(/^\//, "").replace(/^\$/, "").startsWith(typed));
}

export function slashText(command) {
  return (command.name.startsWith("/") ? command.name : "/" + command.name) + " ";
}

// Appends text to a draft, separated by one space.
export function appendDraft(draftText, text) {
  return (draftText.trim() ? draftText.replace(/\s*$/, " ") : "") + text + " ";
}

const confirmLabels = { delete: "Delete", remove: "Remove", kill: "End conversation", stop: "Stop task",
  restart: "New conversation", reload: "Reload session", close: "Close", start: "Start" };

export function confirmStyle(message, label, danger) {
  const inferred = /^(delete|remove|kill|stop|restart|reload|close|start)\b/i.exec(message)?.[1]?.toLowerCase();
  return { label: label || confirmLabels[inferred] || "Confirm", danger: danger ?? /delete|remove|kill|stop|restart/i.test(inferred || "") };
}

export const actionLabels = { steer: "Steer with current draft", stop: "Stop current task", reload: "Reload session",
  restart: "New conversation", fork: "Fork conversation", close: "Close agent" };

export function settingValueName(setting) {
  return setting.choices.find((choice) => choice.value === setting.value)?.name || setting.value || "Select";
}

export function actionLabel(action, settings) {
  const setting = (settings || []).find((item) => item.id === action);
  return setting ? `${setting.label} · ${settingValueName(setting)}` : actionLabels[action] || action;
}

// The file a link target names, for the download endpoint; null for web, mail and in-page links.
export function fileRef(href) {
  if (!href) return null;
  let ref = href.replace(/^file:\/\/(localhost)?/i, "");
  if (ref === href && (/^[a-z][a-z0-9+.-]*:/i.test(ref) || ref.startsWith("#") || ref.startsWith("//"))) return null;
  ref = ref.replace(/[?#].*$/s, "");
  return ref || null;
}

export function fileSize(bytes) {
  const units = ["bytes", "KB", "MB", "GB"];
  let value = bytes, index = 0;
  while (value >= 1000 && index < units.length - 1) { value /= 1000; index++; }
  return index ? `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[index]}` : unit(bytes, "byte");
}

export function randomKey() {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), (n) => n.toString(16).padStart(2, "0")).join("");
}
