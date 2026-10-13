# overlook

A dashboard over everything you are working on in Emacs: each
[perspective](https://github.com/nex3/perspective-el), the Git repos of
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
   ⚠ codex   ? Run git push                                  18%

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

It pulls in perspective and agent-shell.  agent-shell needs the ACP
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
  (overlook-project-mode 1)       ; repos under each perspective
  (overlook-agent-mode 1)         ; agents under each perspective
  (overlook-agent-shell-mode 1)   ; agents run in agent-shell
  (overlook-usage-mode 1))        ; Claude and Codex plan usage
```

To let agents message, spawn and monitor each other, install
[courier](../courier) and turn on its bridge:

```elisp
(require 'overlook-courier)
(overlook-courier-mode 1)
```

A spawned agent opens in its parent's perspective, and its row shows
`← parent`, and `✉N` while messages wait for it.

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
- `M-x overlook-agent-start` starts an agent at the current project's
  root, or shows the one already running there.
- `M-x overlook` toggles the dashboard.

## Commands

| Command | |
|---|---|
| `overlook` | toggle the dashboard |
| `overlook-agent-start` | show an agent of this project, starting it when needed; with a prefix argument, start another |
| `overlook-agent-toggle` | hide the agent in the selected window, or show this project's |
| `overlook-agent-switch` | pick any running agent and show it in its perspective |
| `overlook-agent-send` | paste the region, or an `@` reference to the file, into this project's agent |
| `overlook-agent-shell-handoff` | draft a handoff of an agent's task to another agent, from its transcript |
| `overlook-perspective-open-project` | open a project in its own perspective |

On the dashboard:

| Key | |
|---|---|
| `RET` / `o` | visit the row: switch to a perspective, show a repo's diff in Magit, compare a changed file in Ediff, show an agent |
| `C-j` / `C-k` | next / previous heading |
| `] a` / `[ a`, `C-S-j` / `C-S-k` | next / previous agent needing you |
| `H` | hand the agent's task off to another agent |
| `x` | forget a saved agent |
| `g` | redraw |
| `q` | close |

Evil users can bind the same keys in normal state:

```elisp
(with-eval-after-load 'overlook
  (pcase-dolist (`(,key . ,command) overlook-keys)
    (evil-define-key* 'normal overlook-mode-map (key-parse key) command)))
```

## What the rows show

- An agent: `◐` working, `⚠` waiting for you, `●` finished while you were
  not looking, `○` idle; what it is doing; how long its turn has run; how
  much of its context window is used.
- A saved agent: `○ claude saved`, dimmed, for each agent running when
  Emacs quit.  `RET` on it, or `overlook-agent-start` of that agent in
  its project, resumes its session where it left off, minus a turn cut
  short; they are kept in `overlook-agent-saved-file`.
- When an agent turns `⚠` or `●` while no Emacs frame has focus, a
  desktop notification says so (`osascript` on macOS, D-Bus elsewhere).
  Set `overlook-agent-notify` to `t` to be told even while Emacs has
  focus, or `nil` never; `overlook-agent-notify-function` shows it.
- A repo: its branch and the lines changed since its last commit, then the
  changed files with their line counts.  These come from Git, so they show
  every change in the working tree, whoever made it.

## Customization

`M-x customize-group RET overlook`.  Among others:

- `overlook-side`, `overlook-width`: where the dashboard sits, and how
  wide it is in columns or as a fraction of the frame.
- `overlook-perspective-order`: the current perspective first, then the
  rest by how often and how recently you switched to them (the default),
  or the backend's order.  To remember switches across sessions:
  `(add-to-list 'savehist-additional-variables 'overlook-perspective-visits)`.
- `overlook-markers`: the files marking a folder of several repos
  as one project.
- `overlook-perspective-root`: how a perspective's project root is found.
  The default guesses from the projects of its buffers.
- `overlook-perspective-annotation`: a function of a perspective name
  returning a tag shown dimmed after its heading, such as which
  workspace it belongs to.
- `overlook-agent-root-function`: the directory agents start in.
- `overlook-agent-shell-configs`: the agents you can start, and the
  agent-shell configs they run with.
- `overlook-agent-shell-handoff-prompt`: the handoff draft.

## Extending

Everything on the dashboard comes from hooks, so a module of your own can
add to it:

- `overlook-sections`: top level sections, by hook depth.  The
  perspectives section is at 0, usage at -50.  Insert through
  `overlook-insert-section`.
- `overlook-perspective-functions`: rows under each perspective, called
  with its name.
- `overlook-usage-functions`: rows in the usage section.
- `overlook-mode-line-functions`: strings in the dashboard's mode line.
- `overlook-tick-hook`: run every few seconds while the dashboard is live.

Text properties on a row tell the dashboard about it: `overlook-action`
is called by `RET`, `overlook-item` keeps point on the row across
redraws, `overlook-heading` and `overlook-attention` mark the lines the
motion commands stop at.  Call `overlook-refresh` when something you show
changed.

Another perspective implementation can drive overlook by setting the
`overlook-perspective-*-function` variables, as overlook-perspective.el
does; another agent frontend by setting `overlook-agent-start-function`
and describing its buffers in `overlook-agent-identity`, as
overlook-agent-shell.el does.

## Caveats

Plan usage comes from undocumented sources: Claude's from rate limits
claude-agent-acp forwards to agent-shell, Codex's from its session logs
in `~/.codex/sessions`.  Either may change without notice.

## Development

```sh
OVERLOOK_INSTALL_DEPS=1 make test lint
```

installs the dependencies into `.elpa/` and runs the tests, package-lint
and checkdoc.  Without `OVERLOOK_INSTALL_DEPS`, list the directories of
installed dependencies in `OVERLOOK_LOAD_PATH`.

## License

GPL-3.0-or-later.
