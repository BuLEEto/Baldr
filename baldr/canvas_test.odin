package baldr

@(require) import "core:math"
@(require) import "core:slice"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Canvases through the CPU reference, which the GPU's work must match.


@(private = "file")
Cv_Msg :: union { Gpu, Canvas_Read }

@(private = "file")
texel :: proc(g: Gpu, c: Canvas, x, y: int) -> [4]f32 {
	e := canvas_entry(g, c)
	bpp := canvas_bpp_of(e.format)
	return canvas_decode(e.format, e.pixels[(y * e.size.x + x) * bpp:][:bpp])
}

@(private = "file")
canvas_bpp_of :: proc(f: Canvas_Format) -> int {
	switch f {
	case .RGBA8:   return 4
	case .RGBA16:  return 8
	case .RGBA32F: return 16
	case .R8:      return 1
	case .R16:     return 2
	}
	return 4
}

// A new canvas is clear; a fill sets a rectangle as the format stores it
// (8 and 16 bits rounded to the nearest step and clamped, floats as they
// are); a write puts texels where it is told; work outside a canvas is
// refused.
@(test)
canvases_are_filled_and_written_as_their_format_stores :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c8, ok := canvas_create(g, {16, 8})
	testing.expect(t, ok, "made")
	testing.expect_value(t, texel(g, c8, 3, 3), [4]f32{})
	testing.expect(t, canvas_fill(g, c8, 2, 1, 4, 3, {0.5, 1.5, -1, 1}), "filled")
	testing.expect(t, slice.equal(canvas_entry(g, c8).pixels[(1 * 16 + 2) * 4:][:4], []u8{128, 255, 0, 255}), "128, 255, 0, 255")
	testing.expect_value(t, texel(g, c8, 1, 1), [4]f32{}) // outside the rectangle
	testing.expect(t, !canvas_fill(g, c8, 14, 0, 4, 1, {1, 1, 1, 1}), "past the edge")

	c16, _ := canvas_create(g, {4, 4}, .RGBA16, .Linear)
	canvas_fill(g, c16, 0, 0, 4, 4, {0.5, 0.25, 1, 1})
	e := canvas_entry(g, c16)
	testing.expect(t, e.pixels[0] == 0x00 && e.pixels[1] == 0x80, "0.5 is 32768, little-endian") // round(0.5 × 65535) = 32768

	cf, _ := canvas_create(g, {4, 4}, .RGBA32F, .Linear)
	canvas_fill(g, cf, 0, 0, 1, 1, {2.5, -0.25, 1, 1})
	testing.expect_value(t, texel(g, cf, 0, 0), [4]f32{2.5, -0.25, 1, 1}) // HDR: kept

	px := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect(t, canvas_write(g, c8, 10, 5, 2, 1, px), "written")
	testing.expect(t, slice.equal(canvas_entry(g, c8).pixels[(5 * 16 + 11) * 4:][:4], []u8{5, 6, 7, 8}), "5, 6, 7, 8")
	testing.expect(t, !canvas_write(g, c8, 10, 5, 2, 2, px), "too few bytes")

	size, format, space, known := canvas_info(g, c16)
	testing.expect(t, known && size == {4, 4} && format == .RGBA16 && space == .Linear, "its info")
	canvas_destroy(g, c16)
	_, _, _, known = canvas_info(g, c16)
	testing.expect(t, !known, "gone")
	testing.expect(t, !canvas_fill(g, c16, 0, 0, 1, 1, {}), "nothing to fill")
	_, big := canvas_create(g, {1 << 16, 4})
	testing.expect(t, !big, "past the limit")
}

// A copy between formats keeps what the values mean, as the GPU's blit
// does; within one canvas the rectangles must not overlap.
@(test)
canvas_copies_keep_what_values_mean :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	a, _ := canvas_create(g, {8, 8})
	b, _ := canvas_create(g, {8, 8}, .RGBA16)
	f, _ := canvas_create(g, {8, 8}, .RGBA32F)
	canvas_write(g, a, 0, 0, 1, 1, {255, 128, 0, 255})
	testing.expect(t, canvas_copy(g, a, 0, 0, 1, 1, b, {3, 3}), "8 to 16")
	e := canvas_entry(g, b)
	t16 := e.pixels[(3 * 8 + 3) * 8:][:8]
	testing.expect(t, t16[0] == 0xFF && t16[1] == 0xFF && u16(t16[2]) | u16(t16[3]) << 8 == 32896, "255 is 65535; 128 is 32896")
	canvas_fill(g, f, 0, 0, 2, 1, {1.75, 0.5, -0.5, 1})
	canvas_copy(g, f, 0, 0, 2, 1, a, {4, 4})
	testing.expect(t, slice.equal(canvas_entry(g, a).pixels[(4 * 8 + 4) * 4:][:4], []u8{255, 128, 0, 255}), "255, 128, 0, 255") // clamped into 8 bits
	testing.expect(t, canvas_copy(g, a, 0, 0, 2, 2, a, {2, 2}), "apart within one canvas")
	testing.expect(t, !canvas_copy(g, a, 0, 0, 3, 3, a, {2, 2}), "overlapping: refused")
}

