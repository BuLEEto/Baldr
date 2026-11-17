#+build darwin
package main

// A real window on macOS, with no renderer at all: the platform primitives
// platform/cocoa is built on, proved in isolation, like spikes/wl_triangle
// and spikes/win32_triangle. Nothing is drawn — a window that opens,
// resizes, reports its scale and delivers input is checkable without a
// single pixel.
//
// It also measures the push→pull bridge. `Backend.pump(timeout_ms) -> []Event`
// is a poll; AppKit's window callbacks are a push. Everything the pump cannot
// read off the event queue — resize, close, focus, scale and screen changes —
// arrives as a delegate message at AppKit's convenience, so the backend has
// to record those and hand them over when pump is next called. When they
// land relative to a pump decides whether that recording needs a lock or is
// merely re-entrant bookkeeping:
//
//   - every callback notes whether it fired inside a pump call or outside one
//   - the loop reports any gap over GAP_MS between consecutive pumps, which
//     is how a starved pump shows itself
//
// That last one is the macOS analogue of a Win32 hazard: there
// `WM_ENTERSIZEMOVE` blocks the message pump for a whole window drag, so the
// app must render from a timer instead. If AppKit's live resize does the
// same, the backend needs the same answer.
//
// Run: build with tools/mac-sync.sh, then launch the .app bundle (`open` on
// a bundle, not the bare binary). It exits on its own after BUDGET seconds
// so an ssh session never hangs.

import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"

BUDGET :: 25 // seconds, then quit on its own: an ssh session must not hang
GAP_MS :: 100 // a gap between pumps longer than this is a starved pump

// State is what the delegate records and the pump drains: a Baldr backend
// keeps exactly this kind of queue.
State :: struct {
	win:         ^NS.Window,
	in_pump:     bool, // set around the one call that can run AppKit's own code
	pending:     [dynamic]string,
	outside:     int, // callbacks that fired while NOT inside a pump
	inside:      int,
	live_resize: bool,
	started:     time.Tick,
}

g: State

note :: proc(kind: string, detail: string) {
	place := "outside a pump"
	if g.in_pump {
		g.inside += 1
		place = "inside a pump"
	} else {
		g.outside += 1
	}
	at := time.duration_milliseconds(time.tick_since(g.started))
	append(&g.pending, fmt.aprintf("%8.1f ms  %-32s %-16s %s", at, kind, place, detail))
}

window_now :: proc() -> string {
	if g.win == nil do return ""
	f := g.win->frame()
	return fmt.tprintf("frame %.0fx%.0f at %.0f,%.0f scale=%.2f",
		f64(f.size.width), f64(f.size.height), f64(f.origin.x), f64(f.origin.y),
		f64(g.win->backingScaleFactor()))
}

// drag_corner prints the window's bottom-right corner in CGEvent's
// coordinates — origin TOP LEFT — so tools/mac_click can grab the resize
// corner without anyone converting by hand. NSWindow.frame has its origin at
// the bottom left, and getting that backwards drags the mirror image.
drag_corner :: proc() -> string {
	if g.win == nil do return ""
	f := g.win->frame()
	screen_h := 0.0
	if sc := NS.Screen.screens(); sc != nil && sc->count() > 0 {
		screen_h = f64(sc->objectAs(0, ^NS.Screen)->frame().size.height)
	}
	x := f64(f.origin.x) + f64(f.size.width) - 3
	y := screen_h - f64(f.origin.y) - 3 // flip: NS bottom-left -> CG top-left
	return fmt.tprintf("%.0f,%.0f", x, y)
}

