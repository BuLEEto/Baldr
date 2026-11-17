#!/usr/bin/env bash
# Baldr build helper.
#   ./build.sh test                                run the headless test suites, every package (no GPU, window or bus needed)
#   ./build.sh check                               type-check every package, for Linux, Windows and macOS
#   ./build.sh example 01_hello  [run [args...]]   build (and run) an example; on macOS it is wrapped in a .app
#   ./build.sh gallery                             build the gallery (00_gallery) alone: the quick check after an API change
#   ./build.sh examples                            build every example (a couple of minutes)
#   ./build.sh spike wl_triangle [run [args...]]   build (and run) a spike; args go to the program
#   BALDR_FAST=1 ./build.sh example <name> run     optimised build (-o:speed, ~5x slower to compile): judge speed with this
#   ./build.sh api                                 regenerate docs/API.md from the doc comments (diff it before a release)
#   ./build.sh emoji [out|--stats]                 regenerate baldr/emoji_data.odin from Unicode + the bundled emoji font
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"; mkdir -p "$OUT"
COLL="-collection:baldr=$HERE"
# --- macOS: a built binary is not yet a runnable app
#
# A bare Mach-O has no Dock identity and no Info.plist, so no
# NSHighResolutionCapable, which decides the layer's backing scale: running it
# exercises a different renderer path from a real app's. Every build is
# wrapped, which also keeps the bundle and the binary in step.
mac_bundle() {
  [ "$(uname)" = Darwin ] || return 0
  n="$1"
  app="$OUT/$n.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$OUT/$n" "$app/Contents/MacOS/$n"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$n</string>
  <key>CFBundleIdentifier</key><string>dev.baldr.$(echo "$n" | tr '_' '-')</string>
  <key>CFBundleName</key><string>$n</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
}

# mac_run picks what to actually run: the bundle on macOS, the binary
# elsewhere. So `./build.sh example 05_overlays run` on a Mac runs the thing
# a person would double-click, not a lesser version of it.
mac_run() {
  n="$1"; shift
  if [ "$(uname)" = Darwin ] && [ -x "$OUT/$n.app/Contents/MacOS/$n" ]; then
    "$OUT/$n.app/Contents/MacOS/$n" "$@"
  else
    "$OUT/$n" "$@"
  fi
}

# On Windows a program is a console program unless it says otherwise, so
# double-clicking a GUI app opens a terminal behind it. -subsystem:windows
# asks for a GUI program (the linker-flag spelling of it makes the default
# linker warn about the entry point). An app that wants a console (a tool,
# something reading stdout) leaves it off.
#
# Only when building on Windows for Windows: a cross-check never links.
WINGUI=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*|Windows*) WINGUI='-subsystem:windows' ;;
esac

