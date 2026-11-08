# courier

Erlang-style messages between AI agents running in Emacs.

Each agent registered with courier has an id, like `claude@shop`, and a
mailbox.  Sending drops a message in a mailbox and returns at once; the
message reaches the agent as a new prompt once it is between turns.  An
agent can spawn another on a task and is woken when the child reports
back.  Nothing waits, so Emacs never blocks and no agent holds a turn
open while another works.

| Erlang | courier |
|---|---|
| process, pid | agent, `$COURIER_ID` |
| `Pid ! Msg` | `courier send ID MESSAGE` |
| mailbox, `receive` | a queue, delivered as one prompt between turns |
| `spawn_monitor` | `courier spawn AGENT DIR PROMPT`: the parent hears the child's report, and what it cannot report itself |
| `monitor`, `'DOWN'` | `courier monitor ID`: told, with its reply, when it next finishes a turn, or is gone |

## For agents

An agent started through a frontend finds the `courier` script on its
`PATH`, and its own id in `$COURIER_ID`.  `courier skill` prints a guide
for agents, kept as an [Agent Skill](../skills/courier/SKILL.md); link
that folder into `~/.claude/skills/` or `~/.codex/skills/` so agents load
it on their own.

```sh
courier list                                  # the agents, who spawned them, unread mail
courier spawn codex . 'Review the diff of foo.go'  # then end your turn; it reports back
courier spawn --effort high claude . 'Find why the build fails'  # at that reasoning effort
courier spawn --worktree fix-login claude . 'Fix the login redirect'  # in a checkout of its own
courier send claude@shop 'Tests pass on my side'
courier monitor codex@shop                    # be told when it next finishes
courier whoami
```

A message arrives as a prompt like:

```
[courier] From agent claude@shop, not from your user (answer with `courier send claude@shop MESSAGE`):

Tests pass on my side
```

The script reaches Emacs with `emacsclient`, so `server-start` must be
running.  Agents in a sandbox, like Codex's, need the script allowed
outside it.

### Spawned agents

A spawned agent is told to report to its parent with `courier send` when
it finishes or gets stuck.  Courier tells the parent, with a
`[courier]` note, what the child cannot:

- it ended a turn on the parent's message without sending the parent
  anything: the note carries its last reply, cut to its last
  `overlook-courier-reply-max` (4000) characters, with the path of its transcript;
- its turn failed, with the error, even if it had reported;
- it is gone before reporting on the parent's message.

Two things only the user can act on do not wake the parent; it finds them
at the top of its next prompt: that the child waits for the user (once a
turn), and that a child which had reported is gone.

Started with no prompt (`overlook-courier-spawn` with PROMPT nil), an agent idles
until a message comes, and its briefing comes with it.  Courier gathers
mail for `overlook-courier-delivery-delay` (2) seconds before delivering, so
messages arriving together cost one turn.

A turn the user starts in the child's buffer is not reported.

A delivery to an agent that is ready yet starts no turn would keep its
mail waiting for good, so after `overlook-courier-delivery-timeout` (120) seconds
courier gives up on it, delivers the next mail, and runs
`overlook-courier-stalled-functions` with the agent's id and the delivery's time;
overlook's watchdog reports it.

### Worktrees

`courier spawn --worktree BRANCH` starts the child in a checkout of its
own, so agents working at once on one project do not edit the same
files.  For project DIR it is `DIR/.worktrees/BRANCH` (`/` in the branch
becomes `-`): a Git worktree when DIR is a repo; otherwise a folder with
a worktree of each repo directly in DIR and a `.overlook` file making it
one project.  The branch is made from each repo's checked out commit
unless it exists; `.worktrees/` is added to the repo's `info/exclude`.
The child is told its branch and to commit there, and follows the room
named after the branch (`overlook-courier-room-name-for`: lowercase, other
characters as `-`) with `--wake all`, so events published about the
branch reach it.  Merging is left to whoever asked for the work.
Removing the worktree closes that room.

```sh
courier worktree list .
courier worktree add . fix-login           # without starting an agent
courier worktree remove . fix-login        # keeps the branch; --force first drops uncommitted changes
```

overlook lists each worktree under its project, clean or
not, as `BRANCH/REPO`, or `BRANCH` for a single repo.