main :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	g.started = time.tick_now()
	g.pending = make([dynamic]string)

	app := NS.Application.sharedApplication()
	// .Regular is what makes a bare binary a foreground app with a Dock tile
	// and a menu bar. Without it the window appears but never takes focus,
	// which looks exactly like broken event delivery.
	app->setActivationPolicy(.Regular)

	rect := NS.Rect{{100, 100}, {720, 480}}
	style := NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable}
	win := NS.Window.alloc()->initWithContentRect(rect, style, .Buffered, false)
	if win == nil {
		fmt.eprintln("cocoa_window: initWithContentRect gave nil")
		os.exit(1)
	}
	g.win = win

	// Not NS.AT: that is CFSTR, which takes a 7-bit C literal and mangles
	// anything above \177, and a title is arbitrary user text. initWithOdinString
	// is initWithBytesNoCopy underneath, so the Odin string must outlive the
	// NSString: a title from app state is kept or copied, never a temporary.
	title := "Baldr — cocoa_window spike"
	win->setTitle(NS.String.alloc()->initWithOdinString(title))

	// The delegate. The bindings build the class at runtime from this
	// template (objc_allocateClassPair + class_addMethod), so only AppKit the
	// bindings have missed needs the objc runtime by hand.
	del := NS.window_delegate_register_and_alloc({
		windowDidResize = proc(n: ^NS.Notification) {
			note("windowDidResize", g.live_resize ? "during a live resize" : window_now())
		},
		windowWillStartLiveResize = proc(n: ^NS.Notification) {
			g.live_resize = true
			note("windowWillStartLiveResize", "the drag begins — does the pump starve?")
		},
		windowDidEndLiveResize = proc(n: ^NS.Notification) {
			g.live_resize = false
			note("windowDidEndLiveResize", window_now())
		},
		windowDidChangeBackingProperties = proc(n: ^NS.Notification) {
			note("windowDidChangeBackingProperties", window_now()) // scale changed
		},
		windowDidChangeScreen = proc(n: ^NS.Notification) {
			note("windowDidChangeScreen", window_now())
		},
		windowDidBecomeKey = proc(n: ^NS.Notification) { note("windowDidBecomeKey", "focus in") },
		windowDidResignKey = proc(n: ^NS.Notification) { note("windowDidResignKey", "focus out") },
		windowWillClose    = proc(n: ^NS.Notification) { note("windowWillClose", "") },
		windowShouldClose  = proc(sender: ^NS.Window) -> NS.BOOL {
			// A Baldr app owns the decision (on_close can refuse), so the
			// backend answers NO and posts a close event instead: YES would
			// destroy the window before the app heard about it.
			note("windowShouldClose", "answered NO: the app decides, not AppKit")
			return false
		},
	}, "BaldrSpikeWindowDelegate", context)
	if del == nil {
		fmt.eprintln("cocoa_window: window_delegate_register_and_alloc gave nil")
		os.exit(1)
	}
	win->setDelegate(del)

	// The view. Keys only reach a view that is first responder,
	// and mouseMoved: only arrives if the window is told to send it — both
	// off by default, and both look like broken input when missed.
	view := view_make(NS.Rect{{0, 0}, rect.size})
	if view == nil {
		fmt.eprintln("cocoa_window: view_make gave nil")
		os.exit(1)
	}
	view->setWantsLayer(true) // layer-backed, which is what a CAMetalLayer needs
	win->setContentView(view)
	win->setAcceptsMouseMovedEvents(true)
	// makeFirstResponder is not in the bindings; the objc runtime is the door.
	_ = intrinsics.objc_send(NS.BOOL, win, "makeFirstResponder:", view)
	view_report(view)

	win->center()
	win->makeKeyAndOrderFront(nil)
	// finishLaunching: [NSApp run] is never called, because Backend.pump owns
	// the loop, and without this the app is half-launched — invisible to the
	// accessibility API, so neither System Events nor a screen reader can
	// find its window.
	app->finishLaunching()
	app->activateIgnoringOtherApps(true)

	fmt.printfln("window up: %s", window_now())
	report_screens()
	fmt.printfln("appearance: %s", appearance_name())
	fmt.printfln("DRAG_CORNER %s", drag_corner())
	fmt.printfln("--- pumping for %d s; resize, click, type, focus away ---", BUDGET)

	pumps, events, gaps := 0, 0, 0
	idle_worst, gap_worst: time.Duration
	last := time.tick_now()
	for time.duration_seconds(time.tick_since(g.started)) < BUDGET {
		gap := time.tick_since(last)
		if gap > time.Millisecond * GAP_MS {
			gaps += 1
			if gap > gap_worst do gap_worst = gap
			fmt.printfln("!! the pump was away for %.0f ms — starved", time.duration_milliseconds(gap))
		}
		last = time.tick_now()

		// Baldr's Backend.pump(timeout_ms) in miniature: wait up to 16 ms for
		// an event, then come back whether or not one arrived. `distantPast`
		// would make this a spin; a real date is what gives a timeout.
		// Called as a plain proc: the binding is a class method on NSDate but
		// is not tagged `objc_is_class_method`, so `NS.Date.x()` does not
		// resolve and the generated proc has to be named directly.
		mark := time.tick_now()
		until := NS.Date.dateWithTimeIntervalSinceNow(0.016)
		g.in_pump = true
		ev := app->nextEventMatchingMask(NS.EventMaskAny, until, NS.DefaultRunLoopMode, true)
		if ev != nil {
			events += 1
			describe(ev)
			app->sendEvent(ev) // AppKit's own handling: delegates fire in here
		}
		g.in_pump = false
		waited := time.tick_since(mark)

		pumps += 1
		if ev == nil && waited > idle_worst do idle_worst = waited
		for line in g.pending do fmt.println(line)
		clear(&g.pending)

		// one programmatic resize, so windowDidResize is proven to fire
		// without needing a hand on the mouse
		if pumps == 150 {
			fmt.println("-- setting the frame programmatically --")
			f := win->frame()
			win->setFrame(NS.Rect{f.origin, {f.size.width + 80, f.size.height + 40}}, true)
			fmt.printfln("DRAG_CORNER %s", drag_corner())
		}
	}
	fmt.printfln("--- %d pumps, %d events, worst idle pump %.1f ms (asked for 16) ---",
		pumps, events, time.duration_milliseconds(idle_worst))
	fmt.printfln("--- delegate callbacks: %d inside a pump, %d outside; %d starved gaps, worst %.0f ms ---",
		g.inside, g.outside, gaps, time.duration_milliseconds(gap_worst))
	fmt.printfln("--- %s ---", view_hits_line())
	fmt.printfln("final: %s appearance=%s", window_now(), appearance_name())
}

