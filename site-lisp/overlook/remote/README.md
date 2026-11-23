# overlook-remoted

Serves the overlook remote page to a phone. Emacs publishes the dashboard and
agents to it over a unix socket (`overlook-remote-bridge-mode`); the daemon
owns HTTP, TLS, compression, history and fan-out. Design: `docs/plan.md`,
`docs/architecture.md`; wire contracts: `docs/bridge-protocol.md`,
`api/openapi.yaml`; byte and cost numbers: `docs/measurements.md`.

## Running

```sh
cd site-lisp/overlook/remote
go build -o /tmp/overlook-remoted ./cmd/overlook-remoted
/tmp/overlook-remoted -token-file ~/path/to/overlook-remote-token -listen 127.0.0.1:8767
```

Flags (`-h` lists them all):

| Flag | Meaning |
|---|---|
| `-token-file` | Bearer token file, shared with Emacs (`overlook-remote-token-file`); re-read when it changes. Required. |
| `-listen` | plain HTTP address, repeatable; default `127.0.0.1:8767`; `launchd:<name>` takes the socket of the plist's `Sockets` entry |
| `-listen-tls`, `-tls-cert`, `-tls-key` | HTTPS address(es) (also `launchd:<name>`) and key pair; enables HTTP/2 |
| `-socket` | bridge socket; default `${XDG_RUNTIME_DIR:-~/.local/state}/overlook-remote/bridge.sock` |
| `-admin-socket` | control socket for the menu bar app (below); default `admin.sock` beside `-socket`; `""` disables it |
| `-caffeinate` | command that keeps the Mac awake while the daemon runs (default `/usr/bin/caffeinate` on macOS); `""` never does |
| `-settings-file` | keeps the keep-awake choice across restarts; default `settings.json` beside `-socket`; `""` keeps it in memory |
| `-state-file` | state kept across restarts (history, read positions, receipts, images in `media/` beside it); default `state.json` beside `-socket`; `""` keeps nothing |
| `-cache-dir` | compressed page files by content hash, so starts take ~10 ms; default `~/Library/Caches/overlook-remoted`; `""` disables |
| `-web-dir` | serve the page from this directory (e.g. `remote/web`) instead of the binary, picking up edits on the next page load |
| `-emacs-start` | command (split on spaces) that starts Emacs after a crash or on request, e.g. `/usr/bin/open -a Emacs`; default empty: Emacs is not supervised beyond being reported |
| `-auto-close` | minutes after which non-loopback listeners close (0 never; not with `launchd:` sockets) |
| `-stream-compression` | gzip the event stream (default true; `=false` if iOS misbehaves) |
| `-debug` | debug logging |

The page is `http://HOST:PORT/overlook/#TOKEN`, the same address the old
server used, so a Home Screen link keeps working once the daemon takes the old
port. `GET /overlook/healthz` answers without a token and says whether Emacs is
connected.

## Watching Emacs

With `-emacs-start` the daemon watches the Emacs process behind the bridge
(details: `docs/bridge-protocol.md` section 11):

- **Crash.** Emacs says `bye` before it disconnects on purpose (quitting,
  SIGTERM, or turning `overlook-remote-bridge-mode` off). A process that
  disappears without it has crashed, and the daemon starts Emacs again with
  `-emacs-start`. More than 3 crashes within 10 minutes stop that until a
  manual restart.
- **Not responding.** A connected Emacs that misses two pings in a row (15 s
  apart) shows as not responding on the page and in the menu bar. The daemon
  never restarts it by itself.
- **Restart**, e.g. to apply init file changes: the page's **Restart Emacs**
  (dashboard footer, and the banner while Emacs is stuck or gone), the menu bar
  app's **Restart Emacs**, `{"op":"restart-emacs"}` on the admin socket, or
  `POST /overlook/api/emacs/restart`. Emacs saves its file buffers without
  asking and quits; a process still there after 30 s gets SIGTERM, then
  SIGKILL 10 s later; then the daemon starts Emacs. Buffers are not restored,
  and agents running in Emacs stop.

