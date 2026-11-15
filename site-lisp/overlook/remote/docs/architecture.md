# overlook remote: architecture

Companion to `plan.md` (goals, constraints, phases). The wire contracts are
`bridge-protocol.md` (Emacs ↔ daemon) and `../api/openapi.yaml` (browser ↔
daemon). This file says who owns what, how data moves, and why.

## Components

```
Safari (page: ES modules, Framework7)
   │  HTTPS or HTTP: snapshot GETs, writes, one SSE stream per page
   ▼
overlook-remoted (Go)
   config ─ auth ─ api ─ stream ─ assets
                    │      │
                    ▼      ▼
                  store (derived state, in memory) ── state (state file)
                    ▲
                  bridge (unix socket server, JSON-RPC 2.0 over NDJSON)
   │
   ▼
Emacs: overlook-remote-bridge.el (client; reconnects with backoff)
   └─ overlook agents, dashboard model, row commands
```

| Package | Responsibility |
|---|---|
| `cmd/overlook-remoted` | flags → `config.Config`, wiring, signals, graceful shutdown, periodic state saves |
| `internal/config` | flag parsing and validation, defaults |
| `internal/auth` | token file (re-read when its mtime changes), Bearer middleware, constant-time compare |
| `internal/bridge` | socket listener, framing, JSON-RPC envelopes, typed calls to Emacs, bridge wire types |
| `internal/store` | everything derived: dashboard versions, conversations, activity items, unread/read, images, uploads, unified diffs; browser wire types |
| `internal/api` | REST handlers, validation, problem+json, idempotency receipts, confirmation tokens, ETags, compression |
| `internal/stream` | SSE subscriptions, 200 ms coalescing, gzip-per-event, heartbeats |
| `internal/assets` | page from the embedded FS or `-web-dir`: hashing, precompression and its disk cache, import map, CSP, cache headers, reload on change |
| `internal/state` | the state file: format version, atomic 0600 writes, loading |
| `internal/launchd` | listening sockets launchd holds for the job (`-listen launchd:<name>`) |
| `internal/admin` | admin socket: line-delimited JSON `status`, `watch`, `set-awake`; server and client |
| `internal/awake` | keeping the Mac awake with `caffeinate -i -w <pid>`, restarted if it dies |
| `internal/settings` | the settings file (keep-awake), atomic 0600 writes |
| `internal/netaddr` | the address a phone should open (Tailscale, else `en*`) |
| `internal/fakeemacs` | bridge client double that replays fixtures and answers requests |
| `web` | page sources and `embed.go` |
| `menubar` | the menu bar app, a Swift package (macOS only): `MenubarCore` holds flags, status → menu model, page URL, launchctl, the admin client and the QR code; `overlook-menubar` draws it with AppKit |

Dependency direction: `api → stream → store → bridge` (types only), `api →
bridge` (calls), `assets → web`. `bridge` imports nothing internal.

## State ownership

| State | Owner | Lifetime |
|---|---|---|
| Agents, buffers, prompt queue and its delivery, choices, forms, controls, row commands and their closures | Emacs | Emacs process |
| Emacs epoch | Emacs (`defvar`, made once per process) | Emacs process |
| Serialized dashboard tree, conversation states | Emacs publishes; daemon keeps the latest copy | until replaced |
| Node ids, node hashes, dashboard versions (≥ 32) | daemon | state file |
| Activity items, `seq`, text marks, history floor, retention (300/conversation) | daemon | state file + Emacs epoch |
| Read positions, unread counts | daemon | state file + Emacs epoch |
| Idempotency receipts (512, 1 h), confirmation secret | daemon | state file (receipts + Emacs epoch) |
| Images (content-addressed) | daemon (`media/` beside the state file, 0700) | state file, LRU-bounded |
| Uploads | daemon (same directory) | until handed to Emacs |
| Compressed page files | daemon (`-cache-dir`, by content hash) | pruned after 7 days unused |
| Unified diffs of tool calls | daemon (computed from `diffs`) | with the item |
| Unified diffs of dashboard nodes | Emacs computes on request (`git diff`) | per request |
| Keep-awake setting | daemon (`-settings-file`) | across restarts |
| Drafts, disclosure, scroll positions | page (memory only) | page lifetime |

"State file" means the daemon keeps it in memory and writes it to `-state-file`
(default `state.json` beside the socket) on shutdown and every 30 s when it
changed; without a state file it lives as long as the daemon process.

