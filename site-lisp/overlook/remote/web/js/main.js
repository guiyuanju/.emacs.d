// Entry point: credential, router, the one stream, and which page is shown.
import { loadToken, hasToken, PROTOCOL } from "js/api.js";
import { state } from "js/state.js";
import { Stream } from "js/stream.js";
import { $, viewState, closeModals } from "js/ui.js";
import { installRouter, currentRoute, navigate } from "js/router.js";
import { installShell, connected, connectionFailure, clearProblem, setEmacs, onRetry, onReturnDashboard, onRestartEmacs } from "js/shell.js";
import { restartEmacs } from "js/emacs.js";
import { showDashboard, leaveDashboard, dashboardEvent, saveDashboardScroll, closePanel } from "js/dashboard.js";
import { showConversation, leaveConversation, conversationEvent, installConversation, markSeen, flushRead } from "js/conversation.js";
import { installCompose, setComposeTarget, saveCompose } from "js/compose.js";

loadToken();

const stream = new Stream({
  onEvent(name, data) {
    if (name === "hello") {
      if (String(data.protocol) !== PROTOCOL) { stream.close(); connectionFailure({ code: "protocol_mismatch" }); return; }
      setEmacs(data.emacs, data.process);
      connected();
      return;
    }
    if (name === "status") { setEmacs(data.emacs, data.process); return; }
    connected();
    if (state.route.conversation) conversationEvent(name, data);
    else dashboardEvent(name, data);
  },
  onError: (error) => connectionFailure(error),
});

function leave() {
  saveDashboardScroll();
  saveCompose();
}

// Draws the route in location: stops the old page's stream and work, then starts the new page.
function show() {
  state.generation++;
  stream.close();
  if (state.route.conversation) leaveConversation(); else leaveDashboard();
  state.route = currentRoute();
  clearProblem();
  const id = state.route.conversation;
  $("dash").hidden = !!id;
  $("detail").hidden = !id;
  $("latest").hidden = true;
  $("back").hidden = !id && !state.route.node;
  document.querySelector(".remote-page").classList.toggle("home", !id && !state.route.node);
  $("session-menu").hidden = true;
  $("context").hidden = true;
  $("persona-profile").hidden = true;
  closePanel(false);
  closeModals();
  setComposeTarget(id);
  if (!hasToken()) {
    (id ? $("d-feed") : $("dashboard-content")).replaceChildren(viewState("Open your personal link",
      "In Emacs, run M-x overlook-remote-url and open the generated link on this device."));
    $("compose").hidden = true;
    $("heading").textContent = "Overlook";
    connectionFailure({ status: 401 });
    return;
  }
  if (id) showConversation(id, stream);
  else showDashboard(stream);
}

installShell();
installCompose();
installConversation();
installRouter({ render: show, beforeLeave: leave });
onRetry(() => { if (stream.query !== null) { clearProblem(); stream.retry(); } else show(); });
onReturnDashboard(() => navigate({}, { back: true }));
onRestartEmacs(restartEmacs);
window.addEventListener("online", () => { if (!state.connection.blocked) stream.retry(); });
window.addEventListener("offline", () => connectionFailure(new TypeError("offline")));
document.addEventListener("visibilitychange", () => {
  if (document.hidden) { flushRead(); stream.pause(); }
  else if (!state.connection.blocked) { stream.resume(); markSeen(); }
});
show();