`GET /overlook/api/emacs`, the stream's `hello` and `status` events (`process`)
and the admin status (`emacsProcess`) carry the state: `online`,
`unresponsive`, `disconnected`, `restarting`, `stopped`, `crashed`, or
`unknown` before Emacs first connects.

## Keeping the Mac awake

While it runs, the daemon keeps the Mac from idle sleeping (the display still
sleeps) with `caffeinate -i -w <daemon pid>`: caffeinate exits by itself when
the daemon does, crash included, and the daemon restarts it if it dies. It is
on by default; the menu bar app's **Keep Mac Awake** (or `set-awake` on the
admin socket) turns it off and on, and the choice is kept in `-settings-file`.
Emacs no longer holds a sleep assertion for remote.

## Admin socket

`-admin-socket` (0600 in the same 0700 directory as the bridge socket, so its
permissions are the authentication; no token) speaks line-delimited JSON. Each
request is one line, each answer one line, `{"status": {...}}` or `{"error": "..."}`:

| Request | Answer |
|---|---|
| `{"op":"status"}` | the status |
| `{"op":"watch"}` | the status now and again whenever it changes, until the client disconnects |
| `{"op":"set-awake","on":false}` | turns keep-awake off (or on) and answers the new status |
| `{"op":"restart-emacs"}` | quits Emacs and starts it again (see Watching Emacs); answers the status once that is under way |

The status has `daemon` (version), `started`, `uptime` (seconds), `emacs`
(`online`/`offline`), `streams` (open page streams), `listeners`
(`addr`, `tls`, `loopback`), `awake` (the setting), `awakeHeld` (caffeinate
running), `emacsProcess` (the watched Emacs, with `-emacs-start`), and `scheme`, `host`, `port` for the page URL: the first
non-loopback plain HTTP listener's port, and the host a phone should use
(Tailscale's 100.64.0.0/10 address, else an `en` interface's). Try it with
`echo '{"op":"status"}' | nc -U -w 1 ~/.local/state/overlook-remote/admin.sock`.

## Menu bar app

`overlook-menubar` (`menubar/`, a Swift package, macOS only) shows remote in
the menu bar. The icon is an SF Symbols phone: with radio waves when Emacs is
connected, plain while it is not, struck through when the daemon is stopped.
The menu:

- **status line**: `Remote online`, `Emacs not connected` or `Remote stopped`, with the number of open pages.
- **Copy URL**: `http://HOST:PORT/overlook/#TOKEN` to the clipboard, the token read from `-token-file`.
- **Show QR Code**: the same URL as a QR code in a window of its own, made in memory; Escape or ⌘W closes it.
- **Keep Mac Awake**: the daemon's keep-awake setting.
- **Restart Emacs** (asks first), or **Start Emacs** after it quit or crashed; shown when the daemon has `-emacs-start`.
  The status line says when Emacs is not responding, restarting, crashed or quit.
- **Start at Login**: `launchctl enable`/`disable` of both the daemon's and the app's labels (read from `launchctl print-disabled`).
- **Restart Remote** (`launchctl kickstart -k`), or **Start Remote** while stopped.
- **Open Log**: the daemon's log in Console.
- **Quit and Stop Remote**: boots the daemon out (`launchctl bootout`), then quits.

Starting the app starts the daemon if needed (`launchctl bootstrap` of its
plist, or `kickstart` if loaded but not running). Only Quit stops the daemon:
the app's LaunchAgent restarts it after a crash (`KeepAlive` on unsuccessful
exit) without touching the daemon, and a Quit (exit 0) stays quit until the
next login or a manual `launchctl bootstrap`. It follows the daemon over the
admin socket's `watch` and reconnects every second while the daemon is down.

## Enabling Emacs

