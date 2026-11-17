#+build darwin
package cocoa

// A window sized by its app, and a window given the whole screen.
//
// There is no hold here. macOS has no configures to resist: nothing proposes
// a size but the person dragging an edge, so the size is set once and the
// window is theirs again. A held size would stop it being resized by hand.
// `{0, 0}` has nothing to release.
//
// A zoomed or full-screen window is the desktop's to size, as the contract
// says, so an ask is ignored in those states.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"
import "baldr:platform"

// NSWindowStyleMaskFullScreen, which the bindings' WindowStyleMask does not
// carry: it is a state AppKit sets rather than one an app asks for.
@(private) STYLE_FULLSCREEN :: NS.UInteger(1 << 14)
// NSWindowCollectionBehaviorFullScreenPrimary: without it toggleFullScreen:
// does nothing at all, silently.
@(private) BEHAVIOR_FULLSCREEN_PRIMARY :: NS.UInteger(1 << 7)

@(private)
window_is_fullscreen :: proc "contextless" (win: ^NS.Window) -> bool {
	if win == nil do return false
	return intrinsics.objc_send(NS.UInteger, win, "styleMask") & STYLE_FULLSCREEN != 0
}

@(private)
window_is_zoomed :: proc "contextless" (win: ^NS.Window) -> bool {
	if win == nil do return false
	return bool(intrinsics.objc_send(NS.BOOL, win, "isZoomed"))
}

// configure_of is the Ev_Configure for this surface as it is now. Every
// configure goes through here so that `maximized` and `fullscreen` are read
// from the window.
@(private)
configure_of :: proc(s: ^Surface, activated := true) -> platform.Ev_Configure {
	return platform.Ev_Configure{
		surface    = s.id,
		size       = s.size,
		size_px    = {u32(s.size.x * s.scale), u32(s.size.y * s.scale)},
		scale      = s.scale,
		maximized  = window_is_zoomed(s.win),
		fullscreen = window_is_fullscreen(s.win),
		activated  = activated,
	}
}

// b_surface_set_size gives the window the size the app asked for, in
// logical points, as the content; the frame adds the title bar. The top-left
// stays put: AppKit measures a frame from its bottom-left, so the origin is
// moved by the height difference or the window would slide up or down.
@(private)
b_surface_set_size :: proc(b: ^platform.Backend, id: platform.Surface, size: [2]f32) {
	c := self(b)
	s := find(c, id)
	if s == nil || s.win == nil do return
	if size == {} {
		// No hold to release: the window keeps its size.
		if c.debug_files do fmt.eprintfln("baldr/cocoa: surface %v: its size handed back (nothing held here)", id)
		return
	}
	if window_is_zoomed(s.win) || window_is_fullscreen(s.win) do return // the desktop's to size

	content := NS.Rect{{0, 0}, {NS.Float(size.x), NS.Float(size.y)}}
	frame := intrinsics.objc_send(NS.Rect, s.win, "frameRectForContentRect:", content)
	old := s.win->frame()
	frame.origin.x = old.origin.x
	frame.origin.y = old.origin.y + old.size.height - frame.size.height
	intrinsics.objc_send(nil, s.win, "setFrame:display:animate:", frame, NS.BOOL(true), NS.BOOL(false))
	if c.debug_files {
		fmt.eprintfln("baldr/cocoa: surface %v asked for %.0fx%.0f, frame now %.0fx%.0f",
			id, size.x, size.y, f64(frame.size.width), f64(frame.size.height))
	}
	// windowDidResize fires re-entrantly from inside setFrame:, so the
	// Ev_Configure the contract asks for is already queued.
}

// b_surface_set_fullscreen asks for the whole screen. AppKit animates the
// change, so the answer is the Ev_Configure the delegate sends once it is
// done, never from here.
@(private)
b_surface_set_fullscreen :: proc(b: ^platform.Backend, id: platform.Surface, on: bool) -> bool {
	c := self(b)
	s := find(c, id)
	if s == nil || s.win == nil do return false
	if window_is_fullscreen(s.win) == on do return true // already there: nothing to ask for

	// Without FullScreenPrimary, toggleFullScreen: silently does nothing.
	behavior := intrinsics.objc_send(NS.UInteger, s.win, "collectionBehavior")
	if behavior & BEHAVIOR_FULLSCREEN_PRIMARY == 0 {
		intrinsics.objc_send(nil, s.win, "setCollectionBehavior:", behavior | BEHAVIOR_FULLSCREEN_PRIMARY)
	}
	intrinsics.objc_send(nil, s.win, "toggleFullScreen:", ObjC.id(nil))
	if c.debug_files do fmt.eprintfln("baldr/cocoa: surface %v asked for fullscreen %v", id, on)
	return true
}
