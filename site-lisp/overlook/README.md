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
  it and its changed files.  A checkout shows by the branch its repos are
  on, or by its folder when they are on several; a repo under it names
  its branch only where it differs, on the phone page too.  A worktree shows its
  commits ahead of (`↑N`) and behind (`↓N`) the main checkout's branch, or
  `merged`, and is dimmed when merged with nothing in it.
- A project with no rows is left out, unless it is current or
  `overlook-show-empty-projects` says so; it can be a function of the name.

### Keys

| Key | |
|---|---|
| `RET` / `o` | visit the row: switch to a project, show a repo's or file's diff in Magit, show an agent, resume a saved one |
| `TAB` | fold or unfold the rows under a row; folds are kept across redraws |
| `C-j` / `C-k` | next / previous row at the same level, as Magit's `M-n` / `M-p` do |
| `C-h` / `C-l` | up to the parent row / on into the next row, the first child of an unfolded one, as Magit's `^` / `n` do |
| `] a` / `[ a`, `C-S-j` / `C-S-k` | next / previous agent needing you |
| `d d` | delete the row's thing, asking first where that loses something: kill an agent, forget a saved one, remove a worktree with its agents (keeping its branch), close a project with its agents unless it has uncommitted changes |
| `H` | hand the agent's task off to another agent |
| `w` | start an agent in a new worktree of the row's project, as `overlook-agent-worktree` does; on a task row a function of `overlook-agent-worktree-task-functions` knows, offer its branch name and leave the task unsent at the agent's prompt |
| `a` | start another agent in the row's worktree, else in its project's root |
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
| `overlook-agent-worktree` | agents started in a worktree of their project, from the keyboard or the dashboard |
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

With `overlook-usage-mode` enabled, Claude and Codex subscription quotas
are queried asynchronously every five minutes, even with no dashboard open.
`overlook-usage-subscription-interval` controls the interval. Claude uses
the configured account tokens or its CLI credential file/macOS Keychain;
Codex uses `CODEX_HOME/auth.json` (default `~/.codex/auth.json`).
These are read-only, undocumented service endpoints. Login credentials
are never refreshed here. Errors retain the last reading and back off
up to one hour; expired credentials must be renewed through the client.
Successful server readings override unchanged local session readings and publish
availability transitions without requiring an agent turn. New local readings
take precedence over an older server cache.

When an agent ends a turn while its subscription quota is exhausted,
continuation is scheduled automatically. Usage publishes per-account
availability transitions via `overlook-usage-state-change-hook`;
auto continue subscribes to recovery and waits `overlook-agent-resume-delay`
before sending. Expired quota windows count as recovered; unknown readings
do not publish recovery.

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
If an agent-shell prompt contains a draft at the scheduled time, the draft
is removed, `continue` is sent, and the draft is appended to the native prompt
queue for the following turn. A failed submission also preserves the draft
in that queue. A busy agent cancels the job; other frontends still require
an empty prompt. There are no automatic retries, and appointments do not
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
with back navigation and restored reading positions. Projects and personas
come before compact, expandable usage summaries. Project pages show a
conversation/task/change overview and a direct new-conversation action; long
resource lists expand on demand. Usage windows have separate labeled progress
bars. System fonts, message bubbles, and a growing message bar keep the phone
layout consistent. Its pinned scripts
and styles are served locally, with no CDN dependency or build step. It shows:

- **The dashboard**, populated by the same modules as in Emacs and streamed as
  it changes, sending only what changed.  Buttons answer what an agent
  waits for, such as a permission request.  A row's `⋯`, or the row itself
  when tapping it does nothing else, offers an action menu: kill an agent,
  resume or forget a saved one, start
  a persona, start an agent in a project, delete a worktree. Project and persona
  rows also offer touch-and-hold, right-click, or Shift+F10 menus; their detail
  pages keep the same actions visible. Those that lose something ask first.
  Touch and hold a running Persona to choose **Kill**, with confirmation; this
  ends its live conversation and leaves its definition available to Start again.
  For Personas with multiple conversations, each conversation has its own Kill action.
  Persona descriptions appear in the conversation, while their overview rows
  show identity and status. Command sheets retain unfinished input until a
  successful submission or the page is reloaded.
