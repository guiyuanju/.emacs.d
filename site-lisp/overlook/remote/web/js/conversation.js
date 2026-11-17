// The conversation page: header, activity feed, history paging, live answers and the read position.
import { api } from "js/api.js";
import { state, holdConversation, remember, draft, on } from "js/state.js";
import { $, el, toast, viewState, actionSheet, imageStrip, messageTime, personaProfile, preloader, confirmAction } from "js/ui.js";
import { markdownHtml, enhanceCodeBlocks, foldContent, diffPre } from "js/markdown.js";
import { connected, connectionFailure, setEmacs } from "js/shell.js";
import { panelContainer } from "js/dashboard.js";
import { syncCompose, sessionAction, renderSlashCommands, focusCompose, sessionBusy } from "js/compose.js";
import { conversationFromSnapshot, applyDelta, applyHistory, sortedItems, toolRuns, statusLabel, streamQuery,
  actionLabel, randomKey, fileSize } from "js/model.js";

let stream = null;
let generation = 0;
// The page shown: conversation id, rendered nodes by item id, and whether the first render happened.
let view = null;
// Disclosure state of items (expanded, open code blocks, open diffs) by conversation, kept for the page lifetime.
const itemViews = new Map();

export const shownConversation = () => view && state.conversations.get(view.id);

on("sent", (id) => {
  if (view?.id !== id) return;
  renderEchoes(state.conversations.get(id));
  scrollToBottom();
});

function renderEchoes(held) {
  if (!held) return;
  const current = draft(held.id);
  if (current.echoEpoch && current.echoEpoch !== held.epoch) {
    current.echoes = [];
    current.echoThrough = 0;
  }
  current.echoEpoch = held.epoch;
  const prompts = sortedItems(held).filter((item) => item.type === "prompt");
  current.echoes = current.echoes.filter((echo) => {
    const index = prompts.findIndex((item) => item.seq > Math.max(echo.after, current.echoThrough || 0) && item.text === echo.text);
    if (index < 0) return true;
    current.echoThrough = prompts[index].seq;
    prompts.splice(index, 1);
    return false;
  });
  $("d-feed").querySelectorAll(":scope > .local-echo").forEach((node) => node.remove());
  for (const echo of current.echoes) {
    const node = el("div", "item prompt local-echo", echo.text);
    if (echo.status === "sending" || echo.status === "failed") {
      const status = el("span", "delivery-status");
      status.setAttribute("role", "status");
      if (echo.status === "sending") status.append(preloader(), "Sending…");
      else {
        status.classList.add("delivery-failed");
        status.textContent = "Send failed · " + echo.error;
      }
      node.append(status);
    }
    messageTime(node, echo.at);
    $("d-feed").append(node);
  }
  if (current.echoes.length) $("d-feed").querySelector(":scope > .view-state")?.remove();
}

export function showConversation(id, liveStream) {
  stream = liveStream;
  const mine = ++generation;
  if (!itemViews.has(id)) remember(itemViews, id, new Map(), 32);
  view = { id, generation: mine, nodes: new Map(), ready: false, loadingHistory: false, historyRevision: 0, presentedSeq: 0, headerKey: "" };
  $("d-feed").replaceChildren();
  $("d-live").replaceChildren();
  $("d-earlier").hidden = true;
  $("history-controls").hidden = true;
  $("persona-profile").hidden = true;
  $("heading").replaceChildren(el("span", "navigation-title", "Conversation"), el("span", "navigation-subtitle", "Loading…"));
  const held = state.conversations.get(id);
  if (held) {
    holdConversation(held);
    present(held, { first: true });
    openStream(held);
  } else {
    $("d-feed").setAttribute("aria-busy", "true");
    $("d-feed").replaceChildren(viewState("Loading conversation…", "", true));
    loadSnapshot(mine);
  }
}

export function leaveConversation() {
  flushRead();
  if (view && !$("detail").hidden) state.conversationScroll.set(view.id, { top: $("detail").scrollTop, pinned: atBottom() });
  for (const item of itemViews.get(view?.id)?.values() || []) { clearTimeout(item.timer); item.timer = null; }
  generation++;
  view = null;
}

