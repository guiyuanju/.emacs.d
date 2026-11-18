// Dashboard and group pages: usage, projects, personas, node commands and diffs.
import { api } from "js/api.js";
import { usageAnalytics } from "js/usage.js";
import { state, setDashboard, remember, draft } from "js/state.js";
import { $, el, svg, toast, confirmAction, actionSheet, viewState, actionFailure, icon, personaAvatar, personaProfile, pressMenu } from "js/ui.js";
import { diffPre } from "js/markdown.js";
import { openConversation, openGroup, replaceRoute } from "js/router.js";
import { connected, connectionFailure, setEmacs } from "js/shell.js";
import { Stale, expandNodes, findNodes, nodePath, nodeTitle, statusLabel, unit, nodeCounts, agentSummary, stableProjects,
  isPersonaSection, orderSections, sectionTab, TABS, dueLabel, resetLabel, shownBranch, groupSections, personaStatus,
  unreadOf, streamQuery, randomKey, appendDraft } from "js/model.js";
import { app } from "js/vendor.js";

const icons = {
  folder: '<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" aria-hidden="true"><path d="M3 10V8a2 2 0 0 1 2-2h6l2.5 3H23a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V10Z"/></svg>',
  file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><path d="M14 3H6a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8l-5-5Z"/><path d="M14 3v5h5M8 12h8M8 16h5"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><circle cx="12" cy="12" r="9"/></svg>',
  task: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><circle cx="12" cy="12" r="9"/></svg>',
  waitingTask: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/></svg>',
  agents: '<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" aria-hidden="true"><path d="M5 6h18a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H12l-5 4v-4H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2Z"/></svg>',
  personas: '<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="14" cy="10" r="4.5"/><path d="M5 24c1-5 4.5-7.5 9-7.5s8 2.5 9 7.5"/></svg>',
  inbox: '<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" aria-hidden="true"><path d="M3 15l3.5-9h15L25 15v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7Z"/><path d="M3 15h6l1.5 3h7L19 15h6"/></svg>',
  usage: '<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><path d="M4.5 19a9.5 9.5 0 1 1 19 0"/><path d="m14 19 5-6"/></svg>',
  chevron: '<svg viewBox="0 0 8 14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m1 1 6 6-6 6"/></svg>',
};

let stream = null;
let generation = 0;

// Starts the dashboard page: held sections at once, a snapshot only when none are held, then the stream.
export function showDashboard(liveStream) {
  stream = liveStream;
  const mine = ++generation;
  const route = state.route;
  pendingScroll = state.dashboardScroll.get(route.node || "") || 0;
  if (state.dashboard.sections) {
    renderDashboard();
    stream.open(streamQuery({ dashboard: state.dashboard.known }));
  } else {
    $("dashboard-content").setAttribute("aria-busy", "true");
    $("dashboard-content").replaceChildren(viewState("Loading projects…", "", true));
    renderHeader(null);
    loadSnapshot(mine);
  }
}

export function leaveDashboard() {
  generation++;
  closePanel(false);
  pendingSections = null;
}

async function loadSnapshot(mine, retries = 0) {
  try {
    const snapshot = await api.dashboard();
    if (mine !== generation) return;
    connected();
    setEmacs(snapshot.emacs);
    setDashboard(snapshot.known, expandNodes(snapshot.sections, new Map()));
    renderDashboard();
    stream.open(streamQuery({ dashboard: snapshot.known }));
  } catch (error) {
    if (mine !== generation || connectionFailure(error)) return;
    setTimeout(() => { if (mine === generation) loadSnapshot(mine, retries + 1); }, Math.min(30000, 1000 * 2 ** Math.min(retries, 5)));
  }
}

// Handles dashboard stream events; an unknown {same} hash refetches the whole dashboard.
export function dashboardEvent(name, data) {
  if (name !== "dashboard") return;
  let sections;
  try { sections = expandNodes(data.sections, state.dashboard.byHash); }
  catch (error) {
    if (!(error instanceof Stale)) throw error;
    stream.close();
    state.dashboard = { known: "", sections: state.dashboard.sections, byHash: new Map() };
    loadSnapshot(generation);
    return;
  }
  setDashboard(data.known, sections);
  renderDashboard();
}

