#!/bin/sh
# Tests deploy.sh end to end against a throwaway install prefix and a fake launchctl that runs the
# daemon (with its fake Emacs) on a spare loopback port; the real LaunchAgent is never touched.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
remote=$(dirname "$here")
dir=$(mktemp -d /tmp/overlook-deploy-test.XXXXXX)
fail() { echo "deploy_test: FAIL: $*" >&2; exit 1; }

cleanup() {
  if [ -s "$dir/launchd/pid" ]; then kill "$(cat "$dir/launchd/pid")" 2>/dev/null || true; fi
  if [ -s "$dir/launchd/menubar.pid" ]; then kill "$(cat "$dir/launchd/menubar.pid")" 2>/dev/null || true; fi
  rm -rf "$dir"
}
trap cleanup EXIT

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$dir/prefix/bin" "$dir/launchd" "$dir/path" "$dir/state"
chmod 700 "$dir/state"
echo test-token >"$dir/token"
echo 0 >"$dir/launchd/count"
echo 0 >"$dir/launchd/menubar.count"

# The fake launchctl restarts the daemon like kickstart -k; FAKE_BREAK_ON=N makes the Nth start crash.
# For the menu bar label it runs a sleep standing in for the app after checking the binary starts;
# FAKE_MENUBAR_BREAK=1 makes the new app die at once.
cat >"$dir/path/launchctl" <<EOF
#!/bin/sh
set -eu
d=$dir/launchd
if [ "\$1 \${2-}" = "print gui/\$(id -u)/test.overlook-menubar" ]; then
  [ -e \$d/menubar.loaded ] || { echo 'Could not find service'; exit 113; }
  if [ -s \$d/menubar.pid ] && kill -0 \$(cat \$d/menubar.pid) 2>/dev/null; then
    printf 'x = {\\n\\tstate = running\\n\\tpid = %s\\n}\\n' \$(cat \$d/menubar.pid)
  else printf 'x = {\\n\\tstate = not running\\n}\\n'; fi
  exit 0
fi
if [ "\$1 \${2-} \${3-}" = "kickstart -k gui/\$(id -u)/test.overlook-menubar" ]; then
  [ -s \$d/menubar.pid ] && kill \$(cat \$d/menubar.pid) 2>/dev/null || true
  : >\$d/menubar.pid
  echo \$((\$(cat \$d/menubar.count) + 1)) >\$d/menubar.count
  if $dir/prefix/bin/overlook-menubar -token-file /dev/null -check >/dev/null && ! cmp -s $dir/prefix/bin/overlook-menubar $dir/menubar-broken; then
    nohup sleep 300 >/dev/null 2>&1 &
    echo \$! >\$d/menubar.pid
  fi
  exit 0
fi
[ "\$1 \$2" = "kickstart -k" ] || { echo "fake launchctl: unsupported: \$*" >&2; exit 64; }
[ "\$3" = "gui/\$(id -u)/test.overlook-remoted" ] || { echo "fake launchctl: no such service \$3" >&2; exit 113; }
if [ -s \$d/pid ]; then
  pid=\$(cat \$d/pid)
  kill -TERM \$pid 2>/dev/null || true
  while kill -0 \$pid 2>/dev/null; do sleep 0.05; done
fi
n=\$((\$(cat \$d/count) + 1))
echo \$n >\$d/count
extra=
if [ "\$n" = "\${FAKE_BREAK_ON-}" ]; then extra=-no-such-flag; fi
nohup $dir/prefix/bin/overlook-remoted \$extra -listen 127.0.0.1:$port -token-file $dir/token \\
  -socket $dir/state/bridge.sock -state-file $dir/state/state.json -cache-dir $dir/cache \\
  -fake-emacs $remote/testdata/fixtures -fake-live-delay -1s >>\$d/log 2>&1 &
echo \$! >\$d/pid
EOF
chmod +x "$dir/path/launchctl"

health_url=http://127.0.0.1:$port/overlook/healthz
wait_online() {
  for _ in $(seq 100); do
    case $(curl -fsS -m 1 "$health_url" 2>/dev/null) in *'"emacs":"online"'*) return 0 ;; esac
    sleep 0.1
  done
  fail "daemon not online: $(tail -n 5 "$dir/launchd/log")"
}
daemon_version() { curl -fsS -m 1 "$health_url" | sed -n 's/.*"daemon":"\([^"]*\)".*/\1/p'; }
deploy() {
  PATH="$dir/path:$PATH" LABEL=test.overlook-remoted BIN="$dir/prefix/bin/overlook-remoted" \
    HEALTH_URL="$health_url" STATE_FILE="$dir/state/state.json" CACHE_DIR="$dir/cache" TIMEOUT=10 \
    MENUBAR=${MENUBAR:-$menubar} MENUBAR_LABEL=test.overlook-menubar MENUBAR_BIN="$dir/prefix/bin/overlook-menubar" MENUBAR_SETTLE=1 \
    GO_TEST_ARGS="${GO_TEST_ARGS:-$compile_only}" SWIFT_TEST=0 "$here/deploy.sh" "$@"
}
# The suite runs where deploy_test.sh itself is run from; deploy.sh only needs it to compile here.
compile_only='-run ^$ ./...'


