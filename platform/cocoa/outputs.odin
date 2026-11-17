#+build darwin
package cocoa

// The screens, and where a window is on them.
//
// AppKit's global space puts the primary screen's bottom-left at (0,0) with
// y rising; `Output.pos` has a top-left origin, as on Wayland and Win32. So
// every y is flipped about the primary screen's top edge, in `flip_y`. A
// wrong flip in `surface_position` would walk a restored window down the
// display at every launch.
//
// The desktop plane is logical (points), as on Wayland and unlike Windows:
// a screen's rectangle is `pos + size`, and `mode_px` is the same rectangle
// in device pixels.
//
// `Ev_Outputs` comes from AppKit's notification, and only when something the
// toolkit reports changed: a colour-profile change fires the notification
// too.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "baldr:platform"

@(private) @(objc_class = "NSNotificationCenter")
Note_Centre :: struct {using _: NS.Object}

@(private)
NOTE_SCREENS_CHANGED :: "NSApplicationDidChangeScreenParametersNotification"

@(private)
b_outputs :: proc(b: ^platform.Backend) -> []platform.Output {
	return self(b).screens[:]
}

// primary_top is the y of the top edge of the screen AppKit measures from,
// which is the first in its list. Everything else is flipped about it.
@(private = "file")
primary_top :: proc() -> f64 {
	screens := intrinsics.objc_send(^NS.Array, NS.Screen, "screens")
	if screens == nil || screens->count() == 0 do return 0
	first := intrinsics.objc_send(^NS.Screen, screens->object(0), "self")
	if first == nil do return 0
	f := first->frame()
	return f64(f.origin.y) + f64(f.size.height)
}

// flip_y turns an AppKit y (bottom-left origin, y up) into the desktop's
// own (top-left origin, y down), given the height of the thing being
// placed. The same arithmetic both ways, which is why it is one proc.
@(private)
flip_y :: proc(y, height, top: f64) -> f64 {
	return top - (y + height)
}

// outputs_refresh re-reads the screens and says whether anything the
// toolkit hears about changed.
@(private)
outputs_refresh :: proc(c: ^Cocoa) -> (changed: bool) {
	screens := intrinsics.objc_send(^NS.Array, NS.Screen, "screens")
	if screens == nil do return false
	top := primary_top()
	n := int(screens->count())
	next := make([dynamic]platform.Output, 0, n, c.allocator)
	for i in 0 ..< n {
		sc := intrinsics.objc_send(^NS.Screen, screens->object(NS.UInteger(i)), "self")
		if sc == nil do continue
		f := sc->frame()
		scale := f32(sc->backingScaleFactor())
		if scale <= 0 do scale = 1
		o := platform.Output{
			pos     = {i32(f64(f.origin.x)), i32(flip_y(f64(f.origin.y), f64(f.size.height), top))},
			size    = {i32(f.size.width), i32(f.size.height)},
			mode_px = {i32(f64(f.size.width) * f64(scale)), i32(f64(f.size.height) * f64(scale))},
			scale   = scale,
			// macOS rotates a display by rewriting its frame, so a rotated
			// screen already reports the shape it is now.
			transform = .Normal,
			refresh   = i32(intrinsics.objc_send(NS.Integer, sc, "maximumFramesPerSecond")) * 1000,
		}
		// macOS has no connector name. The display number is stable, so it is
		// `name` (which surfaces are matched against); the readable name is
		// the description.
		o.name = screen_id_name(sc, i, c.allocator)
		o.description = screen_label(sc, c.allocator)
		append(&next, o)
	}

	changed = !outputs_same(c.screens[:], next[:])
	if !changed {
		outputs_free(next[:], c.allocator)
		delete(next)
		return
	}
	outputs_free(c.screens[:], c.allocator)
	delete(c.screens)
	c.screens = next
	if c.debug_files {
		for o in c.screens {
			fmt.eprintfln("baldr/cocoa: screen %s (%s) at %d,%d %dx%d logical, %dx%d px, scale %.2f, %d Hz",
				o.name, o.description, o.pos.x, o.pos.y, o.size.x, o.size.y,
				o.mode_px.x, o.mode_px.y, o.scale, o.refresh / 1000)
		}
	}
	return
}

// screen_id_name is the display's own number, which survives a rename and is
// stable across runs.
@(private = "file")
screen_id_name :: proc(sc: ^NS.Screen, index: int, allocator := context.allocator) -> string {
	id: NS.Integer
	if desc := intrinsics.objc_send(^NS.Object, sc, "deviceDescription"); desc != nil {
		key := ns_str("NSScreenNumber")
		if key != nil {
			defer key->release()
			if num := intrinsics.objc_send(^NS.Object, desc, "objectForKey:", key); num != nil {
				id = intrinsics.objc_send(NS.Integer, num, "integerValue")
			}
		}
	}
	text := fmt.tprintf("display-%d", id if id != 0 else NS.Integer(index + 1))
	out, err := strings.clone(text, allocator)
	return out if err == nil else ""
}

