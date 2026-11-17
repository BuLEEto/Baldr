#+build linux
package atspi

// org.a11y.atspi.Text and org.a11y.atspi.Value: what an object *holds*,
// rather than what it is. Without these an entry reads as a box with a
// name and a slider does not say its value.
//
// AT-SPI counts in characters and the toolkit counts in bytes, so every
// offset crossing this file is converted. A caret sits between characters,
// so offset N means "before the Nth character" and the count itself is a
// valid caret position.

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "baldr:dbus"

// ------------------------------------------------------------ offsets

// runes_len is the character count of `s`, which is what AT-SPI calls its
// length.
@(private)
runes_len :: proc(s: string) -> int {
	return utf8.rune_count_in_string(s)
}

// byte_at is the byte offset of character `off`; the end for anything past
// it, 0 for anything before.
@(private)
byte_at :: proc(s: string, off: int) -> int {
	if off <= 0 do return 0
	n := 0
	for _, i in s {
		if n == off do return i
		n += 1
	}
	return len(s)
}

// char_at is the character offset of byte `b`.
@(private)
char_at :: proc(s: string, b: int) -> int {
	if b <= 0 do return 0
	n := 0
	for _, i in s {
		if i >= b do return n
		n += 1
	}
	return n
}

// slice_chars is s[start:end] in characters, clamped.
@(private)
slice_chars :: proc(s: string, start, end: int) -> string {
	lo, hi := start, end
	if hi < lo do lo, hi = hi, lo
	a, b := byte_at(s, max(lo, 0)), byte_at(s, max(hi, 0))
	return s[a:b]
}

// ------------------------------------------------------------ boundaries

@(private)
is_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'
}

// rune_at is the character at offset `i` (0 past the ends).
@(private)
rune_at :: proc(s: string, i: int) -> rune {
	if i < 0 do return 0
	b := byte_at(s, i)
	if b >= len(s) do return 0
	r, _ := utf8.decode_rune_in_string(s[b:])
	return r
}

// rune_of is the character at index `i` of decoded text (0 past the ends).
@(private)
rune_of :: proc(rs: []rune, i: int) -> rune {
	return rs[i] if i >= 0 && i < len(rs) else 0
}

// line_bounds is the line containing `off`, as character offsets. `with_end`
// includes the newline that ends it, which is the difference between
// AT-SPI's LINE_START and LINE_END.
@(private)
line_bounds :: proc(s: string, off: int, with_end: bool) -> (start, end: int) {
	rs := utf8.string_to_runes(s, context.temp_allocator) // indexed, so a long line is not scanned again per character
	n := len(rs)
	at := clamp(off, 0, n)
	start = 0
	for i := at - 1; i >= 0; i -= 1 {
		if rune_of(rs, i) == '\n' {
			start = i + 1
			break
		}
	}
	end = n
	for i := at; i < n; i += 1 {
		if rune_of(rs, i) == '\n' {
			end = i + 1 if with_end else i
			break
		}
	}
	return
}

// word_bounds is the word containing `off` — or the run of characters that
// are not one, so that stepping by words never stands still. This is the
// word itself, which is what a reader asking by granularity wants.
@(private)
word_bounds :: proc(s: string, off: int) -> (start, end: int) {
	rs := utf8.string_to_runes(s, context.temp_allocator) // indexed, so a long line is not scanned again per character
	n := len(rs)
	at := clamp(off, 0, n)
	if n == 0 do return 0, 0
	if at >= n do at = n - 1
	inside := is_word_rune(rune_of(rs, at))
	start = at
	for start > 0 && is_word_rune(rune_of(rs, start - 1)) == inside do start -= 1
	end = at
	for end < n && is_word_rune(rune_of(rs, end)) == inside do end += 1
	return
}

