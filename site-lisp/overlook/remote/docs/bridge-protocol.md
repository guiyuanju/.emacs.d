# Bridge protocol (version 1)

Between `overlook-remote-bridge.el` (the **client**, Emacs) and
`overlook-remoted` (the **daemon**). Go types: `internal/bridge/protocol.go`.
Fixtures: `testdata/fixtures/` (see the last section). Keywords MUST/SHOULD/MAY
as in RFC 2119.

## 1. Transport and framing

- Unix domain stream socket. Default path
  `${XDG_RUNTIME_DIR:-$HOME/.local/state}/overlook-remote/bridge.sock`; the
  daemon creates the directory 0700 and the socket 0600, and removes a stale
  socket file at startup only if connecting to it fails. Socket permissions are
  the only authentication.
- The daemon listens; Emacs connects. One active Emacs connection: a
  connection whose `hello` succeeds replaces (closes) the previous one.
- Each message is one JSON object encoded as UTF-8 on one line, terminated by
  `\n` (NDJSON). No batches. Strings MUST be valid UTF-8; Emacs replaces raw
  bytes and invalid characters with U+FFFD before serializing.
- Envelopes are JSON-RPC 2.0: requests `{"jsonrpc":"2.0","id":…,"method":…,"params":{…}}`,
  notifications without `id`, responses `{"jsonrpc":"2.0","id":…,"result":{…}}`
  or `{"jsonrpc":"2.0","id":…,"error":{"code":…,"message":…,"data":{…}}}`.
  `params` and `result` are always objects (`{}` when empty).
- Request ids: the daemon uses increasing integers; Emacs uses strings
  (`"hello-<n>"`). Ids are unique per direction per connection.
- Conventions for all payloads: optional fields are omitted rather than `null`;
  empty arrays and `false` booleans MAY be omitted and mean empty/false;
  timestamps are RFC 3339 UTC with milliseconds (`2026-11-13T08:05:09.120Z`).
  Unknown fields MUST be ignored by both sides (forward compatibility).

## 2. Lifecycle

```
Emacs                                      daemon
  ── connect ──────────────────────────────▶
  ── hello (request) ──────────────────────▶
  ◀───────────────────────────── hello result
  ── sync (notification) ──────────────────▶   state replaced, emacs online
  ── agent.event × buffered (replay) ──────▶
  ── live notifications … ─────────────────▶
  ◀──────────────────── requests / notifications
```

- Before a successful `hello`, the daemon answers any other request with error
  400 `hello_required` and drops notifications. Emacs sends nothing else until
  the `hello` result arrives.
- After the `hello` result Emacs MUST send `sync` before any other message.
  The daemon sends no request until `sync` is applied.
- **Epochs.** Emacs makes its epoch once per process (e.g. `"<pid>-<unix
  nanoseconds>"`, kept in a `defvar` so reloading the bridge keeps it).
  - `hello.epoch` equals the epoch of the previous connection: the daemon
    keeps activity, read positions and receipts; `sync` replaces dashboard and
    conversation states (conversations absent from `sync` are removed).
  - Different epoch, or the daemon's first connection: the daemon drops all
    conversations, activity, read positions and receipts, and starts a new
    history epoch.
- **Disconnect.** EOF or a write error on either side ends the connection. The
  daemon marks Emacs offline, fails outstanding requests with 503
  `emacs_offline`, and keeps the last snapshot.
- **Handshake timeout.** Emacs closes a connection whose `hello` is not
  answered within 10 s and reconnects.
- **Reconnect.** Emacs retries after 0.5 s, doubling to 30 s, ±20 % jitter;
  the delay resets after a successful `hello`. On error 409
  `protocol_mismatch` Emacs stops retrying and tells the user.
