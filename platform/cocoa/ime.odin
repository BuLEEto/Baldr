#+build darwin
package cocoa

// Input methods on macOS, through NSTextInputClient. Dead keys go through
// the same path as CJK composition (Option-e then e is é).
//
// The view hands every keyDown to its input context, and text comes back
// through `insertText:`; the event's `characters` know nothing of a
// composition in progress. `translate` still raises the Ev_Key, because the
// toolkit matches shortcuts against keys, not text.
//
// While there is marked text no Ev_Key is raised: a Return that commits a
// phrase must not also be a Return in the app. `translate` reads the flag
// before the event reaches the input context, so it asks whether a
// composition was already in progress when the key was pressed.
//
// The toolkit draws the preedit, as on Windows: marked text arrives as
// `Ev_Ime.preedit`. macOS is told only where the caret is, through
// `firstRectForCharacterRange:`, so the candidate window sits beside it.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"
import "baldr:platform"

@(private)
Ime :: struct {
	on:        bool,      // the toolkit wants an input method here at all
	composing: bool,      // there is marked text right now
	caret:     [4]f32,    // where the caret is, in the surface's logical pixels
}

// NSRange is two unsigned words; the bindings have no spelling for it.
@(private)
Range :: struct {
	location: NS.UInteger,
	length:   NS.UInteger,
}

@(private) NOT_FOUND :: NS.UInteger(0x7FFFFFFFFFFFFFFF) // NSNotFound

@(private)
b_ime_set :: proc(b: ^platform.Backend, st: platform.Ime_State) {
	c := self(b)
	s := find(c, st.surface)
	if s == nil do return
	was := s.ime.on
	s.ime.on = st.on
	s.ime.caret = st.caret
	if !st.on && s.ime.composing {
		// The field that was composing has gone away (the keyboard moved,
		// or the app turned the input method off): the composition goes
		// with it rather than being committed into whatever is focused now.
		if ctx := input_context(s); ctx != nil {
			intrinsics.objc_send(nil, ctx, "discardMarkedText")
		}
		s.ime.composing = false
	}
	if c.debug_files && was != st.on {
		fmt.eprintfln("baldr/cocoa: input method %s for surface %v (caret %.0f,%.0f %.0fx%.0f)",
			"on" if st.on else "off", st.surface, st.caret.x, st.caret.y, st.caret.z, st.caret.w)
	}
}

@(private)
input_context :: proc "contextless" (s: ^Surface) -> ^NS.Object {
	if s == nil || s.view == nil do return nil
	return intrinsics.objc_send(^NS.Object, s.view, "inputContext")
}

// v_key_down hands the key to the input method. Everything that comes back
// — ordinary text, a composition, a command — arrives through the
// NSTextInputClient methods below.
@(private)
v_key_down :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, event: ^NS.Event) {
	s := surface_of(self)
	if s == nil do return
	context = s.cocoa.ctx
	// A key held with Command or Control is a shortcut, and an input context
	// handed one inserts its letter (Cmd-V would type a "v"). Option is a
	// text modifier on macOS: the input context makes Option-e a dead key.
	mods := mods_from_flags(u64(transmute(NS.UInteger)event->modifierFlags()))
	if mods & {.Ctrl, .Super} != {} do return
	ctx := input_context(s)
	if ctx == nil do return
	intrinsics.objc_send(NS.BOOL, ctx, "handleEvent:", event)
}

// insertText: is both ordinary typing and the end of a composition, and
// they are not the same event: a commit has to take the preedit away in the
// same round, which Ev_Ime does and Ev_Text cannot.
@(private)
v_insert_text :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, text: ObjC.id, replacement: Range) {
	s := surface_of(self)
	if s == nil do return
	c := s.cocoa
	context = c.ctx
	str := ime_string(text)
	if str == "" && !s.ime.composing do return
	if s.ime.composing {
		append(&c.queue, platform.Ev_Ime{surface = s.id, commit = arena_str(c, str), preedit = "", cursor_begin = -1, cursor_end = -1})
		s.ime.composing = false
		if c.debug_files do fmt.eprintfln("baldr/cocoa: ime commit %q on surface %v", str, s.id)
	} else {
		if txt := text_of(str); txt != "" {
			append(&c.queue, platform.Ev_Text{surface = s.id, text = arena_str(c, txt)})
		}
	}
	b_wake(&c.backend)
}

