// The composer: per-conversation drafts, sending and queueing, steering, session actions and image uploads.
import { api } from "js/api.js";
import { state, draft, emit } from "js/state.js";
import { $, el, toast, confirmAction, actionFailure, zoomable, preloader } from "js/ui.js";
import { navigate, openConversation, currentRoute } from "js/router.js";
import { slashMatches, slashText, appendDraft, randomKey, actionLabels } from "js/model.js";

let composeId = null;
let composing = false;
let sessionPending = false;

const conversationOf = (id) => state.conversations.get(id)?.conversation || null;
export const sessionBusy = () => sessionPending;

// Points the composer at conversation id (null hides it), keeping the previous draft.
export function setComposeTarget(id) {
  saveCompose();
  if (composeId !== id) composing = false;
  composeId = id;
  $("compose").hidden = !id;
  if (id) syncCompose(true);
  else $("slash-commands").replaceChildren();
}

export function saveCompose() {
  if (composeId) draft(composeId).text = $("text").value;
}

export function focusCompose(id) {
  if (composeId === id) $("text").focus();
}

function resize() {
  if (composing) return;
  const box = $("text");
  box.style.height = "44px";
  const height = Math.max(44, box.scrollHeight + 2);
  const limit = Math.max(44, (window.visualViewport?.height || innerHeight) * 0.4);
  box.style.maxHeight = limit + "px";
  box.style.height = height + "px";
  box.style.overflowY = height > limit ? "auto" : "hidden";
}

// Redraws the composer from the draft; the textarea is only overwritten outside IME composition.
export function syncCompose() {
  if (!composeId) return;
  const id = composeId;
  const current = draft(id);
  if (!composing && $("text").value !== current.text) $("text").value = current.text;
  $("previews").replaceChildren(...current.previews.map((preview) => previewCard(preview, current, id)));
  resize();
  const failedUpload = current.previews.some((preview) => preview.uploadError);
  const blocked = !current.text.trim() || current.pending || current.uploading > 0 || failedUpload;
  $("send").disabled = blocked;
  const sendButton = $("send");
  sendButton.setAttribute("aria-busy", String(current.pending));
  if (current.pending && !sendButton.querySelector(".preloader")) {
    sendButton.querySelector("svg").setAttribute("hidden", "");
    const spinner = preloader();
    spinner.setAttribute("aria-hidden", "true");
    sendButton.append(spinner);
  } else if (!current.pending) {
    sendButton.querySelector(".preloader")?.remove();
    sendButton.querySelector("svg").removeAttribute("hidden");
  }
  const conversation = conversationOf(id);
  const busy = conversation?.status === "working";
  $("send").setAttribute("aria-label", busy ? "Queue message" : "Send message");
  const status = $("compose-status");
  status.replaceChildren();
  if (current.sendError) {
    status.append(el("span", "error", "Not sent · " + current.sendError));
    const retry = el("button", "", "Retry send");
    retry.disabled = blocked;
    retry.onclick = () => send();
    status.append(retry);
  } else if (current.pending || current.uploading) status.append(el("span", "", current.uploading ? "Uploading attachments…" : "Sending…"));
  else if (busy) status.append(el("span", "", "Busy · messages will queue"));
  if (busy && conversation.controls?.steer) {
    const steer = el("button", "", "Adjust now");
    steer.disabled = blocked;
    steer.onclick = () => sessionAction("steer", steer);
    status.append(steer);
  }
  if (busy && conversation.controls?.actions?.includes("stop")) {
    const stop = el("button", "stop-task", "Stop");
    stop.disabled = current.pending || current.uploading > 0;
    stop.onclick = () => sessionAction("stop", stop);
    status.append(stop);
  }
  renderSlashCommands();
}

