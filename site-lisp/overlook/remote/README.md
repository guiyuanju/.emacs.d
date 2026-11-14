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
| `-state-file` | state kept across restarts (history, read positions, receipts, images in `media/` beside it); default `state.json` beside `-socket`; `""` keeps nothing |
| `-cache-dir` | compressed page files by content hash, so starts take ~10 ms; default `~/Library/Caches/overlook-remoted`; `""` disables |
| `-web-dir` | serve the page from this directory (e.g. `remote/web`) instead of the binary, picking up edits on the next page load |
| `-auto-close` | minutes after which non-loopback listeners close (0 never; not with `launchd:` sockets) |
| `-stream-compression` | gzip the event stream (default true; `=false` if iOS misbehaves) |
| `-debug` | debug logging |

The page is `http://HOST:PORT/overlook/#TOKEN`, the same address the old
server used, so a Home Screen link keeps working once the daemon takes the old
port. `GET /overlook/healthz` answers without a token and says whether Emacs is
connected.

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
TOKEN_FILE=… LISTEN=0.0.0.0:8766 PLIST=~/Library/LaunchAgents/io.github.guiyuanju.overlook-remoted.plist deploy/install.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.guiyuanju.overlook-remoted.plist
```

`install.sh` builds the binary into `$PREFIX/bin` (default `~/.local/bin`) and
renders `deploy/overlook-remoted.plist.in` (KeepAlive, logs in
`~/Library/Logs/overlook-remoted.log`); it never loads anything. `TOKEN_FILE`
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
| `go test -race ./...` | daemon packages, a daemon end to end with the in-process fake Emacs, restarts resuming from the state file, `-web-dir` reloads |
| `deploy/deploy_test.sh` | `deploy.sh` with a throwaway prefix and a fake `launchctl`: dry run, deploy, rollback, failing tests |
| `webtest/unit.test.mjs` | page modules under Node |
| `webtest/browser.test.mjs` | the page in emulated phones against a Node fake daemon |
| `webtest/daemon.test.mjs` | the page against the real daemon with `-fake-emacs`, across a daemon restart |
| `webtest/e2e-emacs.test.mjs` | the page against the real daemon and a batch Emacs running the bridge with fake agents (`webtest/e2e-emacs.el`) |

`node webtest/measure.mjs [old] [new]` prints the byte table of
`docs/measurements.md`; `node webtest/bridge-cost.mjs [projects agents]` times
the bridge inside Emacs. Both start their own daemon and batch Emacs on random
ports and clean up after themselves; `OVERLOOK_E2E_VERBOSE=1` shows their logs.
