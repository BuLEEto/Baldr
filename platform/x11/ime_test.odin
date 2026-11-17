#+build linux
package x11

@(require) import "core:testing"
@(require) import "baldr:dbus"

// Runs with the rest: `./build.sh test`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The shapes a real `ibus-daemon` sends while a Japanese engine composes.
// Typing k, a, n, a gives the preedit "k", then "か", then "かn", each
// underlined.

@(private = "file")
str :: proc(s: string) -> dbus.Value { return s }

@(private = "file")
attr :: proc(kind, value, start, end: u32) -> dbus.Value {
	fields := make([]dbus.Value, 6, context.temp_allocator)
	fields[0] = str("IBusAttribute")
	fields[1] = dbus.Dict{}
	fields[2], fields[3], fields[4], fields[5] = kind, value, start, end
	return dbus.Struct{fields = fields}
}

// text_value builds ('IBusText', a{sv}, s, <('IBusAttrList', a{sv}, av)>).
@(private = "file")
text_value :: proc(text: string, attrs: ..dbus.Value) -> dbus.Value {
	items := make([]dbus.Value, len(attrs), context.temp_allocator)
	copy(items, attrs)
	list_fields := make([]dbus.Value, 3, context.temp_allocator)
	list_fields[0] = str("IBusAttrList")
	list_fields[1] = dbus.Dict{}
	list_fields[2] = dbus.Array{sig = "v", items = items}
	inner := new_clone(dbus.Value(dbus.Struct{fields = list_fields}), context.temp_allocator)

	fields := make([]dbus.Value, 4, context.temp_allocator)
	fields[0] = str("IBusText")
	fields[1] = dbus.Dict{}
	fields[2] = text
	fields[3] = dbus.Variant{value = inner}
	return dbus.Struct{fields = fields}
}

@(test)
an_ibus_text_is_read_out_of_its_object :: proc(t: ^testing.T) {
	// "か" underlined across its one character.
	v := text_value("か", attr(IBUS_ATTR_UNDERLINE, 1, 0, 1))
	got, ok := ibus_text(v)
	testing.expect(t, ok, "it is an IBusText")
	testing.expect_value(t, got.text, "か")
	testing.expect_value(t, len(got.attrs), 1)
	if len(got.attrs) == 1 {
		testing.expect_value(t, got.attrs[0].kind, u32(IBUS_ATTR_UNDERLINE))
		testing.expect_value(t, got.attrs[0].start, u32(0))
		testing.expect_value(t, got.attrs[0].end, u32(1))
	}

	// An empty preedit is what arrives when composing ends; still an IBusText.
	empty, empty_ok := ibus_text(text_value(""))
	testing.expect(t, empty_ok, "an empty preedit is not a failure")
	testing.expect_value(t, empty.text, "")
	testing.expect_value(t, len(empty.attrs), 0)
}

// The type name tells one of ibus's objects from another, so a reader that
// ignored it would read an engine description as text: `GetEngine` answers
// with an IBusEngineDesc through a variant on the same context.
@(test)
another_ibus_object_is_not_read_as_text :: proc(t: ^testing.T) {
	fields := make([]dbus.Value, 4, context.temp_allocator)
	fields[0] = str("IBusEngineDesc")
	fields[1] = dbus.Dict{}
	fields[2] = "anthy"
	fields[3] = "Anthy"
	_, ok := ibus_text(dbus.Struct{fields = fields})
	testing.expect(t, !ok, "an engine description is not a preedit")

	// Nor is something that is not one of ibus's objects at all.
	_, plain := ibus_text(dbus.Value("かな"))
	testing.expect(t, !plain, "a bare string is not an IBusText")

	// Nor a struct too short to hold one.
	short := make([]dbus.Value, 2, context.temp_allocator)
	short[0] = str("IBusText")
	short[1] = dbus.Dict{}
	_, cut := ibus_text(dbus.Struct{fields = short})
	testing.expect(t, !cut, "a truncated IBusText is refused, not half-read")
}

// ibus counts characters; the toolkit counts bytes. The preedit "かn"
// with cursor 2 means after both characters — byte 4, not byte 2. Reading
// it as a byte offset would put the caret inside the か.
@(test)
the_preedit_cursor_is_turned_from_characters_into_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, ibus_cursor_bytes("かn", 0), i32(0))
	testing.expect_value(t, ibus_cursor_bytes("かn", 1), i32(3)) // か is three bytes
	testing.expect_value(t, ibus_cursor_bytes("かn", 2), i32(4))
	testing.expect_value(t, ibus_cursor_bytes("kana", 2), i32(2)) // ASCII: the same number
	// Past the end — a daemon saying something we did not expect — clamps
	// rather than running off the string.
	testing.expect_value(t, ibus_cursor_bytes("かn", 9), i32(4))
	testing.expect_value(t, ibus_cursor_bytes("", 3), i32(0))
}

}