- **Buffering.** While disconnected, Emacs keeps `agent.event` notifications
  (not states, which `sync` resends) in a FIFO of at most 2000 events or 16 MiB;
  overflow drops the oldest and counts them. After `sync` it replays the FIFO in
  order and reports the count of dropped events in the next `hello.lost`.
  When `lost > 0` the daemon closes every open text item so the next text
  chunk starts a new item instead of extending a gapped one.

## 3. Shared types

### Node (dashboard tree)

| Field | Type | Notes |
|---|---|---|
| `key` | string, required | identity, unique among siblings, stable across redraws (`overlook-data-id` / resourceId) |
| `kind` | string, required | `group`, `text`, `project`, `persona`, `agent`, `saved`, `usage`, `repo`, `folder`, `file`, `todo`, `tasks`, others allowed |
| `title` | string, required | |
| `subtitle` | string | agent brief, file directory, task parent, persona description |
| `provider` | string | agent program or icon name (`claude`, `codex`, …) |
| `status` | string | agents: `idle`/`working`/`waiting`/`done`/`failed`; personas: `idle`/`offline`; files: git status letter; todos: `open`/`waiting` |
| `account` | string | usage account |
| `branch` | string | repos/folders |
| `added`, `removed` | integer ≥ 0 | line counts |
| `due` | string `YYYY-MM-DD` | todos |
| `persona`, `description` | string | persona identity |
| `windows` | UsageWindow[] | usage |
| `heading` | boolean | row is a heading |
| `attention` | boolean | row asks for attention |
| `conversation` | string | conversation id, on agent rows |
| `choices` | Choice[] | agent rows: answers offered now |
| `commands` | Command[] | row commands, run with `node.command` |
| `diff` | boolean | `node.diff` returns a diff |
| `children` | Node[] | |

No ids, hashes or unread counts: the daemon derives them. Duplicate sibling
keys are disambiguated by the daemon by appending `#2`, `#3`, … in order.

- **UsageWindow** `{label: string, value?: number|string, reset?: number|string}`;
  `value` a percentage used (number) or display text; `reset` Unix seconds
  (number) or display text.
- **Command** `{name, label, input?, options?, confirm?}`: `input` is the
  placeholder of a required text; `options` strings to pick one of; `confirm`
  true when running it asks a question first.
- **Choice** `{key, label}`.

### Conversation

| Field | Type | Notes |
|---|---|---|
| `id` | string, required | `overlook-data-agent-id`, stable for the buffer's life |
| `provider` | string, required | agent program name, `"agent"` if unknown |
| `title` | string, required | may be `""` |
| `status` | enum, required | `idle`, `working`, `waiting`, `done`, `failed` |
| `persona`, `description` | string | persona conversations |
| `project`, `folder` | string | project name, root's last component |
| `root` | string, required | absolute directory; the daemon resolves relative image paths against it; never sent to browsers |
| `brief` | string | one line on what it is doing |
| `context` | number | percent of context window used |
| `choices` | Choice[] | |
| `form` | Form | question the agent waits on |
| `queue` | QueueItem[] | remote prompts waiting, oldest first |
| `queueError` | string | delivery paused until `conversation.retry` |
| `controls` | Controls, required | |
| `canAttach` | boolean | the agent has the `attach` capability |

- **QueueItem** `{id, text}`; ids are made by Emacs, unique per Emacs process.
- **Controls** `{steer?: boolean, actions: string[], slash?: Slash[], settings?: Setting[]}`.
  `actions` always includes `"close"`; it also lists each setting's id.
  **Slash** `{name, description?}`. **Setting** `{id, label, value, choices:
  [{value, name}]}` (e.g. `model`, `effort`).
- **Form** `{id, message, answerable, fields: Field[]}`.
  **Field** `{key, type, title, description?, required?, options?: Option[],
  other?}` with `type` one of `single`, `multi`, `text`, `boolean`, `number`,
  `integer`, `unsupported`; `other` is the key under which a free-text “Other”
  answer goes. **Option** `{value, title, description?}`.

### Event (`agent.event` params)

Flat object: `conversation` (id, required), `at` (timestamp, required), `type`
(required), then per type:

