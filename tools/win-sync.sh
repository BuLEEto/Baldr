#!/usr/bin/env bash
# Sync the repo to the Windows build box and optionally run a command there.
#   tools/win-sync.sh                 # sync only (rsync-like: tar over ssh, excludes .git and build/)
#   tools/win-sync.sh test            # sync + run the headless tests on Windows
#   tools/win-sync.sh run <cmd...>    # sync + run an arbitrary command (cmd.exe syntax)
# The host is an ssh alias from ~/.ssh/config: `win-build` by default, or set
# BALDR_WIN_HOST. Odin on the box: C:\odin\dev-2026-11a\odin.exe.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BALDR_WIN_HOST:-win-build}"
DEST='C:\baldr'
# dev-2026-11a or newer: the tree does not build on older releases. Its
# install has no `dist` subdirectory. WIN_ODIN overrides.
#
# A fresh Odin install lacks the box's local patch to
# `core\nbio\impl_windows.odin` (CLAUDE.local.md): this tree does not need
# it, other programs built on the box do.
ODIN="${WIN_ODIN:-C:\odin\dev-2026-11a\odin.exe}"
ssh -o BatchMode=yes "$HOST" "if not exist $DEST mkdir $DEST" >/dev/null
# Wipe the destination first, keeping only `build` (the artifacts and the
# logs read back): `tar -xf` only adds and overwrites, so a file deleted or
# renamed here would linger there and still be compiled.
# `-Path "$DEST\*"`, not `-LiteralPath`: PowerShell silently ignores
# `-Exclude` with -LiteralPath, and `build` would go too. `exit 0` and
# `|| true`: PowerShell reports failure for a Remove-Item told to ignore
# errors, and this script runs under `set -e`.
ssh -o BatchMode=yes "$HOST" "powershell -NoProfile -Command \"Get-ChildItem -Path '$DEST\*' -Exclude build | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; exit 0\"" >/dev/null 2>&1 || true
tar -C "$HERE" --exclude=.git --exclude=build -cf - . | ssh -o BatchMode=yes "$HOST" "tar -xf - -C $DEST"
echo "synced -> $HOST:$DEST"
case "${1:-}" in
  test)
    # Two calls, not one: in cmd, `if not exist X mkdir X && cmd2` binds the && to the mkdir, so cmd2 is silently
    # skipped once X exists. And a test binary's own output never reaches a non-interactive ssh session, so it goes
    # to a log on the box, which we read back.
    ssh -o BatchMode=yes "$HOST" "if not exist $DEST\\build mkdir $DEST\\build" >/dev/null
    ssh -o BatchMode=yes "$HOST" "$ODIN test $DEST\\baldr -collection:baldr=$DEST -out:$DEST\\build\\baldr_test.exe > $DEST\\build\\test.log 2>&1"
    ssh -o BatchMode=yes "$HOST" "type $DEST\\build\\test.log"
    # The backend's own tests: the package is #+build windows, so this is the
    # only place they run, and they belong to this gate rather than
    # ./build.sh test.
    ssh -o BatchMode=yes "$HOST" "$ODIN test $DEST\\platform\\win32 -collection:baldr=$DEST -out:$DEST\\build\\win32_test.exe > $DEST\\build\\win32_test.log 2>&1"
    ssh -o BatchMode=yes "$HOST" "type $DEST\\build\\win32_test.log"
    # baldr:audio, for the same reason: the WASAPI stream's bookkeeping is
    # #+build windows. These tests are the part that needs no device;
    # `spikes/audio_check` exercises the playback thread on real hardware.
    ssh -o BatchMode=yes "$HOST" "$ODIN test $DEST\\audio -collection:baldr=$DEST -out:$DEST\\build\\audio_test.exe > $DEST\\build\\audio_test.log 2>&1"
    ssh -o BatchMode=yes "$HOST" "type $DEST\\build\\audio_test.log"
    ;;
  run)  shift; ssh -o BatchMode=yes "$HOST" "$*" ;;
  "") ;;
esac