// AT-SPI's older question asks for a word *and* the space beside it, and
// which side is the whole difference between its two spellings: WORD_START
// runs from this word's start to the next word's start (the spaces after
// it), WORD_END from the last word's end to this one's end (the spaces
// before it).
@(private)
word_start_bounds :: proc(s: string, off: int) -> (start, end: int) {
	rs := utf8.string_to_runes(s, context.temp_allocator) // indexed, so a long line is not scanned again per character
	n := len(rs)
	start, end = word_bounds(s, off)
	for end < n && !is_word_rune(rune_of(rs, end)) && rune_of(rs, end) != '\n' do end += 1
	return
}

@(private)
word_end_bounds :: proc(s: string, off: int) -> (start, end: int) {
	rs := utf8.string_to_runes(s, context.temp_allocator)
	start, end = word_bounds(s, off)
	for start > 0 && !is_word_rune(rune_of(rs, start - 1)) && rune_of(rs, start - 1) != '\n' do start -= 1
	return
}

// sentence_bounds is the sentence containing `off`: to the end of a '.', '!'
// or '?' run, or to the end of the line.
@(private)
sentence_bounds :: proc(s: string, off: int) -> (start, end: int) {
	rs := utf8.string_to_runes(s, context.temp_allocator) // indexed, so a long line is not scanned again per character
	n := len(rs)
	at := clamp(off, 0, n)
	ends :: proc(r: rune) -> bool { return r == '.' || r == '!' || r == '?' || r == '\n' }
	start = 0
	for i := at - 1; i >= 0; i -= 1 {
		if ends(rune_of(rs, i)) {
			start = i + 1
			for start < n && rune_of(rs, start) == ' ' do start += 1
			break
		}
	}
	end = n
	for i := at; i < n; i += 1 {
		if ends(rune_of(rs, i)) {
			end = i + 1
			break
		}
	}
	return
}

// piece is the run of text `off` falls in, by granularity.
@(private)
piece :: proc(s: string, off: int, g: Granularity) -> (text: string, start, end: int) {
	switch g {
	case .Char:
		n := runes_len(s)
		at := clamp(off, 0, n)
		if at >= n do return "", n, n
		return slice_chars(s, at, at + 1), at, at + 1
	case .Word:
		start, end = word_bounds(s, off)
	case .Sentence:
		start, end = sentence_bounds(s, off)
	case .Line, .Paragraph:
		start, end = line_bounds(s, off, false)
	}
	return slice_chars(s, start, end), start, end
}

// piece_bounded answers the older question, which distinguishes the start of
// a run from its end.
@(private)
piece_bounded :: proc(s: string, off: int, b: Boundary) -> (text: string, start, end: int) {
	switch b {
	case .Char:           return piece(s, off, .Char)
	case .Word_Start:     start, end = word_start_bounds(s, off)
	case .Word_End:       start, end = word_end_bounds(s, off)
	case .Sentence_Start, .Sentence_End: start, end = sentence_bounds(s, off)
	case .Line_Start:     start, end = line_bounds(s, off, false)
	case .Line_End:       start, end = line_bounds(s, off, true)
	}
	return slice_chars(s, start, end), start, end
}

// ------------------------------------------------------------ the interface

@(private)
text_of :: proc(b: ^Bridge, id: u64) -> (Text_Info, bool) {
	if b.provider.text == nil do return {}, false
	return b.provider.text(b.provider.user, id)
}

