package baldr

@(require) import "core:testing"
@(require) import "core:time"
@(require) import "baldr:gpu"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A photo at its own resolution, smooth when drawn smaller, a part of one,
// and the screen's scale to the view.


@(private = "file")
Pic_Msg :: enum { None }

@(private = "file")
Pic_Sink :: struct {
	pictures:  [dynamic][2]u32,
	uploads:   [dynamic]Pic_Upload,
	destroyed: [dynamic]gpu.Page,
	next:      gpu.Page,
}

@(private = "file")
Pic_Upload :: struct {
	page:  gpu.Page,
	w, h:  u32,
	bytes: int,
	x, y:  u32,
	first: [4]u8, // the first pixel sent
}

@(private = "file")
pic_sink :: proc(rec: ^Pic_Sink) -> Atlas_Sink {
	rec.next = 500
	return {
		user = rec,
		create = proc(user: rawptr, format: gpu.Page_Format, size: [2]u32) -> gpu.Page {
			r := (^Pic_Sink)(user)
			r.next += 1
			return r.next
		},
		upload = proc(user: rawptr, page: gpu.Page, x, y, w, h: u32, pixels: []u8) {
			first: [4]u8
			if len(pixels) >= 4 do first = {pixels[0], pixels[1], pixels[2], pixels[3]}
			append(&(^Pic_Sink)(user).uploads, Pic_Upload{page, w, h, len(pixels), x, y, first})
		},
		picture = proc(user: rawptr, size: [2]u32) -> gpu.Page {
			r := (^Pic_Sink)(user)
			append(&r.pictures, size)
			r.next += 1
			return r.next
		},
		destroy = proc(user: rawptr, page: gpu.Page) {
			append(&(^Pic_Sink)(user).destroyed, page)
		},
	}
}

@(private = "file")
pic_sink_destroy :: proc(r: ^Pic_Sink) {
	delete(r.pictures)
	delete(r.uploads)
	delete(r.destroyed)
}

@(private = "file")
picture_of :: proc(w, h: int) -> Image {
	px := make([]u8, w * h * 4, context.temp_allocator)
	img, _ := image_from_rgba(w, h, px)
	return img
}

// build builds one image node; show also renders it, returning the node and
// the gpu.Image it drew (none: `drawn` false).
@(private = "file")
build :: proc(ui: ^Ui(Pic_Msg), img: ^Image, width, height: f32, fit: Image_Fit, source: Rect) -> (n: Node) {
	begin_view(ui)
	column(ui, align = .Start)
	n = image(ui, img, width = width, height = height, fit = fit, source = source)
	end(ui)
	end_view(ui)
	return
}

@(private = "file")
show :: proc(ui: ^Ui(Pic_Msg), te: ^Text_Engine, img: ^Image, width, height: f32, fit: Image_Fit, source: Rect, sink: ^Atlas_Sink, scale: f32 = 1) -> (n: Node, g: gpu.Image, drawn: bool) {
	n = build(ui, img, width, height, fit, source)
	frame(&ui.tree, {1600, 1200})
	for c in draw_list(&ui.tree) {
		di, is := c.(Draw_Image)
		if !is do continue
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_image(te, di, scale, sink, &out)
		for o in out {
			if gi, ok := o.(gpu.Image); ok {
				g, drawn = gi, true
			}
		}
	}
	return
}

@(private = "file")
near :: proc(a, b: f32) -> bool { return abs(a - b) < 1e-4 }

