#!/usr/bin/env bash
# Regenerate platform/wayland/wl/gen_*.odin from the protocol XML files.
# System XMLs are vendored into platform/wayland/wl/xml/ first so the output
# does not depend on what happens to be installed. Run manually after
# changing this list or bumping a protocol; commit the result.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
XML="$HERE/platform/wayland/wl/xml"
WP=/usr/share/wayland-protocols
mkdir -p "$XML"
copy() { [ -f "$1" ] || { echo "missing: $1" >&2; exit 1; }; cp -f "$1" "$XML/"; }
copy /usr/share/wayland/wayland.xml
copy $WP/stable/xdg-shell/xdg-shell.xml
copy $WP/stable/viewporter/viewporter.xml
copy $WP/stable/presentation-time/presentation-time.xml
copy $WP/stable/tablet/tablet-v2.xml
copy $WP/stable/linux-dmabuf/linux-dmabuf-v1.xml
copy $WP/staging/fractional-scale/fractional-scale-v1.xml
copy $WP/staging/cursor-shape/cursor-shape-v1.xml
copy $WP/staging/xdg-activation/xdg-activation-v1.xml
copy $WP/staging/ext-session-lock/ext-session-lock-v1.xml
copy $WP/staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml
copy $WP/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml
copy $WP/staging/ext-workspace/ext-workspace-v1.xml
copy $WP/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml
copy $WP/unstable/text-input/text-input-unstable-v3.xml
copy $WP/unstable/xdg-output/xdg-output-unstable-v1.xml
copy $WP/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml
copy $WP/unstable/primary-selection/primary-selection-unstable-v1.xml
copy $WP/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml
copy $WP/unstable/xdg-foreign/xdg-foreign-unstable-v2.xml
# wlr-layer-shell, wlr-virtual-pointer, wlr-foreign-toplevel-management (wlroots), rikkiti-backdrop-v1 and rikkiti-applet-v1 (from the compositor tree) and ext-background-effect-v1 (wayland-protocols > 1.44) are vendored.
for f in wlr-layer-shell-unstable-v1.xml wlr-virtual-pointer-unstable-v1.xml wlr-foreign-toplevel-management-unstable-v1.xml rikkiti-backdrop-v1.xml rikkiti-applet-v1.xml ext-background-effect-v1.xml; do [ -f "$XML/$f" ] || { echo "missing vendored $f" >&2; exit 1; }; done

# The definitions' notices, collected for baldr.notices(): a Linux build carries the bindings.
python3 "$HERE/tools/wl_scanner/notice.py" "$XML" "$HERE/platform/wayland/wl/NOTICE.txt"

odin build "$HERE/tools/wl_scanner" -out:"$HERE/build/wl_scanner" -collection:baldr="$HERE"
rm -f "$HERE/platform/wayland/wl"/gen_*.odin
"$HERE/build/wl_scanner" "$HERE/platform/wayland/wl" "$XML"/*.xml
odin check "$HERE/platform/wayland/wl" -collection:baldr="$HERE" -no-entry-point -vet -strict-style
echo "generated: $(ls "$HERE/platform/wayland/wl"/gen_*.odin | wc -l) files, $(cat "$HERE/platform/wayland/wl"/gen_*.odin | wc -l) lines"