| `type` | Fields | From `overlook-agent-event-functions` |
|---|---|---|
| `prompt` | `text` | `prompt :text` |
| `text` | `text` (may be `""`), `images?` | `text :text :images` |
| `tool` | `id` (required), `title?`, `status?`, `kind?`, `diffs?`, `output?`, `images?` | `tool …` |
| `end` | — | `end` |
| `error` | `text` | `error :text` |

- `status` as the agent says it: `pending`, `in_progress`, `completed`,
  `failed`. `kind`: ACP tool kind (`edit`, `read`, `execute`, `other`, …).
- **Diff** `{file, old, new}` (missing strings sent as `""`).
- **Image** `{file}` (absolute path) or `{data, mime}` (base64, `image/png`,
  `image/jpeg`, `image/gif`, `image/webp`).
- `output` is the tool's text so far; the daemon only scans it for image paths.

## 4. Emacs → daemon

### `hello` (request)

Params: `{protocol: 1, epoch: string, emacs: string (emacs-version), pid:
integer, lost: integer ≥ 0}`.
Result: `{protocol: 1, daemon: string (version), historyEpoch: string,
maxMessageBytes: integer}`.
Errors: 409 `protocol_mismatch` (the daemon closes the connection after
responding).

### `sync` (notification)

Params: `{dashboard: Node[], conversations: Conversation[]}`. Replaces all
state. Sent once after every successful `hello`.

### `dashboard.set` (notification)

Params: `{sections: Node[]}` — the whole tree, top-level rows in order.

### `conversation.set` (notification)

Params: `{conversation: Conversation}` — the whole state; creates or replaces.

### `conversation.remove` (notification)

Params: `{conversation: string}`. The buffer is gone; the daemon drops its
activity and read position and ends its subscriptions with `gone`.

### `agent.event` (notification)

Params: Event (section 3).

## 5. Daemon → Emacs requests

`conversation` params are conversation ids; `path` params are the node's key
path from the top-level section to the node (`["<k0>", "<k1>", …]`), resolved
by Emacs against the rows of the tree it last published. Emacs re-validates
everything; the daemon pre-validates what it can from the published state.

| Method | Params | Result | Errors |
|---|---|---|---|
| `conversation.prompt` | `{conversation, text}` (text trimmed, non-empty) | `{delivery: "sent"}` or `{delivery: "queued", queueId}` | 404 `conversation_missing`, 409 `prompt_unsupported`, 400 `empty_text` |
| `conversation.unqueue` | `{conversation, queueId}` | `{}` (also clears `queueError`) | 404 `conversation_missing`, 409 `already_sent` |
| `conversation.retry` | `{conversation}` | `{}` (clears `queueError`) | 404 `conversation_missing` |
| `conversation.action` | `{conversation, action, text, confirmed: string[]}` | ActionOutcome | 404 `conversation_missing`, 400 `unsupported_action`, 400 `empty_text`, 409 `state_conflict` |
| `conversation.choose` | `{conversation, key}` | `{}` | 404 `conversation_missing`, 409 `state_conflict` (no longer offered) |
| `conversation.answer` | `{conversation, form, action: "accept"\|"decline", values: object}` | `{}` | 404 `conversation_missing`, 409 `answer_unsupported`, 409 `state_conflict` |
| `conversation.attach` | `{conversation, path, name}` | `{text}`: what to insert into the prompt | 404 `conversation_missing`, 409 `attachment_unsupported` |
| `conversation.earlier` | `{conversation}` | `{reply, transcript}`: last reply (markdown, may be `""`), last 8000 characters of the buffer | 404 `conversation_missing` |
| `node.command` | `{path, name, text?, option?, confirmed: string[]}` | CommandOutcome | 404 `node_missing`, 404 `command_missing`, 400 `empty_text`, 400 `invalid_option`, 409 `state_conflict` |
| `node.diff` | `{path}` | `{diff}`: unified diff text | 404 `node_missing`, 404 `diff_missing` |
| `ping` | `{}` | `{}` | — |