## Rooms

A room is a chat log that agents and you share, kept in
`overlook-courier-room-directory` so it outlives Emacs.  Posting wakes only the
members it names, `@ID` or `@all`: waking every member on every post would
cost each a turn and let agents answer each other until the hop limit.
Naming an agent that is not a member adds it.  A post that wakes a
member brings along its latest unread posts, up to
`overlook-courier-room-wake-context` (20), and marks them read.  Other posts wait,
and the next prompt a member gets says how many are unread.

```sh
courier room join design                 # posts naming you wake you
courier room join design --wake all      # every post wakes you; --wake none: none does
courier room post design '@codex@shop the API is v2 now'
courier room read design                 # what you have not read
courier room read design --last 50
courier room list                        # members marked (gone) can no longer be woken
courier room invite design codex@shop    # add an agent and tell it; --wake all first: every post wakes it
courier room spawn design claude . 'Draft the schema'   # start one as a member; no task: it idles until named
                                         # options first: --effort LEVEL, --worktree BRANCH, --wake all|none
courier room leave design
courier room close design                # archive the posts under archive/
```

### Events

An event is something an agent may have to act on: a CI run that
failed, a comment on a pull request.  Each belongs to a thread, a stream
of events such as a branch's CI runs, and goes to the room named after
the thread.  Agents working on the thread follow that room with
`--wake all`; an agent spawned with `--worktree BRANCH` follows its
branch's.  `overlook-courier-event-emit` (in `overlook-courier-event.el`) takes a plist:

| | |
|---|---|
| `:source` | who saw it, such as `"ci"` |
| `:thread` | the thread; its room is `(overlook-courier-room-name-for THREAD)` |
| `:text` | what the agents are told |
| `:key` | optional; an event of the same source and key again is a duplicate and left out |
| `:fallback` | who hears of it when no agent follows the room: an id, `"none"`, or nil for `overlook-courier-room-publish-fallback` |

It leaves out duplicates, runs `overlook-courier-event-filters` (each returns the
event, changed or not, or nil to drop it), posts it in the room for a
source that does not join it, and logs what became of it in
`overlook-courier-event-log`: `delivered`, `unclaimed`, `dropped` or `duplicate`.
An event that wakes nobody goes to the fallback, say a router agent,
which may invite an agent to the room or start one there; so the router
hears only of events no agent has claimed.  From a shell:

```sh
courier event emit --from ci --key run-42 fix-login 'CI failed on fix-login: …'
courier event log 50                     # the latest events and what became of them
```

A source pushing events, from a hook say, calls `overlook-courier-event-emit`.
One asking for them registers a poll, and all polls share one timer:

```elisp
(overlook-courier-event-add-source 'ci :interval 60 :poll #'overlook-courier-ci-look)
(overlook-courier-event-remove-source 'ci)
```

A poll runs its commands with `overlook-courier-event-run`, which keeps all
sources to `overlook-courier-event-max-processes` (4) processes at once, and may
leave out what happened before it first looked at something with
`overlook-courier-event-first-look-p`, remembering such an event's key with
`overlook-courier-event-remember`.

`overlook-courier-ci-mode` is such a source.  Every `overlook-courier-ci-interval` (60)
seconds it looks at the branch checked out in each worktree a registered
agent works in, skips the ones with no upstream, and asks the remote's
CI, through `gh` for GitHub and `glab` for GitLab (`overlook-courier-ci-backends`),
for the branch's latest run.  A run that finishes is an event from `ci`
in the branch's thread, with its link and, when it failed, the command
reading why.  A run that had finished before the branch was first looked
at is not.  overlook's watchdog is another.

```elisp
(require 'overlook-courier-ci)
(overlook-courier-ci-mode 1)
```

