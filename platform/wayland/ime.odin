#+build linux
package wayland

// Input methods (zwp_text_input_v3): the focused field says what it is and
// where its caret is, and the input method answers with a preedit, text to
// commit, and text to delete around the caret.
//
// The protocol is double-buffered both ways: our state goes out as a set of
// requests followed by one commit, and the compositor's changes arrive as
// preedit_string / commit_string / delete_surrounding_text events that only
// take effect on `done`. We gather a round into one platform.Ev_Ime so the
// toolkit applies it in the order the protocol prescribes and in one undo
// step.

import "core:strings"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// Ime is the seat's text input and the last state we sent it, so nothing is
// re-sent that has not changed, plus the round being received.
@(private)
Ime :: struct {
	mgr:      wl.Proxy, // zwp_text_input_manager_v3
	obj:      wl.Proxy, // zwp_text_input_v3 for the seat
	listener: wl.Zwp_Text_Input_V3_Listener,
	entered:  ^Surface_State, // the surface the input method is on (its keyboard focus)
	serial:   u32,            // commit requests we have issued
	sent:     platform.Ime_State,
	sent_text: string, // sent.surrounding, ours (heap)
	on:       bool,    // enabled, as far as the compositor knows

	// the round being gathered, applied on done
	pending:     platform.Ev_Ime,
	has_pending: bool,
}

@(private)
ime_init :: proc(st: ^State) {
	if st.ime.mgr == nil || st.seat == nil || st.ime.obj != nil do return
	st.ime.obj = wl.zwp_text_input_manager_v3_get_text_input(st.ime.mgr, st.seat)
	if st.ime.obj == nil do return
	st.ime.listener = wl.zwp_text_input_v3_listener_noop()
	st.ime.listener.enter = on_ime_enter
	st.ime.listener.leave = on_ime_leave
	st.ime.listener.preedit_string = on_ime_preedit
	st.ime.listener.commit_string = on_ime_commit
	st.ime.listener.delete_surrounding_text = on_ime_delete
	st.ime.listener.done = on_ime_done
	wl.zwp_text_input_v3_add_listener(st.ime.obj, &st.ime.listener, st)
	debugf(st, "input method: text-input-v3 bound")
}

@(private)
ime_teardown :: proc(st: ^State) {
	if st.ime.obj != nil {
		wl.zwp_text_input_v3_destroy(st.ime.obj)
		st.ime.obj = nil
	}
	if st.ime.mgr != nil {
		wl.proxy_destroy(st.ime.mgr)
		st.ime.mgr = nil
	}
	delete(st.ime.sent_text)
	st.ime.sent_text = ""
}

// ime_set sends the focused field's state. The protocol wants every part of
// the state re-sent after an enable, so a field taking focus sends the lot;
// afterwards only what changed goes out, and each round ends with a commit.
@(private)
ime_set :: proc(b: ^platform.Backend, in_st: platform.Ime_State) {
	st := state(b)
	im := &st.ime
	if im.obj == nil do return
	want := in_st
	if im.entered == nil || (want.on && im.entered.id != want.surface) do want.on = false // the input method is not on this surface
	if !want.on {
		if !im.on do return
		wl.zwp_text_input_v3_disable(im.obj)
		ime_commit_state(st)
		im.on = false
		im.sent = {}
		debugf(st, "input method: disabled")
		return
	}
	fresh := !im.on
	if fresh {
		wl.zwp_text_input_v3_enable(im.obj)
		im.on = true
		im.sent = {} // enable resets the state: everything goes again
	}
	changed := fresh
	if fresh || want.purpose != im.sent.purpose || want.hints != im.sent.hints {
		wl.zwp_text_input_v3_set_content_type(im.obj, ime_hints(want.hints), ime_purpose(want.purpose))
		changed = true
	}
	if fresh || want.surrounding != im.sent.surrounding || want.cursor != im.sent.cursor || want.anchor != im.sent.anchor {
		text := strings.clone_to_cstring(want.surrounding, context.temp_allocator)
		wl.zwp_text_input_v3_set_surrounding_text(im.obj, text, i32(want.cursor), i32(want.anchor))
		wl.zwp_text_input_v3_set_text_change_cause(im.obj, .Input_Method if want.cause == .Input_Method else .Other)
		changed = true
	}
	if fresh || want.caret != im.sent.caret {
		wl.zwp_text_input_v3_set_cursor_rectangle(im.obj, i32(want.caret.x), i32(want.caret.y), i32(max(want.caret.z, 1)), i32(max(want.caret.w, 1)))
		changed = true
	}
	if !changed do return
	ime_commit_state(st)
	delete(im.sent_text)
	im.sent_text = strings.clone(want.surrounding)
	im.sent = want
	im.sent.surrounding = im.sent_text
}