let pendingScroll = null;
let pendingSections = null;

export function saveDashboardScroll() {
  if (!$("dash").hidden) state.dashboardScroll.set(state.route.node || "", $("dash").scrollTop);
}

function renderHeader(selected) {
  if (state.route.conversation) return;
  $("heading").textContent = selected ? nodeTitle(selected) : "Overlook";
  const menu = $("session-menu");
  menu.hidden = !selected || !(selected.commands?.length || selected.diff);
  menu.setAttribute("aria-label", "Group actions");
  menu.onclick = () => nodeActions($("dashboard-content"), selected);
}

export function renderDashboard() {
  if (panel) { pendingSections = true; return; }
  const sections = state.dashboard.sections || [];
  const container = $("dashboard-content");
  const group = state.route.node;
  const path = group ? nodePath(group, sections) : null;
  const selected = path?.at(-1);
  $("dashboard-intro").hidden = !!group;
  renderHeader(selected);
  if (group && !selected) {
    container.replaceChildren(el("p", "empty", "This group is no longer available. Go back to your projects."));
    return;
  }
  const agents = selected ? [] : findNodes(sections, (node) => !!node.conversation || node.kind === "saved").filter((node) => {
    const path = nodePath(node.id, sections) || [];
    return !path.some((parent) => parent.kind === "persona" || parent.persona || isPersonaSection(parent));
  }).map((node) => {
    const path = nodePath(node.id, sections) || [];
    const project = path.find((parent) => parent.kind === "project");
    const context = project ? nodeTitle(project) : "";
    return { ...node, kind: node.kind === "saved" ? "saved" : "agent",
      subtitle: [context, node.subtitle].filter(Boolean).join(" · ") };
  });
  const tab = state.route.tab || TABS[0].id;
  renderTabs(tab, agents);
  const shown = orderSections(sections).filter((section) => sectionTab(section) === tab);
  // The tab names its first group, so that group goes without a heading.
  const sectionGroups = shown.map((section, index) => nodeGroup(index === 0 ? "" : nodeTitle(section),
    stableProjects(section.children?.length ? section.children : [section]), { personaList: isPersonaSection(section) }));
  const groups = selected
    ? [...(selected.kind === "persona" ? [personaProfile(selected.persona || selected.title, selected.description)] : []), ...groupContents(selected)]
    : tab === "agents"
      ? [newAgent(sections), agents.length ? nodeGroup("", agents) : el("p", "empty", "No agents yet.")].filter(Boolean)
      : sectionGroups;
  if (!selected && tab === "usage") groups.push(usageAnalytics());
  container.replaceChildren(...(groups.length ? groups : [el("p", "empty", "Nothing here yet.")]));
  if (pendingScroll !== null) {
    $("dash").scrollTop = pendingScroll;
    pendingScroll = null;
  }
  const waiting = new Set([...container.querySelectorAll(".choices")].map((choices) => choices.closest("[data-node-id]").dataset.nodeId)).size;
  document.title = waiting ? `(${waiting}) Overlook` : "Overlook";
}

function renderTabs(selected, agents) {
  const bar = $("tabs");
  $("dashboard-intro").querySelector("h1").textContent = TABS.find((tab) => tab.id === selected).title;
  const waiting = agents.filter((node) => node.attention || node.choices?.length > 0 || ["waiting", "failed"].includes(node.status)).length;
  bar.replaceChildren(...TABS.map((tab) => {
    const button = el("button", "remote-tab");
    button.type = "button";
    button.setAttribute("role", "tab");
    button.setAttribute("aria-selected", String(tab.id === selected));
    button.innerHTML = icons[tab.id === "projects" ? "folder" : tab.id];
    button.append(el("span", "remote-tab-label", tab.title));
    if (tab.id === "agents" && waiting) {
      button.append(el("span", "remote-tab-badge", String(waiting)));
      button.setAttribute("aria-label", `${tab.title}, ${unit(waiting, "waiting agent")}`);
    }
    button.onclick = () => selectTab(tab.id);
    return button;
  }));
}

