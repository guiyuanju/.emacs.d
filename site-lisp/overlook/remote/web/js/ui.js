// DOM primitives and Framework7 wrappers shared by every view.
import { app } from "js/vendor.js";
import { confirmStyle } from "js/model.js";
import { imageUrl } from "js/api.js";

export const $ = (id) => document.getElementById(id);

export function htmlText(text) {
  return String(text).replace(/[&<>"']/g, (character) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}

const plainButtons = /(?:^| )(?:button|link|more|unqueue|remote-row|task-check|attention-shortcut|navigation-info|dashboard-show-more|code-copy)(?: |$)/;

// An element; buttons get Framework7's tonal style unless they are plain controls.
export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (tag === "button") {
    node.type = "button";
    if (!plainButtons.test(className || "")) {
      node.classList.add("button", className === "primary" ? "button-fill" : "button-tonal");
      if (className === "danger") node.classList.add("color-red");
    }
  }
  if (text) node.textContent = text;
  return node;
}

// An SVG element from trusted markup in this source.
export function svg(markup) {
  const template = document.createElement("template");
  template.innerHTML = markup.trim();
  return template.content.firstChild;
}

let currentToast = null;
export function toast(message) {
  const previous = currentToast;
  currentToast = null;
  if (previous && !previous.destroyed) previous.close();
  const notification = app.toast.create({ text: htmlText(message), closeTimeout: 4000, destroyOnClose: true,
    on: { closed(instance) { if (currentToast === instance) currentToast = null; } } });
  currentToast = notification;
  notification.open();
}

export function confirmAction(message, { title = "Confirm action", label, danger } = {}) {
  const style = confirmStyle(message, label, danger);
  return new Promise((resolve) => {
    const previous = document.activeElement;
    app.dialog.create({ title: htmlText(title), text: htmlText(message), destroyOnClose: true,
      on: { closed: () => { resolve(false); if (previous?.isConnected) previous.focus({ preventScroll: true }); } },
      buttons: [{ text: "Cancel", onClick: () => resolve(false) },
        { text: htmlText(style.label), bold: true, color: style.danger ? "red" : undefined, onClick: () => resolve(true) }] }).open();
  });
}

// An action sheet: buttons are {text, color, onClick}; text is plain.
export function actionSheet(buttons, title) {
  const groups = [];
  if (title) groups.push([{ text: htmlText(title), label: true }]);
  groups.push(buttons.map((button) => ({ ...button, text: htmlText(button.text) })));
  groups.push([{ text: "Cancel", color: "gray" }]);
  app.actions.create({ buttons: groups, destroyOnClose: true }).open();
}

export function closeModals() {
  app.actions.close();
  app.dialog.close();
  closePhotos();
}

export function viewState(title, message, loading = false) {
  const box = el("div", "view-state" + (loading ? " loading" : ""));
  if (loading) {
    const spinner = el("span", "preloader");
    spinner.setAttribute("aria-hidden", "true");
    box.append(spinner);
  }
  box.append(el("h2", "", title));
  if (message) box.append(el("p", "", message));
  return box;
}

export function preloader() {
  const node = el("span", "preloader");
  app.preloader.init(node);
  return node;
}

// Shows error beside control (inside its commands, choices or row), else beside fallback.
export function actionFailure(error, control, fallback) {
  const target = control?.closest?.(".commands, .choices, .remote-item") || fallback;
  if (!target) { toast(error.message); return null; }
  let feedback = target.querySelector(":scope > .operation-error");
  if (!feedback) {
    feedback = el("p", "operation-error");
    feedback.setAttribute("role", "status");
    feedback.setAttribute("aria-live", "polite");
    target.append(feedback);
  }
  feedback.textContent = error.message || "The action could not be completed. Try again.";
  return feedback;
}

export function copyText(text) {
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text).catch(() => copyFallback(text));
  return copyFallback(text);
}

// Plain-HTTP pages have no Clipboard API; copy through a hidden textarea and restore focus and selection.
function copyFallback(text) {
  const focused = document.activeElement;
  const selection = document.getSelection();
  const ranges = Array.from({ length: selection?.rangeCount || 0 }, (_, index) => selection.getRangeAt(index).cloneRange());
  const start = focused?.selectionStart, end = focused?.selectionEnd;
  const input = el("textarea", "offscreen");
  input.value = text;
  document.body.append(input);
  input.select();
  let copied = false;
  try { copied = document.execCommand("copy"); }
  finally {
    input.remove();
    focused?.focus?.({ preventScroll: true });
    if (typeof start === "number") focused.setSelectionRange(start, end);
    selection?.removeAllRanges();
    for (const range of ranges) selection.addRange(range);
  }
  return copied ? Promise.resolve() : Promise.reject(new Error("Copy unavailable"));
}

export const iconPaths = {
  claude: '<g stroke="#d97757" stroke-width="2.4"><path d="M12 2v20M2 12h20M5 5l14 14M5 19L19 5M8 3l8 18M3 8l18 8M3 16l18-8M8 21l8-18"/></g>',
  // OpenAI mark from lobe-icons; licence in vendor/lobe-icons-LICENSE.
  codex: '<path fill="#10a37f" fill-rule="evenodd" d="M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z"/>',
  gemini: '<path fill="#4285f4" d="M12 1C11 8 8 11 1 12c7 1 10 4 11 11 1-7 4-10 11-11C16 11 13 8 12 1Z"/>',
  antigravity: '<g fill="#8b5cf6"><path d="m12 2 3 7 7 3-7 3-3 7-3-7-7-3 7-3Z"/><path d="m20 1 1 2 2 1-2 1-1 2-1-2-2-1 2-1Z"/></g>',
  deepseek: '<g fill="none" stroke="#4d6bfe" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12c2-5 8-6 13-2l5-3-1 6c-1 6-11 9-16 3l-2-1m6-6 3-4 1 4"/><path d="M8 13h.01M4 19c4 2 9 2 13 0"/></g>',
};

// A provider mark, or its name when there is none.
export function icon(name, title = name) {
  const path = iconPaths[String(name).toLowerCase()];
  if (!path) return el("span", "icon-text", name);
  const image = el("img", "icon");
  image.src = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">' + path + "</svg>");
  image.alt = name;
  image.title = title;
  return image;
}

export function personaAvatar(name) {
  const avatar = el("span", "persona-avatar", Array.from(name || "?")[0].toLocaleUpperCase());
  let hue = 0;
  for (const char of name || "") hue = (hue * 31 + char.codePointAt(0)) % 360;
  avatar.style.setProperty("--avatar-hue", hue);
  avatar.setAttribute("aria-hidden", "true");
  return avatar;
}

export function personaProfile(name, description) {
  const profile = el("div", "persona-profile");
  profile.append(personaAvatar(name), el("h2", "", name));
  if (description) profile.append(el("p", "", description));
  return profile;
}

// Touch and hold, right click, or the context menu key (Shift+F10) on row call show.
export function pressMenu(row, show) {
  let timer, origin, held = false;
  const cancel = () => { clearTimeout(timer); timer = null; };
  const open = () => { cancel(); held = true; show(); };
  row.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    held = false;
    origin = { x: event.clientX, y: event.clientY };
    timer = setTimeout(open, 550);
  });
  row.addEventListener("pointermove", (event) => {
    if (origin && Math.hypot(event.clientX - origin.x, event.clientY - origin.y) > 8) cancel();
  });
  for (const type of ["pointerup", "pointercancel", "pointerleave"]) row.addEventListener(type, cancel);
  row.addEventListener("contextmenu", (event) => { event.preventDefault(); if (!held) open(); });
  row.addEventListener("keydown", (event) => {
    if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) { event.preventDefault(); open(); }
  });
  row.addEventListener("click", (event) => {
    cancel();
    if (held) { held = false; event.preventDefault(); event.stopImmediatePropagation(); }
  }, true);
  row.setAttribute("aria-description", "Touch and hold or press Shift+F10 for actions");
}

