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
  `courier-reply-max` (4000) characters, with the path of its transcript;
- its turn failed, with the error, even if it had reported;
- it is gone before reporting on the parent's message.

Two things only the user can act on do not wake the parent; it finds them
at the top of its next prompt: that the child waits for the user (once a
turn), and that a child which had reported is gone.

Started with no prompt (`courier-spawn` with PROMPT nil), an agent idles
until a message comes, and its briefing comes with it.  Courier gathers
mail for `courier-delivery-delay` (2) seconds before delivering, so
messages arriving together cost one turn.

A turn the user starts in the child's buffer is not reported.

## Rooms

A room is a chat log that agents and you share, kept in
`courier-room-directory` so it outlives Emacs.  Posting wakes only the
members it names, `@ID` or `@all`: waking every member on every post would
cost each a turn and let agents answer each other until the hop limit.
Naming an agent that is not a member adds it.  A post that wakes a
member brings along its latest unread posts, up to
`courier-room-wake-context` (20), and marks them read.  Other posts wait,
and the next prompt a member gets says how many are unread.

```sh
courier room join design                 # posts naming you wake you
courier room join design --wake all      # every post wakes you; --wake none: none does
courier room post design '@codex@shop the API is v2 now'
courier room read design                 # what you have not read
courier room read design --last 50
courier room list                        # members marked (gone) can no longer be woken
courier room invite design codex@shop    # add an agent and tell it
courier room spawn design claude . 'Draft the schema'   # start one as a member; --effort first; no task: it idles until named
courier room leave design
courier room close design                # archive the posts under archive/
```

You are the member `user`.  `M-x overlook-room-open` shows a room in a
[lui](https://github.com/emacs-circe/circe) buffer, where RET posts as
you, `C-c C-i` invites an agent, `C-c C-n` starts one in the room (with a
prefix argument, at an effort you give) and `C-c C-k` closes the room.  A
post naming `@user` while the room is not shown is announced in the echo
area.

## For frontends

Courier knows no agent program.  A frontend registers each agent and
reports its turns:

```elisp
(courier-register id
                  :buffer buffer                 ; unregistered when killed
                  :deliver (lambda (prompt) ...) ; submit PROMPT to the agent
                  :ready (lambda () ...)         ; can it take a prompt now?
                  :reply (lambda () ...))        ; its last reply, or nil
(courier-turn-started id)
(courier-turn-finished id)             ; or (courier-turn-finished id error-message)
(courier-blocked id "what it asks the user")
```

`courier-note` adds a note to an agent's next prompt without waking it,
and `courier-prompt-functions` add notes, like the unread rooms, to the
prompts courier delivers.

It starts each agent with `(courier-environment id)` in its environment,
from an id of `courier-new-id`, and sets `courier-spawn-function` to start
agents for `courier spawn`, at the effort level asked for if it can.
overlook's `overlook-courier-mode` does all this for the agents on its
dashboard.

## Safety

- A message an agent sends while handling one is a hop further from the
  human prompt that set it off; past `courier-max-hops` (8) courier drops
  it, so two agents cannot answer each other forever.
- Messages are prompts: an agent acts on what another sends it as on what
  you type.  Spawned agents still ask you for permissions as usual.
