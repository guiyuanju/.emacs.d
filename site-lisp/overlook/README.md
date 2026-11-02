# overlook

A dashboard over everything you are working on in Emacs: each
[perspective](https://github.com/nex3/perspective-el), the changed Git repos of
its project, and the AI agents working in it through
[agent-shell](https://github.com/xenodium/agent-shell).

```
Usage
   claude    5h ━━━━━━━━━━  54% 22m     7d ━━━━━━━━━━  13% 3d11h
   codex     5h ━━━━━━━━━━   5% 2h46m   7d ━━━━━━━━━━  16% 6d1h

Perspectives
blog
   ⎇ blog      main
   ○ codex

checkout
   ⎇ api       feature/refunds  ●4
   ⎇ frontend  feature/refunds  ●2
   ◐ claude  Running the payment tests                 12m  41%
      refund.go +48 −6 api/internal/
      RefundButton.tsx +31 frontend/src/
   ▲ codex   ? Run git push                                  18%

main
```

The idea: one project per perspective, one perspective per feature.  A
feature may span several repos, so a project is a folder holding them, and
agents run at the project's root, seeing all of them.  Mark such a folder
with an empty `.overlook` file; a project of one repo needs nothing.  When agents work
on several features at once, overlook shows which need you, what each is
doing, and what it changed.

## Concepts

| | |
|---|---|
| repo | a Git repository |
| project | a [project.el](https://www.gnu.org/software/emacs/manual/html_node/emacs/Projects.html) project, holding one or more repos; a folder of several is marked by a `.overlook` file |
| perspective | a perspective.el perspective: a project with its own buffers and window layout |
| agent | an agent-shell session running at a project's root |
| dashboard | a side window listing every perspective |

## Install

Requires Emacs 29.1 or later.  overlook is not on MELPA yet; install it
from GitHub.

With `package-vc` (Emacs 30):

```elisp
(use-package overlook
  :vc (:url "https://github.com/guiyuanju/overlook")
  :bind ("C-c o" . overlook))
```

With [elpaca](https://github.com/progfolio/elpaca):

```elisp
(use-package overlook
  :ensure (:host github :repo "guiyuanju/overlook")
  :bind ("C-c o" . overlook))
```

It pulls in magit-section, perspective and agent-shell.  agent-shell needs the ACP
adapters of the agents you use; see its README.

## Setup

Turn on the modules you want; each is a global minor mode:

```elisp
(with-eval-after-load 'overlook
  (require 'overlook-perspective)
  (require 'overlook-project)
  (require 'overlook-agent-shell)
  (require 'overlook-usage)
  (persp-mode 1)
  (overlook-perspective-mode 1)   ; perspectives from perspective.el
  (overlook-project-mode 1)       ; changed repos under each perspective
  (overlook-agent-mode 1)         ; agents under each perspective
  (overlook-agent-shell-mode 1)   ; agents run in agent-shell
  (overlook-usage-mode 1))        ; Claude and Codex plan usage
```

To let agents message, spawn and monitor each other, turn on the bundled
[courier](docs/courier.md) bridge:

```elisp
(require 'overlook-courier)
(overlook-courier-mode 1)
```

A spawned agent opens in the perspective of the project it works in,
else in its parent's, and its row shows
`← parent`, and `✉N` while messages wait for it.  `courier spawn --effort
LEVEL` starts it at that reasoning effort, through the session config
option `overlook-agent-shell-effort-options` names for it (Claude's
`effort`, Codex's `reasoning_effort`); `--worktree BRANCH` starts it in
a Git worktree of its own, listed under the perspective with the agents working in it.  Agents and you can also talk in shared chat
rooms; `M-x overlook-room-open` shows one, and a Rooms section above
the perspectives lists them with your unread posts (`✉N`), highlighted
when one names you.  The room of a worktree's branch is listed under
the worktree instead.  Personas, folders in `courier-persona-directories`, give
agents a lasting id, role and memory; a Personas section lists them, and
messaging one nobody runs starts it.

Two more modes act on agents working on branches:

```elisp
(require 'courier-ci)
(courier-ci-mode 1)          ; CI results of agents' worktree branches, into the branch's room
(require 'overlook-watchdog)
(overlook-watchdog-mode 1)   ; report spawned agents stuck in a turn or waiting for you
```

`courier-ci-mode` asks GitHub (`gh`) or GitLab (`glab`) about each pushed
branch an agent works on in a worktree, and posts each finished run in
the room named after the branch, which that agent follows; see
[courier](docs/courier.md#events).  `overlook-watchdog-mode` checks, by
fixed rules, for a spawned agent whose turn runs past
`overlook-watchdog-turn-limit` (30 min) or that waits for you past
`overlook-watchdog-waiting-limit` (15 min), and reports a courier delivery
that started no turn, which courier gave up on.  Each
finding goes once to the room `#watchdog`, and to the agent's parent when
nobody follows that room.

Folders of several repos are projects through their own mode, which needs
nothing else of overlook, so turn it on at startup:

```elisp
(require 'overlook-markers)
(overlook-markers-mode 1)
```

Then:

- For a feature spanning several repos, put them in one folder and
  `touch .overlook` there.  A file in any of the repos now belongs to the
  whole folder: agents start at its root, and `project-find-file` and
  `project-find-regexp` search every repo, each by its own `.gitignore`.
  Eglot still starts a language server per repo.  `project-vc-dir` does
  not work on such a folder, as it is no repo; use the repo rows on the
  dashboard instead.
- `M-x overlook-perspective-open-project` opens a project in a
  perspective named after it.
- Start agents with agent-shell's own commands, such as `M-x agent-shell`
  or `M-x agent-shell-anthropic-start-claude-code`.  Every agent-shell
  buffer shows up on the dashboard, however it was started.
- `M-x overlook` toggles the dashboard.

## Commands

| Command | |
|---|---|
| `overlook` | toggle the dashboard |
| `overlook-agent-switch` | pick any running agent and show it in its perspective |
| `overlook-agent-send` | paste the region, or an `@` reference to the file, into this project's agent |
| `overlook-agent-shell-handoff` | draft a handoff of an agent's task to another agent, from its transcript |
| `overlook-agent-shell-claude-switch-account` | pick the Claude account agents started or resumed from now on run as |
| `overlook-perspective-open-project` | open a project in its own perspective |

On the dashboard:

| Key | |
|---|---|
| `RET` / `o` | visit the row: switch to a perspective, show a repo's diff in Magit, show a changed file's diff in Magit (a renamed one with its old path; a new one is visited), show an agent |
| `TAB` | fold or unfold the rows under a row; folds are kept across redraws |
| `C-j` / `C-k` | next / previous heading |
| `] a` / `[ a`, `C-S-j` / `C-S-k` | next / previous agent needing you |
| `H` | hand the agent's task off to another agent |
| `d d` | delete the row's thing: kill an agent, once confirmed; forget a saved agent; remove a worktree with the agents in it, keeping its branch; close a room, archiving its posts |
| `g` | redraw |
| `q` | close |

Evil users can bind the same keys in normal state:

```elisp
(with-eval-after-load 'overlook
  (pcase-dolist (`(,key . ,command) overlook-keys)
    (evil-define-key* 'normal overlook-mode-map (key-parse key) command)))
```

## What the rows show

- An agent: `◐` working, `▲` waiting for you, `●` finished while you were
  not looking, `○` idle, `✖` failed; what it is doing; how long its turn has run; how
  much of its context window is used.
- A failed agent shows its error message and stays marked after you view it,
  until it starts working again. Failures also participate in attention
  navigation and desktop notifications.
- A saved agent: `○ claude saved`, dimmed, with its title and how long
  ago its last turn was, for each agent running when Emacs quit.  `RET` on it resumes its session where it left off, minus a turn cut
  short; they are kept in `overlook-agent-saved-file`.
- A fork, made with `agent-shell-fork`: under the agent it was forked
  from, after `└`, when both are listed under the same perspective;
  otherwise marked `fork`.  Which session each fork came from is kept in
  `overlook-agent-forks-file`, so the tree survives restarts.
- When an agent turns `▲`, `✖` or `●` while no Emacs frame has focus, a
  desktop notification says so (D-Bus outside macOS), and again for each
  further permission request or question while it waits.  An agent shown in
  the selected window counts as seen only while Emacs has focus.  On macOS it uses
  `terminal-notifier` when installed: clicking the notification raises
  Emacs and, while Emacs runs a server, visits that agent; otherwise it
  falls back to `osascript`.  Set `overlook-agent-notify` to `t` to be told
  even while Emacs has focus, or `nil` never; `overlook-agent-notify-function`
  shows it.
- A repo: its branch and the lines changed since its last commit, then the
  changed files, indented, with their line counts.  These come from Git, so they show
  every change in the working tree, whoever made it.
- While a project has worktrees, its rows are grouped by checkout, each
  group's rows indented: first the main checkout, with the agents in no
  worktree and the changed repos, then each worktree, with the agents
  working in it, its branch's room and its changed files.  A worktree
  shows its commits ahead of (`↑N`) and behind (`↓N`) the main
  checkout's branch, or `merged`, and is dimmed when merged with no agent
  or change in it.
- A perspective with no rows is left out unless current, or
  `overlook-show-empty-perspectives` is set.

## Customization

`M-x customize-group RET overlook`.  Among others:

- `overlook-side`, `overlook-width`: where the dashboard sits, and how
  wide it is in columns or as a fraction of the frame.
- `overlook-perspective-order`: the current perspective first, then the
  rest by how recently you switched to them (the default), or the
  backend's order.  To remember switches across sessions:
  `(add-to-list 'savehist-additional-variables 'overlook-perspective-switch-times)`.
- `overlook-markers`: the files marking a folder of several repos
  as one project.
- `overlook-perspective-root`: how a perspective's project root is found.
  The default guesses from the projects of its buffers.
- `overlook-perspective-annotation`: a function of a perspective name
  returning a tag shown dimmed after its heading, such as which
  workspace it belongs to.
- `overlook-perspective-filter`: a function of a perspective name
  returning nil to hide it, such as one outside the workspace you are
  working in.  The current perspective, and one with an agent needing
  you, still show.
- `overlook-project-folder-display`: `mark` to show a folder inside a
  larger repo, from `overlook-project-folders`, as a `*` after its
  perspective's heading while it has changes, instead of listing them.
- `overlook-orphan-perspective`: a perspective, such as perspective.el's
  `"main"`, to list agents of no perspective under; opening one there
  moves it in, and it is left out while empty unless current.  By default
  they sit under the current perspective.
- `overlook-agent-root-function`: the project an agent belongs to, worked
  out in its shell's directory.
- `overlook-agent-shell-configs`: the names agents are shown by, and the
  agent-shell configs overlook starts them with when resuming, handing
  off or spawning.
- `overlook-agent-shell-handoff-prompt`: the handoff draft.
- `overlook-agent-shell-claude-accounts`: Claude accounts, each a name
  and an OAuth token from `claude setup-token` (or a function returning
  it).  The first may have none, keeping Claude Code's own login.
  Agents on another account show `@NAME` after their name, cut to
  `overlook-account-width` characters (3 by default), and its plan
  usage gets a row of its own, kept beside `overlook-usage-file`.
  `overlook-account-labels` draws accounts by a short label instead,
  the first one too, and `overlook-usage-accounts` names the account
  behind a usage row that has none, shown as `@NAME` without a label:

  ```elisp
  (setopt overlook-agent-shell-claude-accounts
          `(("work")
            ("personal" . ,(lambda () (auth-source-pick-first-password
                                       :host "claude.ai" :user "personal")))))
  (setopt overlook-account-labels '(("work" . "W") ("personal" . "P"))
          overlook-usage-accounts '(("claude" . "work") ("codex" . "personal")))
  ```

## Extending

Everything on the dashboard comes from hooks, so a module of your own can
add to it:

- `overlook-sections`: top level sections, by hook depth.  The
  perspectives section is at 0, usage at -50.  Insert through
  `overlook-insert-section`.  `overlook-section-order` fixes the order
  of the ones it lists, ahead of the rest.
- `overlook-perspective-functions`: rows under each perspective, called
  with its name, by hook depth, such as the rows of its checkouts.
  Insert each row with `overlook-insert-row`, which can nest rows under
  it.  Under `overlook-orphans-perspective`, also insert the rows that
  belong to no perspective.
- `overlook-delete-functions`: what `d d` does on a row, given its
  `overlook-item`; `overlook-folder-contents-functions`: what lies in a
  folder about to go, each with a function letting it go.
- `overlook-nested`: wrap a function inserting rows to indent them a
  step more.
- `overlook-worktrees-functions`: worktree folders listed under a
  perspective; `overlook-worktree-functions`: rows of what lies in a
  checkout, called with the perspective's name and the worktree's
  folder, or nil for what lies in none, by hook depth: agents at 0,
  changed repos at 50.  With nil they go right under the perspective
  while it lists no worktrees, else under its main checkout's row;
  `overlook-worktree-of` tells which worktree holds a folder.
- `overlook-detach`: keep a buffer out of every perspective, even once
  shown; opening it from the dashboard shows it in the current one.
  The courier module detaches the agents running a persona.
- `overlook-usage-functions`: rows in the usage section.
- `overlook-usage-add-poller`: refresh a row's data over the network, at most every few minutes while the dashboard is open.
- `overlook-mode-line-functions`: strings in the dashboard's mode line.
- `overlook-tick-hook`: run every few seconds while the dashboard is live.

Text properties on a row tell the dashboard about it: `overlook-action`
is called by `RET`, `overlook-item` keeps point on the row across
redraws, `overlook-heading` and `overlook-attention` mark the lines the
motion commands stop at.  The dashboard is a
[magit-section](https://github.com/magit/magit) buffer and every row a
section, so Magit's section commands (`C-<tab>`, `1`–`4`, `^`, `n`/`p`)
work too.  Call `overlook-refresh` when something you show changed.

Another perspective implementation can drive overlook by setting the
`overlook-perspective-*-function` variables, as overlook-perspective.el
does; another agent frontend by describing each of its buffers in
`overlook-agent-identity`, handing it to `overlook-agent-register`, and
setting `overlook-agent-start-function` for the agents overlook starts
itself, as overlook-agent-shell.el does.

## Caveats

Plan usage comes from undocumented sources: Claude's from rate limits
claude-agent-acp forwards to agent-shell, Codex's from its session logs
in `~/.codex/sessions`.  Either may change without notice.

## Development

```sh
OVERLOOK_INSTALL_DEPS=1 make test lint
```

This installs the dependencies into `.elpa/` and runs the tests, package-lint
and checkdoc.  Without `OVERLOOK_INSTALL_DEPS`, list the directories of
installed dependencies in `OVERLOOK_LOAD_PATH`.

## License

GPL-3.0-or-later.
