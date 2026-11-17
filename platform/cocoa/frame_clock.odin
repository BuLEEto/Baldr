#+build darwin
package cocoa

// Waking the pump, and a frame clock the display drives. One mechanism:
// something outside `b_pump` has to be able to make `nextEventMatchingMask`
// return.
//
// A wake posts an application-defined NSEvent, the documented way to make
// the event loop return and one of the few AppKit calls safe from another
// thread. The pump recognises it, discards it, and returns what the queue
// holds. Callers include the menu bar (`menu_wake`), `A11y_Window.wake` and
// a worker posting to the mailbox.
//
// The frame clock is a `CADisplayLink` per surface, so a due frame waits for
// the display rather than for a timeout, which AppKit treats as advisory (a
// 16 ms wait can return after 29). `NSView.displayLinkWithTarget:selector:`
// and not `CVDisplayLink`, which is deprecated from macOS 15 and calls back
// on its own thread; a CADisplayLink is driven by the run loop, so it fires
// inside the pump's own wait. The link also reports the display's true
// refresh interval.

import "base:intrinsics"
import "core:fmt"
import "core:os"
import ObjC "core:sys/darwin/ObjectiveC"
import NS "vendor:darwin/AppKit"

// The two classes this file talks to. A class method takes the type as its
// receiver, as `shared_workspace` does for NSWorkspace; a `^Display_Link`
// is what an `objc_send` needs where the runtime hands back a bare `id`.
@(private) @(objc_class = "NSRunLoop")
Run_Loop :: struct {using _: NS.Object}

@(private) @(objc_class = "CADisplayLink")
Display_Link :: struct {using _: NS.Object}

// WAKE_SUBTYPE marks the event a wake posts, so the pump can tell it from an
// application-defined event an app or a framework posted for its own reasons
// and must still see.
@(private)
WAKE_SUBTYPE :: i16(0x_0b1d)

// wake_post makes the pump return. Safe from any thread: `postEvent:atStart:`
// is documented as such. An event and not a run-loop source, because a
// source signal does not make `nextEventMatchingMask` return before its date.
@(private)
wake_post :: proc(c: ^Cocoa) {
	if c.app == nil do return
	ev := NS.Event.otherEventWithType(
		.ApplicationDefined, NS.Point{0, 0}, {}, 0, 0, nil, WAKE_SUBTYPE, 0, 0)
	if ev == nil do return
	c.app->postEvent(ev, true) // atStart: ahead of what is already queued
}

// wake_event is whether this is one of ours, to be swallowed rather than
// translated or handed to AppKit.
@(private)
wake_event :: proc(ev: ^NS.Event) -> bool {
	if ev == nil || ev->type() != .ApplicationDefined do return false
	return i16(ev->subtype()) == WAKE_SUBTYPE
}

// ---------------------------------------------------------- the frame clock

// Clock is one surface's display link and what it has measured.
Clock :: struct {
	link:    ^NS.Object, // the CADisplayLink, retained by the run loop it is added to
	running: bool,
	// The interval the display actually reported, in ms, and whether it has
	// reported one yet. Until it has, the backend says so (`estimated`)
	// rather than inventing a number.
	refresh_ms: f64,
	measured:   bool,
	// Whether the link has ever fired. The pump trusts this and not
	// `running`: a running but silent link (a view not yet in a window, a
	// display asleep) would otherwise remove the fallback clamp and leave
	// the surface waiting out the caller's whole timeout.
	ticked: bool,
}

// clock_init reads `BALDR_NO_DISPLAY_LINK=1`, which falls back to the
// one-refresh clamp in `b_pump` in case a display link misbehaves. Read
// once: `clock_want` runs for every frame, and `os.get_env` allocates.
@(private)
clock_init :: proc(c: ^Cocoa) {
	c.clock_off = os.get_env("BALDR_NO_DISPLAY_LINK", context.temp_allocator) == "1"
}

// clock_want starts or stops a surface's link. Called wherever `frames` or
// `frame_requested` changes, and on close.
@(private)
clock_want :: proc(c: ^Cocoa, s: ^Surface, on: bool) {
	if s == nil || c.clock_off do return
	if on {
		if s.clock.link == nil do clock_make(c, s)
		if s.clock.link != nil && !s.clock.running {
			intrinsics.objc_send(nil, s.clock.link, "setPaused:", NS.BOOL(false))
			s.clock.running = true
			if c.debug_files do fmt.eprintfln("baldr/cocoa: link running for surface %d", s.id)
		}
		if c.debug_files && s.clock.link == nil {
			fmt.eprintfln("baldr/cocoa: no link for surface %d (view %v)", s.id, s.view)
		}
		return
	}
	// Paused, not released: a link is cheap to hold and costly to make, and
	// `frames` goes on and off with every animation.
	if s.clock.link != nil && s.clock.running {
		intrinsics.objc_send(nil, s.clock.link, "setPaused:", NS.BOOL(true))
		s.clock.running = false
	}
}

