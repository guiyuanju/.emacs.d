# overlook remote rewrite: standalone Go server

Working plan for the rewrite. Every agent on this work reads this first.

## Goal

Replace the HTTP server embedded in Emacs (`overlook-remote*.el` on simple-httpd)
with a standalone Go daemon. Emacs keeps the domain (agents, dashboard model,
commands); the daemon owns everything about serving browsers. Transport must be
as efficient as possible: fewest bytes, fewest connections, no redundant
payloads. A full architectural rewrite is allowed; protocol compatibility with
the old page is not required.

## Hard constraints: the user is using the old remote right now

- Work only in this worktree: `~/.emacs.d.worktrees/overlook-remote-go`
  (branch `overlook-remote-go`). Never edit `~/.emacs.d` itself.
- Never talk to the user's running Emacs: no `emacsclient`, no `server-*`, no
  loading files into it. For an Emacs under test use `emacs -Q --batch`, or a
  separate daemon `emacs -Q --daemon=overlook-remote-dev` that you start and stop.
- Never bind or kill anything on ports 8765 (MacControl) and 8766 (live remote).
  Dev servers use `127.0.0.1:8767` or random ports in tests. Only kill
  processes you started.
- Do not modify the old `overlook-remote*.el`, `overlook-remote.html` or their
  tests; they keep working until switchover. New Elisp goes in new files.
- Do not commit. Leave changes in the worktree for review.
- Several agents work in this worktree at once: touch only the paths you own
  (see Phases). If a shared contract must change, make the smallest additive
  change, and record it in `remote/docs/contract-changes.md`.

## Architecture

```
iPhone Safari ──HTTP(S)/SSE──▶ overlook-remoted (Go, launchd)
                                   │  unix socket, NDJSON JSON-RPC 2.0
                                   ▼
                               Emacs: overlook-remote-bridge.el
```

### Go daemon `overlook-remoted` owns

- HTTP serving: stdlib `net/http` (Go 1.22+ method/pattern `ServeMux`), graceful
  shutdown, `log/slog`, context cancellation, timeouts on every server.
