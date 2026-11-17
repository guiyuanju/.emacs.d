// The page's state in one place; views read it and change it only through these functions.
import { indexNodes } from "js/model.js";

export const state = {
  // Route shown: {conversation, node}; generation changes on every navigation.
  route: { conversation: null, node: null },
  generation: 0,
  // Connection: problem is "", "retry", "offline", "auth", "version" or "missing"; emacs is "online" or "offline".
  connection: { problem: "", emacs: "online", lastSync: null, blocked: false },
  // Latest dashboard version: cursor, expanded sections and nodes by hash.
  dashboard: { known: "", sections: null, byHash: new Map() },
  // Held conversations (see model.conversationFromSnapshot), most recent last.
  conversations: new Map(),
  // Per-conversation composer drafts.
  drafts: new Map(),
  // Dashboard disclosure, keyed by section key or "attention".
  disclosures: new Map(),
  // Reading positions: dashboard scroll by node route, conversation {top, pinned} by id, focused row by route.
  dashboardScroll: new Map(),
  conversationScroll: new Map(),
  focus: new Map(),
  // Unsent command sheet input by [node, command].
  formDrafts: new Map(),
  // Highest read position sent, by "epoch:conversation".
  readSent: new Map(),
};

const listeners = new Map();

export function on(topic, fn) {
  if (!listeners.has(topic)) listeners.set(topic, new Set());
  listeners.get(topic).add(fn);
  return () => listeners.get(topic).delete(fn);
}

export function emit(topic, value) {
  for (const fn of listeners.get(topic) || []) fn(value);
}

// Map.set that drops the oldest entry beyond limit.
export function remember(map, key, value, limit = 256) {
  map.delete(key);
  map.set(key, value);
  while (map.size > limit) map.delete(map.keys().next().value);
  return value;
}

export function setDashboard(known, sections) {
  state.dashboard = { known, sections, byHash: indexNodes(sections) };
  emit("dashboard", state.dashboard);
}

export function holdConversation(held) {
  remember(state.conversations, held.id, held, 8);
  return held;
}

export function draft(id) {
  if (!state.drafts.has(id)) {
    state.drafts.set(id, { text: "", revision: 0, previews: [], uploading: 0, pending: false,
      attempts: new Map(), pendingAttachments: [], sendError: "", echoes: [] });
  }
  return state.drafts.get(id);
}

export function setConnection(change) {
  Object.assign(state.connection, change);
  emit("connection", state.connection);
}