// clock_make asks the view for a link and puts it on this thread's run loop.
@(private)
clock_make :: proc(c: ^Cocoa, s: ^Surface) {
	if s.view == nil do return
	target := clock_target(c)
	if target == nil do return
	sel := ObjC.sel_registerName("baldrFrameTick:")
	link := intrinsics.objc_send(^NS.Object, s.view, "displayLinkWithTarget:selector:", target, sel)
	if c.debug_files do fmt.eprintfln("baldr/cocoa: display link for surface %d: %v", s.id, link)
	if link == nil do return
	// The link fires only on a run loop, in the modes the pump waits in.
	// The modes are passed by their symbols: a hand-built mode string never
	// fires and gives no error. Event tracking is added because the default
	// mode alone stops the clock while a scroll bar is dragged or a menu is
	// held open.
	loop := intrinsics.objc_send(^Run_Loop, Run_Loop, "currentRunLoop")
	if loop == nil do return
	intrinsics.objc_send(nil, link, "addToRunLoop:forMode:", loop, NS.DefaultRunLoopMode)
	intrinsics.objc_send(nil, link, "addToRunLoop:forMode:", loop, NS.EventTrackingRunLoopMode)
	intrinsics.objc_send(nil, link, "setPaused:", NS.BOOL(true))
	if c.debug_files {
		paused := bool(intrinsics.objc_send(NS.BOOL, link, "isPaused"))
		dur := f64(intrinsics.objc_send(NS.TimeInterval, cast(^Display_Link)link, "duration"))
		fmt.eprintfln("baldr/cocoa: link on the run loop, paused %v, duration %.4f s", paused, dur)
	}
	// The surface this link belongs to, so the callback can find it without
	// a global. The ivar holds the ^Surface; the target holds the ^Cocoa.
	s.clock.link, s.clock.running = link, false
	if s.clock.refresh_ms <= 0 do s.clock.refresh_ms = 1000.0 / 60.0
}

// clock_stop releases a surface's link, on close.
@(private)
clock_stop :: proc(s: ^Surface) {
	if s == nil || s.clock.link == nil do return
	intrinsics.objc_send(nil, s.clock.link, "invalidate")
	s.clock = {}
}

// clock_target is the object the links send `baldrFrameTick:` to — one for
// the whole backend, holding the ^Cocoa in its indexed ivars, which is the
// same shape as `menu_target`.
@(private = "file")
clock_target :: proc(c: ^Cocoa) -> ^NS.Object {
	if c.clock_target != nil do return c.clock_target
	if c.clock_class == nil {
		super := intrinsics.objc_find_class("NSObject")
		if super == nil do return nil
		cls := ObjC.objc_allocateClassPair(super, "BaldrFrameClock", size_of(rawptr))
		if cls == nil do return nil
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrFrameTick:"), auto_cast m_tick, "v@:@")
		ObjC.objc_registerClassPair(cls)
		c.clock_class = cls
	}
	obj := ObjC.class_createInstance(c.clock_class, size_of(rawptr))
	if obj == nil do return nil
	if slot := (^^Cocoa)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = c
	c.clock_target = cast(^NS.Object)obj
	return c.clock_target
}

@(private = "file")
clock_owner :: proc "c" (self: ObjC.id) -> ^Cocoa {
	if self == nil do return nil
	slot := (^^Cocoa)(ObjC.object_getIndexedIvars(self))
	return slot^ if slot != nil else nil
}

// m_tick is the display saying it is ready for another frame. It records the
// interval the link reports and wakes the pump; it does not queue an event
// of its own, because `b_pump` already decides what a due frame becomes
// (an Ev_Redraw, and an Ev_Frame only while continuous frames are wanted).
@(private = "file")
m_tick :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := clock_owner(self)
	if c == nil do return
	context = c.ctx
	// `duration` is how long the next frame will be shown on the window's
	// screen: the true refresh interval.
	link := cast(^Display_Link)sender
	ms := f64(intrinsics.objc_send(NS.TimeInterval, link, "duration")) * 1000.0
	// Recorded on the surface that owns this link: two windows can be on
	// displays of different rates.
	if ms > 0.1 && ms < 1000 {
		for s in c.surfaces do if s != nil && s.clock.link == cast(^NS.Object)sender {
			first := !s.clock.ticked
			s.clock.refresh_ms, s.clock.measured, s.clock.ticked = ms, true, true
			if first && c.debug_files {
				fmt.eprintfln("baldr/cocoa: first display tick, surface %d, %.3f ms (%.1f Hz)",
					s.id, ms, 1000.0 / ms)
			}
			break
		}
	}
	// Only while the pump is waiting: a wake on every tick restarts the
	// pump's drain loop at the display's rate, and it never reaches the code
	// that emits a frame. The callback runs on the main thread inside that
	// wait, so the flag is exact, and one wake ends one wait.
	if c.in_wait do wake_post(c)
}