The **history epoch** (`epoch` in the browser API) names one run of daemon
`seq` numbers. It changes when Emacs reconnects with a different Emacs epoch,
and when the daemon starts without a readable state file. A page holding
another epoch gets a full reset.

## Data flows

### Page load

1. `GET /overlook/` → `index.html` (`no-cache`, ETag, CSP). Modules and vendor
   files load from content-hashed immutable URLs via the import map.
2. The page reads the token from `location.hash` and `GET /api/dashboard`
   (brotli/gzip). Response: `{emacs, known, sections}` with `ETag: "<known>"`.
3. The page opens `GET /api/stream?dashboard=<known>`. First event `hello`
   (`protocol`, `epoch`, `emacs`); nothing else until something changes.

### Dashboard change

1. A model change in Emacs → the bridge serializes the whole tree (no hashes),
   at most every 0.5 s, and sends `dashboard.set`, unless the JSON text equals
   the last one sent.
2. The store assigns ids (`hash(parentId, key)`), overlays `unreadCount` on
   agent nodes, hashes nodes bottom-up, and records a version if the root hash
   changed.
3. The stream hub marks dashboard subscribers dirty; ≤ 200 ms later each gets
   one `dashboard` event with only nodes whose hash it lacks (others as
   `{same: hash}`), `id:` carrying the new cursor.

### Streaming reply

1. agent-shell chunk → `overlook-agent-event 'text` → bridge sends
   `agent.event` (adjacent chunks may be merged, ≤ 50 ms).
2. The store appends to the open text item, bumps `seq`, records a mark
   `(seq, length)`.
3. Subscribers of that conversation get, ≤ 200 ms later, a `conversation`
   event whose item carries only the appended suffix and its `offset`.
   Conversation state is included only if its hash changed.

### Sending a prompt while busy

1. `POST /conversations/{id}/prompts` with `Idempotency-Key`.
2. The api checks receipts, then calls `conversation.prompt`.
3. Emacs: queue empty and agent ready → submit; else append `{id, text}` to its
   queue. It flushes the resulting `conversation.set` **before** responding.
4. Daemon answers `{delivery: "queued", queueId}` and stores the receipt; the
   stream already carries the new queue.
5. Later Emacs's queue timer submits it: `conversation.set` (queue shorter) and
   `agent.event prompt`. Withdrawal before that: `DELETE …/prompts/{queueId}`
   → `conversation.unqueue`; after delivery → 409 `already_sent`.

### Confirmation flow (session actions and node commands)

1. `POST …/actions {action, text}` (or `/nodes/{node}/commands/{name}`).
2. Daemon forwards with `confirmed: []`. Emacs runs the operation with
   `y-or-n-p`/`yes-or-no-p` rebound; the first question not in `confirmed`
   aborts it and returns `{outcome: "confirm", question}`.
3. Daemon returns `{outcome: "confirm", question, confirmations: [...q],
   confirmationToken}`; token = HMAC(secret, target, operation, input,
   confirmation-state hash, confirmations).
4. Page asks the user, re-POSTs with the same `Idempotency-Key`,
   `confirmations` and token. A valid token → forwarded as `confirmed`; an
   invalid one (state changed) → forwarded as `[]`, restarting the sequence.
5. `outcome: "done"` is stored as the receipt; confirm outcomes never are.

### Emacs restart or disconnect

1. Socket closes → store marks Emacs offline, keeps the last snapshot; streams
   get `status {emacs: "offline"}`; writes return 503 `emacs_offline`.
2. Emacs reconnects: `hello` (Emacs epoch, events lost while disconnected).
   - Same epoch (bridge hiccup, daemon still running): store keeps items and
     read positions; `sync` replaces dashboard and conversation states;
     buffered events replay; if any were lost, open text items are closed.
   - New epoch (Emacs restarted): store drops conversations, items, read
     positions, receipts; new history epoch. Streams on vanished conversations
     get `gone`; dashboard subscribers get a delta.
3. `status {emacs: "online"}` once `sync` is applied.

### Daemon restart

1. On SIGTERM the daemon ends the streams, disconnects Emacs and writes the
   state file. launchd keeps the listening socket open (decision 22), so new
   connections wait in its backlog instead of being refused.
2. The new daemon loads the state file (unknown format or unreadable → logged
   and ignored), reads compressed page files from `-cache-dir`, removes a stale
   bridge socket, and serves within tens of milliseconds, `emacs: offline`
   until Emacs syncs.