// text_iface answers org.a11y.atspi.Text: the characters, the caret and the
// selection. Read-only except SetCaretOffset; the selection cannot be set
// from here.
@(private)
text_iface :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	info, have := text_of(b, id)
	s := info.text
	n := runes_len(s)
	// Callers send numbers as either signedness (loosely typed tools, older
	// signatures); both are accepted.
	arg :: proc(call: ^dbus.Message, i: int) -> i32 {
		if len(call.body) <= i do return 0
		if v, is_i := dbus.as_i32(call.body[i]); is_i do return v
		if v, is_u := dbus.as_u32(call.body[i]); is_u do return i32(v)
		return 0
	}
	argu :: proc(call: ^dbus.Message, i: int) -> u32 {
		if len(call.body) <= i do return 0
		if v, is_u := dbus.as_u32(call.body[i]); is_u do return v
		if v, is_i := dbus.as_i32(call.body[i]); is_i && v >= 0 do return u32(v)
		return 0
	}
	answer_piece :: proc(b: ^Bridge, call: ^dbus.Message, text: string, start, end: int) {
		dbus.reply(b.conn, call, {strings.clone(text, context.temp_allocator), i32(start), i32(end)})
	}
	switch call.member {
	case "GetText":
		if !have {
			dbus.reply(b.conn, call, {""})
			return true
		}
		start, end := int(arg(call, 0)), int(arg(call, 1))
		if end < 0 do end = n // -1 means "to the end"
		dbus.reply(b.conn, call, {strings.clone(slice_chars(s, start, end), context.temp_allocator)})
	case "GetCharacterCount":
		dbus.reply(b.conn, call, {i32(n)})
	case "GetCaretOffset":
		dbus.reply(b.conn, call, {i32(char_at(s, info.caret)) if have && info.caret >= 0 else i32(0)})
	case "SetCaretOffset":
		// AT-SPI counts characters and the widget counts bytes
		ok := have && b.provider.set_caret != nil && b.provider.set_caret(b.provider.user, id, byte_at(s, int(arg(call, 0))))
		dbus.reply(b.conn, call, {ok})
	case "GetStringAtOffset":
		text, start, end := piece(s, int(arg(call, 0)), Granularity(argu(call, 1)))
		answer_piece(b, call, text, start, end)
	case "GetTextAtOffset":
		text, start, end := piece_bounded(s, int(arg(call, 0)), Boundary(argu(call, 1)))
		answer_piece(b, call, text, start, end)
	case "GetTextBeforeOffset":
		_, start, _ := piece_bounded(s, int(arg(call, 0)), Boundary(argu(call, 1)))
		text, bstart, bend := piece_bounded(s, max(start - 1, 0), Boundary(argu(call, 1)))
		answer_piece(b, call, text, bstart, bend)
	case "GetTextAfterOffset":
		_, _, end := piece_bounded(s, int(arg(call, 0)), Boundary(argu(call, 1)))
		text, astart, aend := piece_bounded(s, min(end, n), Boundary(argu(call, 1)))
		answer_piece(b, call, text, astart, aend)
	case "GetCharacterAtOffset":
		dbus.reply(b.conn, call, {i32(rune_at(s, int(arg(call, 0))))})
	case "GetNSelections":
		dbus.reply(b.conn, call, {i32(1) if have && info.sel_lo != info.sel_hi else i32(0)})
	case "GetSelection":
		lo, hi := char_at(s, info.sel_lo), char_at(s, info.sel_hi)
		if lo > hi do lo, hi = hi, lo
		dbus.reply(b.conn, call, {i32(lo), i32(hi)})
	case "AddSelection", "RemoveSelection", "SetSelection":
		dbus.reply(b.conn, call, {false})
	case "GetAttributes", "GetAttributeRun":
		// no per-character attributes of our own yet: the whole text is one run
		dbus.reply(b.conn, call, {dbus.Dict{key_sig = "s", value_sig = "s"}, i32(0), i32(n)})
	case "GetDefaultAttributes", "GetDefaultAttributeSet":
		dbus.reply(b.conn, call, {dbus.Dict{key_sig = "s", value_sig = "s"}})
	case "GetAttributeValue":
		dbus.reply(b.conn, call, {""})
	case "GetCharacterExtents":
		f := make([]dbus.Value, 4, context.temp_allocator)
		f[0], f[1], f[2], f[3] = i32(0), i32(0), i32(0), i32(0)
		dbus.reply(b.conn, call, {i32(0), i32(0), i32(0), i32(0)}) // per-character extents are not known here
	case "GetRangeExtents":
		dbus.reply(b.conn, call, {i32(0), i32(0), i32(0), i32(0)})
	case "GetOffsetAtPoint":
		dbus.reply(b.conn, call, {i32(-1)})
	case "GetBoundedRanges":
		dbus.reply(b.conn, call, {dbus.Array{sig = "(iiisv)"}})
	case "ScrollSubstringTo", "ScrollSubstringToPoint":
		dbus.reply(b.conn, call, {false})
	case:
		return false
	}
	return true
}

