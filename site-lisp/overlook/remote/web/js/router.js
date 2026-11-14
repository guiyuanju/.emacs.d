// Query-string navigation with browser history, page transitions and focus restoration.
import { $ } from "js/ui.js";
import { state } from "js/state.js";
import { parseRoute, formatRoute, nodePath } from "js/model.js";

let render = () => {};
let beforeLeave = () => {};
let depth = history.state?.overlookDepth || 0;
let animateHistoryBack = false;
let pageTransition = null;
let restoringFocus = null;
let shownSearch = location.search;

export const currentRoute = () => parseRoute(location.search);

// render() draws the route in location; beforeLeave() saves the reading position of the page leaving.
export function installRouter(options) {
  ({ render, beforeLeave } = options);
  $("back").onclick = goBack;
  window.addEventListener("popstate", (event) => {
    const target = event.state?.overlookDepth || 0;
    const back = target < depth;
    depth = target;
    // Browser gestures already animate history traversal; only the in-app Back button animates here.
    const animate = animateHistoryBack && back;
    animateHistoryBack = false;
    transition(back, animate);
  });
}

export function navigate(route, { back = false, replace = false } = {}) {
  const next = replace ? Math.max(0, depth - 1) : depth + 1;
  history[replace ? "replaceState" : "pushState"]({ overlookDepth: next }, "", location.pathname + formatRoute(route) + location.hash);
  depth = next;
  transition(back, true);
}

export const openConversation = (id) => navigate({ ...currentRoute(), conversation: id });
export const openGroup = (id) => navigate({ node: id });

export function goBack() {
  if (depth > 0) { animateHistoryBack = true; history.back(); return; }
  const route = currentRoute();
  if (route.conversation) route.conversation = null;
  else {
    const path = nodePath(route.node, state.dashboard.sections || []);
    route.node = path?.length > 2 ? path.at(-2).id : null;
  }
  navigate(route, { back: true, replace: true });
}

function rememberFocus() {
  const row = document.activeElement?.closest?.("[data-node-id]");
  if (row?.dataset.nodeId) state.focus.set(shownSearch, row.dataset.nodeId);
}

function restoreFocus(back) {
  restoringFocus?.();
  const search = location.search;
  const nodeId = back && state.focus.get(search);
  const target = () => nodeId
    ? [...document.querySelectorAll("[data-node-id]")].find((node) => node.dataset.nodeId === nodeId)?.querySelector(".remote-row")
    : parseRoute(search).conversation || parseRoute(search).node ? $("heading") : $("dashboard-intro").querySelector("h1");
  const focus = () => {
    const element = target();
    if (!element || element.closest("[hidden]") || element.closest(".page-snapshot")) return false;
    if (!element.matches("button, a, input, textarea, select")) element.tabIndex = -1;
    element.focus({ preventScroll: true });
    return true;
  };
  if (focus()) return;
  const observer = new MutationObserver(() => { if (focus()) cleanup(); });
  observer.observe($("dashboard-content"), { childList: true, subtree: true });
  const timer = setTimeout(() => { cleanup(); $("heading").focus({ preventScroll: true }); }, 4000);
  function cleanup() { observer.disconnect(); clearTimeout(timer); restoringFocus = null; }
  restoringFocus = cleanup;
}

// Draws the new route; the old page slides out as an inert snapshot.
function transition(back, animate) {
  beforeLeave();
  rememberFocus();
  const update = () => {
    render();
    shownSearch = location.search;
    requestAnimationFrame(() => restoreFocus(back));
  };
  pageTransition?.();
  const page = document.querySelector(".remote-page");
  if (!animate || window.matchMedia?.("(prefers-reduced-motion: reduce)").matches || !page?.animate) { update(); return; }
  const snapshot = page.cloneNode(true);
  snapshot.classList.add("page-snapshot", back ? "snapshot-above" : "snapshot-below");
  snapshot.inert = true;
  snapshot.setAttribute("aria-hidden", "true");
  snapshot.querySelectorAll("[id]").forEach((node) => {
    node.dataset.snapshotId = node.id;
    node.removeAttribute("id");
  });
  snapshot.querySelectorAll("textarea").forEach((node) => node.removeAttribute("name"));
  const scrolls = [...page.querySelectorAll(".page-content")].map((node) => node.scrollTop);
  update();
  page.parentElement.append(snapshot);
  [...snapshot.querySelectorAll(".page-content")].forEach((node, index) => { node.scrollTop = scrolls[index] || 0; });
  page.classList.add(back ? "page-below" : "page-above");
  const timing = { duration: 340, easing: "cubic-bezier(.32,.72,0,1)", fill: "both" };
  const outgoing = snapshot.animate([{ transform: "translateX(0)", opacity: 1 },
    { transform: back ? "translateX(100%)" : "translateX(-25%)", opacity: back ? 1 : 0.7 }], timing);
  const incoming = page.animate([{ transform: back ? "translateX(-25%)" : "translateX(100%)" }, { transform: "translateX(0)" }], timing);
  const cleanup = () => {
    outgoing.cancel(); incoming.cancel(); snapshot.remove();
    page.classList.remove("page-below", "page-above");
  };
  pageTransition = cleanup;
  incoming.finished.then(() => { if (pageTransition === cleanup) { cleanup(); pageTransition = null; } }, () => {});
}