// `source` picks the part of the picture that fills the box, in its pixels:
// the missing side follows its aspect, Cover and Contain follow it, it is
// clamped to the picture, and a change of it repaints without uploading.
@(test)
an_image_shows_the_part_its_source_names :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	img := picture_of(400, 300)
	defer image_destroy(&img)

	n, g, drawn := show(&ui, &te, &img, 200, 0, .Stretch, {100, 50, 200, 100}, nil)
	testing.expect(t, drawn)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, [2]f32{d.abs.w, d.abs.h}, [2]f32{200, 100}) // the height from the source's aspect, not the picture's
	slot, _ := image_slot(&te, &img) // a picture at its size stays in the atlas
	u := slot.uv_rect
	uw, uh := u[2] - u[0], u[3] - u[1]
	want := [4]f32{u[0] + uw * 100 / 400, u[1] + uh * 50 / 300, u[0] + uw * 300 / 400, u[1] + uh * 150 / 300}
	testing.expectf(t, near(g.uv[0], want[0]) && near(g.uv[1], want[1]) && near(g.uv[2], want[2]) && near(g.uv[3], want[3]), "the source's part of the atlas copy: %v, want %v", g.uv, want)
	uploads := len(te.images)

	// panned: a repaint, not a layout, and no upload
	testing.expect_value(t, build(&ui, &img, 200, 100, .Stretch, {150, 50, 200, 100}), n)
	testing.expect(t, .Dirty_Paint in d.flags && .Dirty_Layout not_in d.flags, "a pan repaints and does not lay out")
	_, g, _ = show(&ui, &te, &img, 200, 100, .Stretch, {150, 50, 200, 100}, nil)
	testing.expect(t, near(g.uv[0], u[0] + uw * 150 / 400), "the new part")
	testing.expect_value(t, len(te.images), uploads)

	_, g, _ = show(&ui, &te, &img, 200, 200, .Cover, {100, 50, 200, 100}, nil) // a square box over a 2:1 source: its middle 100 × 100
	testing.expect(t, near(g.uv[0], u[0] + uw * 150 / 400) && near(g.uv[2], u[0] + uw * 250 / 400) && near(g.uv[1], u[1] + uh * 50 / 300), "Cover trims the source, not the picture")
	_, g, _ = show(&ui, &te, &img, 200, 200, .Contain, {100, 50, 200, 100}, nil)
	testing.expect(t, near(g.rect[3], 100) && near(g.rect[2], 200), "Contain letterboxes to the source's aspect")

	_, g, _ = show(&ui, &te, &img, 100, 100, .Stretch, {-50, -50, 100, 100}, nil) // clamped to the picture
	testing.expect(t, near(g.uv[0], u[0]) && near(g.uv[2], u[0] + uw * 50 / 400) && near(g.uv[3], u[1] + uh * 50 / 300), "clamped at its edges")
	_, _, drawn = show(&ui, &te, &img, 100, 100, .Stretch, {500, 0, 100, 100}, nil)
	testing.expect(t, !drawn, "a source outside the picture draws nothing")
	_, g, _ = show(&ui, &te, &img, 400, 300, .Stretch, {}, nil)
	testing.expect(t, near(g.uv[0], u[0]) && near(g.uv[2], u[2]) && near(g.uv[3], u[3]), "{} is all of it")
}

