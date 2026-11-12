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
for agents, kept as an [Agent Skill](../skills/courier/SKILL.md);
[courier-handoff](../skills/courier-handoff/SKILL.md) guides an agent
starting one the user takes over.  Turning on `overlook-agent-courier-mode`
links every folder of `skills/` into `overlook-courier-skill-directories`
(`~/.claude/skills/` and `~/.codex/skills/`), so agents load them on their
own; a missing or dangling link is made anew, anything else left alone.

```sh
courier list                                  # the agents, who spawned them, unread mail
courier spawn codex . 'Review the diff of foo.go'  # then end your turn; it reports back
courier spawn --effort high claude . 'Find why the build fails'  # at that reasoning effort
courier spawn --worktree fix-login claude . 'Fix the login redirect'  # in a checkout of its own
courier spawn --handoff claude ~/p 'Draft the plan'  # the user's: left unsent at its prompt, reports nothing
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

`courier spawn --handoff` starts an agent for the user instead: it has no
parent, and courier tells nobody about its turns.  The prompt, as is,
with no briefing or `[courier]` header, waits unsent at the agent's
prompt once it is ready, for the user to check and send; a frontend
offers this by registering the agent with `:insert`.

A delivery to an agent that is ready yet starts no turn would keep its
mail waiting for good, so after `overlook-courier-delivery-timeout` (120) seconds
courier gives up on it and delivers the next mail.

### Worktrees

`courier spawn --worktree BRANCH` starts the child in a checkout of its
own, so agents working at once on one project do not edit the same
files.  For project DIR it is `DIR/.worktrees/BRANCH` (`/` in the branch
becomes `-`): a Git worktree when DIR is a repo; otherwise a folder with
a worktree of each repo directly in DIR and a `.overlook` file making it
one project.  The branch is made from each repo's checked out commit
unless it exists; `.worktrees/` is added to the repo's `info/exclude`.
The child is told its branch and to commit there.  Merging is left to
whoever asked for the work.  `--worktree` goes with `--handoff` too.

```sh
courier worktree list .
courier worktree add . fix-login           # without starting an agent
courier worktree add --from origin/main . fix-login   # branch from origin/main
courier worktree remove . fix-login        # keeps the branch; --force first drops uncommitted changes
```

overlook lists each worktree under its project, clean or
not, as `BRANCH/REPO`, or `BRANCH` for a single repo.

## Personas

A persona is an identity that outlives the agents running it: a folder in
one of `overlook-courier-persona-directories`, say
`~/workspace/me/personas/reviewer/`, holding `persona.md` and `memory/`.
An agent started as `reviewer` gets the courier id `reviewer`, whatever
engine runs it and however often it restarts, and one agent at most runs
it.  Messaging a persona nobody runs with `courier send` starts it on
its own engine.

```markdown
---
engine: claude, codex   # the agents to run it, required; see below
effort: medium          # its reasoning effort
directory: ~/src/shop   # where it starts, else the folder above the personas
description: Reviews diffs; never edits
avatar: 🦉              # its icon on the dashboard; the rest are optional too
personality: calm, exacting
tone: terse
memory: off             # no memory, for an agent that may not write files
briefing: off           # tell it nothing; it starts idle
---
Its role, its rules, and any background story.
```

A `#` after a space starts a comment.  Names are lowercase letters,
digits, `-` and `_`.

Listing several engines lets a persona go on when one plan runs low:
started without an explicit engine, it runs on the first one every
function of `overlook-courier-persona-engine-available-functions` lets
start it, else on the first.  `overlook-agent-courier-mode` adds one
saying no to an engine whose plan, as overlook-usage reads it for the
account in use, has a window at `overlook-usage-warning` (80%) or more.
`--engine`, or `overlook-persona-converse-on`, picks one instead.

Starting, the agent is told the body, the personality and tone, and the
index of its memory, `memory/MEMORY.md` (up to
`overlook-courier-persona-index-lines`, 200).  It keeps that memory itself, a
file per fact as in Claude's own memory; courier only tells it where.
With `memory: off` it is told of no memory and none is made.
Started with no task, it says in one line that it is ready; started by a
message, it learns who it is with that message, in the same turn.
With `briefing: off` it is told none of this, nor about courier, and
starts idle; its agent's own instruction files, such as a `CLAUDE.md` or
`AGENTS.md` in its directory, carry its role.  A general chat assistant
that should not know it is a persona is one.

```sh
courier persona list
courier persona start reviewer                       # in its own directory, on its own engine
courier persona start --engine codex --effort high reviewer ~/repo 'Review the diff'
```

On the dashboard a Personas section lists them: RET starts one or shows
the agent running it, `e` opens its `persona.md`, and RET on the heading,
or on its only row while there are none, makes a new one.  An agent
running a persona is listed there only, not under a project.  overlook
keeps every agent's courier id when it resumes the agent in a later
Emacs, and refuses to resume a persona's session while another agent
runs that persona.  Its agent's buffer is named after the instance and
engine, like `chat-2 · codex`; `overlook-persona-converse` starts a
further conversation with a persona whose multiple is on.

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

Its buffer, `*NAME*`, is a comint buffer: type at the `NAME> ` prompt and
press `RET` to ask; a spinner shows while it answers, and the header line
says no earlier question is sent.  `C-c C-c` or `C-c C-k` stops the
request.  Every exchange is also appended to `NAME.md` in
`overlook-courier-gptel-history-directory`, never sent back; each start
of the persona moves the last one to `archive/` there.  `M-x
overlook-courier-gptel-ask` asks it about the region or typed text from
anywhere, starting it if needed.  Courier delivers messages to it like to any agent,
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
                           :reply (lambda () ...)         ; its last reply, or nil
                           :insert (lambda (text) ...))   ; put TEXT at its prompt unsent, or nil
(overlook-courier-turn-started id)
(overlook-courier-turn-finished id)    ; or (overlook-courier-turn-finished id error-message)
(overlook-courier-blocked id "what it asks the user")
```

`overlook-courier-note` adds a note to an agent's next prompt without waking it.

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