// The display transform: each space's values to linear sRGB, as the shader
// does it. White is white in every space; P3's pure red is redder than
// sRGB's (above 1 in red, below 0 in green); Adobe RGB's curve is a 2.2
// power.
@(test)
color_spaces_decode_to_linear_srgb :: proc(t: ^testing.T) {
	near3 :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool { return abs(a.r - b.r) <= eps && abs(a.g - b.g) <= eps && abs(a.b - b.b) <= eps }
	for space in Color_Space do testing.expectf(t, near3(color_space_to_linear({1, 1, 1}, space), {1, 1, 1}), "%v white", space)
	testing.expect(t, near3(color_space_to_linear({0.5, 0.5, 0.5}, .sRGB), {0.2140411, 0.2140411, 0.2140411}), "sRGB's curve")
	testing.expect(t, near3(color_space_to_linear({0.5, 0.5, 0.5}, .Display_P3), color_space_to_linear({0.5, 0.5, 0.5}, .sRGB)), "P3's grey is sRGB's")
	red := color_space_to_linear({1, 0, 0}, .Display_P3)
	testing.expect(t, red.r > 1.2 && red.g < 0 && red.b < 0, "P3 red is outside sRGB")
	grey := math.pow(f32(0.5), f32(2.19921875))
	testing.expect(t, near3(color_space_to_linear({0.5, 0.5, 0.5}, .Adobe_RGB), {grey, grey, grey}), "Adobe RGB's curve")
	testing.expect_value(t, color_space_to_linear({0.25, 0.5, 2}, .Linear), [3]f32{0.25, 0.5, 2})
}

// A canvas node sizes like an image and, from the reference, draws a
// picture of the canvas through its space: 0.5 linear light shows as
// sRGB's 188; new texels paint it again.
@(test)
a_canvas_node_shows_its_canvas_through_its_space :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c, _ := canvas_create(g, {40, 20}, .RGBA16, .Linear)
	canvas_fill(g, c, 0, 0, 40, 20, {0.5, 0.5, 0.5, 1})
	ui: Ui(Cv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(Cv_Msg), g: Gpu, c: Canvas) -> Node {
		begin_view(ui)
		column(ui, align = .Start, key = 1)
		n := canvas(ui, g, c, width = 80, label = "Document", key = 2)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {300, 200})
		return n
	}
	n := build(&ui, g, c)
	d := node_get(&ui.tree, n)
	testing.expect(t, d.rect.w == 80 && d.rect.h == 40, "its aspect kept")
	testing.expect(t, d.access.role == .Image && d.access.name == "Document", "named")
	drew := false
	for cmd in draw_list(&ui.tree) do if v, ok := cmd.(Draw_Image); ok {
		drew = true
		testing.expect_value(t, v.img.pixels[0], 188) // round(encode(0.5) × 255)
	}
	testing.expect(t, drew, "drawn as a picture")
	canvas_fill(g, c, 0, 0, 1, 1, {0, 0, 0, 1})
	build(&ui, g, c)
	for cmd in draw_list(&ui.tree) do if v, ok := cmd.(Draw_Image); ok do testing.expect_value(t, v.img.pixels[0], 0) // the new texel shows
}

// gpu_open answers at once without a GPU (the reference); a read comes back
// as a message with the texels, after the work queued before it.
@(test)
gpu_open_and_a_read_come_back_as_messages :: proc(t: ^testing.T) {
	rt: Runtime(int, Cv_Msg)
	defer {
		canvases_shutdown(&rt)
		jobs_shutdown(&rt.mailbox, &rt.jobs)
		delete(rt.jobs)
		delete(rt.msgs)
		delete(rt.mailbox.mail)
	}
	run_cmd(&rt, gpu_open(Cv_Msg, proc(e: Ev(Gpu)) -> Cv_Msg { return e.value }))
	testing.expect_value(t, len(rt.msgs), 1)
	g, ok := rt.msgs[0].(Gpu)
	testing.expect(t, ok && g.host != nil && !gpu_limits(g).on_gpu, "the reference")
	clear(&rt.msgs)
	c, _ := canvas_create(g, {8, 8})
	canvas_fill(g, c, 2, 2, 2, 2, {1, 0, 0, 1})
	run_cmd(&rt, canvas_read(Cv_Msg, g, c, 2, 2, 2, 1, proc(e: Ev(Canvas_Read)) -> Cv_Msg { return e.value }, tag = 7))
	canvases_step(&rt)
	got: Canvas_Read
	for i := 0; i < 100 && got.canvas == 0; i += 1 {
		mailbox_drain(&rt.mailbox, &rt.jobs, &rt.msgs)
		for m in rt.msgs do if v, is := m.(Canvas_Read); is do got = v
		time.sleep(time.Millisecond)
	}
	testing.expect(t, got.ok && got.w == 2 && got.format == .RGBA8, "read")
	testing.expect(t, slice.equal(got.pixels, []u8{255, 0, 0, 255, 255, 0, 0, 255}), "255, 0, 0, 255, 255, 0, 0, 255")
	mailbox_release(&rt.mailbox)
}

