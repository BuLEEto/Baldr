#!/usr/bin/env bash
# Sync the repo to the macOS build box and optionally run a gate there.
#   tools/mac-sync.sh                 # sync only (tar over ssh, excludes .git and build/)
#   tools/mac-sync.sh check           # sync + ./build.sh check
#   tools/mac-sync.sh test            # sync + ./build.sh test
#   tools/mac-sync.sh gate            # sync + both, which is what to run before trusting a claim
#   tools/mac-sync.sh run <cmd...>    # sync + run an arbitrary command in the synced tree
# The host is an ssh alias from ~/.ssh/config: `mac-build` by default, or set
# BALDR_MAC_HOST. It expects an arm64 Mac.
#
# Unlike the Windows box this is a Unix, so `./build.sh` runs there unchanged and
# a test binary's output comes straight back down the ssh pipe — no log dance.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BALDR_MAC_HOST:-mac-build}"
DEST='$HOME/baldr'    # single-quoted: expanded on the Mac, not here
# The compiler's own directory goes on PATH ahead of everything, so the binary
# sees its real path and finds core/ and vendor/ beside it.
#
# dev-2026-11a or newer: Baldr does not build on older releases (AppKit left
# Foundation, Metal's methods follow their selectors, `core:image`'s pixels
# are a dynamic array), and dev-2026-10 cannot compile Objective-C on macOS
# at all (the checker never registers objc_lookUpClass for a program that
# only sends messages). MAC_ODIN_DIR overrides.
ODIN_DIR="${MAC_ODIN_DIR:-\$HOME/odin/dev-2026-11a}"
# A non-interactive ssh session gets PATH=/usr/bin:/bin:/usr/sbin:/sbin — no
# Homebrew, no Odin — so every remote command sets its own PATH. Forgetting
# this looks exactly like Odin not being installed.
remote() { ssh -o BatchMode=yes "$HOST" "export PATH=\"$ODIN_DIR:/opt/homebrew/bin:\$PATH\"; cd $DEST && $*"; }

# A true mirror, not an overlay: `tar -x` adds and overwrites but never
# deletes, so a file removed here would linger there and still fail the
# remote `check`. Everything but build/ goes first, then the tree (about
# 35 MB) is laid down fresh.
ssh -o BatchMode=yes "$HOST" "mkdir -p $DEST && cd $DEST && find . -maxdepth 1 ! -name . ! -name build -exec rm -rf {} +" >/dev/null
tar -C "$HERE" --exclude=.git --exclude=build -cf - . | ssh -o BatchMode=yes "$HOST" "tar -xf - -C $DEST"
echo "synced -> $HOST:$DEST"

case "${1:-}" in
  check) remote ./build.sh check ;;
  test)  remote ./build.sh test ;;
  gate)  remote ./build.sh check && remote ./build.sh test ;;
  run)   shift; remote "$*" ;;
  "") ;;
  *) echo "mac-sync.sh: unknown command '$1' (check|test|gate|run)" >&2; exit 2 ;;
esac