- Auth: Bearer token read from the existing token file (same path as now, so the
  phone's Home Screen link keeps working); constant-time compare.
- Static assets: `embed.FS`; content-hashed URLs with
  `Cache-Control: public, max-age=31536000, immutable`; HTML `no-cache` + ETag;
  brotli and gzip precompressed once at startup; import map for ES modules
  rendered into the HTML with hashed URLs. Security headers: strict CSP
  (`script-src 'self'` plus the import map's hash), `X-Content-Type-Options`,
  `Referrer-Policy: no-referrer`, `frame-ancestors 'none'`.
- Derived state, in memory and kept across restarts in a state file: dashboard
  tree versions and node-hash deltas; per-conversation activity items (seq,
  text offsets, history paging, retention); unread counts and read positions;
  idempotency receipts; uploaded files; unified diffs for tool calls (computed
  in Go, not by Emacs).
- Fan-out to any number of browsers; 200 ms coalescing of bursts.
- Exposure policy: listen addresses from flags/config; optional auto-close of
  non-loopback listeners after N minutes; optional TLS (`tailscale cert` files)
  which enables HTTP/2.
- When Emacs is disconnected: still serves the page and the last snapshot, and
  reports `emacs: offline` so the page shows it instead of spinning.

### Emacs `overlook-remote-bridge.el` owns

- Connecting to the daemon's unix socket and reconnecting with backoff; a
  global minor mode `overlook-remote-bridge-mode`.
- Publishing domain state, cheaply: serialized dashboard tree when the model
  changes; a conversation's state when it changes; raw agent events as they
  happen. No hashing, deltas, history or per-client work in Emacs.
- Executing commands the daemon forwards: prompt (and its queue while the agent
  is busy), unqueue, retry, session actions with confirmations, choices, forms,
  node commands, marking seen.
- Reload safety per repo rules: state in `defvar`, named hook functions, no new
  `cl-defstruct`.

### Bridge protocol

Newline-delimited JSON over a unix socket (mode 0600 in a 0700 directory; the
socket permissions are the bridge's authentication). JSON-RPC 2.0 shapes:
notifications Emacs → daemon for state and events, requests daemon → Emacs for
commands with responses. A `hello` handshake carries protocol version and the
Emacs epoch; a new epoch resets daemon-side conversation state. Full message
catalogue: `remote/docs/bridge-protocol.md` (written in phase 1).

### Browser API (protocol 3)

REST under `/overlook/api/`, specified in `remote/api/openapi.yaml` (OpenAPI
3.1, the source of truth). Errors are RFC 9457 problem+json with stable codes.
Writes take an `Idempotency-Key` header. GET resources carry ETags.

| Method + path | Purpose |
|---|---|
| `GET /dashboard` | snapshot, with `known` cursor |
| `GET /stream?dashboard=<known>` or `?conversation=<id>&after=<seq>&known=<hash>&epoch=` | the page's one SSE stream: deltas only, `id:` carries the cursor |
| `GET /conversations`, `GET /conversations/{id}` | list, snapshot with first history page |
| `GET /conversations/{id}/history?before=&limit=` | older pages |
| `POST /conversations/{id}/prompts` | send or queue |
| `DELETE /conversations/{id}/prompts/{queueId}` | withdraw queued |
| `POST /conversations/{id}/prompts/retry` | retry failed queue |
| `PUT /conversations/{id}/read` | read position |
| `POST /conversations/{id}/actions` | session actions incl. confirmation flow |
| `POST /conversations/{id}/choice` | permission choice |
| `POST /conversations/{id}/forms/{formId}` | answer or decline a question form |
| `POST /conversations/{id}/attachments` | raw image bytes, `Content-Type: image/*` |
| `GET /images/{n}` | immutable, ETag |
| `GET /nodes/{node}/diff` | |
| `POST /nodes/{node}/commands/{name}` | dashboard node commands incl. confirmation |
| `GET /overlook/healthz` | unauthenticated liveness |

Transport rules:

- Snapshot first (compressed GET), then one SSE stream per page that subscribes
  only to what the page shows. Changing page = close and reopen with cursors; an
  unchanged resource sends nothing.
- SSE is compressed (gzip, flushed per event) when the client accepts it; keep a
  flag to disable it in case iOS misbehaves. Heartbeat comment every 25 s.
- Conversation state is sent only when its hash changes; reply text only as the
  appended suffix; dashboard only changed nodes (keep at least 32 versions).
- No long polling, no WebSocket (writes are human-paced; not worth it).
- Drop fields kept only for compatibility in protocol 2 (`queued`, problem
  `error`, legacy row data, buffer-name ids).

### Page

Rewrite as native ES modules, no build step, Framework7 iOS theme kept (vendored;
trim to the used components if measurably smaller). Behaviour follows
`docs/remote-ui.md` of the old page; read the old `overlook-remote.html` as the
reference for every feature. Explicit state module instead of scattered
globals; one module per page/area (api, stream, state, router, ui, dashboard,
conversation, compose). Tests: `node --test` units plus Playwright (already
installed: `require('playwright')`) end-to-end against the Go daemon with the
fake Emacs.

### Layout (inside `site-lisp/overlook/`)

```
remote/
  go.mod                      module github.com/guiyuanju/overlook/remote
  cmd/overlook-remoted/       main
  internal/...                config, auth, bridge, store, api, stream, assets
  internal/fakeemacs/         bridge test double, also used by browser tests
  api/openapi.yaml
  docs/                       plan.md, architecture.md, bridge-protocol.md
  web/                        index.html, css, js modules, vendor/, embed.go
overlook-remote-bridge.el
test/overlook-remote-bridge-test.el
```

Dependencies: prefer stdlib. Allowed: `github.com/andybalholm/brotli`, a unified
diff library (e.g. `github.com/pmezard/go-difflib`). Anything else needs a
reason in `architecture.md`.

Quality bar: `go vet`, `go test -race ./...`, table-driven tests, `httptest`;
`make test` and `make lint` in `site-lisp/overlook` stay green (wire new
targets in only when they pass). Comments follow the repo rule: no restating the
code, no change history, one sentence (three at most).

## Phases

1. **Contract** (one agent). `architecture.md`, `bridge-protocol.md`,
   `openapi.yaml`, Go module skeleton (packages, shared types, interfaces, stub
   main that builds), `web/embed.go`, a fixture data set. Owns `remote/` until
   done.
2. **In parallel**, each owning only its paths:
   - **Go daemon**: `remote/cmd`, `remote/internal`, `remote/go.*`.
   - **Emacs bridge**: `overlook-remote-bridge.el`, its test file. May copy
     serialization logic out of the old `overlook-remote-model.el` /
     `-activity.el` / `-service.el` (those get deleted after switchover), but not
     edit them.
   - **Page**: `remote/web/` except `embed.go`, page tests under `remote/web/test/`.
3. **Integration** (one agent): real Emacs daemon (dev) + Go daemon + browser,
   fix seams, measure bytes for page load / launch / streaming / dashboard vs. the
   old server, launchd plist template, wire tests into `make test`, docs.
3b. **Self-update safety** (one agent): the daemon can be changed and restarted
   from the phone while the phone uses it: `-web-dir`, a state file, launchd
   socket activation, a disk cache of compressed page files, `deploy/deploy.sh`
   with rollback (decisions 21–24 in `architecture.md`).
4. **Switchover** (main session, only with the user's approval): parallel run on
   a second port, then the daemon takes 8766 with the same token file and path so
   the Home Screen link survives; move `iuiw-notify-overlook` and `iuiw-remote`
   off `overlook-remote-mode`; rollback = stop daemon, re-enable the old mode.
   Old Elisp is deleted in a later, separate step.
