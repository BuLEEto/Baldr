#+build darwin
package cocoa

// The NSView subclass and the window delegate.
//
// The bindings build window-delegate classes but have no helper for views,
// so the view is made through the objc runtime: objc_allocateClassPair +
// class_addMethod, with the owning Surface in the instance's indexed ivars
// so a `proc "c"` callback can find it without a global.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"
import "baldr:platform"

// surface_of recovers the Surface a view belongs to, from the pointer kept
// in its indexed ivars.
@(private)
surface_of :: proc "contextless" (self: ObjC.id) -> ^Surface {
	slot := (^^Surface)(ObjC.object_getIndexedIvars(self))
	if slot == nil do return nil
	return slot^
}

@(private)
v_is_flipped :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	return true // top-left origin, like every other backend
}

@(private)
v_accepts_first_responder :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	return true // or the view is never sent a key
}

@(private)
v_accepts_first_mouse :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) -> NS.BOOL {
	return true // or the click that raises a background window is swallowed
}

// The input methods are empty: `pump` has already translated the NSEvent.
// They must exist, because NSResponder beeps at an unhandled key.
@(private)
v_swallow :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {}

@(private)
view_class_make :: proc(c: ^Cocoa) -> ObjC.Class {
	if c.view_class != nil do return c.view_class
	super := intrinsics.objc_find_class("NSView")
	if super == nil do return nil
	// extraBytes carries one pointer: the Surface this view belongs to.
	cls := ObjC.objc_allocateClassPair(super, "BaldrView", size_of(rawptr))
	if cls == nil do return nil

	add :: proc(cls: ObjC.Class, sel: cstring, imp: rawptr, types: cstring) {
		// sel_registerName, not intrinsics.objc_find_selector: the intrinsic
		// needs a compile-time literal, so it cannot be used from a helper.
		ObjC.class_addMethod(cls, ObjC.sel_registerName(sel), auto_cast imp, types)
	}
	add(cls, "isFlipped", auto_cast v_is_flipped, "B@:")
	add(cls, "acceptsFirstResponder", auto_cast v_accepts_first_responder, "B@:")
	add(cls, "acceptsFirstMouse:", auto_cast v_accepts_first_mouse, "B@:@")
	// cursor.odin: AppKit asks the view what the pointer should be over it.
	add(cls, "resetCursorRects", auto_cast v_reset_cursor_rects, "v@:")
	// drag.odin: the view is both ends of a drag — the destination for what
	// arrives (NSDraggingDestination) and the source for what leaves
	// (NSDraggingSource). An encoding of "L" is NSDragOperation, which is
	// an NSUInteger bit set and not an enum.
	add(cls, "draggingEntered:", auto_cast v_dragging_entered, "L@:@")
	add(cls, "draggingUpdated:", auto_cast v_dragging_updated, "L@:@")
	add(cls, "draggingExited:", auto_cast v_dragging_exited, "v@:@")
	add(cls, "prepareForDragOperation:", auto_cast v_prepare_for_drag, "B@:@")
	add(cls, "performDragOperation:", auto_cast v_perform_drag, "B@:@")
	add(cls, "draggingSession:sourceOperationMaskForDraggingContext:", auto_cast v_source_mask, "L@:@q")
	add(cls, "draggingSession:endedAtPoint:operation:", auto_cast v_session_ended, "v@:@{CGPoint=dd}L")
	for sel in ([]cstring{"keyUp:", "mouseDown:", "mouseUp:", "mouseMoved:",
		"mouseDragged:", "rightMouseDown:", "rightMouseUp:", "scrollWheel:"}) {
		add(cls, sel, auto_cast v_swallow, "v@:@")
	}
	// ime.odin: keyDown is not swallowed but handed to the input context,
	// where text comes from. The rest is NSTextInputClient, whose encodings
	// carry NSRange as two unsigned words and NSRect as four doubles.
	add(cls, "keyDown:", auto_cast v_key_down, "v@:@")
	add(cls, "insertText:replacementRange:", auto_cast v_insert_text, "v@:@{_NSRange=QQ}")
	add(cls, "setMarkedText:selectedRange:replacementRange:", auto_cast v_set_marked_text, "v@:@{_NSRange=QQ}{_NSRange=QQ}")
	add(cls, "unmarkText", auto_cast v_unmark_text, "v@:")
	add(cls, "hasMarkedText", auto_cast v_has_marked_text, "B@:")
	add(cls, "markedRange", auto_cast v_marked_range, "{_NSRange=QQ}@:")
	add(cls, "selectedRange", auto_cast v_selected_range, "{_NSRange=QQ}@:")
	add(cls, "attributedSubstringForProposedRange:actualRange:", auto_cast v_attributed_substring, "@@:{_NSRange=QQ}^{_NSRange=QQ}")
	add(cls, "validAttributesForMarkedText", auto_cast v_valid_attributes, "@@:")
	add(cls, "firstRectForCharacterRange:actualRange:", auto_cast v_first_rect, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}")
	add(cls, "characterIndexForPoint:", auto_cast v_character_index, "Q@:{CGPoint=dd}")
	add(cls, "doCommandBySelector:", auto_cast v_do_command, "v@::")
	// The class must declare the protocol: `[NSView inputContext]` is nil
	// for a view that does not claim NSTextInputClient, and having the
	// methods is not claiming it. Without it no typing arrives.
	if proto := ObjC.objc_getProtocol("NSTextInputClient"); proto != nil {
		ObjC.class_addProtocol(cls, proto)
	}
	ObjC.objc_registerClassPair(cls)
	c.view_class = cls
	return cls
}