function openStream(held) {
  stream.open(streamQuery({ conversation: held.id, after: held.seq, known: held.known, epoch: held.epoch }));
}

async function loadSnapshot(mine, retries = 0) {
  try {
    const snapshot = await api.conversation(view.id);
    if (mine !== generation) return;
    connected();
    setEmacs(snapshot.emacs);
    reset(snapshot);
  } catch (error) {
    if (mine !== generation || connectionFailure(error)) return;
    setTimeout(() => { if (mine === generation) loadSnapshot(mine, retries + 1); }, Math.min(30000, 1000 * 2 ** Math.min(retries, 5)));
  }
}

// Replaces everything held for the conversation shown with a snapshot.
function reset(snapshot) {
  const held = holdConversation(conversationFromSnapshot(snapshot));
  const first = !view.ready;
  view.historyRevision++;
  view.loadingHistory = false;
  view.nodes.clear();
  view.presentedSeq = 0;
  $("d-feed").replaceChildren();
  present(held, { first });
  openStream(held);
}

export function conversationEvent(name, data) {
  if (!view) return;
  if (name === "gone") {
    if (data.conversation !== view.id) return;
    stream.close();
    connectionFailure({ code: "gone" });
    return;
  }
  if (name !== "conversation") return;
  if (data.reset) { reset(data); return; }
  const held = state.conversations.get(view.id);
  const touched = held ? applyDelta(held, data) : null;
  if (touched === null) {
    stream.close();
    loadSnapshot(generation);
    return;
  }
  update(held, touched);
}

// First render of held (from a snapshot or memory).
function present(held, { first }) {
  $("d-feed").removeAttribute("aria-busy");
  renderHeader(held.conversation);
  renderItems(held, sortedItems(held));
  renderEarlier(held);
  renderEchoes(held);
  renderHistoryControls();
  const position = state.conversationScroll.get(held.id);
  if (first && position && !position.pinned) {
    $("detail").scrollTop = position.top;
    onScroll();
  } else scrollToBottom();
  view.ready = true;
  markSeen();
}

function update(held, touched) {
  const bottom = atBottom(), top = $("detail").scrollTop;
  renderHeader(held.conversation);
  renderItems(held, touched.map((id) => held.items.get(id)));
  renderEarlier(held);
  renderEchoes(held);
  if (bottom && touched.length) scrollToBottom();
  else $("detail").scrollTop = top;
  markSeen();
}

function renderEarlier(held) {
  const earlier = held.earlier;
  const shown = !view.nodes.size && !!earlier?.reply;
  $("d-earlier").hidden = !shown;
  if (shown && $("d-reply").dataset.source !== earlier.reply) {
    $("d-reply").dataset.source = earlier.reply;
    $("d-reply").innerHTML = markdownHtml(earlier.reply);
    const options = itemView(0);
    enhanceCodeBlocks($("d-reply"), options);
    foldContent($("d-reply"), earlier.reply, options);
    $("d-transcript").textContent = earlier.transcript || "";
  }
  const empty = $("d-feed").querySelector(":scope > .view-state");
  if (view.nodes.size || earlier?.reply) { empty?.remove(); return; }
  const working = held.conversation.status === "working";
  const replacement = viewState(working ? "Working on your request" : "Start a conversation",
    working ? "The response will appear here." : "Send a message below to get started.");
  if (empty) empty.replaceWith(replacement); else $("d-feed").append(replacement);
}

function itemView(id) {
  const views = itemViews.get(view.id);
  if (!views.has(id)) views.set(id, { expanded: false, codeOpen: new Set(), drawn: 0, timer: null, diffOpen: false });
  return views.get(id);
}

// Renders items (new or changed), then regroups completed tools once.
function renderItems(held, items) {
  const regroup = items.some((item) => item.type === "tool" || !view.nodes.has(item.item));
  for (const item of items) renderItem(item);
  if (regroup) groupTools();
  view.presentedSeq = Math.max(view.presentedSeq, ...items.map((item) => item.seq || 0));
}