```elisp
(use-package overlook-remote-bridge
  :ensure nil
  :load-path "site-lisp/overlook"
  :custom
  ;; The same path as the daemon's -socket; launchd does not see XDG_RUNTIME_DIR.
  (overlook-remote-bridge-socket (expand-file-name "~/.local/state/overlook-remote/bridge.sock"))
  :config
  (overlook-remote-bridge-mode 1))
```

The mode connects, and reconnects with backoff whenever the daemon restarts;
the dashboard's mode line shows the connection. Without the daemon running it
costs nothing but a retry timer. `M-x overlook-remote-url` (old package) still
prints the link with the token.

## TLS with Tailscale

```sh
tailscale cert HOST.TAILNET.ts.net          # writes HOST.TAILNET.ts.net.crt and .key
overlook-remoted -token-file … -listen 127.0.0.1:8767 \
  -listen-tls 0.0.0.0:8766 -tls-cert HOST.TAILNET.ts.net.crt -tls-key HOST.TAILNET.ts.net.key
```

Open `https://HOST.TAILNET.ts.net:8766/overlook/#TOKEN`. The certificate is
re-read within a minute of the file changing; Tailscale certificates last 90
days, so rerun `tailscale cert` monthly (e.g. a launchd `StartCalendarInterval`
job). A changed scheme or host is a new origin: the Home Screen link has to be
added again.

## Installing as a LaunchAgent

```sh
cd site-lisp/overlook/remote
TOKEN_FILE=… LISTEN=0.0.0.0:8766 PLIST=~/Library/LaunchAgents/io.github.guiyuanju.overlook-remoted.plist \
  MENUBAR_PLIST=~/Library/LaunchAgents/io.github.guiyuanju.overlook-menubar.plist deploy/install.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.guiyuanju.overlook-remoted.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.guiyuanju.overlook-menubar.plist
```

`install.sh` builds both binaries into `$PREFIX/bin` (default `~/.local/bin`;
the menu bar app needs macOS and Swift, and `MENUBAR=0` skips it) and renders
`deploy/overlook-remoted.plist.in` (`-emacs-start` from `EMACS_START`, default
`/usr/bin/open -a Emacs`, empty to leave Emacs alone; KeepAlive, logs in
`~/Library/Logs/overlook-remoted.log`) and `deploy/overlook-menubar.plist.in`
(RunAtLoad, restarted only after a crash, GUI sessions only, logs in
`~/Library/Logs/overlook-menubar.log`, pointing at the daemon's label, plist,
token file, admin socket, log and port); it never loads anything. Bootstrapping
the menu bar app alone is enough: it bootstraps the daemon. `TOKEN_FILE`
is the file the init sets as `overlook-remote-token-file` (under
`iuiw-state-directory`). launchd itself listens on `LISTEN` (the plist's
`Sockets` → `http` entry) and hands the socket to the daemon
(`-listen launchd:http`), so connections made while the daemon restarts wait
instead of failing. For TLS add a second `Sockets` entry (say `https`) and
`-listen-tls launchd:https -tls-cert … -tls-key …` to the plist.

- Upgrade: `deploy/deploy.sh` (below).
- Stop: `launchctl bootout gui/$(id -u)/io.github.guiyuanju.overlook-remoted`.
- Status: `launchctl print gui/$(id -u)/io.github.guiyuanju.overlook-remoted`, `curl -s http://127.0.0.1:PORT/overlook/healthz`.

## Updating remote from remote

Agents directed from the phone may change remote itself while the phone uses
it. Each part has its own way to go live without taking remote down:

- **Page** (`remote/web/`): run the daemon with `-web-dir
  …/site-lisp/overlook/remote/web` (`WEB_DIR=…` for `install.sh`). Edits
  show up on the next page load: reload the page, or reopen it from the Home
  Screen. Hashed URLs, import map and CSP are recomputed; no build, no
  restart. Without `-web-dir` the page is the one built into the binary and
  changes with a Go deploy.