- **An agent's page**, following its prompts, replies and tool calls as
  they come, with the diff of each edit and the images it shows, from when
  the mode started; before that, its last reply.  You prompt it from
  there, with photos attached.  Prompts sent while it is busy wait in a
  queue. You can remove queued messages or move them back to the draft until
  they are sent. Sending errors stay beside the composer with a retry action;
  failed image uploads keep their preview for retry or removal. Busy sessions
  show Stop and, when supported, Adjust now beside the composer. Tap the
  conversation title for session information. Completed tool runs collapse
  together, and code blocks have a copy action.
  With agent-shell, typing `/` lists the commands advertised by the agent.
  **Steer with current draft** in the session menu, when supported, sends
  the prompt into the running turn instead of the queue, or starts a new
  turn when idle. Steering remains available when the running turn ends.  Steering while the agent awaits user action asks first.
  The session menu offers reload, a fresh conversation and, when supported,
  fork; reload and restart ask for confirmation. Close Agent ends the live
  session after confirmation and keeps a resumable entry when supported.
  Long messages have expandable previews. Message times, unread counts and
  paged earlier activity come from the backend.

See [Remote interface](docs/remote-ui.md) for navigation, draft and attachment
behavior and the limits of browser-only state.

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

On iOS, open that address in Safari, then add it to the Home Screen. The
page provides a touch icon and a web app manifest for standalone display.
The manifest omits a fixed launch URL so the installing address retains
its authentication fragment. The page keeps `#token` in its address so the Home Screen app can authenticate
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
| `overlook-agent-worktree` | pick an agent in agent-shell's picker (`overlook-agent-preferred-names` first, the first preselected) and a branch, and start it in that worktree of the current project, made from the remote's default branch if missing; the branch of the main checkout starts it there instead. agent-shell then offers a past session there, as `agent-shell-session-strategy` says |
| `(overlook-agent-worktree-command NAME)` | returns a command that does the same for agent NAME, asking only for the branch; bind it to start a given agent this way |
| `overlook-worktree-create` | make a worktree of this project, branching from a ref (empty: the remote's default branch); with `C-u`, pick the project and which of its repos |
| `overlook-worktree-delete` | remove a worktree of this project and its buffers; with `C-u`, its branch too where merged |

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
- `overlook-agent-preferred-names`: the agents offered first, in order,
  when one is picked to start; the rest follow, including every
  agent-shell agent not in `overlook-agent-shell-configs`.
- `overlook-worktree-copied-files`: untracked files, such as `.env`,
  copied from each repo into its new worktree checkouts;
  `overlook-worktree-setup-functions` runs more setup on them.
- `overlook-worktree-fetch`: fetch the remote before branching from one
  of its branches.
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
- `overlook-agent-shell-claude-accounts`: defaults to `(("login"))`,
  using this machine's Claude Code login. The login name is resolved from
  the CLI config for display. Extra accounts belong in each machine's
  `local.el`, loaded before package configuration. Use their actual account
  identities as keys; tokens may be strings or functions returning them.
  An extra entry matching the local login shares its usage row and poll.
  `overlook-account-labels` can shorten displayed identities without
  changing which account they identify.

  For example, on a machine needing an extra account:

  ```elisp
  (setq overlook-agent-shell-claude-accounts
        `(("login")
          ("account-name" . ,(lambda ()
                               (auth-source-pick-first-password
                                :host "claude.ai" :user "account-name")))))
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
`overlook-add-hint` adds a key to the Keys section, last on the
dashboard; `overlook-hints` holds them.  `overlook-agent-worktree-task-functions` tells `w` on the dashboard the
task a row stands for: its project, a branch name, the prompt to leave
unsent, and what to do once the agent started.

