#!/usr/bin/env bash
# first-commit-check.sh <binary> [seconds] — what a window's first commit carries.
#
# A compositor shows a window when its surface maps, and applies the shadow
# and the backdrop blur it asked for at that moment. So nothing may be
# committed between acking the first configure and attaching the first
# painted buffer: a commit of its own is a window with nothing in it. Runs
# the app under WAYLAND_DEBUG, then reports what it sent in between. Needs a
# Wayland session (the nested harness will do).
#
#   tools/first-commit-check.sh build/16_launcher
set -uo pipefail
bin=${1:?usage: first-commit-check.sh <binary> [seconds]}
secs=${2:-3}
log=$(mktemp -t baldr-first-commit-XXXXXX.log)
WAYLAND_DEBUG=1 "$bin" >"$log" 2>&1 &
app=$!
sleep "$secs"
kill "$app" 2>/dev/null
wait "$app" 2>/dev/null

attach=$(grep -n -m1 "wl_surface#[0-9]*\.attach(wl_buffer" "$log")
[ -z "$attach" ] && { echo "no buffer was ever attached (did the window open?) — $log"; exit 1; }
at_line=${attach%%:*}
surf=$(sed 's/.*wl_surface#\([0-9]*\)\.attach.*/\1/' <<<"$attach")
ack=$(grep -n -m1 "xdg_surface#[0-9]*\.ack_configure\|zwlr_layer_surface_v1#[0-9]*\.ack_configure" "$log")
[ -z "$ack" ] && { echo "no configure was acked — $log"; exit 1; }
ack_line=${ack%%:*}

between=$(sed -n "$((ack_line + 1)),$((at_line - 1))p" "$log" | grep "wl_surface#$surf\." || true)
echo "surface $surf: acked its configure on line $ack_line, attached its first buffer on line $at_line"
if [ -n "$between" ]; then
	echo "$between" | sed 's/^/  /'
fi
if grep -q "wl_surface#$surf\.commit()" <<<"$between"; then
	echo "FAIL: the window was committed before it had anything in it ($log)"
	exit 1
fi
echo "OK: nothing was committed before the painted buffer (log: $log)"