// A picture bigger than an atlas page is drawn from its own pixels: a
// texture of its own at its full size, uploaded once. A new part of it is
// no upload; a new version goes into the same texture, and a new size
// into a new one.
@(test)
a_big_picture_draws_from_a_texture_of_its_own :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rec: Pic_Sink
	defer pic_sink_destroy(&rec)
	sink := pic_sink(&rec)
	img := picture_of(4000, 3000)
	defer image_destroy(&img)

	_, g, drawn := show(&ui, &te, &img, 1600, 1200, .Stretch, {}, &sink)
	testing.expect(t, drawn)
	testing.expect_value(t, len(rec.pictures), 1)
	if len(rec.pictures) != 1 do return
	testing.expect_value(t, rec.pictures[0], [2]u32{4000, 3000}) // not a quarter of it
	testing.expect_value(t, len(rec.uploads), 1)
	testing.expect(t, rec.uploads[0].w == 4000 && rec.uploads[0].h == 3000 && rec.uploads[0].bytes == 4000 * 3000 * 4, "every pixel, once")
	page := rec.uploads[0].page
	testing.expect_value(t, g.page, page)
	testing.expect_value(t, g.uv, [4]f32{0, 0, 1, 1})
	testing.expect_value(t, len(te.images), 0) // nothing in the atlas

	_, g, _ = show(&ui, &te, &img, 1600, 1200, .Stretch, {1000, 750, 2000, 1500}, &sink) // zoomed in on its middle
	testing.expect_value(t, g.uv, [4]f32{0.25, 0.25, 0.75, 0.75})
	testing.expect_value(t, len(rec.uploads), 1)

	img.version += 1 // new pixels, same size: the same texture
	_, g, _ = show(&ui, &te, &img, 1600, 1200, .Stretch, {}, &sink)
	testing.expect(t, len(rec.uploads) == 2 && rec.uploads[1].page == page && len(rec.pictures) == 1, "uploaded again into its texture")
	testing.expect_value(t, g.page, page)

	delete(img.pixels, img.allocator) // the same picture turned: another size
	img.pixels = make([]u8, 3000 * 4000 * 4, img.allocator)
	img.width, img.height = 3000, 4000
	img.version += 1
	_, g, _ = show(&ui, &te, &img, 1200, 1600, .Stretch, {}, &sink)
	testing.expect(t, len(rec.pictures) == 2 && rec.pictures[1] == {3000, 4000}, "a new texture for the new size")
	testing.expect(t, len(rec.destroyed) == 1 && rec.destroyed[0] == page, "the old one goes")
	testing.expect(t, g.page != page && g.page != 0, "drawn from the new one")
}

// A picture drawn at more than two of its pixels to a screen pixel moves to
// a texture of its own too, sampled through its mip levels, and stays there;
// one drawn at its size stays in the atlas. The screen's pixels count, so
// the same box on a 2× screen needs no mip levels.
@(test)
a_picture_drawn_much_smaller_is_sampled_through_mip_levels :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rec: Pic_Sink
	defer pic_sink_destroy(&rec)
	sink := pic_sink(&rec)
	avatar := picture_of(512, 512)
	defer image_destroy(&avatar)

	_, g, _ := show(&ui, &te, &avatar, 400, 400, .Cover, {}, &sink)
	testing.expect_value(t, len(rec.pictures), 0) // 1.3 of its pixels a screen pixel: the atlas
	testing.expect(t, g.page != 0 && len(te.images) == 1, "in the atlas")

	_, g, _ = show(&ui, &te, &avatar, 128, 128, .Cover, {}, &sink, scale = 2) // 2 a pixel on a 2× screen: still fine
	testing.expect_value(t, len(rec.pictures), 0)

	_, g, _ = show(&ui, &te, &avatar, 32, 32, .Cover, {}, &sink) // 16 a pixel
	testing.expect_value(t, len(rec.pictures), 1)
	testing.expect(t, len(rec.pictures) == 1 && rec.pictures[0] == {512, 512} && g.uv == {0, 0, 1, 1}, "its own texture, at its size")
	own := g.page

	_, g, _ = show(&ui, &te, &avatar, 512, 512, .Cover, {}, &sink) // back at its size: it stays
	testing.expect_value(t, g.page, own)
	testing.expect_value(t, len(rec.pictures), 1)
}