- `overlook-worktree-add DIR BRANCH &optional START REPOS`: make or
  extend the worktree and return its path.  A new branch starts at
  START, or `default` for `overlook-worktree-default-start` (the
  remote's default branch), or the checked out commit; a START is kept
  in Git config as the branch's base.  REPOS picks some repos of a
  folder; adding again with others adds them.  A folder already holding
  another branch (`a/b` and `a-b` share one) is an error.
- `overlook-worktree-remove DIR BRANCH &optional FORCE DELETE-BRANCH`,
  `overlook-worktree-prune DIR`: remove one, optionally with its branch
  where merged; clear those whose folders were deleted by hand.
- `overlook-worktree-list`, `-path`, `-at`, `-repos`, `-branch`,
  `-main`: names, locations and checkouts.
- `overlook-worktree-dirty-p`, `-uncommitted`, `-base`,
  `-divergence`: changes and commits ahead of and behind the base,
  read synchronously.

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
`overlook-agent-form` exposes a pending structured question;
`overlook-agent-answer` submits or declines it by form ID with field values.
Remote exposes this through `POST /api/answer` with `id`, `form`, `action`
(`accept` or `decline`) and a `values` object keyed by field name.
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
| `overlook-row` | row protocol, segments and shared faces | none |
| `overlook-model` | project backend, model collection, invalidation and update subscriptions | row |
| `overlook` | Magit sections, window layout, navigation and redraw scheduling | model |
| `overlook-agent-core` | identity, capabilities, project association, status and turns | model, markers |
| `overlook-agent-session` | saved sessions, resume and fork persistence | agent core |
| `overlook-agent-view` | live and saved rows, fork trees and labels | agent core, sessions |
| `overlook-agent` | interactive commands and tracking mode | Emacs view, agent layers |
| `overlook-agent-worktree` | agents in project worktrees, `w` and `a` on the dashboard | agent, worktree |
| `overlook-usage` | local quota readings, availability publisher and usage rows | data, Emacs view |
| `overlook-usage-subscription` | asynchronous subscription queries, credential reads and backoff | usage |
| `overlook-agent-resume` | session-bound continuation on quota recovery | agent, usage |
| `overlook-data` | shared business queries and resource identities | agent core |
| `overlook-remote-contract` | typed DTOs, request validation, protocol version and problem details | none |
| `overlook-remote-model` | semantic JSON serialization, subtree hashes and deltas | data, contract |
| `overlook-remote-activity` | agent snapshots, prompt queues, history, diffs and images | remote model |
| `overlook-remote-service` | prompt/session/resource commands, confirmations and bounded retry receipts | remote activity |
| `overlook-remote` | HTTP routes, authentication, streaming and server lifecycle | agent entry point, remote layers |
| `overlook-worktree` | Git checkout operations | none |
| `overlook-courier-worktree` | agent spawning in worktrees | worktree, courier |

Dashboard JSON contains business data, not Emacs faces or layout segments.
Each node has `kind`, `title`, `children`, opaque `id` / `hash`, and any available
commands. Agent nodes add provider, status, full title, brief, context and duration;
usage nodes carry window values and reset timestamps; files carry paths and numeric
change counts. Tasks carry text, due date and state, with completion exposed as a
command. `overlook-data-functions` queries business keys without a display row;
Emacs rows and remote DTOs share these queries. `overlook-row-data-functions`
remains an extension compatibility adapter, with plain text fallback for legacy
rows. Dashboard composition and allowlisted commands still use the shared row
model; business fields never parse built-in display segments. The browser owns
fonts, colors, progress bars, task controls and navigation.

The version 2 wire contract is in [remote-api.schema.json](docs/remote-api.schema.json).
Nullable fields, booleans and arrays have explicit encoders; malformed input is
rejected before service execution. Errors use `application/problem+json` with a
stable `code`. HTTP and SSE carry the same `protocolVersion`; expired live
update cursors receive snapshots. Disconnected clients release their
subscriptions and timers.

Conversation IDs survive buffer renames for the live buffer lifetime; restored
conversations receive new IDs. Task IDs survive line moves and distinguish
identical occurrences; editing task text creates a new identity. Source content
is revalidated before completion. Queued prompts have individual IDs, including
identical text. The queue stores these identified entries once; the legacy
`queued` text array is derived from them. Successful prompt/session/resource actions with `requestId` can
be replayed within `overlook-remote-receipt-seconds` and
`overlook-remote-receipt-limit`; receipts are in memory and expire on restart.
Confirmations bind the action and target state, and are requested again after
changes. Elapsed durations do not invalidate a confirmation. Session confirmation
responses supply the complete `confirmations` array for the client to return
with the new token. Confirmation credentials are excluded from successful
request replay signatures. Refresh an open remote page when updating this protocol.

Activity items expose optional UTC `createdAt` and `updatedAt` timestamps;
older items recorded before an update can lack them. Conversations expose
`unreadCount`, `readThrough` and `latestSeq`. Unread counts include retained
assistant reply items updated beyond the shared read sequence. `POST /api/seen`
accepts `through` and `epoch` to acknowledge only received changes, without
clearing a newer streaming update.

Initial event snapshots contain at most `overlook-remote-page-size` items
(50 by default) and `history: {hasMore, before}`. `GET /api/history` takes `id`,
an exclusive `before` item identity, optional `limit` (1–100), and `epoch`;
it returns chronological `items`, `hasMore`, `before` and `epoch`. Item identities
order history; change sequences order live updates. Expired history cursors
return `409 history_expired`. History and read positions remain in memory;
retention is bounded by `overlook-remote-history` (300 items by default).

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

For the phone UI, with Playwright and Chromium installed:

```sh
node test/overlook-remote-browser-test.cjs
```

This uses local assets and a fixture API, checks the iOS layout on phone sizes in light
and dark mode, and saves screenshots in the temporary directory. Set
`PLAYWRIGHT_CHROMIUM_EXECUTABLE` to use an existing Chromium binary.
Keyboard and Home Screen behavior still need testing on an actual iPhone.

## License

GPL-3.0-or-later.