function selectTab(tab) {
  if ((state.route.tab || TABS[0].id) === tab) { $("dash").scrollTo({ top: 0, behavior: "smooth" }); return; }
  closePanel(false);
  state.route = { ...state.route, tab: tab === TABS[0].id ? null : tab };
  replaceRoute(state.route);
  renderDashboard();
  $("dash").scrollTop = 0;
}

// Starts an agent in a project picked from a sheet: the project's own new-agent command, with its engine choice.
function newAgent(sections) {
  const command = (project) => project.commands?.find((item) => ["new-agent", "new"].includes(item.name));
  const projects = findNodes(sections, (node) => node.kind === "project" && !!command(node));
  if (!projects.length) return null;
  const box = el("section", "dashboard-overview new-agent");
  const button = el("button", "button button-fill overview-new", "New agent");
  button.onclick = () => {
    const container = panelContainer(box, null, {}, "New agent");
    container.append(el("label", "form-label", "Project"));
    for (const project of projects) {
      const group = nodePath(project.id, sections)?.at(-2);
      // Projects under a nested group such as later or done carry its name.
      const shelved = group?.kind === "group" && nodePath(group.id, sections)?.length > 1;
      const choice = el("button", "", nodeTitle(project) + (shelved ? ` · ${nodeTitle(group)}` : ""));
      choice.onclick = (event) => {
        event.stopPropagation();
        const start = command(project);
        if (start.input || start.options) openPanel(box, project, { name: start.name });
        else runCommand(project, start, {}, choice);
      };
      container.append(choice);
    }
    const cancel = el("button", "", "Cancel");
    cancel.onclick = () => closePanel();
    container.append(cancel);
  };
  box.append(button);
  return box;
}

function overview(selected, persona) {
  const box = el("section", "dashboard-overview" + (persona ? " persona-conversations-overview" : ""));
  const counts = nodeCounts(selected);
  const facts = el("div", "overview-facts");
  const items = persona ? [[counts.conversations, "conversation"]]
    : [[counts.conversations, "conversation"], [counts.tasks, "task"], [counts.files, "changed file"]];
  for (const [count, name] of items) facts.append(el("span", "overview-fact", unit(count, name)));
  box.append(facts);
  const command = selected.commands?.find((item) => ["new-agent", "new", "start"].includes(item.name));
  if (command) {
    const button = el("button", "button button-fill overview-new", "New conversation");
    button.setAttribute("aria-label", `New conversation in ${nodeTitle(selected)}`);
    button.onclick = () => command.input || command.options ? openPanel(box, selected, { name: command.name }) : runCommand(selected, command, {}, button);
    box.append(button);
  }
  const engine = selected.commands?.find((item) => item.name === "engine");
  if (engine) {
    const button = el("button", "button overview-new", engine.label);
    button.onclick = () => openPanel(box, selected, { name: engine.name });
    box.append(button);
  }
  return box;
}

function groupContents(selected) {
  const persona = selected.kind === "persona";
  const groups = [];
  if (selected.kind === "project" || persona) groups.push(overview(selected, persona));
  for (const [title, nodes] of groupSections(selected)) {
    groups.push(nodeGroup(title, stableProjects(nodes), { key: `${selected.id}:${title}`, parentBranch: selected.branch }));
  }
  if (!selected.children?.length) {
    groups.push(el("p", "project-empty", persona ? "Start a conversation with this persona." : "No items to show in this group yet."));
  }
  return groups;
}