function renderItem(item) {
  let node = view.nodes.get(item.item);
  const fresh = !node;
  if (fresh) {
    node = el("div");
    node.itemId = item.item;
    view.nodes.set(item.item, node);
  }
  const options = itemView(item.item);
  node.item = item;
  switch (item.type) {
    case "prompt": node.className = "item prompt"; node.textContent = item.text || ""; break;
    case "text": node.className = "item markdown"; renderReply(node, options); break;
    case "tool": renderTool(node, item, options); break;
    case "end": node.className = "item end"; node.textContent = "End of turn"; break;
    case "error": node.className = "item error"; node.textContent = item.text || ""; break;
    default: node.className = "item"; node.textContent = item.text || item.title || ""; break;
  }
  if (!["tool", "text"].includes(item.type)) {
    if (item.images?.length) node.append(imageStrip(item.images));
    foldContent(node, item.text, options);
    messageTime(node, item.createdAt);
  }
  if (fresh) {
    let nextId = Infinity, next = null;
    for (const [id, candidate] of view.nodes) {
      if (id > item.item && id < nextId) { nextId = id; next = candidate; }
    }
    if (next?.isConnected) (next.parentElement.classList.contains("tool-group") && next.parentElement.firstTool === next ? next.parentElement : next).before(node);
    else $("d-feed").append(node);
  }
}

// A reply's markdown, drawn at most four times a second while it streams.
function renderReply(node, options) {
  const wait = options.drawn + 250 - Date.now();
  if (wait > 0) {
    options.timer ??= setTimeout(() => {
      options.timer = null;
      if (!node.isConnected) return;
      const bottom = atBottom();
      renderReply(node, options);
      if (bottom) scrollToBottom();
      markSeen();
    }, wait);
    return;
  }
  const item = node.item;
  options.drawn = Date.now();
  node.innerHTML = markdownHtml(item.text);
  enhanceCodeBlocks(node, options);
  if (item.images?.length) node.append(imageStrip(item.images));
  foldContent(node, item.text, options);
  messageTime(node, item.createdAt);
}

const toolMarks = { pending: "○", in_progress: "◐", completed: "✓", failed: "✗" };
const toolStates = { pending: "Waiting", in_progress: "Running", completed: "Done", failed: "Failed" };

function renderTool(node, item, options) {
  node.className = "item tool " + (item.status || "");
  const head = el("div", "tool-head");
  head.append(el("span", "tool-mark", toolMarks[item.status] || "•"), el("span", "", item.title || item.kind || "tool"),
    el("span", "meta", toolStates[item.status] || item.status || ""));
  const parts = [head];
  if (item.diff) {
    const details = el("details");
    details.open = options.diffOpen;
    details.addEventListener("toggle", () => { options.diffOpen = details.open; });
    details.append(el("summary", "", "View changes"), diffPre(item.diff));
    parts.push(details);
  }
  if (item.images?.length) parts.push(imageStrip(item.images));
  if (item.status === "failed") parts.push(el("p", "inline-feedback error", "This action failed. Review the agent’s response before continuing."));
  node.replaceChildren(...parts);
  foldContent(node, [item.title, item.diff].filter(Boolean).join("\n"), options);
  messageTime(node, item.createdAt);
}

// Collapses runs of three or more adjacent completed tools into a disclosure.
function groupTools() {
  const feed = $("d-feed");
  const open = new Set([...feed.querySelectorAll(":scope > .tool-group[open]")].map((group) => group.firstTool));
  for (const group of [...feed.querySelectorAll(":scope > .tool-group")]) {
    group.replaceWith(...[...group.children].filter((child) => child.tagName !== "SUMMARY"));
  }
  const children = [...feed.children];
  const items = children.map((child) => child.item || {});
  for (const [start, length] of toolRuns(items)) {
    const run = children.slice(start, start + length);
    const group = el("details", "tool-group");
    group.firstTool = run[0];
    group.open = open.has(run[0]);
    group.append(el("summary", "", `${length} completed actions`));
    run[0].before(group);
    group.append(...run);
  }
}

export function renderHistoryControls(error = "") {
  const held = shownConversation();
  const controls = $("history-controls");
  controls.replaceChildren();
  controls.hidden = !held?.history?.hasMore && !error;
  if (controls.hidden) return;
  if (held?.history?.hasMore) {
    const button = el("button", "link", view.loadingHistory ? "Loading earlier messages…" : "Load earlier messages");
    button.disabled = view.loadingHistory;
    button.onclick = loadEarlier;
    controls.append(button);
  }
  if (error) controls.append(el("p", "error", error));
}

