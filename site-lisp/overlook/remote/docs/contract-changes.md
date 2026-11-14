# Contract changes

Additive changes to the phase 1 contract made during phase 2, one entry each.

## Page assets: import map, asset references, CSP (page agent)

`architecture.md` names an import map rendered into `index.html` without saying
how. The page relies on this mechanism; `internal/assets` implements it and the
page's Node test server (`remote/webtest/server.mjs`) mirrors it.

- **Import map placeholder.** `index.html` contains the exact line
  `<!-- overlook:importmap -->` in `<head>`, before any module script. The
  daemon replaces it with
  `<script type="importmap">{"imports":{…}}</script>`.
- **Import map entries.** One per served `*.js` file: the key is the file's
  path relative to `web/` (e.g. `js/api.js`, `vendor/marked.js`), the value its
  hashed URL (e.g. `/overlook/assets/js/api.3f9a1c2b.js`). Modules import each
  other only by these keys (`import { api } from "js/api.js"`), never by
  relative paths, so hashed URLs never need relative resolution.
- **Other references in `index.html`.** Any `src="…"` or `href="…"` attribute
  value starting with `assets/` names a web file (`assets/` + path relative to
  `web/`) and is rewritten to that file's hashed URL, e.g.
  `href="assets/app.css"` → `href="/overlook/assets/app.4be1d0aa.css"`.
  Absolute values (the stable routes `/overlook/icon.svg`, …) stay as they are.
- **Hashed URL form.** `/overlook/assets/<dir>/<name>.<hash>.<ext>`; any hash
  length works for the page.
- **CSP** of `index.html`, as the page needs it:
  `default-src 'self'; script-src 'self' 'sha256-<base64 of the import map
  script's text>'; style-src 'self'; img-src 'self' blob: data:; font-src 'self'
  data:; connect-src 'self'; manifest-src 'self'; object-src 'none';
  base-uri 'none'; form-action 'none'; frame-ancestors 'none'`.
  `blob:` is for authenticated images and upload previews (fetched with the
  token, shown as object URLs), `data:` for provider icons and Framework7's
  embedded font and SVG backgrounds. The page sets styles only through CSSOM,
  never `style` attributes or inline `<style>`.
- **Served files.** The page ships `remote.webmanifest`, `icon.svg`,
  `icon-180.png`, `icon-192.png`, `icon-512.png` at the root of `web/` for the
  `Stable` routes, and licence files under `vendor/` (served like any file;
  harmless). Page tests live in `remote/webtest/`, outside `web/`.

## Daemon behaviour the contract left open (Go daemon agent)

Clarifications only; no wire shapes changed.

- **Node paths use disambiguated keys.** `node.command`/`node.diff` `path`
  entries are the keys after the daemon's `#2`, `#3`, … suffixing, so a
  duplicate sibling is addressable (the bridge already resolves them this way).
- **`gone` ends a conversation-only stream.** A stream that also follows the
  dashboard stays open and keeps sending dashboard events; its later `id:`
  carries no conversation cursors.
- **`after=0` with the current epoch is a delta, not a reset:** every retained
  item, in full. Reset happens only for another epoch, `after` ahead of the
  server, or `after` below the history floor (as specified).
- **Conversation `known` covers `unreadCount` and `readThrough`**, so a read
  position change resends the conversation state (once per change).
- **Snapshot/delta `seq`** is the conversation's latest change, not the global
  counter, so its ETag stays stable while other conversations stream.
- **Events for a conversation not yet published** (an `agent.event` arriving
  before its first `conversation.set`) are kept and shown once the state
  arrives; they are dropped by the next `sync` if it does not list it.
- **Choice keys are not pre-validated** by the daemon (dashboard rows and
  conversation states may lag each other); Emacs answers 409 `state_conflict`.
  The form id is pre-validated against the published state.
- **API caching headers:** ETag'd GETs are `private, no-cache`; other API
  responses `no-store`; API responses carry `Content-Security-Policy:
  default-src 'none'; frame-ancestors 'none'`.
- **Assets:** hashed URL hash is 10 hex characters; unhashed
  `/overlook/assets/<path>` also works (`no-cache` + ETag); relative `url()`
  references in CSS are rewritten to hashed URLs; if the placeholder is
  missing, the import map is inserted right after `<head>`.
- **Browser tests:** `overlook-remoted -fake-emacs <fixtures dir>` runs the
  fake Emacs in-process on the daemon's socket (`-fake-speed`,
  `-fake-live-delay`, negative = only on demand); `kill -USR1 <pid>` replays
  `live.ndjson`. `go run ./cmd/fakeemacs -socket … -fixtures …` does the same
  against a separately started daemon.

## Integration (phase 3)

No wire shapes changed; these are behaviours the contract left open.

- **Bridge writes in pieces.** Emacs writes at most 8000 bytes to the socket
  per turn of its event loop and queues the rest, in order. A write the
  socket cannot take whole makes Emacs sleep 20 ms, and macOS gives local
  sockets 8 KiB, so a 16 KiB dashboard used to cost Emacs ~45 ms. Events
  still queued when the connection closes count in the next `hello.lost`.
- **Handshake timeout.** Emacs drops a connection whose `hello` gets no
  answer within `overlook-remote-bridge-hello-timeout` (10 s) and retries
  with the usual backoff.
- **Dashboard interval.** Emacs sends `dashboard.set` at most every
  `overlook-remote-bridge-dashboard-interval` (0.5 s; serializing a large
  dashboard takes tens of ms). Before answering a request it sends a changed
  dashboard regardless, so read-your-writes still holds for dashboard changes
  a request causes.
- **Read positions from the page** go at most every 2 s per conversation
  while a reply streams; a held position is sent at once when the page leaves
  the conversation or is hidden. Each `PUT …/read` also resends the
  conversation state to every stream, so per-update reads tripled the bytes
  of a streamed reply.

## Self-update safety (phase 3b)

- **`healthz` carries `daemon`**, the build version (additive, in
  `openapi.yaml`); `deploy.sh` uses it to see the new binary answer.
- **The history epoch survives daemon restarts** when the state file is
  readable and Emacs reconnects with the same Emacs epoch: page cursors stay
  valid, so a restart sends deltas instead of `reset`. Without a state file
  (`-state-file ""`) the old behaviour holds.
- **Listen addresses** may be `launchd:<name>`, a `Sockets` entry of the
  LaunchAgent plist, for `-listen` and `-listen-tls`.
- **Browser tests:** `-fake-resume` makes the in-process fake Emacs reconnect
  without replaying `events.ndjson`, like Emacs after a daemon restart.