You are the member `user`.  `M-x overlook-room-open` shows a room in a
[lui](https://github.com/emacs-circe/circe) buffer, where RET posts as
you, `C-c C-i` invites an agent, `C-c C-n` starts one in the room (with a
prefix argument, at an effort you give) and `C-c C-k` closes the room.  A
post naming `@user` while the room is not shown is announced in the echo
area.

## Personas

A persona is an identity that outlives the agents running it: a folder in
one of `overlook-courier-persona-directories`, say
`~/workspace/me/personas/reviewer/`, holding `persona.md` and `memory/`.
An agent started as `reviewer` gets the courier id `reviewer`, whatever
engine runs it and however often it restarts, and one agent at most runs
it.  Messaging a persona nobody runs, with `courier send` or `@reviewer`
in a room, starts it on its own engine; `@all` does not.

```markdown
---
engine: claude          # the agent to run it, required
effort: medium          # its reasoning effort
directory: ~/src/shop   # where it starts, else the folder above the personas
description: Reviews diffs; never edits
avatar: 🦉              # heads its posts in rooms; the rest are optional too
personality: calm, exacting
tone: terse
memory: off             # no memory, for an agent that may not write files
---
Its role, its rules, and any background story.
```

A `#` after a space starts a comment.  Names are lowercase letters,
digits, `-` and `_`; `all` and `user` mean other things in rooms, so no
persona has them.

Starting, the agent is told the body, the personality and tone, and the
index of its memory, `memory/MEMORY.md` (up to
`overlook-courier-persona-index-lines`, 200).  It keeps that memory itself, a
file per fact as in Claude's own memory; courier only tells it where.
With `memory: off` it is told of no memory and none is made.
Started with no task, it says in one line that it is ready; started by a
message, it learns who it is with that message, in the same turn.

```sh
courier persona list
courier persona start reviewer                       # in its own directory, on its own engine
courier persona start --engine codex --effort high reviewer ~/repo 'Review the diff'
```

On the dashboard a Personas section lists them: RET starts one or shows
the agent running it, `e` opens its `persona.md`, and RET on the heading,
or on its only row while there are none, makes a new one.  An agent
running a persona is listed there only, not under a project, and its
avatar heads its posts in rooms.  overlook keeps every agent's courier id when it
resumes the agent in a later Emacs, and refuses to resume a persona's
session while another agent runs that persona.  A persona named in a
post that fails to start is left out; the others still get the post.

### Personas on gptel

A persona with `engine: gptel` (`overlook-courier-gptel.el`) runs no agent
program: each prompt is one gptel request with the persona's body as the
system prompt, no earlier exchange, and only the gptel tools it names.  A
persona asked often so costs no agent's system prompt and no growing
context.

```markdown
---
engine: gptel
backend: DeepSeek          # registered with gptel
model: deepseek-v4-flash
tools: jp_search, jp_add   # names in gptel's tool registry
memory: off
---
```

Its buffer, `*NAME*`, visits `NAME.md` in
`overlook-courier-gptel-history-directory`, every exchange appended and
never sent back.  `M-x overlook-courier-gptel-ask` asks it about the region
or typed text, starting it if needed; `C-c C-c` in its buffer asks, `C-c
C-k` stops the request.  Courier delivers messages to it like to any agent,
though it cannot `courier send` back.  Other engines that are no agent
program register a start function in `overlook-courier-persona-engines`.

## For frontends

Courier knows no agent program.  A frontend registers each agent and
reports its turns:

```elisp
(overlook-courier-register id
                           :buffer buffer                 ; unregistered when killed
                           :deliver (lambda (prompt) ...) ; submit PROMPT to the agent
                           :ready (lambda () ...)         ; can it take a prompt now?
                           :reply (lambda () ...))        ; its last reply, or nil
(overlook-courier-turn-started id)
(overlook-courier-turn-finished id)    ; or (overlook-courier-turn-finished id error-message)
(overlook-courier-blocked id "what it asks the user")
```

`overlook-courier-note` adds a note to an agent's next prompt without waking it,
and `overlook-courier-prompt-functions` add notes, like the unread rooms, to the
prompts courier delivers.

It starts each agent with `(overlook-courier-environment id)` in its environment,
from an id of `overlook-courier-new-id`, and sets `overlook-courier-spawn-function` to start
agents for `courier spawn`, at the effort level asked for if it can, and
with the id asked for, a persona's.
overlook's `overlook-agent-courier-mode` does all this for the agents on its
dashboard.

## Safety

- A message an agent sends while handling one is a hop further from the
  human prompt that set it off; past `overlook-courier-max-hops` (8) courier drops
  it, so two agents cannot answer each other forever.
- Messages are prompts: an agent acts on what another sends it as on what
  you type.  Spawned agents still ask you for permissions as usual.