// value_iface answers org.a11y.atspi.Value: what a slider, spin button or
// progress bar is worth. Read-only: the value is served as properties
// (bridge.odin) and SetCurrentValue is refused.
@(private)
value_iface :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	switch call.member {
	case "SetCurrentValue":
		dbus.reply(b.conn, call, {false})
		return true
	}
	return false
}

// ------------------------------------------------------------ editing

// edit_iface answers org.a11y.atspi.EditableText: a reader typing into a
// field or an editor on someone's behalf. Every change goes through the
// same edit typing makes, not "set the text", because undo steps, a
// composition in flight and the app's change handlers hang off that path.
// AT-SPI counts characters; the toolkit counts bytes.
@(private)
edit_iface :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	info, have := text_of(b, id)
	s := info.text
	n := runes_len(s)
	editable := have && info.editable && b.provider.edit != nil
	arg :: proc(call: ^dbus.Message, i: int) -> int {
		if len(call.body) <= i do return 0
		if v, is_i := dbus.as_i32(call.body[i]); is_i do return int(v)
		if v, is_u := dbus.as_u32(call.body[i]); is_u do return int(v)
		return 0
	}
	text_arg :: proc(call: ^dbus.Message, i: int) -> string {
		if len(call.body) <= i do return ""
		v, _ := dbus.as_string(call.body[i])
		return v
	}
	edit :: proc(b: ^Bridge, id: u64, from, to: int, text: string) -> bool {
		return b.provider.edit(b.provider.user, id, from, to, text)
	}
	switch call.member {
	case "InsertText":
		if !editable {
			dbus.reply(b.conn, call, {false})
			return true
		}
		at := byte_at(s, arg(call, 0))
		text := text_arg(call, 1)
		// the third argument is the length in characters, which the string
		// already carries; a reader that passes fewer means that much of it
		if count := arg(call, 2); count >= 0 && count < runes_len(text) {
			text = slice_chars(text, 0, count)
		}
		dbus.reply(b.conn, call, {edit(b, id, at, at, text)})
	case "DeleteText":
		if !editable {
			dbus.reply(b.conn, call, {false})
			return true
		}
		from, to := arg(call, 0), arg(call, 1)
		if to < 0 do to = n
		dbus.reply(b.conn, call, {edit(b, id, byte_at(s, from), byte_at(s, to), "")})
	case "SetTextContents":
		if !editable {
			dbus.reply(b.conn, call, {false})
			return true
		}
		dbus.reply(b.conn, call, {edit(b, id, 0, len(s), text_arg(call, 0))})
	case "CopyText", "CutText", "PasteText":
		if b.provider.clip == nil {
			dbus.reply(b.conn, call, {false})
			return true
		}
		// Cut and copy take a range, which the toolkit's own action reads
		// from the selection: put the selection there first, so the action
		// cuts what the reader asked for rather than what was selected.
		if call.member != "PasteText" && b.provider.set_caret != nil && len(call.body) >= 2 {
			from, to := byte_at(s, arg(call, 0)), byte_at(s, arg(call, 1))
			b.provider.select_range(b.provider.user, id, from, to)
		} else if call.member == "PasteText" && b.provider.set_caret != nil && len(call.body) >= 1 {
			at := byte_at(s, arg(call, 0))
			b.provider.set_caret(b.provider.user, id, at)
		}
		act := Clip_Act.Copy
		switch call.member {
		case "CutText":   act = .Cut
		case "PasteText": act = .Paste
		}
		if act != .Copy && !editable {
			dbus.reply(b.conn, call, {false})
			return true
		}
		dbus.reply(b.conn, call, {b.provider.clip(b.provider.user, id, act)})
	case:
		return false
	}
	return true
}