@(private)
v_set_marked_text :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, text: ObjC.id, selected: Range, replacement: Range) {
	s := surface_of(self)
	if s == nil do return
	c := s.cocoa
	context = c.ctx
	str := ime_string(text)
	s.ime.composing = len(str) > 0
	begin, end := i32(-1), i32(-1)
	if selected.location != NOT_FOUND && len(str) > 0 {
		begin = i32(selected.location)
		end = i32(selected.location + selected.length)
	}
	append(&c.queue, platform.Ev_Ime{
		surface = s.id, preedit = arena_str(c, str), cursor_begin = begin, cursor_end = end,
	})
	if c.debug_files do fmt.eprintfln("baldr/cocoa: ime preedit %q on surface %v", str, s.id)
	b_wake(&c.backend)
}

@(private)
v_unmark_text :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) {
	s := surface_of(self)
	if s == nil || !s.ime.composing do return
	c := s.cocoa
	context = c.ctx
	s.ime.composing = false
	append(&c.queue, platform.Ev_Ime{surface = s.id, preedit = "", cursor_begin = -1, cursor_end = -1})
	b_wake(&c.backend)
}

@(private)
v_has_marked_text :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	s := surface_of(self)
	return NS.BOOL(s != nil && s.ime.composing)
}

// The ranges, which macOS asks to place its UI and offer reconversion. The
// toolkit holds the document and hands over only text around the caret
// (`Ime_State.surrounding`), so the answer is NSNotFound: not known. The
// candidate window is placed from the caret rect instead.
@(private)
v_marked_range :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> Range {
	return {NOT_FOUND, 0}
}

@(private)
v_selected_range :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> Range {
	return {NOT_FOUND, 0}
}

@(private)
v_attributed_substring :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, range: Range, actual: ^Range) -> ObjC.id {
	if actual != nil do actual^ = {NOT_FOUND, 0}
	return nil
}

@(private)
v_valid_attributes :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	// None: the toolkit styles the preedit itself, so there is nothing
	// macOS can usefully ask to decorate.
	return ObjC.id(intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^NS.Array, NS.Array, "alloc"), "init"))
}

// firstRectForCharacterRange: is where the candidate window goes, in screen
// coordinates. The caret, in the surface's logical pixels with a top-left
// origin, is converted through the view and the window.
@(private)
v_first_rect :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, range: Range, actual: ^Range) -> NS.Rect {
	if actual != nil do actual^ = range
	s := surface_of(self)
	if s == nil || s.win == nil do return {}
	caret := s.ime.caret
	// The view is flipped, so the caret's y is already measured from the
	// top; convertRect:toView:nil wants the view's own space, which this is.
	local := NS.Rect{
		{NS.Float(caret.x), NS.Float(caret.y)},
		{NS.Float(max(caret.z, 1)), NS.Float(max(caret.w, 1))},
	}
	in_window := intrinsics.objc_send(NS.Rect, cast(^NS.View)self, "convertRect:toView:", local, (^NS.View)(nil))
	return intrinsics.objc_send(NS.Rect, s.win, "convertRectToScreen:", in_window)
}

@(private)
v_character_index :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, point: NS.Point) -> NS.UInteger {
	return NOT_FOUND // the toolkit holds the document; no index to give
}

// doCommandBySelector: is how an input context asks for Return, Tab, the
// arrows and the emacs bindings. Swallowed: the toolkit already has those
// keys as Ev_Key from `translate`, and acting here would do each twice.
@(private)
v_do_command :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, selector: ObjC.SEL) {}

@(private = "file")
ime_string :: proc(text: ObjC.id) -> string {
	if text == nil do return ""
	obj := cast(^NS.Object)text
	// Either an NSString or an NSAttributedString, depending on the input
	// method. Asking the object rather than testing its class: an
	// attributed string answers `string` with the plain one, and a plain
	// one does not answer it at all.
	if bool(intrinsics.objc_send(NS.BOOL, obj, "respondsToSelector:", ObjC.sel_registerName("string"))) {
		if plain := intrinsics.objc_send(^NS.String, obj, "string"); plain != nil {
			return string(plain->odinString())
		}
		return ""
	}
	return string(intrinsics.objc_send(^NS.String, obj, "self")->odinString())
}
