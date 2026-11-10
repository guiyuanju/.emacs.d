---
name: courier-handoff
description: "Hand a task to a new AI agent in the user's Emacs that the user takes over themselves: optionally make a project for it, start it with the task waiting unsent at its prompt, and forget it; it is not told about you and reports nothing. Use when the user asks to start an agent or a project for some work they will drive, or says no reply is needed. When you need the result back, use the courier skill instead. Requires COURIER_ID."
---

# courier-handoff

Start an agent for your user and step away.  The task waits unsent at
the new agent's prompt; your user checks it and sends it, so the agent
sees it as typed by your user.  It does not know about you or courier,
and nothing it does comes back to you.

```sh
test -n "${COURIER_ID:-}" && courier whoami
```

If `COURIER_ID` is unset, say you are not running under courier and stop.

## Steps

1. **Pick the folder.**  Use the one your user names.  If the work needs a
   new project, make it as your user's rules for projects say (template,
   marker files, commits); the agent opens in that project.
2. **Write the task as your user would.**  The agent has none of your
   conversation, so put in what it needs: the goal, the facts and paths
   you found, decisions already made, what is out of scope.  Do not
   mention yourself, courier, or that anyone hands it over, and do not ask
   it to report.  For a long brief, write it to a file in the new
   project and point to it.
3. **Start it:**

   ```sh
   courier spawn --handoff claude ~/path/to/project 'Task text'
   courier spawn --handoff --effort high codex . 'Task text'
   courier spawn --handoff --worktree fix-login claude ~/repo 'Task text'
   ```

   Add `--worktree BRANCH` only when your user asks for a checkout of its
   own.
4. **Tell your user** the agent's id and the folder, and that the task
   waits at its prompt for them to send; then end your turn.
   Do not `courier send` to it, `courier monitor` it, or check on it
   later.