- **Emacs bridge** (`overlook-remote-bridge*.el`): `M-x load-file` the
  changed file (or `eval-buffer`) in the running Emacs. The connection, its
  hooks and timers stay as they are (`overlook-bridge-survives-reloading`
  tests this); changed connection code runs from the next reconnect (toggle
  `overlook-remote-bridge-mode` to force one).
- **Daemon** (Go under `remote/`): run `remote/deploy/deploy.sh`. It builds
  the checkout, runs `go vet` and `go test ./...`, starts the new binary on a
  spare loopback port with a copy of the state file and checks it, installs it
  over `~/.local/bin/overlook-remoted` keeping `overlook-remoted.prev`,
  restarts the agent with `launchctl kickstart -k`, and waits until
  `/overlook/healthz` reports the new version (and Emacs online, if it was
  before). If any step fails before the swap nothing changes; if the new
  daemon does not come up it restores `.prev`, restarts again and exits
  non-zero with the reason. `--dry-run` stops before the swap. The page
  stays usable throughout: launchd queues connections during the ~10 ms
  restart, the state file restores history and cursors, Emacs reconnects
  within a second, and the page resumes its stream without reloading.
  Settings (`LABEL`, `PREFIX`/`BIN`, `PLIST`, `HEALTH_URL`, `STATE_FILE`,
  `TIMEOUT`, …) are listed at the top of the script; the defaults match
  `install.sh`.
- **Menu bar app**: `deploy.sh` also builds it (`swift build -c release`);
  release builds are reproducible, so when the result differs from the
  installed `overlook-menubar` it runs `swift test` and swaps it in
  (keeping `.prev`), `kickstart -k`s its agent (a signal, not Quit, so the
  daemon keeps running) and restores `.prev` unless the app is still running
  with the same pid a few seconds later. A menu bar failure never undoes the
  daemon deploy. Skipped when the app is not installed or `MENUBAR=0`.
- **Rollback by hand**: `cp ~/.local/bin/overlook-remoted.prev
  ~/.local/bin/overlook-remoted && launchctl kickstart -k
  gui/$(id -u)/io.github.guiyuanju.overlook-remoted`. For the page under
  `-web-dir` or the bridge, revert the files (`git checkout -- …`) and reload
  the page or the file again.

## Tests

From `site-lisp/overlook`: `make test` runs `go test ./...`, `deploy_test.sh`
and the page's unit, browser and end-to-end tests when `go`/`node` exist; `make lint` adds
`go vet` and a `gofmt` check. Browser tests need Playwright, found as
`require('playwright')` resolves it (so `NODE_PATH` works), else
`OVERLOOK_PLAYWRIGHT`, else the global npm root; without it they skip.

| Test | What |
|---|---|
| `go test -race ./...` | daemon packages, a daemon end to end with the in-process fake Emacs, restarts resuming from the state file, `-web-dir` reloads, the admin socket and keep-awake with a fake caffeinate, the menu bar app's model, URLs, icons, QR file and launchctl calls |
| `deploy/deploy_test.sh` | `deploy.sh` with a throwaway prefix and a fake `launchctl`: dry run, deploy, rollback, failing tests, and the menu bar app's swap, skip when unchanged and rollback |
| `webtest/unit.test.mjs` | page modules under Node |
| `webtest/browser.test.mjs` | the page in emulated phones against a Node fake daemon |
| `webtest/usage.test.mjs` | consumption charts, shared filters, metric switching and retained results on query failure in light/dark phone layouts |
| `webtest/daemon.test.mjs` | the page against the real daemon with `-fake-emacs`, across a daemon restart |
| `webtest/e2e-emacs.test.mjs` | the page against the real daemon and a batch Emacs running the bridge with fake agents (`webtest/e2e-emacs.el`) |