case "${1:-}" in
  test)
    # Every test's views are held to their paint bounds (paint_bounds_check.odin):
    # a drawing outside them is left on screen when it changes, so it fails the gate.
    odin test "$HERE/baldr" $COLL -out:"$OUT/baldr_test" 2>&1 | tee "$OUT/baldr_test.log"; [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
    if grep -q "baldr/bounds:" "$OUT/baldr_test.log"; then echo "FAIL: drawing outside its paint bounds:" >&2; grep "baldr/bounds:" "$OUT/baldr_test.log" | sort -u >&2; exit 1; fi
    # The runner reports a leak as a warning and still says every test passed.
    if grep -q "+++ leak" "$OUT/baldr_test.log"; then echo "FAIL: a test leaked memory:" >&2; grep -E "WARN.*::|\+\+\+ leak" "$OUT/baldr_test.log" | head -20 >&2; exit 1; fi
    odin test "$HERE/audio" $COLL -out:"$OUT/audio_test"  # the ring, across two real threads; the backend needs a device, so spikes/audio_check is its gate
    odin test "$HERE/gpu" $COLL -out:"$OUT/gpu_test"      # the renderer's pure choices (the kind word, format picking)
    odin test "$HERE/platform/cocoa" $COLL -out:"$OUT/cocoa_test"   # the macOS key table: pure data, so it runs anywhere
    odin test "$HERE/dbus" $COLL -out:"$OUT/dbus_test"
    [ "$(uname)" = Linux ] && odin test "$HERE/sys/atspi" $COLL -out:"$OUT/atspi_test"
    [ "$(uname)" = Linux ] && odin test "$HERE/platform/x11" $COLL -out:"$OUT/x11_test"
    [ "$(uname)" = Linux ] && odin test "$HERE/platform/xdg" $COLL -out:"$OUT/xdg_test"
    odin test "$HERE/sys/portal" $COLL -out:"$OUT/portal_test"
    ;;
  check)
    # Single-threaded: the parallel parser races on -vet-packages
    # (ast_file_vet_flags segfaults about 1 run in 12). It costs nothing for
    # packages this size; the retry covers any other crash.
    check() { for _ in 1 2 3; do odin check "$@" -thread-count:1 && return 0; [ $? -eq 139 ] || return 1; echo "(compiler crashed; retrying)" >&2; done; return 1; }
    # -define:BALDR_TESTS=true reads the test files too. They sit behind a
    # `when` so that an app importing Baldr does not type-check them (9.2 GB
    # and 93 s if it did); this gate should.
    # The portable packages, then the Linux-only ones. Every file of
    # sys/portal, platform/{xkb,x11,wayland/wl} is `#+build linux`, and
    # platform/{xdg,wayland} are part-gated: their ungated files name
    # Linux-only types, so checking them on macOS fails with "'x' of type
    # '^invalid type'".
    # platform/cocoa is portable on purpose: its key table is pure data with
    # no AppKit in it, so it is checked and tested on every machine.
    pkgs="baldr audio gpu platform platform/cocoa dbus"
    [ "$(uname)" = Linux ] && pkgs="$pkgs sys/portal platform/xdg platform/xkb platform/wayland/wl platform/wayland platform/x11"
    for p in $pkgs; do
      [ -n "$(ls "$HERE/$p"/*.odin 2>/dev/null)" ] || continue
      defs=""; [ "$p" = baldr ] && defs="-define:BALDR_TESTS=true" # only baldr has test files behind the `when`
      # `|| exit 1`: without it the loop's status is only the *last* package's,
      # so a package that failed earlier would be reported as a clean check.
      check "$HERE/$p" $COLL -no-entry-point $defs -vet -vet-style -vet-semicolon -vet-packages:"$(basename "$p")" || exit 1
    done
    # Cross-checking the Windows target goes through `build -build-mode:obj`,
    # not `check`: `-target:windows_amd64` demands `-windows-sdk-root`, which
    # `odin check` does not accept. An obj build never links, so /nonexistent
    # satisfies the flag; the type-check and vet passes are the same ones.
    # Retire it if `check` ever takes the flag.
    win_check() { odin build "$@" -build-mode:obj -windows-sdk-root:/nonexistent -thread-count:1; }
    # The cross-checks run only from Linux: on another host they add nothing
    # the Linux gate does not already give.
    if [ "$(uname)" != Linux ]; then
      exit 0
    fi
    # BALDR_TESTS: the backend's own tests only run under tools/win-sync.sh,
    # so this is the one pass that reads them with the vet flags on.
    if [ -n "$(ls "$HERE/platform/win32"/*.odin 2>/dev/null)" ]; then
      win_check "$HERE/platform/win32" $COLL -no-entry-point -target:windows_amd64 -define:BALDR_TESTS=true -vet -vet-style -vet-semicolon -vet-packages:win32 -out:"$OUT/win32_cross.obj" || exit 1
    fi
    # audio's Windows path is the real WASAPI backend, and its tests are what
    # hold the playback arithmetic. BALDR_TESTS reads them here too, or a
    # rename in the backend breaks them unseen until win-sync runs.
    win_check "$HERE/audio" $COLL -no-entry-point -target:windows_amd64 -define:BALDR_TESTS=true -vet -vet-style -vet-semicolon -vet-packages:audio -out:"$OUT/audio_cross.obj" || exit 1
    win_check "$HERE/baldr" $COLL -no-entry-point -target:windows_amd64 -define:BALDR_TESTS=true -vet-packages:baldr -out:"$OUT/baldr_cross.obj" || exit 1
    # And the macOS target. The Metal backend's files are darwin-only, so a
    # Linux check never reads them, and code shared by both `gpu` backends
    # (its two Page_States, say) can break the macOS build silently. A plain
    # `check`: unlike Windows it needs no SDK flag.
    # platform/cocoa is read ONLY here: every one of its files is darwin-only,
    # so the native loop above checks an empty package and says nothing.
    for p in gpu platform/cocoa audio; do
      check "$HERE/$p" $COLL -no-entry-point -target:darwin_arm64 -define:BALDR_TESTS=true -vet -vet-style -vet-semicolon -vet-packages:"$(basename "$p")" || exit 1
    done
    check "$HERE/baldr" $COLL -no-entry-point -target:darwin_arm64 -define:BALDR_TESTS=true -vet-packages:baldr || exit 1

    # The backend drivers, each for its own target. Not the other spikes:
    # these five go through `platform.Backend` itself, are the only place
    # some of it is exercised, and are mostly buildable only for another
    # target, so nothing else would notice them stop compiling. About 1.8 s
    # of the gate. Their event switches are `#partial` so that a new event
    # variant does not break them.
    for sp in cocoa_check baldr_metal; do
      check "$HERE/spikes/$sp" $COLL -target:darwin_arm64 || exit 1
    done
    win_check "$HERE/spikes/win32_check" $COLL -target:windows_amd64 -out:"$OUT/win32_check_cross.obj" || exit 1
    for sp in wayland_check x11_check; do
      check "$HERE/spikes/$sp" $COLL || exit 1
    done
    ;;
  spike)   odin build "$HERE/spikes/$2" $COLL -out:"$OUT/$2" -debug ${BALDR_FAST:+-o:speed} || exit 1; mac_bundle "$2"; if [ "${3:-}" = run ]; then mac_run "$2" "${@:4}"; fi ;;
  example) odin build "$HERE/examples/$2" $COLL -out:"$OUT/$2" -debug ${BALDR_FAST:+-o:speed} ${WINGUI:+"$WINGUI"} || exit 1; mac_bundle "$2"; if [ "${3:-}" = run ]; then mac_run "$2" "${@:4}"; fi ;;
  gallery)                        # the gallery alone: it uses most widgets, so it catches most API breaks in one
                                  # build instead of thirty-eight (each build type-checks the whole toolkit: no
                                  # incremental compile). Run `examples` before a commit batch or a release.
    odin build "$HERE/examples/00_gallery" $COLL -out:"$OUT/00_gallery" -debug ${WINGUI:+"$WINGUI"} && mac_bundle 00_gallery
    ;;
  examples)                       # build every example: the cheapest regression check after an API change
    for d in "$HERE"/examples/*/; do n="$(basename "$d")"; echo "== $n"; odin build "$d" $COLL -out:"$OUT/$n" -debug ${WINGUI:+"$WINGUI"} || exit 1; mac_bundle "$n"; done ;;
  api)      odin run "$HERE/tools/api_gen" $COLL -out:"$OUT/api_gen" -- "$HERE/baldr" "$HERE/docs/API.md" ;;
  emoji)    # regenerate baldr/emoji_data.odin from Unicode's emoji-test.txt,
            # keeping only what the bundled face draws as a single emoji.
            # Run it after changing the emoji font or moving to a newer
            # Unicode; `--stats` instead of the output path says what the
            # font covers without writing anything.
            odin run "$HERE/tools/emoji_gen" $COLL -out:"$OUT/emoji_gen" -- \
              "${EMOJI_TEST:-/usr/share/unicode/emoji/emoji-test.txt}" \
              "$HERE/assets/fonts/Twemoji-Mozilla.ttf" "${2:-$HERE/baldr/emoji_data.odin}" ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
