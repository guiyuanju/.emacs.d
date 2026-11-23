#!/bin/sh
# Builds overlook-remoted and, on macOS with Swift, overlook-menubar (remote/menubar) into $PREFIX/bin and writes their LaunchAgent plists.
#   TOKEN_FILE=… [PREFIX=~/.local] [LISTEN=127.0.0.1:8767] [SOCKET=…] [ADMIN_SOCKET=…] [LABEL=…] [WEB_DIR=…] [PLIST=out.plist]
#   [EMACS_START="/usr/bin/open -a Emacs"] [MENUBAR=0] [MENUBAR_LABEL=…] [MENUBAR_PLIST=out.plist] [DAEMON_PLIST=…] deploy/install.sh
# It never loads an agent; see remote/README.md for launchctl, and deploy.sh for updates.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
remote=$(dirname "$here")
PREFIX=${PREFIX:-$HOME/.local}
LISTEN=${LISTEN:-127.0.0.1:8767}
SOCKET=${SOCKET:-$HOME/.local/state/overlook-remote/bridge.sock}
ADMIN_SOCKET=${ADMIN_SOCKET:-$(dirname "$SOCKET")/admin.sock}
LOG=${LOG:-$HOME/Library/Logs/overlook-remoted.log}
LABEL=${LABEL:-io.github.guiyuanju.overlook-remoted}
# Starts Emacs after a crash or on request; empty never starts it.
EMACS_START=${EMACS_START-/usr/bin/open -a Emacs}
PLIST=${PLIST:-$PWD/$LABEL.plist}
MENUBAR_LABEL=${MENUBAR_LABEL:-io.github.guiyuanju.overlook-menubar}
MENUBAR_PLIST=${MENUBAR_PLIST:-$PWD/$MENUBAR_LABEL.plist}
MENUBAR_LOG=${MENUBAR_LOG:-$HOME/Library/Logs/overlook-menubar.log}
# The menu bar app bootstraps the daemon from where its plist ends up.
DAEMON_PLIST=${DAEMON_PLIST:-$PLIST}
if [ -z "${MENUBAR-}" ]; then
  if [ "$(uname)" = Darwin ] && command -v swift >/dev/null; then MENUBAR=1; else MENUBAR=0; fi
fi
: "${TOKEN_FILE:?set TOKEN_FILE to the token file Emacs uses (overlook-remote-token-file)}"

# launchd listens on LISTEN itself: host and port go into the plist's Sockets entry.
node=${LISTEN%:*}
port=${LISTEN##*:}
case $node in \[*\]) node=${node#[}; node=${node%]} ;; esac
if [ -z "$node" ] || [ "$node" = "$LISTEN" ]; then node=0.0.0.0; fi

version=$(git -C "$remote" describe --always --dirty 2>/dev/null || echo dev)
mkdir -p "$PREFIX/bin"
(cd "$remote" && CGO_ENABLED=0 go build -trimpath -ldflags "-X main.version=$version" -o "$PREFIX/bin/overlook-remoted.new" ./cmd/overlook-remoted)
mv "$PREFIX/bin/overlook-remoted.new" "$PREFIX/bin/overlook-remoted"
if [ "$MENUBAR" = 1 ]; then
  swift build -c release --package-path "$remote/menubar"
  cp "$remote/menubar/.build/release/overlook-menubar" "$PREFIX/bin/overlook-menubar.new"
  mv "$PREFIX/bin/overlook-menubar.new" "$PREFIX/bin/overlook-menubar"
fi

render() {
  sed -e "s|@BINARY@|$PREFIX/bin/overlook-remoted|" -e "s|@MENUBAR_BINARY@|$PREFIX/bin/overlook-menubar|" \
      -e "s|@NODE@|$node|" -e "s|@PORT@|$port|" -e "s|@TOKEN_FILE@|$TOKEN_FILE|" -e "s|@SOCKET@|$SOCKET|" \
      -e "s|@ADMIN_SOCKET@|$ADMIN_SOCKET|" -e "s|@LOG@|$LOG|" -e "s|@EMACS_START@|$EMACS_START|" -e "s|@LABEL@|$LABEL|" \
      -e "s|@MENUBAR_LABEL@|$MENUBAR_LABEL|" -e "s|@MENUBAR_LOG@|$MENUBAR_LOG|" -e "s|@DAEMON_PLIST@|$DAEMON_PLIST|" \
      "$1" > "$2"
  if command -v plutil >/dev/null; then plutil -lint "$2" >/dev/null; fi
}
render "$here/overlook-remoted.plist.in" "$PLIST"
if [ -n "${WEB_DIR-}" ]; then
  plutil -insert ProgramArguments -string -web-dir -append "$PLIST"
  plutil -insert ProgramArguments -string "$WEB_DIR" -append "$PLIST"
fi
echo "built $PREFIX/bin/overlook-remoted ($version)"
echo "wrote $PLIST"
if [ "$MENUBAR" = 1 ]; then
  render "$here/overlook-menubar.plist.in" "$MENUBAR_PLIST"
  echo "built $PREFIX/bin/overlook-menubar"
  echo "wrote $MENUBAR_PLIST"
fi