// Prepends an older page, keeping the reading position.
export async function loadEarlier() {
  const held = shownConversation();
  if (!held || view.loadingHistory || !held.history?.hasMore) return;
  const mine = view;
  mine.loadingHistory = true;
  renderHistoryControls();
  const detail = $("detail");
  const height = detail.scrollHeight, top = detail.scrollTop;
  const revision = mine.historyRevision;
  try {
    const page = await api.history(held.id, held.history.before, held.epoch);
    if (view !== mine || revision !== mine.historyRevision) return;
    if (page.epoch !== held.epoch) throw Object.assign(new Error("Earlier messages expired."), { code: "history_expired" });
    const added = applyHistory(held, page);
    renderItems(held, added.map((id) => held.items.get(id)));
    mine.loadingHistory = false;
    renderHistoryControls();
    renderEarlier(held);
    detail.scrollTop = top + detail.scrollHeight - height;
  } catch (error) {
    if (view !== mine || revision !== mine.historyRevision) return;
    mine.loadingHistory = false;
    if (error.code === "history_expired") {
      held.history = null;
      renderHistoryControls("Earlier messages have expired from the server. Reopen this conversation to refresh.");
    } else renderHistoryControls(error.message);
    detail.scrollTop = top;
  }
}

function renderHeader(conversation) {
  const key = JSON.stringify(conversation);
  if (key === view.headerKey) return;
  view.headerKey = key;
  const title = conversation.title || conversation.persona || "Conversation";
  const subtitle = [conversation.persona, conversation.provider || "Agent", statusLabel(conversation.status)].filter(Boolean).join(" · ");
  const info = el("button", "navigation-info");
  info.setAttribute("aria-label", `${title}. Conversation information`);
  info.setAttribute("aria-haspopup", "dialog");
  info.append(el("span", "navigation-title", title), el("span", "navigation-subtitle", subtitle));
  info.onclick = () => showInfo();
  $("heading").replaceChildren(info);
  $("persona-profile").hidden = !conversation.persona;
  $("persona-profile").replaceChildren(...(conversation.persona ? [...personaProfile(conversation.persona, conversation.description).children] : []));
  $("text").placeholder = conversation.persona ? `Message ${conversation.persona}` : "Message";
  const context = Number.isFinite(conversation.context);
  $("context").hidden = !context;
  $("context").textContent = context ? `${Math.round(conversation.context)}%` : "";
  const controls = conversation.controls || {};
  const actions = [...(controls.steer ? ["steer"] : []), ...(controls.actions || [])];
  const menu = $("session-menu");
  menu.hidden = !actions.length;
  menu.setAttribute("aria-label", "Conversation actions");
  menu.onclick = () => sessionMenu(title, actions);
  renderSlashCommands();
  renderLive(conversation);
}

function sessionMenu(title, actions) {
  if (sessionBusy()) return;
  const id = view.id;
  const settings = shownConversation()?.conversation.controls?.settings || [];
  actionSheet(actions.map((action) => ({
    text: actionLabel(action, settings),
    color: ["stop", "restart", "close"].includes(action) ? "red" : undefined,
    onClick: () => {
      if (view?.id !== id) return;
      const setting = settings.find((item) => item.id === action);
      if (!setting) { sessionAction(action, $("session-menu")); return; }
      actionSheet(setting.choices.map((choice) => ({
        text: (choice.value === setting.value ? "✓ " : "") + choice.name,
        onClick: () => { if (view?.id === id && choice.value !== setting.value) sessionAction(action, $("session-menu"), choice.value); },
      })), `Choose ${setting.label.toLowerCase()}`);
    },
  })), title);
}

