// Connection banner, sync footer and the viewport fitting around the iOS keyboard.
import { $, viewState } from "js/ui.js";
import { state, setConnection } from "js/state.js";
import { processBanner } from "js/model.js";

let retryHandler = () => {};
let restartHandler = () => {};

export function onRestartEmacs(fn) { restartHandler = fn; }
let dashboardHandler = () => {};

export function onRetry(fn) { retryHandler = fn; }
export function onReturnDashboard(fn) { dashboardHandler = fn; }

function problemOf(error) {
  if (error.status === 401 || error.code === "unauthorized") return "auth";
  if (error.code === "protocol_mismatch") return "version";
  if (error.code === "conversation_missing" || error.code === "gone") return "missing";
  if (navigator.onLine === false) return "offline";
  return "retry";
}

const messages = {
  auth: ["Link required", "Open your personal link", "Open a fresh link in Emacs with M-x overlook-remote-url. Keep this page open to retain your unsent draft."],
  version: ["Update available", "Update available", "The app has been updated. Refresh to continue."],
  missing: ["Conversation ended", "Conversation ended", "This conversation has ended. Your unsent draft is still available on this page."],
  offline: ["Offline", "Unable to load", "You’re offline. Reconnecting when a network is available."],
  retry: ["Reconnecting", "Unable to load", "Connection interrupted. Reconnecting…"],
  emacs: ["Emacs offline", "", "Emacs is not connected. Showing the last update; sending resumes when Emacs is back."],
};

// Data arrived: hide connection problems and stamp the footer.
export function connected() {
  const lastSync = new Date();
  setConnection({ problem: "", blocked: false, lastSync });
  $("conn").textContent = "Updated " + lastSync.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  $("conn").title = "Last synced: " + lastSync.toLocaleString();
  $("dashboard-content").removeAttribute("aria-busy");
  renderBanner();
}

// Takes emacs ("online"/"offline") and, when the daemon supervises Emacs, its process status.
export function setEmacs(emacs, process) {
  const change = {};
  if (emacs && state.connection.emacs !== emacs) change.emacs = emacs;
  if (process && JSON.stringify(process) !== JSON.stringify(state.connection.process)) change.process = process;
  if (!Object.keys(change).length) return;
  setConnection(change);
  renderBanner();
}

// Shows why loading failed; returns true when retrying cannot help.
export function connectionFailure(error) {
  const problem = problemOf(error);
  const blocked = ["auth", "version", "missing"].includes(problem);
  setConnection({ problem, blocked });
  $("conn").textContent = messages[problem][0];
  renderBanner();
  const target = state.route.conversation ? $("d-feed") : $("dashboard-content");
  target.querySelector(".view-state.loading")?.replaceWith(viewState(messages[problem][1], messages[problem][2]));
  target.removeAttribute("aria-busy");
  return blocked;
}

export function clearProblem() {
  setConnection({ problem: "", blocked: false });
  renderBanner();
}

function renderBanner() {
  const { problem, emacs, process } = state.connection;
  const about = problem ? null : processBanner(process, emacs);
  const shown = problem || (about ? "emacs" : "");
  const banner = $("connection");
  banner.hidden = !shown;
  $("restart-footer").hidden = !process?.canRestart || process.state === "restarting";
  if (!shown) { banner.removeAttribute("data-error"); return; }
  const message = about ? about.message : messages[shown][2];
  if (banner.dataset.error !== shown || $("connection-message").textContent !== message) {
    $("connection-message").textContent = message;
    banner.dataset.error = shown;
  }
  $("return-dashboard").hidden = shown !== "missing";
  $("reconnect").hidden = ["auth", "missing", "emacs"].includes(shown);
  $("reconnect").textContent = shown === "version" ? "Refresh" : "Retry";
  $("restart-emacs").hidden = !about?.action;
  $("restart-emacs").textContent = about?.action === "start" ? "Start Emacs" : "Restart Emacs";
}

export function installShell() {
  $("reconnect").onclick = () => state.connection.problem === "version" ? location.reload() : retryHandler();
  $("return-dashboard").onclick = () => dashboardHandler();
  $("restart-emacs").onclick = () => restartHandler();
  $("restart-footer").onclick = () => restartHandler();
  // iOS never resizes the layout for the keyboard, so the page fits the visual viewport and only its content scrolls.
  const viewport = window.visualViewport;
  if (viewport) {
    viewport.addEventListener("resize", fitShell);
    viewport.addEventListener("scroll", fitShell);
  }
  fitShell();
  // With the keyboard up iOS pans the page on any drag that nothing inside can absorb.
  document.addEventListener("touchmove", (event) => {
    if (!keyboardOpen()) return;
    const scroller = event.target.closest?.(".page-content, textarea, #slash-commands, .dialog-inner");
    if (!scroller || scroller.scrollHeight <= scroller.clientHeight) event.preventDefault();
  }, { passive: false });
}

export function fitShell() {
  const viewport = window.visualViewport;
  if (!viewport || viewport.scale > 1) return;
  document.body.style.height = viewport.height + "px";
  document.body.style.top = Math.max(0, viewport.offsetTop) + "px";
}

export function keyboardOpen() {
  const viewport = window.visualViewport;
  return !!viewport && !(viewport.scale > 1) && innerHeight - viewport.height >= 1;
}