function nodeGroup(title, nodes, options = {}) {
  const section = el("section", "dashboard-section");
  if (title) section.append(el("h2", "block-title", title));
  const list = el("div", "list list-inset list-strong list-dividers");
  const rows = el("ul");
  const limit = options.limit || 6;
  const expanded = () => !options.key || state.disclosures.get(options.key);
  const more = el("button", "dashboard-show-more");
  const draw = () => {
    const all = expanded();
    rows.replaceChildren(...(all ? nodes : nodes.slice(0, limit)).map((node) => renderNode(node, options)));
    more.textContent = all ? "Show less" : `Show all ${nodes.length}`;
    more.setAttribute("aria-label", `${more.textContent}${title ? " · " + title : ""}`);
    more.setAttribute("aria-expanded", String(!!all));
  };
  more.onclick = () => { remember(state.disclosures, options.key, !expanded()); draw(); };
  draw();
  list.append(rows);
  if (options.key && nodes.length > limit) list.append(more);
  section.append(list);
  return section;
}

function usageRow(box, node) {
  box.classList.add("usage-row");
  const content = el("div", "usage-content");
  const provider = node.provider || node.title || "Usage";
  const name = provider[0].toUpperCase() + provider.slice(1) + (node.account ? " · " + node.account : "");
  const mark = icon(provider, name);
  mark.classList.add("usage-icon");
  mark.setAttribute("aria-label", name);
  content.setAttribute("aria-label", name);
  if (node.commands?.length) {
    content.tabIndex = 0;
    pressMenu(content, () => nodeActions(box, node));
  }
  const windows = el("div", "usage-windows");
  for (const item of node.windows || []) {
    const numeric = typeof item.value === "number" && Number.isFinite(item.value);
    const row = el("div", "usage-window" + (numeric && item.value >= 80 ? " warning" : ""));
    if (numeric) {
      const value = Math.min(100, Math.max(0, item.value));
      const ring = el("span", "usage-ring");
      ring.setAttribute("role", "progressbar");
      ring.setAttribute("aria-label", item.label + " used");
      ring.setAttribute("aria-valuemin", "0");
      ring.setAttribute("aria-valuemax", "100");
      ring.setAttribute("aria-valuenow", String(value));
      ring.style.setProperty("--usage-progress", `${value}%`);
      row.append(ring);
    } else row.append(el("span"));
    row.append(el("span", "usage-label", item.label),
      el("span", "usage-value", numeric ? `${Math.floor(item.value)}%` : (item.value || "—")));
    row.setAttribute("aria-label", `${item.label}: ${numeric ? Math.floor(item.value) + "% used" : (item.value || "unavailable")}`);
    if (item.reset) row.append(el("span", "usage-reset", resetLabel(item.reset)));
    windows.append(row);
  }
  content.append(mark, windows);
  box.append(content);
  return box;
}