- **ActionOutcome**: `{outcome: "done", conversation?: string, closed?: true}`
  or `{outcome: "confirm", question: string}`. `conversation` is the resulting
  conversation (the same id, or a new one after `reload`/`restart`/`fork`);
  `closed` after `close`.
- **CommandOutcome**: `{outcome: "done", conversation?: string, draft?: string}`
  or `{outcome: "confirm", question}`. `conversation` is one the command opened
  or started; `draft` is text the page appends to that conversation's draft.
- **Actions.** `steer` (text required; only when `controls.steer`), `close`
  (always), each id in `controls.actions` (`stop`, `reload`, `restart`,
  `fork`, setting ids such as `model`, `effort` with `text` = the chosen
  value). `close` discards the remote queue; resumable sessions stay saved.
- **Confirmations.** Emacs runs the operation with `y-or-n-p` and
  `yes-or-no-p` rebound: a prompt in `confirmed` answers yes; the first prompt
  not in it aborts the operation, which returns `{outcome: "confirm",
  question}`. `close` asks its own question first (as the old service did);
  a command with `confirm` asks its `:confirm` question first. Nothing is
  executed when a confirm outcome is returned.
- **Attach.** `path` is a file the daemon wrote (0600) and deletes after the
  response; Emacs reads its bytes and calls the agent's `attach` with `name`
  (`phone-YYYYmmdd-HHMMSS-mmm.<ext>`) and the bytes.

### Daemon → Emacs notifications

| Method | Params | Meaning |
|---|---|---|
| `conversation.seen` | `{conversation}` | a reader caught up (unread 0): call `overlook-agent-seen` |
| `resync` | `{}` | send a fresh `sync` (the daemon dropped a message it could not apply) |

## 6. Errors

Application errors use the HTTP status as JSON-RPC `code`, a human `message`
the page may show, and `data.problem` a stable code:

```json
{"jsonrpc":"2.0","id":7,"error":{"code":409,"message":"That prompt was sent already","data":{"problem":"already_sent"}}}
```

Emacs mapping: missing conversation → 404 `conversation_missing`; a
`user-error` without a more specific code → 409 `state_conflict`; any other
error → 500 `internal_error` with a generic message (details only in
`*Messages*`).

Daemon mapping to HTTP problems (`type: urn:overlook:problem:<code>`):

| Bridge outcome | HTTP |
|---|---|
| error with code 400–599 and `data.problem` | that status and code, `detail` = `message` |
| error with code 400–599, no `data.problem` | that status, code `state_conflict` (4xx) or `internal_error` (5xx) |
| JSON-RPC reserved code (−32768…−32000) | 500 `bridge_error` (logged) |
| not connected / connection lost while pending | 503 `emacs_offline` |
| timeout | 504 `emacs_timeout` |

## 7. Ordering and coalescing

- One connection, in order. The daemon applies Emacs messages strictly in
  arrival order, on one goroutine.
- **Read-your-writes.** Before writing a response, Emacs flushes every pending
  notification. The daemon completes an HTTP request only after applying all
  messages that preceded the response.
- Emacs MUST NOT reorder `agent.event`s of one conversation, and MUST send
  `conversation.remove` after that conversation's last event.
- Emacs SHOULD coalesce, flushing within 100 ms:
  - `dashboard.set`: latest wins; skip when the JSON text equals the last sent.
  - `conversation.set`: latest per conversation wins; skip when equal to the
    last sent for that id.
  - adjacent `text` events of one conversation MAY merge (concatenate `text`,
    append `images`, keep the last `at`); adjacent `tool` events with the same
    `id` MAY merge (non-empty `title`/`status`/`kind`/`diffs`/`output` of the
    later win, `images` appended). No other merging.
  - `dashboard.set` at most every 0.5 s, except that a changed dashboard is
    flushed before any response.
