# overlook

A dashboard over everything you are working on in Emacs: each
project (a [tabspaces](https://codeberg.org/mclear-tools/tabspaces) tab),
the changed Git repos under its root, and the AI agents working in it through
[agent-shell](https://github.com/xenodium/agent-shell).  It tells you
which agents need you, what each is doing, and what it changed, and lets
you answer them from a phone too.

```
Usage
   claude    5h ━━━━━━━━━━  54% 22m     7d ━━━━━━━━━━  13% 3d11h
   codex     5h ━━━━━━━━━━   5% 2h46m   7d ━━━━━━━━━━  16% 6d1h

Projects
blog
   ⎇ blog      main
   codex

checkout
   ⎇ api       feature/refunds  ●4
   ⎇ frontend  feature/refunds  ●2
   claude  Running the payment tests                   12m  41%
      refund.go +48 −6 api/internal/
      RefundButton.tsx +31 frontend/src/
   codex   ? Run git push                                    18%

main
```

## The idea

One feature, one project.  A feature may span several
repos, so a project's root can be a folder holding them, marked by an empty
`.overlook` file; a project of one repo needs nothing.  Agents run at the
project's root and see all of its repos.  The dashboard lists every
project with its repos and agents, so with several features under way
you see at a glance where you are needed.

| | |
|---|---|
| repo | a Git repository |
| project | a tabspaces tab: its own buffers and window layout, named after the project at its root |
| root | a [project.el](https://www.gnu.org/software/emacs/manual/html_node/emacs/Projects.html) project: one repo, or a folder of several marked by `.overlook` |
| agent | an agent-shell session running at a project's root |
| dashboard | a side window listing every project |

## Install

Requires Emacs 30.1 or later.  overlook is not on MELPA yet; install it
from GitHub.  It pulls in magit-section, tabspaces, agent-shell and
simple-httpd (for the phone page).  agent-shell
needs the ACP adapters of the agents you use; see its README.

With `package-vc` (Emacs 30):

```elisp
(use-package overlook
  :vc (:url "https://github.com/guiyuanju/overlook")
  :bind ("C-c o" . overlook))
```

With [elpaca](https://github.com/progfolio/elpaca), naming the files
besides Elisp that overlook needs:

```elisp
(use-package overlook
  :ensure (:host github :repo "guiyuanju/overlook"
           :files (:defaults "bin" "skills" "overlook-remote.html" "vendor"))
  :bind ("C-c o" . overlook))
```

## Quick start

```elisp
(with-eval-after-load 'overlook
  (require 'overlook-tabspaces)
  (require 'overlook-repo)
  (require 'overlook-agent-shell)
  (tabspaces-mode 1)
  (overlook-tabspaces-mode 1)     ; projects from the tabs of tabspaces
  (overlook-repo-mode 1)          ; changed repos under each project
  (overlook-agent-mode 1)         ; agents under each project
  (overlook-agent-shell-mode 1))  ; agents run in agent-shell
```

Then:

- `M-x tabspaces-open-or-create-project-and-workspace` opens a project
  in a tab named after it.
- Start agents with agent-shell's own commands, such as `M-x agent-shell`.
  Every agent-shell buffer shows up on the dashboard, however it was
  started.  An agent belongs to one project, fixed when it starts: the
  open project whose root holds its folder, else the project of the
  `.overlook` folder holding it, else the current one.
  Showing it in another tab does not move it; `M-x overlook-agent-move`
  does.  Restarting, reloading or forking it keeps its project.
- `M-x overlook` toggles the dashboard.  `RET` on a row visits it;
  `] a` jumps to the next agent waiting for you.

## The dashboard

Projects put the current project first, then sort by priority (when
`overlook-project-priority-function` is set), most recent switch, and name.
With a priority function, open and closed projects share this ordering.
Their order stays fixed while the dashboard window is selected; leaving and
returning updates it. New projects append and closed projects disappear.

### What the rows show

- **An agent**: its icon from `overlook-agent-icons` (else its name),
  colored by its status: yellow working, bold red waiting for you, green
  finished while you were not looking, dimmed idle, red and marked
  `failed` when it failed; then what it is doing, how long its turn has
  run and how much of its context window is used.  The colors come from
  `overlook-agent-status-glyphs`.  A failed agent shows its error and
  stays marked, even once viewed, until it works again.
- **A saved agent**: `claude saved`, dimmed, with its title and how long
  ago its last turn was.  Each agent running when Emacs quits is saved,
  in `overlook-agent-saved-file`; `RET` resumes its session where it left
  off, minus a turn cut short.
- **A fork**, made with `agent-shell-fork`: under the agent it came from,
  after `└`, when both are under the same project; otherwise marked
  `fork`.  `overlook-agent-forks-file` keeps the tree across restarts.
- **A repo**: its branch and the lines changed since its last commit, then
  each changed file with its line counts, an untracked one counted as all
  added.  Files are grouped by folder, and a file leaves blank the
  leading folders it shares with the one above. Every folder is abbreviated
  to its initial; filenames stay complete, and the tooltip shows the full
  path. These come from Git, so
  they show every change in the working tree, whoever made it.
- **Worktrees**: while a project has some, its rows are grouped by
  checkout.  The main checkout comes first, with the agents in no worktree
  and the changed repos; then each worktree, with the agents working in
  it and its changed files.  A worktree shows its
  commits ahead of (`↑N`) and behind (`↓N`) the main checkout's branch, or
  `merged`, and is dimmed when merged with nothing in it.
- A project with no rows is left out, unless it is current or
  `overlook-show-empty-projects` says so; it can be a function of the name.

### Keys

| Key | |
|---|---|
| `RET` / `o` | visit the row: switch to a project, show a repo's or file's diff in Magit, show an agent, resume a saved one |
| `TAB` | fold or unfold the rows under a row; folds are kept across redraws |
| `C-j` / `C-k` | next / previous heading |
| `] a` / `[ a`, `C-S-j` / `C-S-k` | next / previous agent needing you |
| `d d` | delete the row's thing, asking first where that loses something: kill an agent, forget a saved one, remove a worktree with its agents (keeping its branch), close a project with its agents unless it has uncommitted changes |
| `H` | hand the agent's task off to another agent |
| `e` | edit a persona |
| `g` | redraw |
| `q` | close |

The dashboard is a [magit-section](https://github.com/magit/magit) buffer,
so Magit's section commands (`C-<tab>`, `1`–`4`, `^`, `n`/`p`) work too.
Evil users can bind the same keys in normal state:

```elisp
(with-eval-after-load 'overlook
  (pcase-dolist (`(,key . ,command) overlook-keys)
    (evil-define-key* 'normal overlook-mode-map (key-parse key) command)))
```

### Notifications

When an agent starts waiting for you, fails or finishes while no Emacs frame has focus, a
desktop notification says so, and again for each further question while
it waits.  An agent shown in the selected window counts as seen only while
Emacs has focus.  On macOS it uses `terminal-notifier` when installed,
whose click raises Emacs and, with a server running, shows that agent;
otherwise `osascript`.  Elsewhere it uses D-Bus.  Set
`overlook-agent-notify` to `t` to be told even while Emacs has focus, or
to `nil` never.

## Modules

Each module is a file to `require` and, for most, a global minor mode to
turn on.

| Module | Adds |
|---|---|
| `overlook-tabspaces` | projects from the tabs of tabspaces; a buffer of no file and no project, such as `*scratch*`, uses its tab's project in project.el commands |
| `overlook-repo` | changed repos and worktrees under each project |
| `overlook-worktree` | Git worktree operations, independent of agents and courier |
| `overlook-agent`, `overlook-agent-shell` | agents under each project, run in agent-shell |
| `overlook-markers` | folders of several repos as one project |
| `overlook-usage` (+ `-deepseek`, `-antigravity`) | plan usage and balances |
| `overlook-agent-courier` | agents messaging, spawning and watching each other; personas |
| `overlook-remote` | the dashboard and the agents in a phone's browser |
| `overlook-agent-update`, `overlook-agent-rules` | keeping agent CLIs and their rules up to date |

### Projects of several repos

The marker mode needs nothing else of overlook, so turn it on at startup:

```elisp
(require 'overlook-markers)
(overlook-markers-mode 1)
```

Put the repos of a feature in one folder and `touch .overlook` there.  A
file in any of the repos now belongs to the whole folder: agents start at
its root, and `project-find-file` and `project-find-regexp` search every
repo, each by its own `.gitignore`.  Eglot still starts a language server
per repo.  `project-vc-dir` does not work on such a folder, as it is no
repo; use the repo rows on the dashboard instead.

### Plan usage

```elisp
(require 'overlook-usage)
(overlook-usage-mode 1)                         ; Claude and Codex
(setopt overlook-usage-deepseek-api-key "sk-…") ; or a function returning it
(require 'overlook-usage-deepseek)              ; DeepSeek balance and today's spending
(require 'overlook-usage-antigravity)           ; Antigravity's weekly Gemini limit (macOS)
```

`RET` on a usage row opens the provider's usage page.

### Continue after a quota reset

```elisp
(require 'overlook-agent-resume)
```

Run `M-x overlook-agent-resume-toggle` in an idle agent buffer or on its
agent row to schedule one `continue` prompt, or run it again to cancel.
The dashboard shows the subscription account and scheduled time; the web
agent row also offers scheduling and cancellation commands. Claude uses
the account bound to that session. Codex records its login when the shell
is registered and refuses scheduling after that login changes.

Exhausted windows must all reset before continuation; otherwise the next
window reset is used. `overlook-agent-resume-delay` adds five minutes by
default. Missing reset data or an unknown account prevents scheduling.
A manual turn, session/account change or closed buffer cancels the job.
If the prompt is occupied or the agent is busy at the scheduled time, the
job is cancelled. There are no automatic retries, and appointments do not
survive an Emacs restart.

Appointments use a one-shot timer for the next deadline, with a separate
120-second timeout if the submitted continuation does not start. Running
turns are tracked by events rather than polling.

On Emacs 31+, appointments share a built-in `system-sleep` token, keeping
the system awake while allowing the display to sleep. It is released after the last
appointment is cancelled or its continued turn finishes, fails or needs
user attention. Closing the laptop lid can still suspend execution.

### Agents working together: courier

```elisp
(require 'overlook-agent-courier)
(overlook-agent-courier-mode 1)
```

Agents get a `courier` command to message, spawn and monitor each other;
see [courier](docs/courier.md).  On the dashboard:

- A spawned agent opens in the project whose root holds the folder it works in,
  else in the project of the `.overlook` folder holding it, opened in the
  background, else in its parent's.  Its row shows `← parent`, and `✉N` while messages
  wait for it.
- `courier spawn --effort LEVEL` starts it at that reasoning effort,
  through the session option `overlook-agent-shell-effort-options` names
  (Claude's `effort`, Codex's `reasoning_effort`).  `--worktree BRANCH`
  starts it in a Git worktree of its own, listed under the project.
  `--handoff` starts it for you instead: it gets no parent, is told
  nothing about courier, and its task waits unsent at its prompt for you
  to check and send.
- **Personas**: folders in `overlook-courier-persona-directories` give an
  agent a lasting id, role and memory.  A Personas section lists them;
  messaging one nobody runs starts it.

### From your phone: overlook-remote

```elisp
(setopt httpd-serve-files nil)   ; simple-httpd serves only overlook's page
(require 'overlook-remote)
(overlook-remote-mode 1)         ; copies the page's address, with its token
```

The page uses Framework7 Core with an iOS layout and follows system
light / dark mode. Projects and nested groups open as separate screens
with back navigation; the overview uses grouped lists and usage windows have
separate labeled progress bars. System fonts, message bubbles, and a growing
message bar keep the phone layout consistent. Its pinned scripts
and styles are served locally, with no CDN dependency or build step. It shows:

- **The dashboard**, populated by the same modules as in Emacs and streamed as
  it changes, sending only what changed.  Buttons answer what an agent
  waits for, such as a permission request.  A row's `⋯`, or the row itself
  when tapping it does nothing else, offers an action menu: kill an agent,
  resume or forget a saved one, start
  a persona, start an agent in a project, delete a worktree.  Those that lose something ask first.
- **An agent's page**, following its prompts, replies and tool calls as
  they come, with the diff of each edit and the images it shows, from when
  the mode started; before that, its last reply.  You prompt it from
  there, with photos attached.  Prompts sent while it is busy wait in a
  queue, which you can take them back out of, until it is free.
  With agent-shell, typing `/` lists the commands advertised by the agent.
  **Steer with current draft** in the session menu, when supported, sends
  the prompt into the running turn instead of the queue, or starts a new
  turn when idle. Steering remains available when the running turn ends.  Steering while the agent awaits user action asks first.
  The session menu offers reload, a fresh conversation and, when supported,
  fork; reload and restart ask for confirmation.

While the mode is on, the dashboard's mode line shows a network icon
(or `remote` without Nerd Icons). Hover over it to see the serving address.

The page listens on this machine only.  To reach it from a phone on the
same network, set `overlook-remote-host` to `"0.0.0.0"` before turning the
mode on; the mode line then highlights the network indicator, and the mode
turns itself off after `overlook-remote-network-minutes` (120; nil keeps
it on).  `M-x overlook-remote-url` copies the address again.  On a
machine with a Tailscale address that is the address given, so a phone in
the same tailnet reaches the page from any network, and on a Wi-Fi that
keeps its devices apart.

The page and its scripts are served to anyone; every call for data needs
the token, which the address carries after `#`, so the browser keeps it
and never sends it in the address.  The calls then carry it in a header
over plain HTTP, which anyone watching the network can read: serve only a
network you trust, or reach it over a VPN such as Tailscale.  `M-x
overlook-remote-new-token` shuts out every page opened before.

On iOS, open that address in Safari, then add it to the Home Screen.  The
page keeps `#token` in its address so the Home Screen app can authenticate
with its own storage.  If an older shortcut opens without a token, delete
it and add it again from the address copied by `overlook-remote-url`.

### Keeping the agents up to date

```elisp
;; Offer updates of the ACP adapters (npm), CLIs (Homebrew), ACP registry
;; binaries and agent-shell (elpaca), checked once a day when idle.
(run-with-timer 0 (* 24 60 60) #'run-with-idle-timer 30 nil #'overlook-agent-update-check)
(with-eval-after-load 'agent-shell (overlook-agent-update-acp-use)) ; use the installed binaries
;; Offer to let Codex read the CLAUDE.md the other agents read.
(setopt overlook-agent-rules-file "~/projects/CLAUDE.md")
(add-hook 'overlook-mode-hook #'overlook-agent-rules-check-once)
```

## Commands

| Command | |
|---|---|
| `overlook` | toggle the dashboard |
| `overlook-close-project` | close a project, killing the buffers only it holds |
| `overlook-agent-switch` | pick any running agent and show it in its project |
| `overlook-agent-move` | move the agent at point, or this one, to another project |
| `overlook-agent-send` | paste the region, or an `@` reference to the file, into this project's agent |
| `overlook-agent-shell-handoff` | draft a handoff of an agent's task to another agent, from its transcript |
| `overlook-agent-shell-claude-switch-account` | pick the Claude account agents started or resumed from now on run as |
| `overlook-persona-start`, `overlook-persona-new` | start a persona, or make one |
| `overlook-remote-mode`, `overlook-remote-url` | serve the phone page; copy its address |

## Customization

`M-x customize-group RET overlook`.  Among others:

- `overlook-side`, `overlook-width`: where the dashboard sits, and how
  wide it is in columns or as a fraction of the frame.
- `overlook-project-order`: the current project first, then the
  rest by how recently you switched to them (the default), or the
  backend's order.  To remember switches across sessions:
  `(add-to-list 'savehist-additional-variables 'overlook-project-switch-times)`.
- `overlook-project-root`: how a project's root is found;
  by default, guessed from the projects of its buffers.
- `overlook-project-annotation`: a function of a project name
  returning a tag shown dimmed after its heading, such as the workspace
  it belongs to.
- `overlook-project-filter`: a function of a project name
  returning nil to hide it.  The current project, and one with an
  agent needing you, still show.
- `overlook-orphan-project`: a project, such as a tab named `"main"`,
  to list the agents of no project under; by default they
  sit under the current one.
- `overlook-markers`: the files marking a folder of several repos as one
  project.
- `overlook-repo-folder-display`: `mark` to show a folder inside a
  larger repo, from `overlook-repo-folders`, as a `*` after its
  project's heading while it has changes, instead of listing them.
- `overlook-repo-ignored`: repos inside a project, such as a clone of
  data, to leave off the dashboard and out of the check before closing
  it.
- `overlook-repo-count-limit`: the largest untracked file, in bytes,
  whose lines are counted.
- `overlook-agent-root-function`: the root of an agent its frontend did
  not start, worked out in its shell's directory.
- `overlook-agent-shell-configs`: the names agents are shown by, and the
  agent-shell configs overlook starts them with.
- `overlook-agent-shell-handoff-prompt`: the handoff draft.
- `overlook-agent-shell-claude-accounts`: Claude accounts, each a name and
  an OAuth token from `claude setup-token`, or a function returning it.
  The first may have none, keeping Claude Code's own login.  Agents on
  another account show `@NAME` after their name, and its plan usage gets
  a row of its own.  `overlook-account-labels` draws accounts by a short
  label instead, and `overlook-usage-accounts` names the account behind a
  usage row that has none:

  ```elisp
  (setopt overlook-agent-shell-claude-accounts
          `(("work")
            ("personal" . ,(lambda () (auth-source-pick-first-password
                                       :host "claude.ai" :user "personal")))))
  (setopt overlook-account-labels '(("work" . "W") ("personal" . "P"))
          overlook-usage-accounts '(("claude" . "work") ("codex" . "personal")))
  ```

## Extending

Everything on the dashboard comes from hooks, and modules return data,
not text: rows made by `overlook-row`.  Every view, the dashboard buffer
and the phone page alike, draws the same rows.

```elisp
(overlook-row
 :id '(ticket . "OPS-12")          ; keeps point on it; what `d d' gets
 :content (list (overlook-glyph-cell "●")
                (propertize "OPS-12" 'face 'bold)
                " deploy"
                (list :fit "a long summary, cut to fit" :face 'shadow
                      :before "  " :reserve 6)
                (overlook-align-right (propertize "3m" 'face 'shadow) 1))
 :action (lambda () (browse-url "https://example.com/OPS-12")) ; RET
 :commands (list (list :name "close" :label "Close"            ; the page's ⋯
                       :confirm "Close OPS-12?"
                       :run (lambda () (my-close-ticket "OPS-12"))))
 :attention t                      ; a stop for ] a
 :children (list (overlook-row :content "a row under it"))
 :folded t)
```

**Content** is a list of segments: strings, whose text properties give
their look, and parts each view lays out for itself:

| Segment | |
|---|---|
| `(:right TEXT :columns N)` | aligned to the right edge; `overlook-align-right` makes it |
| `(:cell GLYPH)` | a glyph padded to `overlook-cell-columns`; `overlook-glyph-cell` |
| `(:fit TEXT :face F :before GAP :reserve N)` | cut with an ellipsis to fit the line |
| `(:pad TEXT :like TEXTS)` | padded as wide as the widest of TEXTS, so rows line up however each view measures icons |
| `(:wrap PIECES :gap N)` | pieces going to lines of their own, under the first, when the line is too narrow |

Rows in the `overlook-tabular` face line up in columns, so the page draws
them in a fixed-pitch font.  `overlook-icon` gives a name's icon from
`overlook-agent-icons`, carrying the name for views without icon fonts.

A row also takes `:heading`, `:nest` (indent its children under the
name after its cell), `:gap` (a blank line after it), `:dim`, `:face`,
`:help`, `:wrap`, `:keymap`, children as a function called once they
show, `:choices` it offers with `:choose` giving an answer, and
`:commands`.  A command may ask for
`:input` text or one of `:options`, and must not ask in the minibuffer;
`:run` returning an agent's buffer shows that agent, and `(BUFFER . TEXT)`
also leaves TEXT in its prompt, unsent.  See `overlook-row`'s
docstring.

**Hooks**:

- `overlook-sections`: top level sections, by hook depth, each a function
  returning one made by `overlook-section-row`, or nil.  Projects sit
  at 0, usage at -50; `overlook-section-order` fixes the order of those it
  lists.
- `overlook-project-functions`: rows under each project, called
  with its name.  Under `overlook-orphans-project`, also return the
  rows that belong to no project.  A project without worktrees lists
  what lies in its checkout at depth 0.
- `overlook-closed-projects-functions`: rows after the projects'
  headings, for projects that are not open.  Give such a project's row
  the id `(closed-project NAME)`: open and closed projects then sort
  together, and the row starts folded once `d d` closes the project.
- `overlook-projects-mark-functions`: marks after the Projects
  section's title, such as a "*" when something needs syncing.
- `overlook-project-command-functions`: commands on a project's
  heading, such as starting an agent there.  A command that needs the
  project first calls `overlook-ensure-project`, as rows made with
  `overlook-project-heading` can be of projects that are not open.
- `overlook-worktrees-functions`: worktree folders listed under a
  project.  `overlook-worktree-functions`: rows of what lies in a
  checkout, called with the project and the worktree's folder, or nil
  for none; agents at depth 0, changed repos at 50.
  `overlook-worktree-of` tells which worktree holds a folder.
- `overlook-delete-functions`: what `d d` does, given the row's id.
  `overlook-folder-contents-functions`: what lies in a folder about to
  go, each with a function letting it go;
  `overlook-project-contents-functions` the same for a project about to
  close, and `overlook-project-close-blockers` why it cannot.
- `overlook-usage-functions`: rows in the usage section;
  `overlook-usage-add-poller` refreshes their data over the network, at
  most every few minutes while the dashboard is open.
- `overlook-mode-line-functions`: strings in the dashboard's mode line.
  Agent counts use robot, play and bell icons for total, working and needing
  attention; tooltips explain each count. Codicons use 85% size, with text
  fallbacks when Nerd Icons is unavailable.
- `overlook-tick-hook`: run every few seconds while the dashboard is live.

Call `overlook-refresh` when something you show changed.
`overlook-detach` keeps a buffer out of every project, even once
shown, as courier does with the agents running a persona.

**Worktrees**: `overlook-worktree` creates, lists and removes project
checkouts, including folders of several repos.  It has no dashboard or
courier dependency.  `overlook-worktree-directory` and
`overlook-worktree-marker` configure their location and project marker.
`overlook-courier-worktree` starts agents in them.

**Other views** draw the same model: `overlook-model` gathers it,
`overlook-latest-model` gives the one the dashboard last drew while
nothing has changed since, and `overlook-after-model-hook` and
`overlook-refresh-hook` tell a view when to look again, as overlook-remote
does.

A view calls `overlook-start-updates` with its own symbol while active,
then `overlook-stop-updates` with that symbol when it closes.  All views
share one tick timer; stopping one leaves the others running.  The phone
page subscribes independently and needs no dashboard buffer.  Refreshing
invalidates the model; the Emacs view schedules its own redraw.

**Other backends**: another workspace implementation drives overlook by
setting the `overlook-project-*-function` variables, as
overlook-tabspaces.el does.  An agent frontend describes each of its
buffers in `overlook-agent-identity`, hands it to
`overlook-agent-register`, and sets `overlook-agent-start-function` for
the agents overlook starts, as overlook-agent-shell.el does.  Sending its
prompts, replies and tool calls through `overlook-agent-event` lets views
such as overlook-remote follow them live; see
`overlook-agent-event-functions`.

Agent consumers use `overlook-agent-ready-p` and `overlook-agent-submit`
for prompt delivery.  `overlook-agent-call` invokes an optional identity
capability in the agent's buffer, returning nil when absent and letting
errors propagate.  `overlook-agent-title`, `overlook-agent-brief`,
`overlook-agent-reply` and `overlook-agent-choices` provide display values.
Readiness and submission are shared; courier mailboxes and remote prompt
queues retain their own delivery and retry policies.

## Caveats

Plan usage comes from undocumented sources: Claude's from rate limits
claude-agent-acp forwards to agent-shell, Codex's from its session logs
in `~/.codex/sessions`, Antigravity's from an internal Google endpoint.
Any of them may change without notice.

## Development

The public entry points remain `overlook`, `overlook-agent` and
`overlook-remote`.  Their implementation layers are:

| Layer | Responsibility | Dependencies within overlook |
|---|---|---|
| `overlook-row` | row protocol, segments, shared faces and unbounded text | none |
| `overlook-model` | project backend, model collection, invalidation and update subscriptions | row |
| `overlook` | Magit sections, window layout, navigation and redraw scheduling | model |
| `overlook-agent-core` | identity, capabilities, project association, status and turns | model, markers |
| `overlook-agent-session` | saved sessions, resume and fork persistence | agent core |
| `overlook-agent-view` | live and saved rows, fork trees and labels | agent core, sessions |
| `overlook-agent` | interactive commands and tracking mode | Emacs view, agent layers |
| `overlook-remote-model` | row serialization, subtree hashes and deltas | agent core |
| `overlook-remote-activity` | agent snapshots, prompt queues, history, diffs and images | remote model |
| `overlook-remote` | HTTP routes, authentication, streaming and server lifecycle | agent entry point, remote layers |
| `overlook-worktree` | Git checkout operations | none |
| `overlook-courier-worktree` | agent spawning in worktrees | worktree, courier |

Rows, model collection and agent state load without Magit or a dashboard
buffer.  Interactive visit operations delegate to the Emacs view when
invoked.  Session files and browser response formats remain shared across
these layers.

```sh
OVERLOOK_INSTALL_DEPS=1 make test lint
```

This installs the dependencies into `.elpa/` and runs the tests,
package-lint and checkdoc.  Without `OVERLOOK_INSTALL_DEPS`, list the
directories of installed dependencies in `OVERLOOK_LOAD_PATH`.

## License

GPL-3.0-or-later.
