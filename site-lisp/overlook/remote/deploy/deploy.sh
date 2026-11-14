#!/bin/sh
# Replaces the running overlook-remoted with one built from this checkout, without leaving remote down:
# build, vet, test, smoke-test the new binary on a spare port with a copy of the state, swap it in
# keeping overlook-remoted.prev, restart the LaunchAgent, and roll back unless it comes up healthy.
#
#   deploy/deploy.sh [--dry-run]
#
# --dry-run stops before the swap. Settings come from the environment:
#   LABEL         LaunchAgent label (io.github.guiyuanju.overlook-remoted)
#   PREFIX, BIN   installed binary, $PREFIX/bin/overlook-remoted (PREFIX=~/.local)
#   PLIST         the agent's plist, read to find HEALTH_URL and STATE_FILE (~/Library/LaunchAgents/$LABEL.plist)
#   HEALTH_URL    the live daemon's healthz URL (from the plist's Sockets or -listen)
#   STATE_FILE    the live daemon's state file (from the plist's -state-file or -socket)
#   CACHE_DIR     -cache-dir for the smoke test (the daemon's default)
#   TIMEOUT       seconds to wait for the restarted daemon (30)
#   GO_TEST_ARGS  arguments of go test (./...)
#   LAUNCHCTL     launchctl command (launchctl)
set -eu

dry_run=
case ${1-} in
--dry-run) dry_run=1 ;;
"") ;;
*) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
remote=$(dirname "$here")
LABEL=${LABEL:-io.github.guiyuanju.overlook-remoted}
PREFIX=${PREFIX:-$HOME/.local}
BIN=${BIN:-$PREFIX/bin/overlook-remoted}
PLIST=${PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}
TIMEOUT=${TIMEOUT:-30}
GO_TEST_ARGS=${GO_TEST_ARGS:-./...}
LAUNCHCTL=${LAUNCHCTL:-launchctl}
service=gui/$(id -u)/$LABEL

say() { echo "deploy: $*" >&2; }
die() { say "$*"; exit 1; }

# plist_arg prints the ProgramArguments value following flag $1.
plist_arg() {
  i=1
  while prev=$(plutil -extract "ProgramArguments.$((i - 1))" raw -o - "$PLIST" 2>/dev/null); do
    if [ "$prev" = "$1" ]; then
      plutil -extract "ProgramArguments.$i" raw -o - "$PLIST" 2>/dev/null
      return
    fi
    i=$((i + 1))
  done
  return 1
}

loopback_url() {
  case $1 in 0.0.0.0 | "" | "::" | "*") host=127.0.0.1 ;; *:*) host="[$1]" ;; *) host=$1 ;; esac
  echo "http://$host:$2/overlook/healthz"
}

if [ -z "${HEALTH_URL-}" ]; then
  [ -r "$PLIST" ] || die "set HEALTH_URL, or PLIST to the LaunchAgent's plist ($PLIST is not readable)"
  if port=$(plutil -extract Sockets.http.SockServiceName raw -o - "$PLIST" 2>/dev/null); then
    node=$(plutil -extract Sockets.http.SockNodeName raw -o - "$PLIST" 2>/dev/null || true)
    HEALTH_URL=$(loopback_url "$node" "$port")
  elif listen=$(plist_arg -listen); then
    HEALTH_URL=$(loopback_url "${listen%:*}" "${listen##*:}")
  else
    die "cannot find the daemon's address in $PLIST; set HEALTH_URL"
  fi
fi
if [ -z "${STATE_FILE-}" ]; then
  if [ -r "$PLIST" ] && STATE_FILE=$(plist_arg -state-file); then :
  elif [ -r "$PLIST" ] && socket=$(plist_arg -socket); then STATE_FILE=$(dirname "$socket")/state.json
  else STATE_FILE=$HOME/.local/state/overlook-remote/state.json
  fi
fi

health() { curl -fsS -m 2 "$1" 2>/dev/null; }

# healthy URL VERSION ONLINE succeeds when URL answers ok, from VERSION if set, with Emacs online if ONLINE is set.
healthy() {
  h=$(health "$1") || return 1
  case $h in *'"status":"ok"'*) ;; *) return 1 ;; esac
  if [ -n "$2" ]; then case $h in *"\"daemon\":\"$2\""*) ;; *) return 1 ;; esac; fi
  if [ -n "$3" ]; then case $h in *'"emacs":"online"'*) ;; *) return 1 ;; esac; fi
}

# wait_healthy URL VERSION ONLINE SECONDS
wait_healthy() {
  end=$(($(date +%s) + $4))
  while [ "$(date +%s)" -le "$end" ]; do
    healthy "$1" "$2" "$3" && return 0
    sleep 0.2
  done
  return 1
}

