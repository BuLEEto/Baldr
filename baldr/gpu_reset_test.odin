package baldr

@(require) import "baldr:gpu"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// What a GPU reset does to the toolkit's side of the device. The rebuilding
// itself needs a device and is checked by spikes/gpu_reset; what is checked
// here is everything that must be forgotten: a page number kept across a
// reset names whatever took the slot next, and the app draws into someone
// else's texture.

// A canvas does not come back: its texels lived in VRAM and there is no
// copy of them anywhere. The handle an app kept must answer false rather
// than quietly start naming the next canvas made.
@(test)
a_reset_spends_every_canvas_handle :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)

	a, ok_a := canvas_create(g, {8, 8})
	b, ok_b := canvas_create(g, {4, 4})
	testing.expect(t, ok_a && ok_b, "two canvases")
	testing.expect(t, canvas_valid(g, a) && canvas_valid(g, b), "both alive to start with")

	canvas_host_gpu_lost(g.host)
	testing.expect(t, !canvas_valid(g, a), "the first is gone with the device")
	testing.expect(t, !canvas_valid(g, b), "…and so is the second")
	testing.expect(t, !canvas_fill(g, a, 0, 0, 8, 8, {1, 0, 0, 1}), "and nothing can be drawn into it")

	// The slot stays taken, so a canvas made now is a different number: the
	// app's old handle cannot come back to life naming this one.
	c, ok_c := canvas_create(g, {8, 8})
	testing.expect(t, ok_c, "a canvas after the reset")
	testing.expect(t, c != a && c != b, "a new number, not a spent one")
	testing.expect(t, canvas_valid(g, c), "and it is a canvas")

	// An app that tidies up in App.gpu_reset gets its numbers back.
	canvas_destroy(g, a)
	d, ok_d := canvas_create(g, {2, 2})
	testing.expect(t, ok_d && d == a, "the freed slot is handed out again")
	testing.expect(t, canvas_valid(g, d))
}

// Every page the text engine put on the device is gone with it. The pixels
// are runa's and still here, so the engine forgets its pages and the next
// frame uploads them whole. Count_Sink records what the renderer would have
// been asked to make and fill, which is how a headless test sees an upload.
@(private = "file")
Count_Sink :: struct { creates, uploads, bytes: int }

@(private = "file")
count_create :: proc(user: rawptr, format: gpu.Page_Format, size: [2]u32) -> gpu.Page {
	s := (^Count_Sink)(user)
	s.creates += 1
	return gpu.Page(100 + s.creates)
}

@(private = "file")
count_upload :: proc(user: rawptr, page: gpu.Page, x, y, w, h: u32, pixels: []u8) {
	s := (^Count_Sink)(user)
	s.uploads += 1
	s.bytes += len(pixels)
}

@(test)
a_reset_makes_the_text_engine_upload_again :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	tree_use_text_engine(&tr, &te)
	node_append(&tr, tr.root, node_new(&tr, Text_Kind{str = "reset", size = 16}))
	frame(&tr, {400, 200})

	rec: Count_Sink
	sink := Atlas_Sink{user = &rec, create = count_create, upload = count_upload}
	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 1, &sink, &out)
	if rec.creates == 0 do testing.fail_now(t, "no glyph page to lose")
	first_creates, first_bytes := rec.creates, rec.bytes

	// Nothing has changed: a frame asks for nothing.
	clear(&out)
	render_prepare(&tr, 1, &sink, &out)
	testing.expect_value(t, rec.creates, first_creates)
	testing.expect_value(t, rec.bytes, first_bytes)

	text_engine_gpu_lost(&te)

	// …and now every page is made and filled again, from pixels runa kept.
	clear(&out)
	render_prepare(&tr, 1, &sink, &out)
	testing.expect_value(t, rec.creates, first_creates * 2)
	testing.expect_value(t, rec.bytes, first_bytes * 2)
	gs := 0
	for c in out do if _, ok := c.(gpu.Glyph); ok do gs += 1
	testing.expect(t, gs > 0, "and the text is still drawn")
	for c in out do if g, ok := c.(gpu.Glyph); ok {
		testing.expect(t, int(g.page) > 100 + first_creates, "from the pages made after the reset, not the numbers from before")
	}
}

// The loss is said once, since a line a frame buries the log; the next
// reset says so again.
@(test)
a_loss_is_reported_once_per_loss :: proc(t: ^testing.T) {
	r: gpu.Renderer
	testing.expect(t, !gpu.lost(&r), "a renderer starts with its device")

	gpu.simulate_device_lost(&r)
	testing.expect(t, gpu.lost(&r))
	testing.expect(t, gpu.lost_first(&r), "the first frame to find it says so")
	testing.expect(t, !gpu.lost_first(&r), "the next thousand do not")

	r.lost = false // as a successful recover leaves it
	r.lost_logged = false
	gpu.simulate_device_lost(&r)
	testing.expect(t, gpu.lost_first(&r), "a second reset is reported in its turn")
}
}