function showInfo() {
  const conversation = shownConversation()?.conversation;
  if (!conversation) return;
  const container = panelContainer($("heading"), { id: conversation.id, title: "Conversation information" }, {}, "Conversation information");
  if (conversation.persona) container.append(personaProfile(conversation.persona, conversation.description));
  else container.append(el("h2", "info-title", conversation.title || "Conversation"));
  const details = el("dl", "conversation-info");
  for (const [label, value] of [["Conversation", conversation.persona ? conversation.title : null], ["Provider", conversation.provider],
    ["Status", statusLabel(conversation.status)], ["Project", conversation.project], ["Folder", conversation.folder],
    ["Context", Number.isFinite(conversation.context) ? `${Math.round(conversation.context)}% used` : null]]) {
    if (value) details.append(el("dt", "", label), el("dd", "", value));
  }
  container.append(details);
}

// Answers in flight: feedback text by [conversation, choices] signature.
const permissionResponses = new Map();
const questionCards = new Map();
const writeKeys = new Map();

const keyFor = (signature) => writeKeys.get(signature) || remember(writeKeys, signature, randomKey(), 128);

// What happens now, under the feed: answers the agent waits for, its work, then queued prompts.
export function renderLive(conversation) {
  const bottom = atBottom();
  const parts = [];
  const id = conversation.id;
  const choices = conversation.choices || [];
  const activePermission = choices.length ? JSON.stringify([id, choices]) : null;
  for (const signature of permissionResponses.keys()) {
    if (JSON.parse(signature)[0] === id && signature !== activePermission) permissionResponses.delete(signature);
  }
  if (conversation.queueError) {
    const failure = el("div", "item error", "Queued messages paused: " + conversation.queueError);
    const retry = el("button", "", "Retry delivery");
    retry.onclick = async () => {
      retry.disabled = true;
      try { await api.retry(id, keyFor(JSON.stringify(["retry", id, conversation.queueError]))); }
      catch (error) { toast(error.message); retry.disabled = false; }
    };
    failure.append(retry);
    parts.push(failure);
  }
  if (conversation.form?.answerable) parts.push(questionForm(conversation));
  else if (choices.length) parts.push(permissionCard(conversation, choices));
  else if (conversation.form || conversation.status === "waiting") {
    const card = el("section", "permission-card");
    card.append(el("h3", "", conversation.form ? "Answer in Emacs" : "Your attention is needed"),
      el("p", "", (conversation.form?.message || conversation.brief || "The agent is waiting for you.")
        + (conversation.form ? " · This question can only be answered in Emacs." : "")));
    parts.push(card);
  } else if (conversation.status === "working") {
    const working = el("div", "working");
    working.append(preloader(), el("span", "", conversation.brief || "Working…"));
    parts.push(working);
  }
  for (const item of conversation.queue || []) parts.push(queuedPrompt(id, item));
  $("d-live").replaceChildren(...parts);
  syncCompose();
  if (bottom) scrollToBottom();
}

function permissionCard(conversation, choices) {
  const id = conversation.id;
  const card = el("section", "permission-card");
  card.append(el("h3", "", "Your response is needed"),
    el("p", "", conversation.brief || "The agent is waiting for your decision before it can continue. Review the choices below."));
  const row = el("div", "choices");
  const feedback = el("div", "inline-feedback");
  feedback.setAttribute("role", "status");
  const signature = JSON.stringify([id, choices]);
  const previous = permissionResponses.get(signature);
  if (previous) { feedback.textContent = previous; row.dataset.pending = "true"; }
  for (const choice of choices) {
    const button = el("button", "", choice.label);
    button.disabled = !!previous;
    button.onclick = async () => {
      if (row.dataset.pending) return;
      row.dataset.pending = "true";
      for (const other of row.children) other.disabled = true;
      feedback.textContent = "Sending response…";
      remember(permissionResponses, signature, feedback.textContent, 64);
      try {
        await api.choose(id, choice.key, keyFor(JSON.stringify([signature, choice.key])));
        feedback.textContent = "Response sent. Waiting for the agent…";
        if (permissionResponses.has(signature)) permissionResponses.set(signature, feedback.textContent);
      } catch (error) {
        feedback.textContent = "Response not sent · " + error.message;
        permissionResponses.delete(signature);
        delete row.dataset.pending;
        for (const other of row.children) other.disabled = false;
      }
    };
    row.append(button);
  }
  card.append(row, feedback);
  return card;
}