3. Emacs sees EOF, reconnects after 0.5 s, `hello`: the same Emacs epoch keeps
   the restored history (same history epoch), `sync` replaces the states,
   buffered events continue the `seq` numbering; a new Emacs epoch discards it
   as under "Emacs restart".
4. Pages reconnect the stream with their cursors and get only what changed
   while they were away; with no state file they get the reset described
   above.

### Updating the daemon

`deploy/deploy.sh` builds, vets and tests the checkout, runs the new binary on
a spare loopback port with a copy of the state file, then swaps it in (keeping
`overlook-remoted.prev`), `launchctl kickstart -k`s the agent and waits for
`/overlook/healthz` to report the new `daemon` version (and Emacs online if it
was before); otherwise it restores `.prev` and restarts again. With `-web-dir`
the page needs no deploy: the next page load picks up edited files.

## Design decisions

1. **Standalone daemon, Emacs as a bridge client.** Emacs is single-threaded:
   GC pauses, long commands and per-client JSON work stalled every browser in
   the old server. The daemon serves while Emacs is busy or gone.
   *Rejected:* keeping simple-httpd (no TLS, HTTP/2, compression; per-client
   work in Emacs); Emacs as a child of the daemon over stdio (the daemon must
   outlive Emacs restarts).
2. **Unix socket, NDJSON, JSON-RPC 2.0.** Socket permissions (0600 in 0700) are
   the authentication; Emacs has `make-network-process :family 'local` and
   native JSON; NDJSON is trivially framed and debuggable with `socat`.
   *Rejected:* `emacsclient` (process per call, eval strings are an injection
   surface, no push, collides with the user's server); loopback TCP (any local
   user can connect); protobuf/gRPC (dependencies on both sides).
3. **Emacs publishes whole states, daemon derives deltas.** Emacs sends the
   dashboard tree and each conversation's state whole, dropping identical
   consecutive payloads by string comparison. Hashing, versions, per-client
   deltas and history are Go's. *Rejected:* JSON Patch from Emacs (needs diffing
   in Emacs, defeats the point).
4. **Raw agent events cross the bridge; items are built in Go.** The item
   model (text merge, tool merge by id, marks, retention) moves to the store.
   Unified diffs are computed in Go from `{file, old, new}` (the old server
   forked `diff` per tool call). Image paths in text are resolved by the daemon
   against the conversation's `root`, with magic-byte checks.
5. **The prompt queue stays in Emacs.** Delivery depends on `ready-p`, which
   only Emacs knows, and must continue while the daemon is down.
6. **Snapshot, then one SSE stream per page.** GETs are cacheable (ETag) and
   compressed; the stream carries deltas only, `id:` holds the resume query, so
   a reconnect after a drop sends nothing that is unchanged. *Rejected:*
   long-poll (a request plus headers per change, hold bookkeeping);
   WebSocket (bidirectionality unneeded for human-paced writes, no stdlib
   server, per-message deflate complexity, worse with proxies); `EventSource`
   (cannot send `Authorization`, would put the token in URLs) — the page reads
   SSE with `fetch` streaming.
7. **Combined `conversation` events.** State (only on hash change) and new items
   travel in one event per flush, keeping them atomic and framing small.
8. **gzip per SSE event, flushed; brotli for snapshots.** gzip sync-flush keeps
   the dictionary across events (repeated keys cost little). A flag disables it
   if iOS misbehaves. Static assets are precompressed once at startup.
9. **Content-addressed images.** `GET /images/{image}` where `image` is a
   content hash: immutable caching, dedupe across conversations, survives
   re-renders. *Rejected:* sequential numbers (old), which needed a file stamp
   table and could not be cached forever.
10. **Confirmation tokens in the daemon, questions in Emacs.** Emacs stays
    stateless about confirmations; the daemon binds them to a state hash that
    ignores volatile fields (`brief`, `context`, `subtitle`, `unreadCount`) so a
    working agent's ticking brief does not restart the sequence.
11. **Idempotency receipts in the daemon, keyed by `Idempotency-Key`.** A
    duplicate arriving while the first is in flight waits for it. A bridge
    timeout leaves the call pending; a late result is still recorded, so the
    retry replays it instead of executing twice. Receipts are checked before
    resource existence, so replaying a successful close works after the
    conversation is gone.
12. **Read-your-writes.** Emacs flushes pending notifications before writing a
    response; the daemon applies everything preceding a response before
    answering HTTP. A new conversation returned by a command is therefore
    already in the store.
