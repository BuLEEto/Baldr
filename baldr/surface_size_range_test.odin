package baldr

// A window's size range: `Surface_Desc.min_size` / `max_size`, carried to
// Wayland's `set_min_size`, X11's `WM_NORMAL_HINTS` and Win32's
// `WM_GETMINMAXINFO`. `fixed_size` says a window cannot be resized at all;
// a range says "not below 480 wide".

@(require) import "core:testing"
@(require) import "baldr:platform"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sr_Msg :: enum { None }

@(private = "file")
CAPS :: platform.Caps{.Transparent, .Popups}

@(test)
a_window_carries_its_size_range_to_the_backend :: proc(t: ^testing.T) {
	d := Surface_Desc(Sr_Msg){kind = .Window, title = "Chat", size = {900, 600},
		min_size = {480, 320}, max_size = {1600, 0}}
	out := surface_resolve(d, CAPS, "dev.baldr.chat")
	testing.expect_value(t, out.min_size, [2]f32{480, 320})
	testing.expect_value(t, out.max_size, [2]f32{1600, 0}) // zero on an axis is no limit
	testing.expect_value(t, out.size, [2]f32{900, 600})    // inside the range: untouched
}

// The reason the clamp exists: a window reopening at the size it was left
// at, saved by a version of the app whose floor was lower than this one's.
// Without it the desktop is asked for a window below its own minimum, and
// the app lays out into a shape it has just said it cannot use.
@(test)
an_opening_size_below_the_floor_is_raised_to_it :: proc(t: ^testing.T) {
	d := Surface_Desc(Sr_Msg){kind = .Window, size = {320, 200}, min_size = {480, 320}}
	out := surface_resolve(d, CAPS, "dev.baldr.chat")
	testing.expect_value(t, out.size, [2]f32{480, 320})

	over := Surface_Desc(Sr_Msg){kind = .Window, size = {2400, 1800}, max_size = {1600, 1000}}
	testing.expect_value(t, surface_resolve(over, CAPS, "dev.baldr.chat").size, [2]f32{1600, 1000})

	// One axis limited, the other free.
	one := Surface_Desc(Sr_Msg){kind = .Window, size = {300, 900}, min_size = {480, 0}}
	testing.expect_value(t, surface_resolve(one, CAPS, "dev.baldr.chat").size, [2]f32{480, 900})
}

// An app that asks for the impossible gets the usable half of it.
@(test)
a_floor_above_the_ceiling_keeps_the_floor :: proc(t: ^testing.T) {
	d := Surface_Desc(Sr_Msg){kind = .Window, size = {600, 400}, min_size = {800, 600}, max_size = {500, 300}}
	out := surface_resolve(d, CAPS, "dev.baldr.chat")
	testing.expect_value(t, out.size, [2]f32{800, 600}) // too large is usable; too small is not
}

// `fixed_size` is the range collapsed, and says so on its own: a dialog
// that cannot be resized must not also have to state a range, and a range
// must not quietly override it.
@(test)
a_fixed_window_is_not_clamped_by_a_range :: proc(t: ^testing.T) {
	d := Surface_Desc(Sr_Msg){kind = .Window, size = {400, 300}, fixed_size = true, min_size = {900, 700}}
	out := surface_resolve(d, CAPS, "dev.baldr.chat")
	testing.expect(t, out.fixed_size, "still fixed")
	testing.expect_value(t, out.size, [2]f32{400, 300}) // the size it asked for, not the floor
}

// A layer surface is placed and sized by the shell, so a range would be
// something the compositor is not being asked and the toolkit cannot
// enforce: it is dropped rather than sent and ignored.
@(test)
a_layer_surface_carries_no_size_range :: proc(t: ^testing.T) {
	d := Surface_Desc(Sr_Msg){kind = .Layer, size = {0, 48}, min_size = {480, 320},
		layer = {anchor = {.Top, .Left, .Right}}}
	out := surface_resolve(d, CAPS + {.Layer_Shell}, "dev.baldr.bar")
	testing.expect_value(t, out.min_size, [2]f32{})
	testing.expect_value(t, out.max_size, [2]f32{})
}

}
