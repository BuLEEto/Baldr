#+build darwin
package main

// An NSView subclass, built at runtime with the objc runtime.
//
// The bindings have a helper for *window delegates*
// (window_delegate_register_and_alloc) but none for views, so this is the
// hand-rolled `objc_allocateClassPair` + `class_addMethod` path. The backend
// needs it for four things a stock NSView cannot do:
//
//   1. isFlipped → YES. AppKit's default view has its origin at the bottom
//      left; Baldr's coordinates are top-left, as every other platform's
//      are. Overriding isFlipped moves the whole conversion into one method
//      instead of flipping every mouse y by hand.
//   2. acceptsFirstResponder → YES, or the view is never sent keys.
//   3. acceptsFirstMouse → YES, or the click that brings a background
//      window forward is swallowed instead of reaching the app.
//   4. It is where the CAMetalLayer hangs, and where NSAccessibility lives.
//
// Everything is recorded through `note`, so the output shows whether a given
// path reaches the *view* or only the event queue.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"

view_hits: struct {
	key_down, key_up:   int,
	mouse_down, mouse_up: int,
	moved, scrolled:    int,
	draw_rect:          int,
	first:              bool, // has anything reached the view at all
}

@(private = "file")
cls: ObjC.Class

// --- the methods. Each is `proc "c" (self, _cmd, …)`, which is the shape the
// objc runtime calls. There is no Odin context in here, so nothing may
// allocate without setting one up; printing is deferred to the pump by way
// of the counters above.

@(private = "file")
view_is_flipped :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	return true // top-left origin, matching Baldr and every other backend
}

@(private = "file")
view_accepts_first_responder :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	return true
}

@(private = "file")
view_accepts_first_mouse :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) -> NS.BOOL {
	return true
}

@(private = "file")
view_key_down :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {
	view_hits.key_down += 1
	view_hits.first = true
}

@(private = "file")
view_key_up :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {
	view_hits.key_up += 1
}

@(private = "file")
view_mouse_down :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {
	view_hits.mouse_down += 1
	view_hits.first = true
}

@(private = "file")
view_mouse_up :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {
	view_hits.mouse_up += 1
}

@(private = "file")
view_mouse_moved :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {
	view_hits.moved += 1
}

@(private = "file")
view_scroll_wheel :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {
	view_hits.scrolled += 1
}

@(private = "file")
view_draw_rect :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, rect: NS.Rect) {
	view_hits.draw_rect += 1
}

// view_make registers the class once and returns an instance of it, sized to
// `frame`. nil if the class could not be made.
view_make :: proc(frame: NS.Rect) -> ^NS.View {
	if cls == nil {
		super := intrinsics.objc_find_class("NSView")
		if super == nil do return nil
		cls = ObjC.objc_allocateClassPair(super, "BaldrSpikeView", 0)
		if cls == nil do return nil // already registered, or refused

		// "B@:" is BOOL (self, _cmd); "v@:@" is void (self, _cmd, object);
		// the drawRect: encoding carries the struct.
		// sel_registerName, not intrinsics.objc_find_selector: the intrinsic
		// needs a compile-time literal, so it cannot be wrapped in a helper.
		add :: proc(sel: cstring, imp: rawptr, types: cstring) {
			ObjC.class_addMethod(cls, ObjC.sel_registerName(sel), auto_cast imp, types)
		}
		add("isFlipped", auto_cast view_is_flipped, "B@:")
		add("acceptsFirstResponder", auto_cast view_accepts_first_responder, "B@:")
		add("acceptsFirstMouse:", auto_cast view_accepts_first_mouse, "B@:@")
		add("keyDown:", auto_cast view_key_down, "v@:@")
		add("keyUp:", auto_cast view_key_up, "v@:@")
		add("mouseDown:", auto_cast view_mouse_down, "v@:@")
		add("mouseUp:", auto_cast view_mouse_up, "v@:@")
		add("mouseMoved:", auto_cast view_mouse_moved, "v@:@")
		add("scrollWheel:", auto_cast view_scroll_wheel, "v@:@")
		// Spelled out: AppKit's own `_RECT_ENCODING` is private to its package.
		add("drawRect:", auto_cast view_draw_rect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}")
		ObjC.objc_registerClassPair(cls)
	}
	// class_createInstance rather than sending `alloc`: objc_send wants a
	// receiver derived from objc_object, and a Class is not one.
	obj := ObjC.class_createInstance(cls, 0)
	if obj == nil do return nil
	// and cast before sending: objc_send wants a type carrying
	// @(objc_class=…), which a bare `id` does not.
	v := cast(^NS.View)obj
	return intrinsics.objc_send(^NS.View, v, "initWithFrame:", frame)
}

view_report :: proc(v: ^NS.View) {
	if v == nil { fmt.println("view: nil"); return }
	b := v->bounds()
	flipped := intrinsics.objc_send(NS.BOOL, v, "isFlipped")
	wants := v->wantsLayer()
	layer := v->layer()
	fmt.printfln("view: bounds %.0fx%.0f isFlipped=%v wantsLayer=%v layer=%v",
		f64(b.size.width), f64(b.size.height), bool(flipped), bool(wants), layer != nil)
}

view_hits_line :: proc() -> string {
	return fmt.tprintf("view got: keyDown=%d keyUp=%d mouseDown=%d mouseUp=%d moved=%d scroll=%d drawRect=%d",
		view_hits.key_down, view_hits.key_up, view_hits.mouse_down, view_hits.mouse_up,
		view_hits.moved, view_hits.scrolled, view_hits.draw_rect)
}