report_screens :: proc() {
	screens := NS.Screen.screens()
	if screens == nil { fmt.println("screens: none reported"); return }
	n := screens->count()
	fmt.printfln("screens: %d", n)
	for i in 0 ..< n {
		s := screens->objectAs(i, ^NS.Screen)
		fr := s->frame()
		fmt.printfln("  %d: %.0fx%.0f at %.0f,%.0f scale=%.2f",
			i, f64(fr.size.width), f64(fr.size.height), f64(fr.origin.x), f64(fr.origin.y),
			f64(s->backingScaleFactor()))
	}
}

describe :: proc(ev: ^NS.Event) {
	kind := ev->type()
	#partial switch kind {
	case .KeyDown, .KeyUp:
		chars := ev->characters()
		s := chars != nil ? string(chars->odinString()) : ""
		fmt.printfln("%v keyCode=%d chars=%q private_use=%v mods=%v repeat=%v",
			kind, ev->keyCode(), s, is_private_use(s), ev->modifierFlags(), bool(ev->isARepeat()))
	case .LeftMouseDown, .LeftMouseUp, .RightMouseDown, .RightMouseUp, .OtherMouseDown, .OtherMouseUp:
		p := ev->locationInWindow()
		fmt.printfln("%v at %.1f,%.1f (window coords, origin bottom-left)", kind, f64(p.x), f64(p.y))
	case .ScrollWheel:
		fmt.printfln("ScrollWheel dx=%.3f dy=%.3f precise=%v",
			f64(ev->scrollingDeltaX()), f64(ev->scrollingDeltaY()), bool(ev->hasPreciseScrollingDeltas()))
	case .FlagsChanged:
		fmt.printfln("FlagsChanged mods=%v", ev->modifierFlags())
	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged:
	// too chatty for a line each; they show up in the totals
	case:
		fmt.printfln("%v", kind)
	}
}

// is_private_use flags the U+F700–U+F8FF block AppKit uses for arrows and
// function keys. A backend must not let these reach a text field as typed
// text — pressing Up would insert a box.
is_private_use :: proc(s: string) -> bool {
	for r in s do if r >= 0xf700 && r <= 0xf8ff do return true
	return false
}

// appearance_name reads the effective light/dark appearance, which Baldr has
// to follow and to notice changing.
appearance_name :: proc() -> string {
	// NSAppearance is not in the bindings, so this goes straight to the
	// objc runtime, as the backend does for anything unbound.
	app := NS.Application.sharedApplication()
	ap := intrinsics.objc_send(^NS.Object, app, "effectiveAppearance")
	if ap == nil do return "unbound or nil"
	n := intrinsics.objc_send(^NS.String, ap, "name")
	if n == nil do return "unnamed"
	return string(n->odinString())
}