function renderNode(node, options = {}) {
  const box = el("li", "remote-item");
  box.dataset.nodeId = node.id;
  if (node.kind === "usage") return usageRow(box, node);
  const children = node.children || [];
  const task = node.kind === "todo";
  const persona = node.kind === "persona" || (!!options.personaList && !!node.persona);
  const agent = node.kind === "agent" || node.kind === "saved";
  const navigates = !!node.conversation || children.length > 0 || node.kind === "project";
  const actionable = navigates || node.diff || node.commands?.length;
  const hasMenu = !persona && node.kind !== "project" && !!node.commands?.length;
  const row = el(actionable ? "button" : "div", "remote-row item-content" + ((navigates || node.diff) && !hasMenu ? " item-link" : ""));
  const inner = el("div", "item-inner");
  const line = el("div", "line" + (agent ? " agent" : ""));
  const text = el("div", "text");
  text.append(el("span", "row-title", persona ? node.persona || nodeTitle(node) : nodeTitle(node)));
  if (node.subtitle && !persona) text.append(el("span", "row-subtitle", node.subtitle));
  if (agent || persona) {
    const meta = el("div", "agent-meta");
    const status = persona ? personaStatus(node) : node.status;
    meta.append(el("span", "agent-state state-" + (status || "idle"), persona && status === "idle" ? "Available" : statusLabel(status)));
    const unread = unreadOf(node);
    if (unread > 0) {
      const badge = el("span", "unread-badge", unread > 99 ? "99+" : String(unread));
      badge.setAttribute("aria-label", `${unread} unread messages`);
      meta.append(badge);
    }
    const conversations = persona ? children.filter((child) => child.conversation).length : 0;
    if (conversations) meta.append(el("span", "persona-count", unit(conversations, "conversation")));
    text.append(meta);
  }
  const branch = shownBranch(node, options.parentBranch);
  if (branch) text.append(el("span", "row-subtitle", branch));
  if (node.added || node.removed) {
    const counts = el("span", "change-counts");
    if (node.added) counts.append(el("span", "added", `+${node.added}`));
    if (node.removed) counts.append(el("span", "removed", `−${node.removed}`));
    text.append(counts);
  }
  if (task && node.due) {
    const due = dueLabel(node.due);
    text.append(el("span", "task-due" + (due.overdue ? " overdue" : ""), due.label));
  }
  line.append(text);
  const media = el("div", "item-media row-icon");
  if (persona) {
    box.classList.add("persona-row");
    media.append(personaAvatar(node.persona || node.title));
  } else if (agent) {
    box.classList.add("conversation-row");
    media.classList.add("agent-icon");
    media.append(icon(node.provider || "agent"));
  } else if (task) {
    box.classList.add("task-row");
    const done = node.commands?.find((command) => command.name === "done");
    if (done) {
      const check = el("button", "task-check");
      check.setAttribute("aria-label", "Complete: " + nodeTitle(node));
      check.append(svg(icons.check));
      check.onclick = async () => {
        check.setAttribute("aria-busy", "true");
        try { await runCommand(node, done, {}, check); }
        finally { check.removeAttribute("aria-busy"); }
      };
      // The completion control sits beside, not inside, the row button.
      box.append(check);
    }
    media.classList.add("task-icon");
    if (done) media.append(el("span", "task-spacer"));
    else media.append(svg(node.status === "waiting" ? icons.waitingTask : icons.task));
  } else if (node.kind === "file" || (node.diff && !children.length)) {
    box.classList.add("file-row");
    media.classList.add("file-icon");
    media.append(svg(icons.file));
  } else if (children.length || node.heading) {
    box.classList.add("group-row");
    media.classList.add("group-icon");
    media.append(svg(icons.folder));
    if (node.kind === "project") {
      const meta = el("div", "project-list-meta");
      const summary = el("span", "project-agent-summary");
      for (const [status, count] of agentSummary(node)) summary.append(el("span", "agent-state state-" + status, `${count} ${statusLabel(status)}`));
      const count = nodeCounts(node).conversations;
      if (summary.children.length) meta.append(summary);
      else if (count) meta.append(el("span", "", unit(count, "conversation")));
      if (meta.children.length) text.append(meta);
    }
  }
  if (media.childNodes.length) row.append(media);
  if (navigates || node.diff) {
    box.classList.add("dashboard-navigable");
    const chevron = el("span", "dashboard-chevron");
    chevron.setAttribute("aria-hidden", "true");
    chevron.append(svg(icons.chevron));
    line.append(chevron);
  }
  inner.append(line);
  row.append(inner);
  if (actionable) {
    row.onclick = () => {
      if (node.conversation) openConversation(node.conversation);
      else if (children.length || node.kind === "project") openGroup(node.id);
      else if (persona && node.commands?.some((command) => ["start", "new", "open"].includes(command.name))) {
        const command = node.commands.find((item) => ["start", "new", "open"].includes(item.name));
        if (command.input || command.options) openPanel(box, node, { name: command.name });
        else runCommand(node, command, {}, row);
      } else if (node.diff) showDiff(box, node);
      else nodeActions(box, node);
    };
  }
  box.append(row);
  if ((persona || node.kind === "project") && node.commands?.length) pressMenu(row, () => nodeActions(box, node));
  if (hasMenu) {
    box.classList.add("has-menu");
    const more = el("button", "more", "⋯");
    more.setAttribute("aria-label", "Actions for " + nodeTitle(node));
    more.onclick = () => nodeActions(box, node);
    box.append(more);
  }
  if (node.conversation && node.choices?.length) box.append(choiceButtons(node));
  return box;
}