`node webtest/measure.mjs [old] [new]` prints the byte table of
`docs/measurements.md`; `node webtest/bridge-cost.mjs [projects agents]` times
the bridge inside Emacs. Both start their own daemon and batch Emacs on random
ports and clean up after themselves; `OVERLOOK_E2E_VERBOSE=1` shows their logs.

## Consumption analytics

Usage includes daily token trends, weekday/time-slot averages and provider,
project and session rankings. The daemon imports Claude CLI logs from
`${CLAUDE_CONFIG_DIR:-~/.claude}/projects` and Codex logs from
`${CODEX_HOME:-~/.codex}/{sessions,archived_sessions}` on startup, then checks for
appends every minute. It works without Emacs or an open browser. Other providers,
other machines and deleted history that was never imported are not included.

Only numeric usage and attribution metadata are stored in `usage.sqlite` beside
`-state-file`, independently of chat retention and Emacs epochs. The pure-Go
SQLite driver preserves the daemon's CGO_ENABLED=0 build. The database and WAL
sidecars have owner-only permissions; prompts, replies and credentials are not
copied. Collection is disabled with an empty `-state-file` and in `-fake-emacs`
mode. Database failures disable analytics and preserve the original files; the
rest of remote remains available.

On first open, the old `usage.json` is migrated in one transaction, including
all consumption events and file cursors. A committed marker prevents subsequent
imports. The JSON file is left unchanged as a migration backup; it stops updating
after migration. Do not use this stale JSON backup to restore current SQLite
history. Migration errors roll back and can be retried without a partial import.

Each changed source file commits its new/updated consumption and its cursor in
one transaction. Event IDs are unique; duplicate streaming snapshots only raise
token component counts. File identity, shrinking size and fingerprints at the
prefix/read boundary trigger replay when a source is replaced or rewritten. Reads use the initial
file-size snapshot; a detected rewrite during import aborts the transaction for
retry. Existing cursors acquire identity/fingerprints without losing progress.
Project resolution is shared by working directory within one scan, then refreshed
on the next scan. Unchanged scans perform no database writes. WAL mode
allows readers to keep their committed snapshot during ingestion, and FULL
synchronous commits preserve both consumption and cursor on durable storage.
Use SQLite's backup API or `.backup` to copy a running database; copying the main
file alone may omit committed WAL contents.

Queries select only the requested and previous date ranges, using indexes on
time, provider/time, project/time and provider/project/time. First-record and
filter-option queries also use indexed columns. A read transaction provides one
snapshot across the report. SQLite groups token sums and event counts by time
slot, provider, project and session before returning rows. A deterministic Go scalar function assigns IANA
time zones and DST-aware slots. Go combines those aggregates for presentation;
no full history map is loaded into memory. Up to eight reports are cached within
the current minute and invalidated only when committed event values change.
Cursor-only commits and completed scans preserve numeric results; scan status is
attached at response time. Identical concurrent queries share one execution.
Each HTTP request cancels its own wait; the SQL query is canceled when all
waiters leave. SQL reads and report composition are separate stages, and the
read transaction ends before presentation aggregates are composed.

Claude streaming snapshots are deduplicated by session/message ID. Codex
cumulative checkpoints yield increments; repeated or archived copies are
idempotent. A decreasing counter establishes a new baseline, so a discontinuity
may undercount. Forked/copied sessions with a new identity cannot always be
recognized as inherited history. Log timestamps, often request completion times,
place consumption into time slots; long requests cannot be accurately split
across hours. Missing log records cannot be inferred from account quota meters.

Project attribution is captured on import: live Emacs project roots first,
otherwise the nearest workspace `project.md` ancestor of the repository root,
otherwise the repository/folder name. Git worktree metadata resolves to its main
repository. Historical renamed/deleted projects cannot always be reconstructed.
The browser receives project labels, not filesystem paths. Cache reads/writes,
uncached input and output are separate; Codex cached input is a subset of input,
and reasoning output is already included in output. These tokens are not a bill.