let photoBrowser = null;
export const photosOpen = () => photoBrowser !== null;

export function closePhotos() {
  photoBrowser?.close();
}

// Opens the viewer on img, browsing every loaded image of its strip.
function showPhotos(img) {
  const images = [...(img.closest(".images")?.querySelectorAll("img") || [img])].filter((image) => image.src);
  photoBrowser?.close();
  photoBrowser = app.photoBrowser.create({
    photos: images.map((image) => image.src), initialSlide: Math.max(0, images.indexOf(img)),
    type: "standalone", theme: app.darkMode ? "dark" : "light",
    on: { closed(browser) {
      if (photoBrowser === browser) photoBrowser = null;
      setTimeout(() => { browser.modal?.destroy(); browser.destroy(); }, 0);
    } },
  });
  photoBrowser.open();
}

export function zoomable(img) {
  img.addEventListener("click", (event) => {
    event.stopPropagation();
    if (img.src) showPhotos(img);
  });
  return img;
}

// A strip of activity images, each fetched with the token and retryable.
export function imageStrip(ids) {
  const strip = el("div", "images");
  for (const id of ids) {
    const img = zoomable(el("img"));
    img.alt = "Image";
    const retry = el("button", "button button-small", "Retry image");
    const load = async () => {
      try { img.src = await imageUrl(id); retry.remove(); }
      catch (_) { if (!retry.isConnected) strip.append(retry); }
    };
    retry.onclick = load;
    load();
    strip.append(img);
  }
  return strip;
}

export function messageTime(node, createdAt) {
  if (!createdAt) return;
  const date = new Date(createdAt);
  if (!Number.isFinite(date.getTime())) return;
  const today = date.toDateString() === new Date().toDateString();
  const time = el("time", "message-time", (today ? "" : date.toLocaleDateString([], { month: "short", day: "numeric" }) + " · ")
    + date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }));
  time.dateTime = createdAt;
  time.title = date.toLocaleString();
  node.append(time);
}