const choicePending = new Map();

// Permission answers offered on an agent row.
function choiceButtons(node) {
  const container = el("div", "choices");
  const signature = JSON.stringify([node.conversation, node.choices]);
  const pending = choicePending.has(signature);
  container.append(...node.choices.map((choice) => {
    const button = el("button", "", choice.label);
    button.disabled = pending;
    button.onclick = async (event) => {
      event.stopPropagation();
      if (choicePending.has(signature)) return;
      remember(choicePending, signature, randomKey(), 64);
      container.querySelectorAll("button").forEach((item) => { item.disabled = true; });
      container.querySelector(".operation-error")?.remove();
      try { await api.choose(node.conversation, choice.key, choicePending.get(signature)); }
      catch (error) {
        choicePending.delete(signature);
        actionFailure(error, button);
        container.querySelectorAll("button").forEach((item) => { item.disabled = false; });
      }
    };
    return button;
  }));
  return container;
}

function nodeActions(box, node) {
  if (!node) return;
  const buttons = [];
  if (node.diff) buttons.push({ text: "View changes", onClick: () => showDiff(box, node) });
  for (const command of node.commands || []) {
    buttons.push({ text: command.label, color: command.confirm ? "red" : undefined,
      onClick: () => command.input || command.options ? openPanel(box, node, { name: command.name }) : runCommand(node, command, {}, box) });
  }
  actionSheet(buttons);
}

// The command sheet; while it holds input, dashboard updates wait.
let panel = null;
const formKey = (nodeId, name) => JSON.stringify([nodeId, name]);

function rememberPanelDraft() {
  if (!panel?.name) return;
  remember(state.formDrafts, formKey(panel.node.id, panel.name), { text: panel.text || "", option: panel.option }, 128);
}

export function closePanel(redraw = true) {
  rememberPanelDraft();
  const previous = panel;
  panel = null;
  previous?.sheet.close();
  if (pendingSections && redraw) {
    pendingSections = null;
    renderDashboard();
  }
}

// An open sheet's content container, reusing the sheet when box already owns it.
export function panelContainer(box, node, extra = {}, title = "overlook") {
  if (panel?.box === box && panel.sheet.opened) {
    panel = { ...panel, text: "", option: null, ...extra, node: node ?? panel.node };
    const container = panel.sheet.el.querySelector(".commands");
    container.replaceChildren();
    container.className = "commands";
    panel.sheet.el.querySelector(".toolbar .title").textContent = title;
    return container;
  }
  closePanel();
  const previousFocus = document.activeElement;
  const root = el("div", "sheet-modal remote-sheet");
  root.setAttribute("role", "dialog");
  root.setAttribute("aria-modal", "true");
  root.setAttribute("aria-label", node?.title || title);
  const inner = el("div", "sheet-modal-inner");
  const toolbar = el("div", "toolbar");
  const bar = el("div", "toolbar-inner");
  const done = el("button", "link", "Done");
  done.onclick = () => closePanel();
  done.setAttribute("aria-label", "Close sheet");
  bar.append(el("div", "title", title), done);
  toolbar.append(bar);
  const content = el("div", "page-content");
  const container = el("div", "commands");
  content.append(container);
  inner.append(toolbar, content);
  root.append(inner);
  const sheet = app.sheet.create({ el: root, backdrop: true, closeByOutsideClick: false, swipeToClose: true,
    on: {
      opened() { if (!root.querySelector("textarea")) done.focus({ preventScroll: true }); },
      closed() {
        if (panel?.sheet === sheet) closePanel();
        sheet.destroy();
        root.remove();
        if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
      },
    } });
  panel = { text: "", option: null, ...extra, node, box, sheet };
  sheet.open();
  return container;
}