// A question form keeps its card while asked, so live updates keep picks, text and focus.
function questionForm(conversation) {
  const form = conversation.form;
  const signature = JSON.stringify([conversation.id, form]);
  for (const key of questionCards.keys()) {
    if (JSON.parse(key)[0] === conversation.id && key !== signature) questionCards.delete(key);
  }
  if (questionCards.has(signature)) return questionCards.get(signature);
  const card = el("section", "permission-card question-form");
  card.append(el("h3", "", "Your response is needed"));
  if (form.message) card.append(el("p", "question-description", form.message));
  const read = [];
  (form.fields || []).forEach((field, index) => {
    const set = el("fieldset");
    const name = `q-${index}-${field.key}`;
    set.append(el("legend", "", field.title + (field.required ? " *" : "")));
    if (field.description) set.append(el("p", "question-description", field.description));
    if (field.type === "single" || field.type === "multi") {
      const inputs = (field.options || []).map((option) => {
        const label = el("label", "option");
        const input = el("input");
        input.type = field.type === "single" ? "radio" : "checkbox";
        input.name = name;
        input.value = option.value;
        const text = el("span", "", option.title);
        if (option.description) text.append(el("small", "", option.description));
        label.append(input, text);
        set.append(label);
        return input;
      });
      read.push((values) => {
        const picked = inputs.filter((input) => input.checked).map((input) => input.value);
        values[field.key] = field.type === "single" ? (picked[0] || "") : picked;
      });
    } else if (field.type === "boolean") {
      const label = el("label", "option");
      const input = el("input");
      input.type = "checkbox";
      label.append(input, el("span", "", field.title));
      set.append(label);
      read.push((values) => { values[field.key] = input.checked; });
    } else if (field.type === "unsupported") {
      set.append(el("p", "question-description", "Answer this part in Emacs."));
    } else {
      const input = el(field.type === "text" ? "textarea" : "input");
      if (field.type !== "text") { input.type = "number"; if (field.type === "integer") input.step = "1"; }
      else input.rows = 2;
      input.setAttribute("aria-label", field.title);
      set.append(input);
      read.push((values) => {
        if (field.type === "text") values[field.key] = input.value;
        else if (input.value.trim() !== "") values[field.key] = Number(input.value);
      });
    }
    if (field.other) {
      const other = el("textarea");
      other.rows = 1;
      other.placeholder = field.type === "multi" ? "Other (added to your picks)" : "Other, or a note on your pick";
      other.setAttribute("aria-label", `${field.title}: other`);
      set.append(other);
      read.push((values) => { if (other.value) values[field.other] = other.value; });
    }
    card.append(set);
  });
  const actions = el("div", "form-actions");
  const submit = el("button", "primary", "Submit");
  const decline = el("button", "", "Decline");
  const feedback = el("div", "inline-feedback");
  feedback.setAttribute("role", "status");
  const send = async (action) => {
    const body = { action };
    if (action === "accept") { body.values = {}; read.forEach((fn) => fn(body.values)); }
    submit.disabled = decline.disabled = true;
    feedback.textContent = "Sending response…";
    try {
      await api.answer(conversation.id, form.id, body, keyFor(JSON.stringify([signature, body])));
      feedback.textContent = "Response sent. Waiting for the agent…";
    } catch (error) {
      feedback.textContent = "Response not sent · " + error.message;
      submit.disabled = decline.disabled = false;
    }
  };
  submit.onclick = () => send("accept");
  decline.onclick = () => send("decline");
  actions.append(submit, decline);
  card.append(actions, feedback);
  remember(questionCards, signature, card, 16);
  return card;
}