// Textures of their own not drawn for a while go, the longest idle first,
// once they pass the budget; one drawn lately never does. Without a sink
// that makes them (a headless tree) a picture gets a placeholder and stays
// drawable, and without `picture` in the sink the atlas draws it.
@(test)
pictures_not_drawn_lately_make_way :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rec: Pic_Sink
	defer pic_sink_destroy(&rec)
	sink := pic_sink(&rec)

	imgs: [3]Image
	for &img in imgs do img = picture_of(1200, 1000)
	defer for &img in imgs do image_destroy(&img)
	pages: [3]gpu.Page
	for &img, i in imgs {
		_, g, _ := show(&ui, &te, &img, 600, 500, .Stretch, {}, &sink)
		pages[i] = g.page
	}
	testing.expect_value(t, len(te.pictures), 3)
	one := te.pictures[imgs[0].id].bytes
	te.picture_budget = one + one / 2 // room for one idle picture
	long_ago := time.tick_now()
	long_ago._nsec -= 60 * i64(time.Second)
	(&te.pictures[imgs[0].id]).drawn = long_ago                          // the longest idle
	(&te.pictures[imgs[1].id]).drawn = {_nsec = long_ago._nsec + i64(time.Second)} // idle too
	images_begin_frame(&te, &sink)                                        // the third was drawn just now
	testing.expect_value(t, len(rec.destroyed), 1)
	if len(rec.destroyed) == 1 do testing.expect_value(t, rec.destroyed[0], pages[0])
	_, still := te.pictures[imgs[1].id]
	_, recent := te.pictures[imgs[2].id]
	testing.expect(t, still && recent, "the rest fit")
	_, g, _ := show(&ui, &te, &imgs[0], 600, 500, .Stretch, {}, &sink) // drawn again: made again
	testing.expect(t, g.page != pages[0] && len(rec.pictures) == 4, "a new texture")

	headless := picture_of(1500, 800)
	defer image_destroy(&headless)
	_, g, _ = show(&ui, &te, &headless, 750, 400, .Stretch, {}, nil)
	testing.expect(t, g.page != 0 && g.uv == {0, 0, 1, 1}, "a placeholder page, drawable")
	_, g, _ = show(&ui, &te, &headless, 750, 400, .Stretch, {}, &sink) // a sink comes: made and uploaded
	testing.expect(t, len(rec.pictures) == 5 && rec.pictures[4] == {1500, 800}, "made once a sink can")

	plain := sink
	plain.picture = nil
	other := picture_of(1400, 700)
	defer image_destroy(&other)
	_, g, _ = show(&ui, &te, &other, 700, 350, .Stretch, {}, &plain)
	_, own := te.pictures[other.id]
	testing.expect(t, !own && g.page != 0, "drawn from the atlas when the sink makes no pictures")
}

@(test)
device_scale_is_the_surfaces :: proc(t: ^testing.T) {
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	testing.expect_value(t, device_scale(&ui), f32(1)) // before any configure
	ui.surface.scale = 2
	testing.expect_value(t, device_scale(&ui), f32(2))
	ui.surface.scale = 1.25
	testing.expect_value(t, device_scale(&ui), f32(1.25))
}

// A view that asks for the viewport is marked to be built again on a
// resize (a viewer's visible part is worked out from it); one that
// doesn't is only laid out again.
@(test)
a_view_that_reads_the_viewport_is_built_again_on_a_resize :: proc(t: ^testing.T) {
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {1200, 900})
	begin_view(&ui)
	vp := viewport(&ui)
	box(&ui, width = vp.x, height = vp.y)
	end_view(&ui)
	testing.expect(t, ui.read_viewport, "it read the viewport")
	begin_view(&ui)
	box(&ui, width = 100, height = 100)
	end_view(&ui)
	testing.expect(t, !ui.read_viewport, "this one did not")
	_ = viewport(&ui) // outside a build (an update, a test): not the view's
	testing.expect(t, !ui.read_viewport)
}