- Emacs writes at most 8000 bytes per turn of its event loop and queues the
  rest in order: a socket write that does not fit makes Emacs sleep 20 ms,
  and macOS local sockets buffer 8 KiB. Queued events lost to a disconnect
  count in `hello.lost`.
- The daemon coalesces browser fan-out separately (≤ 200 ms).

## 8. Daemon semantics of events

- `seq`: one counter per history epoch; each applied event increments it.
- Item id (`item`) is the `seq` at creation; `createdAt` its event's `at`.
  Each event touching an item sets the item's `seq` and `updatedAt`.
- `text`: extends the conversation's newest-created item if that is an open
  text item, else creates one. After each extension the daemon records a mark
  `(seq, length)`, length in UTF-16 code units (the browser's
  `String.length`).
- `tool`: merges into the retained tool item with the same `id`, else creates
  one. Non-empty `title`/`status`/`kind` replace; non-empty `diffs` different
  from the last applied ones recompute `diff` (unified, `--- file`/`+++ file`
  labels, 3 lines of context, concatenated per file, cut at 20000 characters
  with `"\n…"` appended).
- `prompt`, `end`, `error`: always create an item.
- Images of an item: explicit `images`, then image files named in its title,
  text or tool output, deduplicated by content. A name matches (case
  insensitive) `@"<path>.<ext>"`, or an optional `@`/`file://` prefix followed by
  ASCII characters other than whitespace and `][\"'\`()<>|,;`, ending in
  `.<ext>` not followed by a letter, digit, `_` or `-`; `<ext>` is `png`,
  `jpg`, `jpeg`, `gif` or `webp`. Paths are percent-decoded, `~/` expands to
  the home directory, relative paths resolve against `root`. Only regular
  readable files ≤ 20 MiB whose magic bytes match their type are taken; the
  bytes are copied into the image store at that moment.
- Retention: 300 items per conversation; evicting raises the conversation's
  history floor to the evicted item's max(`seq`, `item`).
- Unread: text items with `seq` greater than the read position.

## 9. Limits and timeouts

| Limit | Value |
|---|---|
| line, Emacs → daemon | 64 MiB (`hello.result.maxMessageBytes`) |
| line, daemon → Emacs | 1 MiB |
| `text` of one event | 1 MiB (Emacs splits longer text into several events) |
| tool `output` | first 256 KiB (Emacs truncates) |
| each diff `old`/`new` | 2 MiB (Emacs omits larger diff entries) |
| image | 20 MiB decoded (the daemon drops larger) |
| conversation state | 1 MiB; dashboard 8 MiB |

The daemon discards an over-long or unparsable line (logged); if it was a
request it answers 413 `request_too_large` / −32700 when the id is
recoverable, and after dropping a notification it sends `resync`.

Daemon wait per request, after which the HTTP call gets 504 `emacs_timeout`:
`conversation.earlier` 2 s, `ping` 5 s, `conversation.action` and
`node.command` 30 s, everything else 10 s. The call stays pending until Emacs
answers or disconnects; a late result is still recorded as the idempotency
receipt.

## 10. Fixtures

`testdata/fixtures/` holds a realistic session in this protocol, used by
`internal/fakeemacs` and the page tests:

| File | Content |
|---|---|
| `hello.json` | the `hello` request |
| `sync.json` | `sync`: usage, two projects with an agent, repo, files, tasks and a saved conversation, a persona with its conversation |
| `events.ndjson` | `agent.event`s replayed right after `sync`: prompts, a streamed reply, tool calls with diffs, images by data and by file |
| `live.ndjson` | messages for streaming tests: `{"delayMs": n, "message": {…}}` per line |
| `responses.json` | canned results per daemon request, including two-step confirmations |
| `root/alpha/…` | files the events name (a screenshot) |

The literal `${FIXTURES}` in strings stands for the absolute path of
`testdata/fixtures`; fakeemacs substitutes it before sending.