echo "deploy_test: installing an old binary"
(cd "$remote" && go build -ldflags "-X main.version=old" -o "$dir/prefix/bin/overlook-remoted" ./cmd/overlook-remoted)
cp "$dir/prefix/bin/overlook-remoted" "$dir/old"
PATH="$dir/path:$PATH" launchctl kickstart -k "gui/$(id -u)/test.overlook-remoted"
# The menu bar app needs macOS and Swift; elsewhere deploy.sh skips it.
menubar=0
menubar_count() { cat "$dir/launchd/menubar.count"; }
if [ "$(uname)" = Darwin ] && command -v swift >/dev/null &&
  swift build -c release --package-path "$remote/menubar" >"$dir/swift-build.log" 2>&1 &&
  cp "$remote/menubar/.build/release/overlook-menubar" "$dir/prefix/bin/overlook-menubar" &&
  "$dir/prefix/bin/overlook-menubar" -token-file /dev/null -check >/dev/null 2>&1; then
  menubar=1
  # The same build signed under another identifier stands in for an older menu bar app.
  codesign -s - -f -i test.overlook-menubar.old "$dir/prefix/bin/overlook-menubar" 2>/dev/null
  cp "$dir/prefix/bin/overlook-menubar" "$dir/menubar-old"
  touch "$dir/launchd/menubar.loaded"
  PATH="$dir/path:$PATH" launchctl kickstart -k "gui/$(id -u)/test.overlook-menubar"
fi
wait_online
[ "$(daemon_version)" = old ] || fail "old daemon reports $(daemon_version)"

echo "deploy_test: --dry-run changes nothing"
deploy --dry-run >"$dir/out" 2>&1 || { cat "$dir/out"; fail "dry run failed"; }
cmp -s "$dir/old" "$dir/prefix/bin/overlook-remoted" || fail "dry run replaced the binary"
[ "$(cat "$dir/launchd/count")" = 1 ] || fail "dry run restarted the daemon"
grep -q "dry run: would install" "$dir/out" || fail "dry run did not say what it would do"
if [ "$menubar" = 1 ]; then
  grep -q "would install the changed menu bar app" "$dir/out" || { cat "$dir/out"; fail "dry run did not mention the menu bar app"; }
  cmp -s "$dir/menubar-old" "$dir/prefix/bin/overlook-menubar" || fail "dry run replaced the menu bar app"
fi

echo "deploy_test: deploy"
deploy >"$dir/out" 2>&1 || { cat "$dir/out"; fail "deploy failed"; }
new=$(daemon_version)
case $new in old | "") fail "the daemon still reports $new" ;; esac
cmp -s "$dir/old" "$dir/prefix/bin/overlook-remoted.prev" || fail ".prev is not the old binary"
cmp -s "$dir/old" "$dir/prefix/bin/overlook-remoted" && fail "binary not replaced"
cp "$dir/prefix/bin/overlook-remoted" "$dir/good"
[ -s "$dir/state/state.json" ] || fail "the daemon did not save state across the restart"
grep -q "state restored" "$dir/launchd/log" || fail "the new daemon did not restore the state"
if [ "$menubar" = 1 ]; then
  grep -q "menu bar app restarted" "$dir/out" || { cat "$dir/out"; fail "the menu bar app was not restarted"; }
  cmp -s "$dir/menubar-old" "$dir/prefix/bin/overlook-menubar.prev" || fail "menu bar .prev is not the old app"
  cmp -s "$dir/menubar-old" "$dir/prefix/bin/overlook-menubar" && fail "menu bar app not replaced"
  cp "$dir/prefix/bin/overlook-menubar" "$dir/menubar-good"
  [ "$(menubar_count)" = 2 ] || fail "menu bar app started $(menubar_count) times, want 2"

  echo "deploy_test: an unchanged menu bar app is left alone"
  deploy >"$dir/out" 2>&1 || { cat "$dir/out"; fail "second deploy failed"; }
  grep -q "menu bar app unchanged" "$dir/out" || { cat "$dir/out"; fail "no unchanged message"; }
  [ "$(menubar_count)" = 2 ] || fail "an unchanged menu bar app was restarted"
  new=$(daemon_version)

  echo "deploy_test: a menu bar app that does not stay up is rolled back"
  cp "$dir/menubar-old" "$dir/prefix/bin/overlook-menubar"
  cp "$dir/menubar-good" "$dir/menubar-broken"
  deploy >"$dir/out" 2>&1 && { cat "$dir/out"; fail "a broken menu bar deploy succeeded"; }
  grep -q "did not stay up and was rolled back" "$dir/out" || { cat "$dir/out"; fail "no menu bar rollback message"; }
  cmp -s "$dir/menubar-old" "$dir/prefix/bin/overlook-menubar" || fail "the previous menu bar app was not restored"
  rm "$dir/menubar-broken"
  new=$(daemon_version)
  cp "$dir/prefix/bin/overlook-remoted" "$dir/good"
fi

echo "deploy_test: a daemon that does not come up is rolled back"
(FAKE_BREAK_ON=$(($(cat "$dir/launchd/count") + 1)) && export FAKE_BREAK_ON && deploy >"$dir/out" 2>&1) &&
  { cat "$dir/out"; fail "a broken deploy succeeded"; }
grep -q "rolled back; remote is up on the previous binary" "$dir/out" || { cat "$dir/out"; fail "no rollback message"; }
cmp -s "$dir/good" "$dir/prefix/bin/overlook-remoted" || fail "the previous binary was not restored"
wait_online
[ "$(daemon_version)" = "$new" ] || fail "after the rollback the daemon reports $(daemon_version), want $new"
[ ! -e "$dir/prefix/bin/overlook-remoted.deploy-lock" ] || fail "lock left behind"

echo "deploy_test: a failing test suite changes nothing"
(GO_TEST_ARGS=./no/such/package && deploy >"$dir/out" 2>&1) && fail "deploy passed without tests"
grep -q "go test failed; nothing changed" "$dir/out" || { cat "$dir/out"; fail "no test failure message"; }
cmp -s "$dir/good" "$dir/prefix/bin/overlook-remoted" || fail "a failed check replaced the binary"

echo "deploy_test: ok"