export function renderSlashCommands() {
  if (composing) return;
  const commands = composeId ? slashMatches($("text").value, conversationOf(composeId)?.controls?.slash) : [];
  const rows = [];
  for (const skill of [false, true]) {
    const group = commands.filter((command) => command.name.replace(/^\//, "").startsWith("$") === skill);
    if (!group.length) continue;
    rows.push(el("div", "command-group", skill ? "Skills" : "Commands"));
    for (const command of group) {
      const bare = command.name.replace(/^\//, "");
      const item = el("button", "link slash-command");
      item.append(el("span", "command-name", skill ? bare.slice(1) : "/" + bare));
      if (command.description) {
        item.append(el("span", "command-description", command.description));
        item.title = command.description;
      }
      item.onclick = () => {
        $("text").value = slashText(command);
        $("text").dispatchEvent(new Event("input"));
        $("text").focus();
      };
      rows.push(item);
    }
  }
  $("slash-commands").replaceChildren(...rows);
}

// The Idempotency-Key of one attempt at action with text; kept until it succeeds.
function attemptKey(current, action, text) {
  const key = JSON.stringify([action, text]);
  if (!current.attempts.has(key)) current.attempts.set(key, randomKey());
  return current.attempts.get(key);
}

// Clears the draft after a successful send unless it changed meanwhile.
function acknowledge(id, current, revision, text) {
  current.attempts.clear();
  if (current.revision === revision && current.text.trim() === text) {
    current.text = "";
    current.previews.forEach((preview) => URL.revokeObjectURL(preview.src));
    current.previews = [];
  }
  if (composeId === id) syncCompose();
}

export async function send() {
  saveCompose();
  const id = composeId;
  if (!id) return;
  const current = draft(id);
  const text = current.text.trim();
  if (!text || composing || current.pending || current.uploading || current.previews.some((preview) => preview.uploadError)) return;
  const revision = current.revision;
  const after = state.conversations.get(id)?.seq || 0;
  const key = attemptKey(current, "send", text);
  let echo = current.echoes.find((item) => item.key === key);
  if (!echo) {
    echo = { key, text, after, at: new Date().toISOString() };
    current.echoes.push(echo);
  }
  echo.status = "sending";
  echo.error = "";
  current.pending = true;
  current.sendError = "";
  syncCompose();
  emit("sent", id);
  try {
    const result = await api.prompt(id, text, key);
    echo.status = "sent";
    if (result?.delivery === "queued") current.echoes = current.echoes.filter((item) => item !== echo);
    if (composeId === id) saveCompose();
    current.sendError = "";
    acknowledge(id, current, revision, text);
  } catch (error) {
    echo.status = "failed";
    echo.error = error.message;
    current.sendError = error.message;
  } finally {
    current.pending = false;
    emit("sent", id);
    if (composeId === id) syncCompose();
  }
}

const confirmLabels = { stop: "Stop task", reload: "Reload session", restart: "New conversation", fork: "Fork conversation", steer: "Adjust now", close: "Close agent" };

// Runs a session action through its confirmations; value is a setting's chosen value.
export async function sessionAction(action, button, value = "") {
  if (sessionPending || !composeId) return;
  const generation = state.generation;
  saveCompose();
  const id = composeId;
  const current = draft(id);
  if (current.pending || current.uploading) return;
  const revision = current.revision;
  const text = action === "steer" ? current.text.trim() : value;
  if (action === "steer" && (!text || composing)) return;
  const setting = conversationOf(id)?.controls?.settings?.find((item) => item.id === action);
  sessionPending = true;
  current.pending = true;
  syncCompose();
  button.disabled = true;
  try {
    const body = { action };
    if (text) body.text = text;
    const key = attemptKey(current, action, text);
    let result;
    for (;;) {
      result = await api.action(id, body, key);
      if (generation !== state.generation) return;
      if (result?.outcome !== "confirm") break;
      if (!await confirmAction(result.question, { title: "Session action", label: confirmLabels[action] || "Continue",
        danger: ["stop", "restart", "close"].includes(action) })) return;
      if (generation !== state.generation) return;
      body.confirmations = result.confirmations;
      body.confirmationToken = result.confirmationToken;
    }
    current.attempts.clear();
    if (action === "steer") {
      if (composeId === id) saveCompose();
      acknowledge(id, current, revision, text);
      toast("Steer sent");
    } else if (action === "stop") toast("Stop requested");
    else if (setting) toast(`${setting.label} change requested`);
    else if (result?.closed) {
      if (currentRoute().conversation === id) navigate({ ...currentRoute(), conversation: null }, { back: true, replace: true });
      toast("Agent closed");
    } else if (result?.conversation && result.conversation !== id && currentRoute().conversation === id) {
      openConversation(result.conversation);
    } else toast((actionLabels[action] || action) + ": done");
  } catch (error) {
    actionFailure(error, button, $("compose"));
  } finally {
    sessionPending = false;
    current.pending = false;
    if (button.isConnected) button.disabled = false;
    if (composeId === id) syncCompose();
  }
}

const sendable = ["image/png", "image/jpeg", "image/gif", "image/webp"];

// Sendable images under 2.5 MB go as they are; others are re-encoded as JPEG at most 2000 px wide.
async function prepare(file) {
  if (sendable.includes(file.type) && file.size <= 2500000) return file;
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, 2000 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
}

function previewCard(preview, current, id) {
  const card = el("div", "attachment");
  const img = zoomable(el("img"));
  img.src = preview.src;
  img.alt = preview.file?.name || "Attachment";
  const info = el("div", "attachment-info", preview.file?.name || "Image");
  info.append(el("span", preview.uploadError ? "error" : "", preview.uploadError || (preview.uploading ? "Uploading…" : "Attached")));
  card.append(img, info);
  if (preview.uploadError) {
    const retry = el("button", "", "Retry");
    retry.onclick = () => upload(preview, current, id);
    card.append(retry);
  }
  const remove = el("button", "", "Remove");
  remove.setAttribute("aria-label", "Remove " + (preview.file?.name || "image"));
  remove.onclick = () => {
    if (composeId === id) saveCompose();
    preview.removed = true;
    current.previews = current.previews.filter((item) => item !== preview);
    if (preview.attachmentText) {
      const start = current.text.lastIndexOf(preview.attachmentText);
      if (start >= 0) current.text = current.text.slice(0, start) + current.text.slice(start + preview.attachmentText.length);
      current.pendingAttachments = current.pendingAttachments.filter((text) => text !== preview.attachmentText);
    }
    URL.revokeObjectURL(preview.src);
    current.revision++;
    if (composeId === id) syncCompose();
  };
  remove.disabled = current.pending;
  card.append(remove);
  return card;
}

// Uploads raw image bytes; the returned text joins the draft, or waits for IME composition to end.
async function upload(preview, current, id) {
  if (preview.uploading || preview.removed || current.pending) return;
  preview.uploading = true;
  preview.uploadError = "";
  current.uploading++;
  if (composeId === id) syncCompose();
  try {
    preview.blob ??= await prepare(preview.file);
    if (!preview.blob) throw new Error("This image could not be prepared");
    const result = await api.attach(id, preview.blob, preview.key);
    if (!result?.text || typeof result.text !== "string") throw new Error("No attachment was returned");
    if (preview.removed) return;
    if (composeId === id) saveCompose();
    preview.attachmentText = result.text;
    if (composing && composeId === id) current.pendingAttachments.push(result.text);
    else current.text = appendDraft(current.text, result.text);
    current.revision++;
  } catch (error) {
    if (!preview.removed) preview.uploadError = error.message;
  } finally {
    preview.uploading = false;
    current.uploading--;
    if (composeId === id) syncCompose();
  }
}

function attach(file) {
  saveCompose();
  const id = composeId;
  if (!id) return;
  const current = draft(id);
  if (current.pending) return;
  const preview = { file, src: URL.createObjectURL(file), key: randomKey(), uploading: false, uploadError: "", removed: false };
  current.previews.push(preview);
  current.revision++;
  return upload(preview, current, id);
}

function finishComposition() {
  composing = false;
  if (!composeId) return;
  const current = draft(composeId);
  current.text = $("text").value;
  current.revision++;
  for (const text of current.pendingAttachments) current.text = appendDraft(current.text, text);
  current.pendingAttachments = [];
  syncCompose();
}

export function installCompose() {
  const text = $("text");
  text.addEventListener("compositionstart", () => {
    composing = true;
    if (composeId) draft(composeId).revision++;
  });
  text.addEventListener("compositionend", finishComposition);
  text.addEventListener("blur", () => { if (composing) finishComposition(); });
  text.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey) || event.isComposing || composing) return;
    event.preventDefault();
    send();
  });
  text.addEventListener("input", (event) => {
    if (composeId) {
      draft(composeId).text = event.target.value;
      draft(composeId).revision++;
    }
    if (event.isComposing || composing) return;
    syncCompose();
  });
  $("attach").onclick = () => $("files").click();
  $("files").onchange = (event) => {
    [...event.target.files].forEach(attach);
    event.target.value = "";
  };
  $("send").onclick = () => send();
}

// Test hook.
export const debug = { get composeId() { return composeId; }, get composing() { return composing; } };
