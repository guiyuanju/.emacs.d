# courier

Erlang-style messages between AI agents running in Emacs.

Each agent registered with courier has an id, like `claude@shop`, and a
mailbox.  Sending drops a message in a mailbox and returns at once; the
message reaches the agent as a new prompt once it is between turns.  An
agent can spawn another on a task and is woken by its reply when it
finishes.  Nothing waits, so Emacs never blocks and no agent holds a turn
open while another works.

| Erlang | courier |
|---|---|
| process, pid | agent, `$COURIER_ID` |
| `Pid ! Msg` | `courier send ID MESSAGE` |
| mailbox, `receive` | a queue, delivered as one prompt between turns |
| `spawn_monitor` | `courier spawn AGENT DIR PROMPT` |
| `monitor`, `'DOWN'` | `courier monitor ID`: told, with its reply, when it next finishes a turn, or is gone |

## For agents

An agent started through a frontend finds the `courier` script on its
`PATH`, and its own id in `$COURIER_ID`:

```sh
courier list                                  # the agents, who spawned them, unread mail
courier spawn codex . 'Review the diff of foo.go'  # then end your turn; its reply comes back
courier send claude@shop 'Tests pass on my side'
courier monitor codex@shop                    # be told when it next finishes
courier whoami
```

A message arrives as a prompt like:

```
[courier] From claude@shop (answer with `courier send claude@shop MESSAGE`):

Tests pass on my side
```

The script reaches Emacs with `emacsclient`, so `server-start` must be
running.  Agents in a sandbox, like Codex's, need the script allowed
outside it.

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
(courier-turn-finished id)
```

It starts each agent with `(courier-environment id)` in its environment,
from an id of `courier-new-id`, and sets `courier-spawn-function` to start
agents for `courier spawn`.  overlook's `overlook-courier-mode` does all
this for the agents on its dashboard.

## Safety

- A message an agent sends while handling one is a hop further from the
  human prompt that set it off; past `courier-max-hops` (8) courier drops
  it, so two agents cannot answer each other forever.
- Messages are prompts: an agent acts on what another sends it as on what
  you type.  Spawned agents still ask you for permissions as usual.