13. **Events buffered in Emacs while disconnected** (bounded); `hello` reports
    how many were dropped. Cheap, and avoids silent holes on a bridge hiccup.
14. *(Superseded by 21.)* **No disk persistence in the daemon.** History is best-effort, bounded and
    tied to the Emacs epoch; after a daemon restart the page shows the last
    reply and transcript tail (`earlier`), as the old page did for activity from
    before recording began.
15. **Dropped from protocol 2:** `protocolVersion` in bodies (header
    `Overlook-Protocol: 3` and the stream `hello` instead), `queued` string
    list, problem `error`, `bufferName`, buffer-name ids, legacy row data,
    `resourceId`/`projectId`/`repositoryId`/`taskId`/`conversationId`/`path`/
    `from`/`context`/`duration*` on nodes (unused by the page), `latestSeq`,
    `confirmed` boolean, command `version`, `reply`/`transcript` on every
    conversation (now `earlier`, only when no items are retained), base64
    uploads (raw bytes now). `controls.model/models` are replaced by
    `controls.settings` (in-flight change in the old code: model and effort).
16. **Renames for clarity:** `agent` (provider name) → `provider`, node `agent`
    → `conversation`, `queueItems` → `queue`, `/api/seen` → `PUT …/read`.
17. **Empty optional arrays and false booleans are omitted** on the wire,
    browser and bridge alike; readers treat absence as empty/false.
18. **Listeners:** `-listen` and `-listen-tls` are repeatable; auto-close
    applies only to non-loopback listeners. One token file shared with the old
    server so the Home Screen link survives switchover.
19. **Dependencies:** stdlib, plus `github.com/andybalholm/brotli` and
    `github.com/pmezard/go-difflib` (phase 2 adds them to `go.mod`). The
    menu bar app is Swift with system frameworks only.
20. **Embedding:** `web/embed.go` embeds `*`; `assets` serves only page files
    (skips `*.go`, `test/`, dot files), so page tests can live under `web/test/`.
21. **State file.** Agents restart the daemon from the phone while the phone
    uses it, so a restart must not reset the page. The store, receipts and
    confirmation secret are written as versioned JSON (`internal/state`,
    format 1) via a temporary file and rename, 0600, on graceful shutdown and
    every 30 s when changed; images move from a temp dir to `media/` beside
    it. Kept only while the Emacs epoch matches, so it never outlives the
    Emacs it describes. Tool-call `diffs` inputs are not saved (the rendered
    diff is), so the next event carrying them recomputes the same diff.
    *Rejected:* gob (opaque, brittle across struct changes); SQLite or an
    append log (a dependency, and whole-state snapshots are a few MB at most);
    saving on every change (a write per streamed chunk).
22. **launchd socket activation, called without cgo.** The plist's `Sockets`
    entry makes launchd own the listening socket; the daemon takes it with
    `launch_activate_socket(3)` (`-listen launchd:http`). During a restart or a
    crash the socket stays open and connections queue: measured with a
    throwaway label, 2158 requests across three `kickstart -k` restarts, none
    refused, slowest 44 ms; the same plist with a plain `-listen` refused 435
    of 2118. The call goes through the runtime's libc trampolines with
    `//go:cgo_import_dynamic`, as `golang.org/x/sys/unix` does, so builds stay
    `CGO_ENABLED=0`-clean and cross-compile. *Rejected:* a cgo shim (needs a C
    toolchain, breaks cross builds); handing listener fds to a re-exec'd child
    (launchd tracks the parent, KeepAlive would fight it); SO_REUSEPORT
    overlap (launchd does not start a second instance of a job). `-auto-close`
    refuses launchd sockets, since launchd keeps them open regardless.
23. **Precompressed page files cached on disk, and `-web-dir`.** Brotli 11 of
    the page took 1.3 s per start; variants are now stored by content hash in
    `-cache-dir` (default the user cache directory), so a start takes about
    11 ms. `-web-dir` serves `remote/web` from disk: each request that the
    browser revalidates (the page, stable routes, unhashed or unknown asset
    URLs) compares a stat fingerprint of the directory and rebuilds on change,
    compressing changed files at brotli 5 at once and at full quality in the
    background; the previous three builds keep their hashed URLs so a page
    loaded just before an edit finishes loading. Hashed immutable URLs, the
    import map and the CSP are recomputed on each rebuild. *Rejected:* fsnotify
    (a dependency for what a stat walk of 50 files does in well under a
    millisecond).
