#!/bin/sh
# Builds overlook-remoted into $PREFIX/bin and writes its LaunchAgent plist.
#   TOKEN_FILE=… [PREFIX=~/.local] [LISTEN=127.0.0.1:8767] [SOCKET=…] [LABEL=…] [WEB_DIR=…] [PLIST=out.plist] deploy/install.sh
# It never loads the agent; see remote/README.md for launchctl, and deploy.sh for updates.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
remote=$(dirname "$here")
PREFIX=${PREFIX:-$HOME/.local}
LISTEN=${LISTEN:-127.0.0.1:8767}
SOCKET=${SOCKET:-$HOME/.local/state/overlook-remote/bridge.sock}
LOG=${LOG:-$HOME/Library/Logs/overlook-remoted.log}
LABEL=${LABEL:-io.github.guiyuanju.overlook-remoted}
PLIST=${PLIST:-$PWD/$LABEL.plist}
: "${TOKEN_FILE:?set TOKEN_FILE to the token file Emacs uses (overlook-remote-token-file)}"

# launchd listens on LISTEN itself: host and port go into the plist's Sockets entry.
node=${LISTEN%:*}
port=${LISTEN##*:}
case $node in \[*\]) node=${node#[}; node=${node%]} ;; esac
if [ -z "$node" ] || [ "$node" = "$LISTEN" ]; then node=0.0.0.0; fi

version=$(git -C "$remote" describe --always --dirty 2>/dev/null || echo dev)
mkdir -p "$PREFIX/bin"
(cd "$remote" && go build -trimpath -ldflags "-X main.version=$version" -o "$PREFIX/bin/overlook-remoted.new" ./cmd/overlook-remoted)
mv "$PREFIX/bin/overlook-remoted.new" "$PREFIX/bin/overlook-remoted"

sed -e "s|@BINARY@|$PREFIX/bin/overlook-remoted|" -e "s|@NODE@|$node|" -e "s|@PORT@|$port|" \
    -e "s|@TOKEN_FILE@|$TOKEN_FILE|" -e "s|@SOCKET@|$SOCKET|" -e "s|@LOG@|$LOG|" -e "s|@LABEL@|$LABEL|" \
    "$here/overlook-remoted.plist.in" > "$PLIST"
if [ -n "${WEB_DIR-}" ]; then
  plutil -insert ProgramArguments -string -web-dir -append "$PLIST"
  plutil -insert ProgramArguments -string "$WEB_DIR" -append "$PLIST"
fi
if command -v plutil >/dev/null; then plutil -lint "$PLIST" >/dev/null; fi
echo "built $PREFIX/bin/overlook-remoted ($version)"
echo "wrote $PLIST"