@(private)
view_make :: proc(c: ^Cocoa, s: ^Surface, frame: NS.Rect) -> ^NS.View {
	cls := view_class_make(c)
	if cls == nil do return nil
	obj := ObjC.class_createInstance(cls, size_of(rawptr))
	if obj == nil do return nil
	if slot := (^^Surface)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = s
	// Cast before sending: objc_send wants a type carrying @(objc_class=…),
	// which a bare `id` does not, and `alloc` cannot be sent to a Class.
	v := cast(^NS.View)obj
	v = intrinsics.objc_send(^NS.View, v, "initWithFrame:", frame)
	if v != nil do drag_register(v) // …and it takes drops (drag.odin)
	return v
}

// --- the window delegate
//
// Everything `pump` cannot read off the event queue arrives here: resize,
// close, focus, scale. These run inside a pump call on the main thread, so
// appending to the queue needs no lock.

@(private)
del_surface :: proc() -> ^Surface {
	// window_delegate_register_and_alloc runs each callback under the
	// context given at registration, so the Surface rides in user_ptr.
	return (^Surface)(context.user_ptr)
}

@(private)
make_delegate :: proc(c: ^Cocoa, s: ^Surface) -> ^NS.WindowDelegate {
	ctx := c.ctx
	ctx.user_ptr = s

	// A class name may only be registered once, and the helper allocates a
	// fresh class per call, so each window needs its own name.
	name := fmt.tprintf("BaldrWindowDelegate%d", u32(s.id))

	return NS.window_delegate_register_and_alloc({
		windowDidResize = proc(n: ^NS.Notification) {
			s := del_surface()
			if s == nil do return
			f := s.win->frame()
			cv := s.win->contentView()
			h := f32(f.size.height)
			if cv != nil do h = f32(cv->bounds().size.height)
			s.size = {f32(f.size.width), h}
			s.scale = f32(s.win->backingScaleFactor())
			// A layer set with setLayer does not track its view, so its frame
			// is set here; otherwise AppKit stretches the old contents into
			// the new bounds for the whole drag, presentsWithTransaction or not.
			if cv != nil && s.layer != nil {
				b := cv->bounds()
				s.layer->setFrame(b)
				sc := f64(s.scale)
				s.layer->setDrawableSize({NS.Float(f64(b.size.width) * sc), NS.Float(f64(b.size.height) * sc)})
			}
			append(&s.cocoa.queue, configure_of(s))
			// Paint from inside the drag: AppKit runs a nested run loop for a
			// live resize, so `pump` is blocked until the mouse is let go.
			// Backend.redraw_callback (as for Win32's WM_ENTERSIZEMOVE) lays
			// out and paints at the live geometry from here.
			b := &s.cocoa.backend
			if b.redraw_callback != nil {
				b.redraw_callback(b.redraw_user, s.id)
			} else {
				s.frame_requested = true
			}
		},
		windowDidChangeBackingProperties = proc(n: ^NS.Notification) {
			s := del_surface()
			if s == nil do return
			s.scale = f32(s.win->backingScaleFactor())
			append(&s.cocoa.queue, configure_of(s))
		},
		// The answer to surface_set_fullscreen: AppKit animates the window in
		// and out, and only these say it has got there.
		windowDidEnterFullScreen = proc(n: ^NS.Notification) {
			if s := del_surface(); s != nil {
				f := s.win->frame()
				cv := s.win->contentView()
				h := f32(f.size.height)
				if cv != nil do h = f32(cv->bounds().size.height)
				s.size = {f32(f.size.width), h}
				append(&s.cocoa.queue, configure_of(s))
			}
		},
		windowDidExitFullScreen = proc(n: ^NS.Notification) {
			if s := del_surface(); s != nil {
				f := s.win->frame()
				cv := s.win->contentView()
				h := f32(f.size.height)
				if cv != nil do h = f32(cv->bounds().size.height)
				s.size = {f32(f.size.width), h}
				append(&s.cocoa.queue, configure_of(s))
			}
		},
		windowDidBecomeKey = proc(n: ^NS.Notification) {
			if s := del_surface(); s != nil {
				append(&s.cocoa.queue, platform.Ev_Focus{surface = s.id, focused = true})
			}
		},
		windowDidResignKey = proc(n: ^NS.Notification) {
			if s := del_surface(); s != nil {
				append(&s.cocoa.queue, platform.Ev_Focus{surface = s.id, focused = false})
			}
		},
		windowShouldClose = proc(sender: ^NS.Window) -> NS.BOOL {
			// NO, always: an on_close may refuse, so this posts a close event
			// and the app calls surface_destroy. YES would destroy the window
			// before the app heard of it.
			if s := del_surface(); s != nil {
				append(&s.cocoa.queue, platform.Ev_Close{surface = s.id, reason = .User})
			}
			return false
		},
	}, name, ctx)
}