tmp=$(mktemp -d /tmp/overlook-deploy.XXXXXX)
lock="$BIN.deploy-lock"
smoke_pid=
cleanup() {
  [ -n "$smoke_pid" ] && kill "$smoke_pid" 2>/dev/null || true
  rm -rf "$tmp"
  [ -n "${locked-}" ] && rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$(dirname "$BIN")"
mkdir "$lock" 2>/dev/null || die "another deploy holds $lock (remove it if no deploy is running)"
locked=1

was_online=
if before=$(health "$HEALTH_URL"); then
  case $before in *'"emacs":"online"'*) was_online=1 ;; esac
  say "live daemon at $HEALTH_URL: $before"
else
  say "no daemon answers at $HEALTH_URL now; deploying anyway"
fi

version=$(git -C "$remote" describe --always --dirty 2>/dev/null || echo dev)-$(date +%Y%m%d%H%M%S)
say "building $version"
(cd "$remote" && go build -trimpath -ldflags "-X main.version=$version" -o "$tmp/overlook-remoted" ./cmd/overlook-remoted) ||
  die "build failed; nothing changed"
say "go vet"
(cd "$remote" && go vet ./...) || die "go vet failed; nothing changed"
say "go test $GO_TEST_ARGS"
# shellcheck disable=SC2086
(cd "$remote" && go test $GO_TEST_ARGS) || die "go test failed; nothing changed"

say "smoke test on a spare port"
mkdir -p "$tmp/state" "$tmp/s"
chmod 700 "$tmp/state" "$tmp/s"
echo smoke-token >"$tmp/token"
if [ -r "$STATE_FILE" ]; then cp "$STATE_FILE" "$tmp/state/state.json"; fi
set -- -listen 127.0.0.1:0 -token-file "$tmp/token" -socket "$tmp/s/bridge.sock" -state-file "$tmp/state/state.json"
if [ -n "${CACHE_DIR-}" ]; then set -- "$@" -cache-dir "$CACHE_DIR"; fi
"$tmp/overlook-remoted" "$@" >"$tmp/smoke.log" 2>&1 &
smoke_pid=$!
url=
for _ in $(seq 150); do
  url=$(sed -n 's/.*msg=listening url=\(http:[^ ]*\).*/\1/p' "$tmp/smoke.log" | head -n 1)
  [ -n "$url" ] && break
  kill -0 "$smoke_pid" 2>/dev/null || break
  sleep 0.1
done
smoke_fail() { sed 's/^/  | /' "$tmp/smoke.log" >&2; die "smoke test failed: $*; nothing changed"; }
[ -n "$url" ] || smoke_fail "the new binary did not start listening"
healthy "${url}healthz" "$version" "" || smoke_fail "healthz did not answer ok from $version"
case $(curl -fsS -m 5 "$url" 2>/dev/null) in *importmap*) ;; *) smoke_fail "the page did not render" ;; esac
kill -TERM "$smoke_pid"
status=0
wait "$smoke_pid" || status=$?
smoke_pid=
[ "$status" -eq 0 ] || smoke_fail "graceful shutdown exited $status"
[ -s "$tmp/state/state.json" ] || smoke_fail "no state file written on shutdown"

if [ -n "$dry_run" ]; then
  say "dry run: would install $version as $BIN (keeping $BIN.prev), run $LAUNCHCTL kickstart -k $service,"
  say "dry run: and wait ${TIMEOUT}s for $HEALTH_URL to answer from $version${was_online:+ with Emacs online}"
  exit 0
fi

had_prev=
if [ -e "$BIN" ]; then
  cp -p "$BIN" "$BIN.prev.tmp" && mv -f "$BIN.prev.tmp" "$BIN.prev"
  had_prev=1
fi

rollback() {
  say "$1"
  if [ -z "$had_prev" ]; then
    die "no previous binary to restore; remote is DOWN until fixed (see $service's log)"
  fi
  cp -p "$BIN.prev" "$BIN.new" && mv -f "$BIN.new" "$BIN"
  say "restored $BIN.prev; restarting"
  "$LAUNCHCTL" kickstart -k "$service" || true
  if wait_healthy "$HEALTH_URL" "" "$was_online" "$TIMEOUT"; then
    die "deploy of $version failed and was rolled back; remote is up on the previous binary"
  fi
  die "deploy of $version failed, and the previous binary does not answer at $HEALTH_URL either: remote is DOWN (see $service's log)"
}

cp "$tmp/overlook-remoted" "$BIN.new" && mv -f "$BIN.new" "$BIN"
say "installed $BIN; restarting $service"
"$LAUNCHCTL" kickstart -k "$service" || rollback "$LAUNCHCTL kickstart failed"
if wait_healthy "$HEALTH_URL" "$version" "$was_online" "$TIMEOUT"; then
  say "deployed $version: $(health "$HEALTH_URL")"
  exit 0
fi
rollback "the new daemon did not answer ok${was_online:+ with Emacs online} at $HEALTH_URL within ${TIMEOUT}s: $(health "$HEALTH_URL" || echo no answer)"
