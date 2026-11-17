#+build darwin
package cocoa

// Holding the screen on while a window is showing something to watch
// (Backend.keep_awake).
//
// NSProcessInfo's activity API: a token taken with
// `beginActivityWithOptions:reason:` and given back with `endActivity:`.
// The token dies with the process, so a crash cannot leave the screen held.
//
// The request is process-wide where the backend contract is per surface, so
// it is counted: taken when the first window asks, given back when the last
// stops, and a window closing while it asks releases its share
// (`surface_destroy`). `NSActivityUserInitiated` goes with the display flag
// because a person asked for this; `NSActivityLatencyCritical` is for audio.

import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "core:fmt"
import "baldr:platform"

@(private, objc_class = "NSProcessInfo") Idle_ProcInfo :: struct { using _: NS.Object }

// The options, spelled out because the bindings do not carry them.
@(private) NS_ACTIVITY_IDLE_DISPLAY_SLEEP_DISABLED :: u64(1) << 40
@(private) NS_ACTIVITY_IDLE_SYSTEM_SLEEP_DISABLED  :: u64(1) << 20
@(private) NS_ACTIVITY_USER_INITIATED              :: u64(0x00FF_FFFF) | NS_ACTIVITY_IDLE_SYSTEM_SLEEP_DISABLED

@(private)
b_keep_awake :: proc(b: ^platform.Backend, id: platform.Surface, on: bool) {
	c := self(b)
	s := find(c, id)
	if s == nil do return
	if s.awake == on do return
	s.awake = on
	idle_apply(c)
}

// idle_release drops this surface's asking (a window going away).
@(private)
idle_release :: proc(c: ^Cocoa, s: ^Surface) {
	if !s.awake do return
	s.awake = false
	idle_apply(c)
}

// idle_apply takes the token when somebody wants the screen on and gives
// it back when nobody does.
@(private)
idle_apply :: proc(c: ^Cocoa) {
	want := false
	for s in c.surfaces do if s != nil && s.awake { want = true; break }
	if want == (c.idle_token != nil) do return

	pi := intrinsics.objc_send(^Idle_ProcInfo, Idle_ProcInfo, "processInfo")
	if c.debug_files do fmt.eprintfln("baldr/cocoa: keep_awake -> %v (processInfo %v)", want, pi != nil)
	if pi == nil do return
	if want {
		why := ns_str("showing something to watch")
		defer why->release()
		opts := NS_ACTIVITY_USER_INITIATED | NS_ACTIVITY_IDLE_DISPLAY_SLEEP_DISABLED
		tok := intrinsics.objc_send(^NS.Object, pi, "beginActivityWithOptions:reason:", opts, why)
		// Held, not autoreleased: it has to outlive this pump.
		if tok != nil do c.idle_token = intrinsics.objc_send(^NS.Object, tok, "retain")
		return
	}
	intrinsics.objc_send(nil, pi, "endActivity:", c.idle_token)
	intrinsics.objc_send(nil, c.idle_token, "release")
	c.idle_token = nil
}

// b_surface_post_close asks for this window to close as if its close
// button had been pressed: the app hears Ev_Close with reason .User on the
// next pump and decides. Not `performClose:`, which beeps at a window with
// no close button, and a window drawing its own title bar is the usual
// caller. The delegate would only post this same event (windowShouldClose:
// in view.odin).
@(private)
b_surface_post_close :: proc(b: ^platform.Backend, id: platform.Surface) {
	c := self(b)
	s := find(c, id)
	if s == nil do return
	append(&c.queue, platform.Ev_Close{surface = s.id, reason = .User})
	b_wake(b)
}
