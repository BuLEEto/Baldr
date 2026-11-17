#!/usr/bin/env bash
# A real X session to develop the X11 backend against, nested in a window.
#
# Xwayland is not X11 for testing: no reparenting window manager, its
# clipboard bridges to Wayland's, and a drag to a Wayland app goes through
# that bridge. Xephyr is a real Xorg server with its own root window, its own
# selections and its own input, and openbox inside it is a real reparenting
# window manager — which is what the X11 backend has to be checked against.
#
#   tools/nested-x.sh start            # Xephyr on :2 with openbox
#   tools/nested-x.sh run 04_controls  # ...and an example inside it
#   tools/nested-x.sh stop
#
# Needs xserver-xephyr, openbox and xdotool. Rendering goes through lavapipe:
# the hardware driver refuses Xephyr with "No DRI3 support detected".
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DISP="${BALDR_NESTED_DISPLAY:-:2}"
SIZE="${BALDR_NESTED_SIZE:-1400x900}"
LVP=/usr/share/vulkan/icd.d/lvp_icd.json

case "${1:-start}" in
  start)
    if DISPLAY="$DISP" xdpyinfo >/dev/null 2>&1; then echo "already up on $DISP"; exit 0; fi
    # -noreset, or the server resets and *exits* the moment its last client
    # disconnects — so closing the one app you were testing takes the whole
    # session with it, which looks like a crash and is not.
    # setsid and </dev/null, or it goes when the shell that started it does.
    setsid Xephyr "$DISP" -screen "$SIZE" -resizeable -ac -noreset \
      >/tmp/xephyr$DISP.log 2>&1 </dev/null &
    disown 2>/dev/null || true
    for _ in $(seq 1 40); do DISPLAY="$DISP" xdpyinfo >/dev/null 2>&1 && break; sleep 0.25; done
    DISPLAY="$DISP" xdpyinfo >/dev/null 2>&1 || { echo "Xephyr did not start; see /tmp/xephyr$DISP.log" >&2; exit 1; }
    setsid env DISPLAY="$DISP" openbox >/tmp/openbox$DISP.log 2>&1 </dev/null &
    disown 2>/dev/null || true
    sleep 1
    echo "nested X on $DISP ($SIZE), openbox running"
    ;;
  run)
    shift
    [ $# -ge 1 ] || { echo "usage: $0 run <example-or-spike> [args...]" >&2; exit 2; }
    exe="$1"; shift
    setsid env DISPLAY="$DISP" BALDR_BACKEND=x11 \
      VK_ICD_FILENAMES="$LVP" VK_DRIVER_FILES="$LVP" \
      "$HERE/build/$exe" "$@" >"/tmp/$exe$DISP.log" 2>&1 </dev/null &
    disown 2>/dev/null || true
    sleep 1
    echo "$exe running on $DISP (log /tmp/$exe$DISP.log)"
    ;;
  stop)
    pkill -x openbox 2>/dev/null || true
    pkill -x Xephyr 2>/dev/null || true
    echo "stopped"
    ;;
  *) echo "usage: $0 start|run <name> [args]|stop" >&2; exit 2 ;;
esac