function queuedPrompt(id, { id: queueId, text }) {
  const node = el("div", "item prompt queued");
  const actions = el("div", "queued-actions");
  const feedback = el("div", "inline-feedback");
  feedback.setAttribute("role", "status");
  actions.append(el("small", "", "Waiting to send"));
  const withdraw = async (edit) => {
    for (const button of actions.querySelectorAll("button")) button.disabled = true;
    feedback.textContent = edit ? "Moving to draft…" : "Removing…";
    try {
      await api.withdraw(id, queueId, keyFor(JSON.stringify(["withdraw", id, queueId])));
      if (edit) {
        const target = draft(id);
        target.text = (target.text.trim() ? target.text + "\n\n" : "") + text;
        target.revision++;
        syncCompose(true);
        focusCompose(id);
      }
      node.remove();
    } catch (error) {
      feedback.textContent = (error.code === "already_sent" ? "Already sent · " : "Could not change queue · ") + error.message;
      for (const button of actions.querySelectorAll("button")) button.disabled = false;
    }
  };
  const edit = el("button", "", "Edit");
  edit.onclick = () => withdraw(true);
  const remove = el("button", "", "Remove");
  remove.onclick = () => withdraw(false);
  actions.append(edit, remove);
  node.append(el("span", "", text), actions, feedback);
  return node;
}

export function atBottom() {
  const detail = $("detail");
  return detail.scrollTop + detail.clientHeight >= detail.scrollHeight - 80;
}

export function scrollToBottom() {
  $("detail").scrollTop = $("detail").scrollHeight;
  $("latest").hidden = true;
  markSeen();
}

let pinned = true;
function onScroll() {
  pinned = atBottom();
  if (pinned) markSeen();
  $("latest").hidden = pinned || !view;
  $("latest").style.bottom = ($("compose").getBoundingClientRect().height + 12) + "px";
}

// Read positions of one conversation go at most this often while a reply streams; a held one goes on leaving or hiding.
const READ_INTERVAL = 2000;
let lastRead = { key: "", at: 0 }, heldRead = null, readTimer = null;

function sendRead({ key, id, through, epoch }) {
  clearTimeout(readTimer);
  readTimer = heldRead = null;
  if ((state.readSent.get(key) || 0) >= through) return;
  lastRead = { key, at: Date.now() };
  remember(state.readSent, key, through, 256);
  api.read(id, through, epoch).catch(() => {
    if (state.readSent.get(key) === through) state.readSent.delete(key);
  });
}

// Sends a read position held back by the interval now.
export function flushRead() {
  if (heldRead) sendRead(heldRead);
}

// Acknowledges what is shown, only while visible, at the latest message and fully drawn.
export function markSeen() {
  const held = shownConversation();
  if (!held || !view.ready || document.hidden || !atBottom() || view.loadingHistory || !view.presentedSeq) return;
  if ([...itemViews.get(view.id).values()].some((item) => item.timer)) return;
  const read = { key: `${held.epoch}:${held.id}`, id: held.id, through: view.presentedSeq, epoch: held.epoch };
  if (Math.max(state.readSent.get(read.key) || 0, held.conversation.readThrough || 0) >= read.through) return;
  const wait = lastRead.key === read.key ? lastRead.at + READ_INTERVAL - Date.now() : 0;
  if (wait <= 0) { sendRead(read); return; }
  if (heldRead && heldRead.key !== read.key) sendRead(heldRead);
  heldRead = read;
  readTimer ??= setTimeout(() => { if (heldRead) sendRead(heldRead); }, wait);
}

let fileAsked = false;

// Asks before downloading a file a reply links to, showing its size.
async function onFileLink(event) {
  const link = event.target.closest?.("a[data-file]");
  if (!link || !view) return;
  event.preventDefault();
  if (fileAsked) return;
  fileAsked = true;
  try {
    const file = await api.fileLink(view.id, link.dataset.file);
    if (!await confirmAction(`${file.name} · ${fileSize(file.size)}`, { title: "Download file?", label: "Download" })) return;
    const anchor = el("a", "external");
    anchor.href = file.url;
    anchor.download = file.name;
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
  } catch (error) {
    toast(error.message);
  } finally {
    fileAsked = false;
  }
}

export function installConversation() {
  $("detail").addEventListener("scroll", onScroll, { passive: true });
  $("detail").addEventListener("click", onFileLink);
  $("latest").onclick = () => { pinned = true; scrollToBottom(); };
  if (window.ResizeObserver) new ResizeObserver(() => { if (pinned && view) scrollToBottom(); }).observe($("detail"));
}

// Test hook: the module's view state.
export const debug = { get view() { return view; }, itemViews, renderItems: (items) => renderItems(shownConversation(), items) };