// A picture that changes in part uploads that part: a touched
// picture has a texture of its own, a touch sends only its rect's rows, two
// touches before a draw go as their union, and a new version still sends
// the whole picture.
@(test)
a_touched_picture_uploads_only_what_changed :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rec: Pic_Sink
	defer pic_sink_destroy(&rec)
	sink := pic_sink(&rec)
	img := picture_of(400, 300) // small enough for the atlas, but a canvas: patched in place
	defer image_destroy(&img)
	image_touch(&img, 0, 0, 1, 1)
	show(&ui, &te, &img, 400, 300, .Stretch, {}, &sink)
	testing.expect_value(t, len(rec.pictures), 1)
	testing.expect(t, len(rec.uploads) == 1 && rec.uploads[0].w == 400 && rec.uploads[0].h == 300, "first: all of it")

	px :: proc(img: ^Image, x, y: int) -> []u8 { return img.pixels[(y * img.width + x) * 4:][:4] }
	copy(px(&img, 10, 20), []u8{9, 8, 7, 255}) // a dab
	image_touch(&img, 10, 20, 30, 5)
	n, _, _ := show(&ui, &te, &img, 400, 300, .Stretch, {}, &sink)
	testing.expect_value(t, len(rec.uploads), 2)
	if len(rec.uploads) == 2 {
		u := rec.uploads[1]
		testing.expect(t, u.x == 10 && u.y == 20 && u.w == 30 && u.h == 5 && u.bytes == 30 * 5 * 4, "just the dab's rect")
		testing.expect_value(t, u.first, [4]u8{9, 8, 7, 255}) // its rows, from where it is
	}
	_ = n

	image_touch(&img, 100, 100, 10, 10) // two touches before a draw: one upload of both
	image_touch(&img, 150, 120, 20, 20)
	show(&ui, &te, &img, 400, 300, .Stretch, {}, &sink)
	testing.expect_value(t, len(rec.uploads), 3)
	if len(rec.uploads) == 3 do testing.expect(t, rec.uploads[2].x == 100 && rec.uploads[2].y == 100 && rec.uploads[2].w == 70 && rec.uploads[2].h == 40, "their union")

	show(&ui, &te, &img, 400, 300, .Stretch, {}, &sink) // nothing touched: nothing sent
	testing.expect_value(t, len(rec.uploads), 3)

	img.version += 1 // all of it changed
	image_touch(&img, 0, 0, 5, 5)
	show(&ui, &te, &img, 400, 300, .Stretch, {}, &sink)
	testing.expect(t, len(rec.uploads) == 4 && rec.uploads[3].w == 400 && rec.uploads[3].h == 300, "a new version: the whole picture, once")
	testing.expect_value(t, len(rec.pictures), 1) // the same texture throughout
}

// How a magnified picture is sampled reaches the renderer. Saying nothing is
// `.Auto`, not `.Smooth`: the shader crossfades smooth into hard between 2
// and 4 device pixels a picture pixel, so a viewer's zoom sharpens without
// every app picking a threshold. `true` and `false` force one or the other.
@(test)
how_a_picture_is_sampled_reaches_the_renderer :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Pic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	img := picture_of(16, 16)
	defer image_destroy(&img)
	begin_view(&ui)
	column(&ui, align = .Start)
	image(&ui, &img, width = 256, height = 256, pixelated = true, key = 1)
	image(&ui, &img, width = 256, height = 256, pixelated = false, key = 2)
	image(&ui, &img, width = 256, height = 256, key = 3)
	image(&ui, &img, width = 256, height = 256, pixel_grid = true, key = 4)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 1200})
	got := make([dynamic]gpu.Image, context.temp_allocator)
	for c in draw_list(&ui.tree) do if di, ok := c.(Draw_Image); ok {
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_image(&te, di, 1, nil, &out)
		for o in out do if gi, is := o.(gpu.Image); is do append(&got, gi)
	}
	if !testing.expect_value(t, len(got), 4) do return
	testing.expect_value(t, got[0].pixels, gpu.Pixels.Hard)
	testing.expect_value(t, got[1].pixels, gpu.Pixels.Smooth)
	testing.expect_value(t, got[2].pixels, gpu.Pixels.Auto)
	testing.expect(t, !got[2].pixel_grid, "no grid unless asked for")
	testing.expect(t, got[3].pixel_grid, "the grid the fourth asked for")
	testing.expect_value(t, got[3].pixels, gpu.Pixels.Auto) // a grid does not force hard pixels
}


} // when ODIN_TEST