# Measurements

## Wire bytes, old server vs. overlook-remoted

`node webtest/measure.mjs old new` (2026-11-14). Both servers are driven by the
same batch Emacs with fake agents (`webtest/e2e-emacs.el`): the old one runs
`overlook-remote-mode` on a random loopback port, the new one is the daemon
with `overlook-remote-bridge-mode`. Chromium emulates an iPhone 13 over plain
HTTP/1.1 through a TCP proxy that counts every byte, headers included. Each
step ends 1.5 s after its result is on screen. ↓ is server to phone, ↑ phone
to server; "req" counts requests the page made, "conn" new TCP connections.

| Scenario | old ↓ KB | old ↑ KB | old req/conn | new ↓ KB | new ↑ KB | new req/conn |
|---|--:|--:|--:|--:|--:|--:|
| Cold page load | 1471.6 | 4.0 | 7/4 | 278.8 | 12.4 | 23/6 |
| Warm launch (Home Screen reopen) | 1471.6 | 4.0 | 7/3 | 1.8 | 1.9 | 23/0 |
| Open a conversation with 50 items | 15.5 | 4.1 | 5/0 | 2.1 | 2.2 | 3/0 |
| Stream a 5 KB reply in 20-character chunks | 63.0 | 78.5 | 92/0 | 5.6 | 6.2 | 8/0 |
| A dashboard change (an agent starts working) | 1.1 | 0.0 | 0/0 | 0.4 | 0.0 | 0/0 |
| Idle minute in a conversation | 1.5 | 1.7 | 2/0 | 0.0 | 0.0 | 0/0 |

- **Loads.** The old server sends the page and Framework7 uncompressed and
  uncached on every launch. The daemon serves brotli and content-hashed
  immutable URLs: a warm launch is the revalidated `index.html`, the dashboard
  snapshot and the stream; the other requests are answered from the browser
  cache. Of the cold 278.8 KB, 171 KB is `vendor/framework7.js` (the full bundle, brotli); a
  custom build with only the dialog, actions, sheet, toast, preloader and
  photo-browser components is the remaining large saving, paid once per device.
- **Streaming.** Before integration the new page sent a read position per
  update (54 `PUT …/read`, each resending the conversation state): 21.5 KB ↓ and
  42.8 KB ↑. Read positions now go at most every 2 s (see `page.md`); the 8
  requests left are those, about 770 bytes each of browser headers. The reply
  itself costs about its size: gzip per event, suffix-only text.
- **Idle.** The old page long-polls (a request per 25 s); the daemon's stream
  sends a 3-byte heartbeat comment every 25 s, about 30 bytes a minute on the
  wire, shown as 0.0.
- Over TLS with HTTP/2 the per-request header cost drops further (HPACK); not
  measured here.

## The bridge's cost in Emacs

`node webtest/bridge-cost.mjs [projects agents]` times the bridge functions
with advice inside the batch Emacs, Apple M-series, Emacs 31.1. "50 agents" is
nine projects (dashboard JSON 16 KB); "2 agents" is one project (1 KB).

| Work | 2 agents | 50 agents |
|---|--:|--:|
| Flush while a reply streams (250 chunks, 20 ms apart): median / p90 / max | 0.37 / 0.68 / 2.4 ms | 0.42 / 0.92 / 2.0 ms |
| Serializing one conversation state | 0.23 ms | 0.24 ms |
| Flush after a dashboard change: median / p90 / max | 0.65 / 1.7 / 3.8 ms | 2.3 / 11.5 / 16.3 ms |
| Gathering and serializing the dashboard (model included) | 1.3 ms | 8.5 ms (15–20 ms on a busier run) |
| 20 status changes 150 ms apart, total | 39 ms | 200 ms |

Before integration the 50-agent case cost a median 47 ms per `dashboard.set`
write alone (p90 flush 90 ms, max 125 ms; 1.8 s for the 20 changes): Emacs
sleeps 20 ms whenever a socket write does not fit, and macOS local sockets
buffer 8 KiB. The bridge now writes at most 8000 bytes per event-loop turn
(0.06 ms per write) and sends the dashboard at most every 0.5 s, so the 20
changes serialized it 7 times instead of 20. Most of what remains after a
dashboard change is `overlook-model` gathering rows (shared with the visible
dashboard's own redraw) and, because `overlook-agent-changed-hook` does not
say which agent changed, re-serializing every conversation (about 0.1–0.2 ms
each, compared and dropped when unchanged).

## Startup and restarts

Time from `exec` to the first `/overlook/healthz` answer on an M-series Mac
(2026-11-14), five runs each:

| | Start |
|---|--:|
| Embedded page compressed at startup (before) | 1.33 s |
| `-cache-dir` empty (first start of a new build) | 1.32 s |
| `-cache-dir` warm (any later start, and after `deploy.sh`'s smoke test) | 11 ms |
| `-web-dir`: page rebuild after editing one module | 25 ms (under `-race`) |

Requests to `/overlook/healthz` in a tight loop across three
`launchctl kickstart -k` restarts of a throwaway LaunchAgent:

| | Requests | Refused | Slowest |
|---|--:|--:|--:|
| Plain `-listen`, no cache (before) | 2118 | 435 | — |
| `Sockets` + `-listen launchd:http`, warm cache | 2158 | 0 | 44 ms |
