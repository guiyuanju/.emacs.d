// HTTP client for the protocol 3 browser API: bearer token, problem+json, idempotency keys.
export const PROTOCOL = "3";
export const BASE = "/overlook/api/";
const TOKEN_KEY = "overlook-token";

let token = "";

// Reads the credential from the launch hash, else from storage; Home Screen apps keep it in their URL.
export function loadToken(location = window.location, storage = window.localStorage, history = window.history) {
  if (location.hash.length > 1) storage.setItem(TOKEN_KEY, decodeURIComponent(location.hash.slice(1)));
  token = storage.getItem(TOKEN_KEY) || "";
  if (token && !location.hash) history.replaceState(history.state, "", location.pathname + location.search + "#" + token);
  return token;
}

export const hasToken = () => !!token;

export class ApiError extends Error {
  constructor(message, { status = 0, code = "", detail = "" } = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

export function headers(extra = {}) {
  return { "Authorization": "Bearer " + token, "Overlook-Protocol": PROTOCOL, ...extra };
}

export function checkProtocol(response) {
  const protocol = response.headers.get("Overlook-Protocol");
  if (protocol && protocol !== PROTOCOL) {
    throw new ApiError("Refresh this page to use the updated app", { status: response.status, code: "protocol_mismatch" });
  }
}

async function failure(response) {
  let problem = {};
  try { problem = await response.json(); } catch (_) { /* not JSON */ }
  return new ApiError(problem.detail || problem.title || response.statusText || `HTTP ${response.status}`,
    { status: response.status, code: problem.code || "", detail: problem.detail || "" });
}

// Sends one request; resolves to the parsed JSON body, or null for empty responses.
export async function request(method, path, { body, raw, type, key, signal, timeout = 40000 } = {}) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) controller.abort();
  const timer = setTimeout(abort, timeout);
  const extra = {};
  if (body !== undefined) extra["Content-Type"] = "application/json";
  if (raw !== undefined) extra["Content-Type"] = type || raw.type || "application/octet-stream";
  if (key) extra["Idempotency-Key"] = key;
  try {
    const response = await fetch(BASE + path, {
      method, headers: headers(extra), signal: controller.signal, cache: "no-store",
      body: raw !== undefined ? raw : body !== undefined ? JSON.stringify(body) : undefined,
    });
    checkProtocol(response);
    if (!response.ok) throw await failure(response);
    if (response.status === 204) return null;
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  } catch (error) {
    if (error.name === "AbortError" && !signal?.aborted) throw new ApiError("Request timed out; retry to check delivery", { code: "timeout" });
    if (error instanceof TypeError) throw new ApiError("Network unavailable; retry when connected", { code: "network" });
    throw error;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", abort);
  }
}

export const get = (path, options) => request("GET", path, options);

const enc = encodeURIComponent;

export const api = {
  dashboard: (known, signal) => get("dashboard" + (known ? "?known=" + enc(known) : ""), { signal }),
  conversation: (id, signal) => get("conversations/" + enc(id), { signal }),
  history: (id, before, epoch, signal) => get(`conversations/${enc(id)}/history?before=${before}&limit=50&epoch=${enc(epoch)}`, { signal }),
  prompt: (id, text, key) => request("POST", `conversations/${enc(id)}/prompts`, { body: { text }, key }),
  withdraw: (id, queueId, key) => request("DELETE", `conversations/${enc(id)}/prompts/${enc(queueId)}`, { key }),
  retry: (id, key) => request("POST", `conversations/${enc(id)}/prompts/retry`, { key }),
  read: (id, through, epoch) => request("PUT", `conversations/${enc(id)}/read`, { body: { through, epoch } }),
  action: (id, body, key) => request("POST", `conversations/${enc(id)}/actions`, { body, key }),
  choose: (id, choiceKey, key) => request("POST", `conversations/${enc(id)}/choice`, { body: { key: choiceKey }, key }),
  answer: (id, form, body, key) => request("POST", `conversations/${enc(id)}/forms/${enc(form)}`, { body, key }),
  attach: (id, blob, key) => request("POST", `conversations/${enc(id)}/attachments`, { raw: blob, type: blob.type, key, timeout: 120000 }),
  fileLink: (id, path) => request("POST", `conversations/${enc(id)}/files`, { body: { path } }),
  diff: (node) => get(`nodes/${enc(node)}/diff`),
  command: (node, name, body, key) => request("POST", `nodes/${enc(node)}/commands/${enc(name)}`, { body, key }),
  emacs: () => get("emacs"),
  restartEmacs: () => request("POST", "emacs/restart"),
};

const images = new Map();

// An object URL for an activity image, fetched once with the token.
export function imageUrl(id) {
  if (!images.has(id)) {
    images.set(id, fetch(BASE + "images/" + enc(id), { headers: headers() })
      .then((response) => response.ok ? response.blob() : Promise.reject(new ApiError("image " + id, { status: response.status })))
      .then((blob) => URL.createObjectURL(blob))
      .catch((error) => { images.delete(id); throw error; }));
  }
  return images.get(id);
}