// screen_label is what the person's own Displays settings call it ("Studio
// Display", "Built-in Retina Display").
@(private = "file")
screen_label :: proc(sc: ^NS.Screen, allocator := context.allocator) -> string {
	name := intrinsics.objc_send(^NS.String, sc, "localizedName")
	if name == nil do return ""
	out, err := strings.clone(string(name->odinString()), allocator)
	return out if err == nil else ""
}

@(private = "file")
outputs_same :: proc(a, b: []platform.Output) -> bool {
	if len(a) != len(b) do return false
	for o, i in a {
		n := b[i]
		if o.name != n.name || o.description != n.description do return false
		if o.pos != n.pos || o.size != n.size || o.mode_px != n.mode_px do return false
		if o.scale != n.scale || o.refresh != n.refresh || o.transform != n.transform do return false
	}
	return true
}

@(private = "file")
outputs_free :: proc(list: []platform.Output, allocator := context.allocator) {
	for o in list {
		delete(o.name, allocator)
		delete(o.description, allocator)
	}
}

@(private)
outputs_shutdown :: proc(c: ^Cocoa) {
	outputs_free(c.screens[:], c.allocator)
	delete(c.screens)
	if c.screens_watch != nil {
		if centre := intrinsics.objc_send(^NS.Object, Note_Centre, "defaultCenter"); centre != nil {
			intrinsics.objc_send(nil, centre, "removeObserver:", c.screens_watch)
		}
		intrinsics.objc_send(nil, c.screens_watch, "release")
		c.screens_watch = nil
	}
}

// outputs_watch asks AppKit to say when the screens change, rather than
// re-reading them every pump: a display asleep, plugged in, rearranged or
// rescaled all arrive here.
@(private)
outputs_watch :: proc(c: ^Cocoa) {
	if c.screens_watch != nil do return
	super := intrinsics.objc_find_class("NSObject")
	if super == nil do return
	cls := ObjC.objc_allocateClassPair(super, "BaldrScreenWatch", size_of(rawptr))
	if cls == nil do return
	ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrScreensChanged:"), auto_cast m_screens_changed, "v@:@")
	ObjC.objc_registerClassPair(cls)
	obj := ObjC.class_createInstance(cls, size_of(rawptr))
	if obj == nil do return
	if slot := (^^Cocoa)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = c
	c.screens_watch = cast(^NS.Object)obj

	centre := intrinsics.objc_send(^NS.Object, Note_Centre, "defaultCenter")
	if centre == nil do return
	name := ns_str(NOTE_SCREENS_CHANGED)
	if name == nil do return
	defer name->release()
	intrinsics.objc_send(nil, centre, "addObserver:selector:name:object:",
		c.screens_watch, ObjC.sel_registerName("baldrScreensChanged:"), name, ObjC.id(nil))
}

@(private = "file")
m_screens_changed :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, note: ObjC.id) {
	slot := (^^Cocoa)(ObjC.object_getIndexedIvars(self))
	if slot == nil || slot^ == nil do return
	c := slot^
	context = c.ctx
	if !outputs_refresh(c) do return // the profile changed, or something else nobody asked about
	append(&c.queue, platform.Ev_Outputs{})
	b_wake(&c.backend)
}

// b_surface_position is where the window's top-left is, frame included, in
// the same plane `Output.pos` uses. NSWindow.frame *is* the frame — title
// bar and all — which is what the contract asks for.
@(private)
b_surface_position :: proc(b: ^platform.Backend, id: platform.Surface) -> (pos: [2]i32, ok: bool) {
	c := self(b)
	s := find(c, id)
	if s == nil || s.win == nil do return {}, false
	f := s.win->frame()
	top := primary_top()
	return {i32(f64(f.origin.x)), i32(flip_y(f64(f.origin.y), f64(f.size.height), top))}, true
}

// surface_place puts a new window where the app asked (`Surface_Desc.position`),
// turning the desktop's top-left coordinates back into AppKit's: the other
// half of surface_position's round trip.
@(private)
surface_place :: proc(win: ^NS.Window, pos: [2]i32) {
	f := win->frame()
	top := primary_top()
	origin := NS.Point{NS.Float(f64(pos.x)), NS.Float(flip_y(f64(pos.y), f64(f.size.height), top))}
	intrinsics.objc_send(nil, win, "setFrameOrigin:", origin)
}
