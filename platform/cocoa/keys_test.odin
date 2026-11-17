package cocoa

// The macOS key table, tested on every machine: it is pure data, so it needs
// no Mac, and a mapping table rots quietly.

@(require) import "baldr:platform"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// Every code here was observed from a real Mac through spikes/cocoa_window,
// not read off a header. The codes are positional, not alphabetical: A is 0
// and B is 11.
@(test)
the_key_codes_are_the_ones_the_mac_really_sends :: proc(t: ^testing.T) {
	seen := [?]struct { code: u32, want: platform.Key } {
		{0, .A},    // typed "a"  → keyCode=0
		{11, .B},   // typed "b"  → keyCode=11
		{8, .C},    // typed "c"  → keyCode=8
		{4, .H},    // typed "hi" → keyCode=4 then 34
		{34, .I},
		{13, .W},   // Cmd+W      → keyCode=13
		{7, .X},    // typed "xyz"
		{16, .Y},
		{6, .Z},
		{126, .Up}, // key code 126
	}
	for c in seen {
		got := key_from_code(c.code)
		testing.expectf(t, got == c.want, "keyCode %d should be %v, got %v", c.code, c.want, got)
	}
}

@(test)
the_key_table_has_no_duplicates_or_stray_codes :: proc(t: ^testing.T) {
	// A duplicate means two physical keys collapse onto one, which shows up
	// as a shortcut firing from the wrong key — easy to write, hard to spot.
	first: map[platform.Key]u32
	defer delete(first)
	for code in 0 ..< u32(len(KEYS)) {
		k := key_from_code(code)
		if k == .Unknown do continue
		if prev, had := first[k]; had {
			testing.expectf(t, false, "%v is mapped by both keyCode %d and %d", k, prev, code)
			continue
		}
		first[k] = code
	}
	testing.expect(t, key_from_code(127) == .Unknown, "an unmapped code in range")
	testing.expect(t, key_from_code(999) == .Unknown, "a code past the table")
	testing.expect(t, key_from_code(10) == .Unknown, "a gap inside the table")
}

// The flags carry device-dependent bits below 16 beside the named ones
// (`{1, Shift}`, `{3, Command}`), so anything that does not mask first sees
// modifiers that are not held.
@(test)
modifier_flags_ignore_the_device_dependent_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, mods_from_flags(0), platform.Mods{})
	testing.expect_value(t, mods_from_flags(FLAG_SHIFT), platform.Mods{.Shift})
	testing.expect_value(t, mods_from_flags(FLAG_SUPER), platform.Mods{.Super})   // Command
	testing.expect_value(t, mods_from_flags(FLAG_ALT), platform.Mods{.Alt})       // Option
	testing.expect_value(t, mods_from_flags(FLAG_SHIFT | FLAG_CTRL | FLAG_ALT | FLAG_SUPER),
		platform.Mods{.Shift, .Ctrl, .Alt, .Super})

	// Shift and Command as they arrive, raw
	testing.expect_value(t, mods_from_flags(FLAG_SHIFT | 1), platform.Mods{.Shift})
	testing.expect_value(t, mods_from_flags(FLAG_SUPER | 3), platform.Mods{.Super})

	// An arrow key arrives with {NumericPad, Function}, a function key with
	// {Function}. Neither is a modifier Baldr reports, and neither may
	// disturb the ones it does.
	testing.expect_value(t, mods_from_flags(FLAG_NUMPAD | FLAG_FUNCTION), platform.Mods{})
	testing.expect_value(t, mods_from_flags(FLAG_NUMPAD | FLAG_FUNCTION | FLAG_SHIFT), platform.Mods{.Shift})
	testing.expect_value(t, mods_from_flags(FLAG_HELP | FLAG_CTRL), platform.Mods{.Ctrl})

	// Caps Lock is a lock, not a modifier Baldr reports in Mods
	testing.expect_value(t, mods_from_flags(FLAG_CAPS), platform.Mods{})
	testing.expect(t, caps_lock_on(FLAG_CAPS), "but it is readable as a lock")
	testing.expect(t, !caps_lock_on(FLAG_SHIFT), "and Shift is not it")
}

// A key with no text must produce none. AppKit puts arrows and function keys
// in the private-use block, and a control character is a key too — letting
// either through types a box, or a stray glyph, into a text field.
@(test)
a_key_that_types_nothing_yields_no_text :: proc(t: ^testing.T) {
	testing.expect_value(t, text_of("a"), "a")
	testing.expect_value(t, text_of("A"), "A")
	testing.expect_value(t, text_of("é"), "é")
	testing.expect_value(t, text_of("日本"), "日本")
	testing.expect_value(t, text_of(""), "") // Up, as AppKit sends it
	testing.expect_value(t, text_of(""), "") // Down
	testing.expect_value(t, text_of(""), "") // the top of the block
	testing.expect_value(t, text_of("\u0003"), "") // Ctrl+C
	testing.expect_value(t, text_of("\u007f"), "") // Delete
	testing.expect_value(t, text_of(""), "")
}

}

// The wheel reports in lines and the trackpad in points. Read as pixels, a
// notch moves one pixel and a whole turn barely moves a line. Pure
// arithmetic, so it needs no Mac and no NSEvent.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
a_wheel_notch_moves_a_step_not_a_pixel :: proc(t: ^testing.T) {
	// A traditional wheel: no precise deltas, and the value is in lines.
	one := scroll_delta(0, 1, false)
	testing.expect_value(t, one.y, platform.SCROLL_STEP_PX)
	// Some mice report three lines a notch; it scales, it is not clamped.
	three := scroll_delta(0, 3, false)
	testing.expect_value(t, three.y, 3 * platform.SCROLL_STEP_PX)
	// And sideways the same way, for a wheel that tilts.
	side := scroll_delta(-1, 0, false)
	testing.expect_value(t, side.x, -platform.SCROLL_STEP_PX)
	// The sign is AppKit's: whatever came in, the direction is unchanged.
	up := scroll_delta(0, -1, false)
	testing.expect(t, up.y < 0, "a delta the other way stays the other way")
}

@(test)
a_trackpad_is_already_in_pixels :: proc(t: ^testing.T) {
	// hasPreciseScrollingDeltas: points, which is what Ev_Scroll is defined
	// in, so multiplying them by a step would make a flick fly off the end.
	d := scroll_delta(-3.5, 17.25, true)
	testing.expect_value(t, d.x, f32(-3.5))
	testing.expect_value(t, d.y, f32(17.25))
	// the small deltas a slow drag of two fingers gives, kept as they are
	tiny := scroll_delta(0, 0.5, true)
	testing.expect_value(t, tiny.y, f32(0.5))
}

}
