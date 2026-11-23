// Restarting the Emacs process the daemon supervises.
import { api } from "js/api.js";
import { state } from "js/state.js";
import { restartQuestion } from "js/model.js";
import { confirmAction, toast } from "js/ui.js";

let pending = false;

export async function restartEmacs() {
  if (pending) return;
  const starting = ["stopped", "crashed"].includes(state.connection.process?.state);
  if (!starting && !await confirmAction(restartQuestion(state.dashboard.sections || []),
    { title: "Restart Emacs?", label: "Restart", danger: true })) return;
  pending = true;
  try {
    await api.restartEmacs();
  } catch (error) {
    toast(error.message || "Could not restart Emacs");
  } finally {
    pending = false;
  }
}