function openPanel(box, node, extra = {}) {
  if (extra.name && !("text" in extra)) extra = { ...state.formDrafts.get(formKey(node.id, extra.name)), ...extra };
  const command = node.commands.find((item) => item.name === extra.name);
  const container = panelContainer(box, node, extra, command?.label || nodeTitle(node));
  const button = (label, className, onclick) => {
    const control = el("button", className, label);
    control.onclick = (event) => { event.stopPropagation(); onclick(control); };
    return control;
  };
  if (!command) {
    for (const item of node.commands) {
      container.append(button(item.label, item.confirm ? "danger" : "", (control) =>
        item.input || item.options ? openPanel(box, node, { name: item.name }) : runCommand(node, item, {}, control)));
    }
  } else if (!command.input) {
    for (const option of command.options) container.append(button(option, "", (control) => runCommand(node, command, { option }, control)));
  } else {
    let select = null;
    if (command.options) {
      select = el("select");
      for (const option of command.options) select.append(new Option(option, option));
      if (panel.option) select.value = panel.option;
      select.setAttribute("aria-label", "Choose " + command.label);
      select.onchange = () => { panel.option = select.value; rememberPanelDraft(); };
      container.append(select);
    }
    const text = el("textarea");
    text.placeholder = command.input;
    text.value = panel.text || "";
    text.setAttribute("aria-label", command.input);
    text.oninput = () => { panel.text = text.value; rememberPanelDraft(); };
    container.append(el("label", "form-label", command.input), text,
      button(command.label, "primary", (control) => runCommand(node, command, { text: text.value, option: select?.value }, control)));
  }
  container.append(button("Cancel", "", () => closePanel()));
  requestAnimationFrame(() => { if (panel?.sheet?.el.contains(container)) container.querySelector("textarea")?.focus(); });
}

async function showDiff(box, node) {
  const container = panelContainer(box, node, {}, nodeTitle(node));
  const active = panel;
  container.classList.add("file-diff");
  container.textContent = "Loading…";
  try {
    const { diff } = await api.diff(node.id);
    if (panel !== active) return;
    container.replaceChildren(diff ? diffPre(diff) : el("span", "meta", "No changes"));
  } catch (error) {
    if (panel === active) closePanel();
    toast(error.message);
  }
}

const commandAttempts = new Map();

// Runs a node command through its confirmation questions; the Idempotency-Key stays for one attempt.
export async function runCommand(node, command, args, control) {
  const mine = state.generation;
  if (control.disabled) return;
  control.disabled = true;
  control.closest?.(".commands, .remote-item")?.querySelector(".operation-error")?.remove();
  const attempt = JSON.stringify([node.id, command.name, args]);
  if (!commandAttempts.has(attempt)) remember(commandAttempts, attempt, randomKey(), 128);
  const key = commandAttempts.get(attempt);
  const body = {};
  if (args.text !== undefined) body.text = args.text;
  if (args.option !== undefined) body.option = args.option;
  try {
    let result = await api.command(node.id, command.name, body, key);
    while (result?.outcome === "confirm") {
      if (mine !== state.generation) return;
      if (!await confirmAction(result.question, { title: nodeTitle(node), label: command.label, danger: !!command.confirm })) {
        commandAttempts.delete(attempt);
        return;
      }
      if (mine !== state.generation) return;
      body.confirmations = result.confirmations;
      body.confirmationToken = result.confirmationToken;
      result = await api.command(node.id, command.name, body, key);
    }
    commandAttempts.delete(attempt);
    if (mine !== state.generation) return;
    state.formDrafts.delete(formKey(node.id, command.name));
    if (panel?.node.id === node.id && panel.name === command.name) panel.name = null;
    closePanel();
    if (result?.draft && result.conversation) {
      const target = draft(result.conversation);
      target.text = appendDraft(target.text, result.draft);
      target.revision++;
    }
    if (result?.conversation) openConversation(result.conversation);
    else toast(command.label + ": done");
  } catch (error) {
    actionFailure(error, control, $("dashboard-content"));
  } finally {
    if (control.isConnected) control.disabled = false;
  }
}