// canvas_write_begin hands over the bytes the write will be made from, so an
// app with a frame to show copies it once instead of twice.
// What lands is exactly what canvas_write would have put there.
@(test)
a_canvas_write_can_fill_the_toolkits_own_bytes :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c, _ := canvas_create(g, {8, 4})
	same, _ := canvas_create(g, {8, 4})
	e := canvas_entry(g, c)
	before := e.version

	px, ok := canvas_write_begin(g, c, 2, 1, 3, 2)
	testing.expect(t, ok, "opened")
	testing.expect_value(t, len(px), 3 * 2 * 4) // w × h texels of the format, rows tight
	testing.expect_value(t, e.version, before)  // nothing has happened yet
	for i in 0 ..< len(px) do px[i] = u8(i + 1)
	testing.expect(t, canvas_write_end(g, c), "ended")
	testing.expect_value(t, e.version, before + 1)

	filled := make([]u8, 3 * 2 * 4, context.temp_allocator)
	for i in 0 ..< len(filled) do filled[i] = u8(i + 1)
	canvas_write(g, same, 2, 1, 3, 2, filled)
	testing.expect(t, slice.equal(e.pixels, canvas_entry(g, same).pixels), "the same canvas as canvas_write makes")
	testing.expect(t, slice.equal(e.pixels[(1 * 8 + 2) * 4:][:12], filled[:12]), "its first row, at x = 2")
	testing.expect_value(t, e.pixels[(1 * 8 + 1) * 4], u8(0)) // and not a texel outside the rectangle
}

// The same refusals as canvas_write, and one of its own: a write stays open
// until it is ended, because the bytes handed over are the GPU's to take.
@(test)
only_one_canvas_write_is_open_at_a_time :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c, _ := canvas_create(g, {8, 4})
	other, _ := canvas_create(g, {8, 4})

	_, past := canvas_write_begin(g, c, 6, 0, 4, 1)
	testing.expect(t, !past, "a rectangle off the canvas")
	_, none := canvas_write_begin(g, 0, 0, 0, 1, 1)
	testing.expect(t, !none, "no such canvas")
	_, empty := canvas_write_begin(g, c, 0, 0, 0, 1)
	testing.expect(t, !empty, "no texels")
	testing.expect(t, !canvas_write_end(g, c), "nothing to end")

	_, ok := canvas_write_begin(g, c, 0, 0, 2, 2)
	testing.expect(t, ok, "opened")
	_, twice := canvas_write_begin(g, c, 4, 0, 2, 2)
	testing.expect(t, !twice, "not a second write while one is open")
	_, elsewhere := canvas_write_begin(g, other, 0, 0, 2, 2)
	testing.expect(t, !elsewhere, "…not even on another canvas")
	testing.expect(t, !canvas_write_end(g, other), "and the wrong canvas does not end it")
	testing.expect(t, canvas_write_end(g, c), "ended")
	_, after := canvas_write_begin(g, other, 0, 0, 2, 2)
	testing.expect(t, after, "…after which the next write opens")
	canvas_write_end(g, other)
}

// A write the app forgot to end still stands, on either host. On the GPU the
// bytes are already the canvas's staging memory and the operation is already
// queued, so the reference must not quietly drop the frame instead — an app
// that misbehaves has to misbehave the same way both ways, or a bug shows up
// only on the machine with a card in it.
@(test)
a_canvas_write_left_open_still_stands :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c, _ := canvas_create(g, {4, 2})
	px, ok := canvas_write_begin(g, c, 0, 0, 1, 1)
	testing.expect(t, ok, "opened")
	px[0], px[1], px[2], px[3] = 9, 8, 7, 6

	canvas_write_commit(g.host) // what the loop does with a write left open
	testing.expect(t, slice.equal(canvas_entry(g, c).pixels[:4], []u8{9, 8, 7, 6}), "the write stands")
	testing.expect_value(t, g.host.writing, Canvas(0))
	testing.expect(t, !canvas_write_end(g, c), "and ending it afterwards does nothing")
	_, again := canvas_write_begin(g, c, 0, 0, 1, 1)
	testing.expect(t, again, "the next write is not blocked by it")
	canvas_write_end(g, c)
}

// A canvas destroyed under an open write takes the write with it, rather
// than copying into memory that has gone.
@(test)
a_canvas_write_open_on_a_destroyed_canvas_goes_nowhere :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c, _ := canvas_create(g, {4, 2})
	px, _ := canvas_write_begin(g, c, 0, 0, 2, 2)
	px[0] = 5
	canvas_destroy(g, c)
	testing.expect(t, !canvas_write_end(g, c), "nowhere to put it")
	testing.expect_value(t, g.host.writing, Canvas(0)) // and not left open for ever
}

} // when ODIN_TEST