@(private)
ime_commit_state :: proc(st: ^State) {
	wl.zwp_text_input_v3_commit(st.ime.obj)
	st.ime.serial += 1
	wl.display_flush(st.display)
}

@(private)
ime_purpose :: proc "contextless" (p: platform.Ime_Purpose) -> wl.Zwp_Text_Input_V3_Content_Purpose {
	switch p {
	case .Normal:   return .Normal
	case .Alpha:    return .Alpha
	case .Digits:   return .Digits
	case .Number:   return .Number
	case .Phone:    return .Phone
	case .Url:      return .Url
	case .Email:    return .Email
	case .Name:     return .Name
	case .Password: return .Password
	case .Pin:      return .Pin
	case .Date:     return .Date
	case .Time:     return .Time
	case .Datetime: return .Datetime
	case .Terminal: return .Terminal
	}
	return .Normal
}

@(private)
ime_hints :: proc "contextless" (h: platform.Ime_Hints) -> wl.Zwp_Text_Input_V3_Content_Hint {
	out := wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE
	if .Completion in h          do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_COMPLETION
	if .Spellcheck in h          do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_SPELLCHECK
	if .Auto_Capitalization in h do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_AUTO_CAPITALIZATION
	if .Lowercase in h           do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_LOWERCASE
	if .Uppercase in h           do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_UPPERCASE
	if .Titlecase in h           do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_TITLECASE
	if .Hidden_Text in h         do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_HIDDEN_TEXT
	if .Sensitive_Data in h      do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_SENSITIVE_DATA
	if .Latin in h               do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_LATIN
	if .Multiline in h           do out |= wl.ZWP_TEXT_INPUT_V3_CONTENT_HINT_MULTILINE
	return out
}

@(private)
on_ime_enter :: proc "c" (data: rawptr, p: wl.Proxy, surface: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	st.ime.entered = lookup_wl(st, surface)
	st.ime.on = false // a fresh text input: the focused field enables it again
	st.ime.sent = {}
	debugf(st, "input method: entered surface %d", st.ime.entered.id if st.ime.entered != nil else 0)
	if st.ime.entered != nil do push(st, platform.Ev_Ime{surface = st.ime.entered.id}) // wakes the toolkit, which sends the field's state
}

@(private)
on_ime_leave :: proc "c" (data: rawptr, p: wl.Proxy, surface: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if s := lookup_wl(st, surface); s != nil do push(st, platform.Ev_Ime{surface = s.id}) // any preedit goes with it
	st.ime.entered = nil
	st.ime.on = false
	st.ime.sent = {}
	st.ime.has_pending = false
	st.ime.pending = {}
	debugf(st, "input method: left")
}

@(private)
on_ime_preedit :: proc "c" (data: rawptr, p: wl.Proxy, text: cstring, cursor_begin: i32, cursor_end: i32) {
	st := (^State)(data)
	context = st.ctx
	st.ime.pending.preedit = strings.clone(string(text), text_allocator(st)) if text != nil else ""
	st.ime.pending.cursor_begin, st.ime.pending.cursor_end = cursor_begin, cursor_end
	st.ime.has_pending = true
}

@(private)
on_ime_commit :: proc "c" (data: rawptr, p: wl.Proxy, text: cstring) {
	st := (^State)(data)
	context = st.ctx
	st.ime.pending.commit = strings.clone(string(text), text_allocator(st)) if text != nil else ""
	st.ime.has_pending = true
}

@(private)
on_ime_delete :: proc "c" (data: rawptr, p: wl.Proxy, before_length: u32, after_length: u32) {
	st := (^State)(data)
	context = st.ctx
	st.ime.pending.delete_before, st.ime.pending.delete_after = before_length, after_length
	st.ime.has_pending = true
}

// on_ime_done: the round is complete. The pending state becomes the current
// one and resets, as the protocol says, whatever the serial: a done with an
// older serial is still applied, it just leaves our own state alone (the
// field will send it again anyway when its text moves).
@(private)
on_ime_done :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	st := (^State)(data)
	context = st.ctx
	if st.ime.entered == nil do return
	ev := st.ime.pending
	ev.surface = st.ime.entered.id
	st.ime.pending = {}
	st.ime.has_pending = false
	push(st, ev)
	if st.debug {
		debugf(st, "input method: done serial %d (ours %d): delete %d/%d, commit %q, preedit %q [%d,%d]",
			serial, st.ime.serial, ev.delete_before, ev.delete_after, ev.commit, ev.preedit, ev.cursor_begin, ev.cursor_end)
	}
}