24. **`healthz` reports the daemon's version** (`daemon`), so `deploy.sh`
    knows the restarted process is the new binary rather than the old one
    still answering.
25. **The daemon keeps the Mac awake, with caffeinate.** Remote is useful only
    while the Mac is awake, and the daemon is what runs whenever remote does,
    so it owns the assertion instead of Emacs. `caffeinate -i -w <daemon
    pid>` needs no cgo (IOKit's `IOPMAssertionCreateWithName` would), and
    exits by itself when the daemon dies, so a crash cannot leave the Mac
    awake; the daemon kills it when turned off and restarts it if it dies.
    The setting lives in its own `settings.json`, not the state file, which
    is dropped with the Emacs epoch. *Rejected:* Emacs's `system-sleep`
    (tied to Emacs running, not remote); IOKit through the libc trampoline
    trick of decision 22 (CoreFoundation strings and retain/release by hand
    for no gain).
26. **Admin socket beside the bridge socket.** Local tools need status and
    control without the page's token: a second unix socket, 0600 in the
    same 0700 directory, line-delimited JSON like the bridge, with `watch`
    pushing a status whenever it changes (Emacs, stream count, keep-awake,
    or the address, rechecked every 5 s). *Rejected:* more HTTP endpoints
    (reachable from the network, would need the token, and `healthz` must
    stay token-free and small); polling `healthz` from the menu.
27. **The menu bar app is a separate process, and its Quit stops the
    daemon.** Keeping it in its own process lets either restart without the
    other: a deploy of the daemon does not make the icon flicker, and a UI
    crash does not take remote down. Quit means "turn remote off" (bootout
    of the daemon, then exit 0); a crash or a signal does not, and the app's
    `KeepAlive = {SuccessfulExit = false}` restarts it after a crash but not
    after Quit. *Rejected:* the menu inside the daemon (AppKit and cgo in
    the daemon, every deploy flickers the icon, a UI crash takes remote down).
28. **The menu bar app is Swift, not Go.** AppKit from Go needs cgo and a
    systray wrapper; Swift gets AppKit, SF Symbols (template icons macOS
    tints for light and dark menu bars), CoreImage's QR generator and its
    own window natively, in a 380 KB binary instead of 5 MB. The QR code is
    drawn in memory into the app's window (Escape or ⌘W closes it and drops
    the image), so the token never touches disk. It stays an unbundled
    executable with flags matching the old Go app, so the LaunchAgent plist
    and `deploy.sh`'s swap-and-rollback stay as they were; the two sides
    share only the admin socket's JSON. Release builds are reproducible, so
    `deploy.sh` still detects a changed app with `cmp`. *Rejected:* Go with
    `fyne.io/systray` (the first version: cgo, a temporary PNG shown with
    Quick Look); a bundled `.app` with `SMAppService` for Start at Login
    (signing, and the daemon's plist would have to move into the bundle,
    away from `deploy.sh`).
29. **File links download through short-lived tickets.** `POST
    /conversations/{c}/files` offers a file only when the link target appears
    in that conversation's retained text (or the earlier reply) and names a
    regular file, and returns its size, which the page shows in a confirmation
    before downloading. The download itself is `GET
    /overlook/files/<ticket>/<name>`, outside the authenticated API: the random
    ticket works for 10 minutes and is the credential, so the browser can
    stream a large file to disk as a plain navigation, with `Range`, and
    without the 2-minute write deadline. *Rejected:* fetching with the token
    into a blob (the whole file in the phone's memory before saving); serving
    any path the token holder names (the mention check keeps a leaked token
    from reading the disk directly); copying files into the media store like
    images (no size bound fits arbitrary files).

## Deployment

The daemon runs as a launchd LaunchAgent (`deploy/overlook-remoted.plist.in`,
rendered by `deploy/install.sh`) that owns the listening socket; updates go
through `deploy/deploy.sh`. The menu bar app is a second LaunchAgent
(`deploy/overlook-menubar.plist.in`, RunAtLoad, restarted only after a crash)
that bootstraps the daemon when it starts and boots it out on Quit;
`deploy.sh` builds it with `swift build -c release`, runs `swift test` and
swaps and restarts it when the binary changed, rolling it back if it does not
stay up. Running it, TLS with `tailscale cert`, enabling
`overlook-remote-bridge-mode` and updating remote from remote are in
`../README.md`.
