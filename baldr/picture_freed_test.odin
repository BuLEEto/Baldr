package baldr

@(require) import "core:fmt"
@(require) import "core:mem"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:gpu"

// What the toolkit does when it is given, or left holding, an Image that is
// not a picture any more: it draws nothing (or the copy the atlas kept),
// says so once, and never reads the pointer again.
//
// GONE_W and GONE_H are what a freed Image's first two fields read as: a
// pair of heap pointers, whose `width * height * 4` overflows, so a guard
// that multiplies first lets them through.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Pf_Msg :: union { int }

@(private = "file")
GONE_W :: 140453617901888
@(private = "file")
GONE_H :: 140453617927296

// pf_gone makes `img` read as a freed one: the fields the allocator wrote
// over, with its pixels left where they were (nothing may read them).
@(private = "file")
pf_gone :: proc(img: ^Image) {
	img.width, img.height = GONE_W, GONE_H
}

@(private = "file")
pf_picture :: proc(w, h: int) -> Image {
	px := make([]u8, w * h * 4, context.temp_allocator)
	for i in 0 ..< len(px) do px[i] = u8(i)
	img, _ := image_from_rgba(w, h, px)
	return img
}

@(private = "file")
pf_user_of :: proc(t: ^Tree, n: Node) -> rawptr {
	d := node_get(t, n)
	if d == nil do return nil
	ck, ok := d.kind.(Custom_Kind)
	return ck.user if ok else nil
}

// pf_cmds_holding: layer commands still carrying `img`.
@(private = "file")
pf_cmds_holding :: proc(t: ^Tree, img: ^Image) -> (held: int) {
	for _, l in t.layers do for c in l.cmds {
		if v, is_img := c.(Draw_Image); is_img && v.img == img do held += 1
	}
	return
}

@(private = "file")
pf_image_cmds :: proc(t: ^Tree) -> (out: [dynamic]Draw_Image) {
	out = make([dynamic]Draw_Image, context.temp_allocator)
	for c in draw_list(t) do if v, is_img := c.(Draw_Image); is_img do append(&out, v)
	return
}

// An Image that cannot be a picture is not drawn, is not remembered, and is
// reported once against the line that handed it over — which is the line the
// app has to look at, since by then the pointer is all the toolkit has.
@(test)
a_picture_that_does_not_add_up_is_not_drawn :: proc(t: ^testing.T) {
	img := pf_picture(4, 4)
	defer image_destroy(&img)
	pf_gone(&img)
	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	set_viewport(&ui.tree, {200, 200})
	begin_view(&ui)
	column(&ui, padding = .none)
	n := image(&ui, &img, width = 40, height = 40, key = 1)
	end(&ui)
	end_view(&ui)

	// the build's own doing, before anything paints: paint has a guard of
	// its own, and asserting after a frame cannot tell the two apart
	testing.expect_value(t, pf_user_of(&ui.tree, n), nil)
	_, before := ui.tree.pictures[n]
	testing.expect(t, !before, "the build wrote nothing down about it")

	frame(&ui.tree, {200, 200})
	testing.expect_value(t, len(pf_image_cmds(&ui.tree)), 0)
	testing.expect_value(t, pf_cmds_holding(&ui.tree, &img), 0)
	testing.expect_value(t, pf_user_of(&ui.tree, n), nil)
	_, has := ui.tree.pictures[n]
	testing.expect(t, !has, "and nothing was written down about it")
	testing.expect_value(t, len(ui.diags), 1)
	if len(ui.diags) == 1 {
		testing.expect(t, strings.contains(ui.diags[0].msg, "does not add up"), ui.diags[0].msg)
		testing.expect(t, strings.contains(ui.diags[0].loc.file_path, "picture_freed_test.odin"), "named where the picture was handed over")
	}
}

// The invariant the release paths rely on: an image node holds the app's
// pointer exactly while `t.pictures[n]` says what it last showed. A node
// holding a pointer with no entry could not be reached by
// `pictures_release` or `image_forget` — both find a node through that map.
@(test)
an_image_node_holds_a_pointer_only_with_a_picture_to_draw :: proc(t: ^testing.T) {
	good := pf_picture(4, 4)
	defer image_destroy(&good)
	empty := Image{width = 4, height = 4} // no pixels: a picture that has not been decoded
	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	// No frame: this is what the *build* leaves behind, and paint has a
	// guard of its own that would tidy the same thing away.
	build :: proc(ui: ^Ui(Pf_Msg), img: ^Image) -> Node {
		set_viewport(&ui.tree, {200, 200})
		begin_view(ui)
		column(ui, padding = .none)
		n := image(ui, img, width = 40, height = 40, key = 1)
		end(ui)
		end_view(ui)
		return n
	}

	n := build(&ui, &good)
	_, has := ui.tree.pictures[n]
	testing.expect(t, has && pf_user_of(&ui.tree, n) == rawptr(&good), "a picture to draw: both")

	n2 := build(&ui, &empty)
	testing.expect_value(t, n2, n)
	_, has2 := ui.tree.pictures[n]
	testing.expect(t, !has2, "no picture to draw: no entry")
	testing.expect_value(t, pf_user_of(&ui.tree, n), nil) // …and no pointer either

	// …and nothing says a word about it: an Image with no pixels yet is an
	// ordinary thing for a view to hold, not a picture that went away.
	frame(&ui.tree, {200, 200})
	testing.expect_value(t, len(ui.diags), 0)
	testing.expect(t, !ui.tree.picture_said)
}

// The two questions on their own: `image_sides_ok` is layout's (could these
// be a picture's sides) and `image_adds_up` is paint's and the renderer's
// (are the pixels there, and enough of them). Both refuse a side past
// IMAGE_MAX_SIDE before multiplying: `width * height * 4` of a freed Image's
// pointer-sized fields wraps, and a wrapped comparison lets it through.
@(test)
the_two_questions_asked_of_an_app_owned_picture :: proc(t: ^testing.T) {
	px := make([]u8, 8, context.temp_allocator) // room for two RGBA8 pixels
	one := Image{width = 1, height = 1, pixels = px}
	two := Image{width = 2, height = 1, pixels = px}
	three := Image{width = 3, height = 1, pixels = px}
	sized := Image{width = 200, height = 100} // sized, not decoded yet
	gone := Image{width = GONE_W, height = GONE_H, pixels = px}
	huge := Image{width = IMAGE_MAX_SIDE + 1, height = 1, pixels = px}

	testing.expect(t, image_sides_ok(&sized), "sized but not decoded: its room is its own")
	testing.expect(t, image_sides_ok(&one))
	testing.expect(t, !image_sides_ok(nil))
	testing.expect(t, !image_sides_ok(&gone), "a freed one's fields are not sides")
	testing.expect(t, !image_sides_ok(&huge))

	testing.expect(t, image_adds_up(&one))
	testing.expect(t, image_adds_up(&two), "exactly enough pixels")
	testing.expect(t, !image_adds_up(&three), "one pixel short")
	testing.expect(t, !image_adds_up(&sized), "nothing to draw yet")
	testing.expect(t, !image_adds_up(nil))
	testing.expect(t, !image_adds_up(&gone))
	testing.expect(t, !image_adds_up(&huge))
}

// Layout asks a weaker question than paint: a picture an app has sized but
// not decoded takes its own room, because that is where its pixels are
// going.
@(test)
a_picture_not_decoded_yet_still_takes_its_room :: proc(t: ^testing.T) {
	coming := Image{width = 200, height = 100} // sized, no pixels
	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	set_viewport(&ui.tree, {400, 400})
	begin_view(&ui)
	column(&ui, padding = .none, align = .Start)
	n := image(&ui, &coming, width = 40, key = 1) // the height follows its aspect
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 400})

	d := node_get(&ui.tree, n)
	testing.expect_value(t, [2]f32{d.abs.w, d.abs.h}, [2]f32{40, 20})
	testing.expect_value(t, len(pf_image_cmds(&ui.tree)), 0) // …and nothing is drawn there yet
	testing.expect_value(t, len(ui.diags), 0)                // nor is anything wrong with it
}

// A tab panel switched away from is parked, not destroyed, and is not built
// again until it is shown, so it would go on pointing at the app's Images
// as a skipped `component` does. Parking lets go of them.
@(test)
a_parked_tab_panel_lets_go_of_its_pictures :: proc(t: ^testing.T) {
	img := pf_picture(4, 4)
	defer image_destroy(&img)
	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Pf_Msg), img: ^Image, second: bool) -> Node {
		n := NODE_NONE
		set_viewport(&ui.tree, {300, 300})
		begin_view(ui)
		column(ui, flex = 1)
		tab_bar(ui, 1 if second else 0, {"Pictures", "Other"}, nil)
		if tab_panel(ui, !second, key = 1) {
			n = image(ui, img, width = 40, height = 40, key = 2)
			end(ui)
		}
		if tab_panel(ui, second, key = 3) {
			text(ui, "the other tab")
			end(ui)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {300, 300})
		return n
	}

	n := build(&ui, &img, false)
	testing.expect_value(t, pf_user_of(&ui.tree, n), rawptr(&img))

	build(&ui, &img, true) // switched away: the panel is parked, with its nodes
	testing.expect(t, node_valid(&ui.tree, n), "the parked panel keeps its nodes")
	testing.expect_value(t, pf_user_of(&ui.tree, n), nil)
	testing.expect(t, ui.tree.pictures[n].released, "and draws the atlas's copy if it is shown again before a build")

	build(&ui, &img, false) // back: the build hands the picture over again
	testing.expect_value(t, pf_user_of(&ui.tree, n), rawptr(&img))
	testing.expect(t, !ui.tree.pictures[n].released)
}

// The hole the toolkit cannot close: a `component` whose revision has not
// changed is not built, so its image node still points at the Image when
// the app frees it. The picture then comes from the copy the atlas kept,
// the node lets go of the pointer, and nothing reads it.
@(test)
a_picture_that_goes_away_under_a_skipped_component_draws_the_atlas_copy :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	rec: Pf_Sink
	defer pf_sink_destroy(&rec)
	sink := pf_sink(&rec)
	img := pf_picture(8, 8)
	defer image_destroy(&img)
	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Pf_Msg), img: ^Image, beat: int) -> Node {
		n := NODE_NONE
		set_viewport(&ui.tree, {200, 200})
		begin_view(ui)
		column(ui, padding = .none)
		text(ui, fmt.tprintf("%d", beat), key = 9) // something else on the layer, changing: the layer paints again
		if component(ui, "pic", 1) { // the revision never changes: never built again
			n = image(ui, img, width = 40, height = 40, key = 1)
			end(ui)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {200, 200})
		return n
	}

	// drawn once, so the atlas has a copy
	n := build(&ui, &img, 1)
	drawn := 0
	for v in pf_image_cmds(&ui.tree) {
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_image(&te, v, 1, &sink, &out)
		for o in out do if _, is := o.(gpu.Image); is do drawn += 1
	}
	testing.expect_value(t, drawn, 1)
	id, version := img.id, img.version

	// the app frees it in `update`; its view does not show it any less,
	// because the component it sits in is not built
	pf_gone(&img)
	build(&ui, &img, 2)
	testing.expect_value(t, pf_user_of(&ui.tree, n), nil)
	testing.expect(t, ui.tree.pictures[n].released, "it draws what the atlas kept")

	cmds := pf_image_cmds(&ui.tree)
	testing.expect_value(t, len(cmds), 1)
	testing.expect_value(t, pf_cmds_holding(&ui.tree, &img), 0)
	if len(cmds) == 1 {
		testing.expect_value(t, cmds[0].id, id)
		testing.expect_value(t, cmds[0].version, version)
		testing.expect_value(t, cmds[0].size, [2]int{8, 8}) // the size the build wrote down, not the freed one's
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_image(&te, cmds[0], 1, &sink, &out) // and it still draws, from the copy
		gpu_images := 0
		for o in out do if _, is := o.(gpu.Image); is do gpu_images += 1
		testing.expect_value(t, gpu_images, 1)
	}
}

// A `Draw_Image` carrying an Image that stopped adding up between the paint
// and the frame. `len(pixels) < width * height * 4` overflows for sides this
// size, so a guard written that way passes and the scale-down loop indexes
// off the end of the pixels.
@(test)
the_renderer_refuses_a_picture_whose_sides_cannot_be_true :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	rec: Pf_Sink
	defer pf_sink_destroy(&rec)
	sink := pf_sink(&rec)
	img := pf_picture(8, 8)
	defer image_destroy(&img)
	pf_gone(&img)

	_, ok := image_slot(&te, &img)
	testing.expect(t, !ok, "the atlas refuses it rather than reading past its pixels")
	_, page_ok := picture_page(&te, 77, &img, &sink)
	testing.expect(t, !page_ok, "and so does a texture of its own")
	testing.expect_value(t, len(rec.pictures), 0) // nothing was asked of the device
	testing.expect_value(t, len(rec.uploads), 0)

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_image(&te, Draw_Image{rect = {0, 0, 40, 40}, img = &img, color = {1, 1, 1, 1}, fit = .Cover,
		id = 5, version = 1, size = {8, 8}}, 1, &sink, &out)
	testing.expect_value(t, len(out), 0) // no copy in the atlas either: nothing is drawn, and nothing crashes
}

// A `Draw_Image` the paint made while the picture was still there, drawn a
// frame later with the Image gone: the copy the atlas kept is what shows.
// The picture must still be on screen — this is the case where the app was
// within its rights (it freed an Image its view had stopped showing) and
// only the cached command was behind.
@(test)
a_command_whose_picture_went_away_draws_the_copy_the_atlas_kept :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	rec: Pf_Sink
	defer pf_sink_destroy(&rec)
	sink := pf_sink(&rec)
	img := pf_picture(8, 8)
	defer image_destroy(&img)

	_, ok := image_slot(&te, &img) // drawn once while it was a picture
	testing.expect(t, ok)
	id, version := img.id, img.version
	testing.expect(t, id != 0)

	pf_gone(&img)
	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_image(&te, Draw_Image{rect = {0, 0, 40, 40}, img = &img, color = {1, 1, 1, 1}, fit = .Cover,
		id = id, version = version, size = {8, 8}}, 1, &sink, &out)
	drawn := 0
	for o in out do if _, is := o.(gpu.Image); is do drawn += 1
	testing.expect_value(t, drawn, 1) // from the atlas, by the identity the paint wrote down
	testing.expect_value(t, len(rec.pictures), 0) // and nothing of the freed one reached the device
}

// A markdown view keeps the pictures the app hands it in its own state, by
// their markdown `src` and again on each laid-out block, where no
// `Tree.pictures` entry points at them, so `image_forget` has to clear
// those too.
@(test)
a_markdown_view_lets_go_of_a_picture_it_was_given :: proc(t: ^testing.T) {
	img := pf_picture(16, 16)
	defer image_destroy(&img)
	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "Before.\n\n![a picture](pic)\n\nAfter.\n")

	build :: proc(ui: ^Ui(Pf_Msg), md: ^Markdown_Doc, img: ^Image) -> Node {
		set_viewport(&ui.tree, {400, 600})
		begin_view(ui)
		n := markdown_view(ui, md, label = "Page", width = 400)
		if img != nil do md_view_image(ui, n, "pic", img)
		end_view(ui)
		frame(&ui.tree, {400, 600})
		return n
	}

	n := build(&ui, &md, &img)
	testing.expect_value(t, pf_cmds_holding(&ui.tree, &img), 1)

	// the app is about to free it, and its view has no way to stop showing
	// it any sooner
	image_forget(&ui, &img)
	s := &ui.tree.md_views[n]
	testing.expect(t, s != nil)
	held := 0
	for _, pic in s.images do if pic == &img do held += 1
	for c in s.blocks do if c.picture == &img do held += 1
	testing.expect_value(t, held, 0)

	frame(&ui.tree, {400, 600})
	testing.expect_value(t, pf_cmds_holding(&ui.tree, &img), 0) // and nothing draws it any more
	testing.expect_value(t, len(pf_image_cmds(&ui.tree)), 0)    // the block shows its alt text instead

	build(&ui, &md, &img) // handed over again: back as it was
	testing.expect_value(t, pf_cmds_holding(&ui.tree, &img), 1)
}

// …and one it was given that stopped adding up is simply not drawn.
@(test)
a_markdown_view_does_not_draw_a_picture_that_does_not_add_up :: proc(t: ^testing.T) {
	img := pf_picture(16, 16)
	defer image_destroy(&img)
	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "![a picture](pic)\n")

	set_viewport(&ui.tree, {400, 600})
	begin_view(&ui)
	n := markdown_view(&ui, &md, label = "Page", width = 400)
	md_view_image(&ui, n, "pic", &img)
	end_view(&ui)
	frame(&ui.tree, {400, 600})
	testing.expect_value(t, pf_cmds_holding(&ui.tree, &img), 1)

	pf_gone(&img) // freed, and the view was never told
	mark_paint_dirty(&ui.tree, n)
	frame(&ui.tree, {400, 600})
	testing.expect_value(t, len(pf_image_cmds(&ui.tree)), 0)
}

// End to end, with a picture that is really freed: `image_destroy` and
// `free` run, and the allocator scribbles the block and keeps it rather
// than handing it back, so a read after the free is a defined read of 0xAA
// rather than undefined behaviour that happens to work.
//
// Nothing in the toolkit may read it: the picture on screen comes from the
// copy the atlas kept, and the one line that was printed names where it was
// being shown from.
@(test)
a_picture_really_freed_under_a_skipped_component_is_never_read :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	rec: Pf_Sink
	defer pf_sink_destroy(&rec)
	sink := pf_sink(&rec)
	poison := Pf_Poison{backing = context.allocator}
	pa := mem.Allocator{pf_poison_proc, &poison}
	defer pf_poison_release(&poison)

	px := make([]u8, 8 * 8 * 4, context.temp_allocator)
	for i in 0 ..< len(px) do px[i] = u8(i)
	img := new(Image, pa)
	img^, _ = image_from_rgba(8, 8, px, pa)

	ui: Ui(Pf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Pf_Msg), img: ^Image, beat: int) -> Node {
		n := NODE_NONE
		set_viewport(&ui.tree, {200, 200})
		begin_view(ui)
		column(ui, padding = .none)
		text(ui, fmt.tprintf("%d", beat), key = 9) // the layer has something else on it, changing
		if component(ui, "pic", 1) { // one revision for ever: never built again
			n = image(ui, img, width = 40, height = 40, key = 1)
			end(ui)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {200, 200})
		return n
	}

	n := build(&ui, img, 1)
	id, version := img.id, img.version
	for v in pf_image_cmds(&ui.tree) { // drawn once, so the atlas has a copy
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_image(&te, v, 1, &sink, &out)
	}
	testing.expect(t, id != 0 && len(te.images) == 1)

	// the app's `update` frees it
	image_destroy(img)
	free(img, pa)
	testing.expect(t, poison.scribbled >= 2, "the pixels and the box were both overwritten")
	// A defined read of the quarantined block: this is what a stale pointer
	// into it gets, and the premise of everything below. (A real allocator
	// writes its own links there instead, which read as heap pointers.)
	testing.expect_value(t, u64(img.width), 0xAAAA_AAAA_AAAA_AAAA)

	// …and its view goes on showing it, because the component it sits in is
	// not built: this is the hole that cannot be closed from here
	build(&ui, img, 2)
	testing.expect_value(t, pf_user_of(&ui.tree, n), nil)
	testing.expect(t, ui.tree.picture_said, "and one line said where it was being shown from")

	cmds := pf_image_cmds(&ui.tree)
	testing.expect_value(t, len(cmds), 1)
	testing.expect_value(t, pf_cmds_holding(&ui.tree, img), 0)
	if len(cmds) == 1 {
		testing.expect_value(t, cmds[0].id, id)
		testing.expect_value(t, cmds[0].version, version)
		testing.expect_value(t, cmds[0].size, [2]int{8, 8}) // what the build wrote down, not what the freed block reads
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_image(&te, cmds[0], 1, &sink, &out)
		drawn := 0
		for o in out do if _, is := o.(gpu.Image); is do drawn += 1
		testing.expect_value(t, drawn, 1)      // still on screen, from the copy
		testing.expect_value(t, len(rec.pictures), 0) // and nothing of it reached the device
	}
}

// ---- an allocator that overwrites what it frees, and keeps it ----
//
// A block handed back to the heap and read again is undefined; one
// scribbled and quarantined reads 0xAA every time, which is what makes
// a test about reading freed memory worth running.

@(private = "file")
Pf_Poison :: struct {
	backing:    mem.Allocator,
	sizes:      map[rawptr]int,
	quarantine: [dynamic]rawptr,
	scribbled:  int,
}

@(private = "file")
pf_poison_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	p := (^Pf_Poison)(data)
	if mode == .Free && old_memory != nil {
		n := old_size if old_size > 0 else p.sizes[old_memory]
		if n > 0 {
			mem.set(old_memory, 0xAA, n)
			p.scribbled += 1
		}
		append(&p.quarantine, old_memory) // kept: whatever reads it reads 0xAA, not someone else's bytes
		delete_key(&p.sizes, old_memory)
		return nil, .None
	}
	bytes, err := p.backing.procedure(p.backing.data, mode, size, alignment, old_memory, old_size, loc)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if err == .None && len(bytes) > 0 {
			if old_memory != nil do delete_key(&p.sizes, old_memory)
			p.sizes[raw_data(bytes)] = len(bytes)
		}
	}
	return bytes, err
}

@(private = "file")
pf_poison_release :: proc(p: ^Pf_Poison) {
	for ptr in p.quarantine do p.backing.procedure(p.backing.data, .Free, 0, 0, ptr, 0)
	delete(p.quarantine)
	delete(p.sizes)
}

// ---- a sink that records what the renderer asked the device for ----

@(private = "file")
Pf_Sink :: struct {
	pictures: [dynamic][2]u32,
	uploads:  [dynamic]int,
	next:     gpu.Page,
}

@(private = "file")
pf_sink :: proc(rec: ^Pf_Sink) -> Atlas_Sink {
	rec.next = 700
	return {
		user = rec,
		create = proc(user: rawptr, format: gpu.Page_Format, size: [2]u32) -> gpu.Page {
			r := (^Pf_Sink)(user)
			r.next += 1
			return r.next
		},
		upload = proc(user: rawptr, page: gpu.Page, x, y, w, h: u32, pixels: []u8) {
			append(&(^Pf_Sink)(user).uploads, len(pixels))
		},
		picture = proc(user: rawptr, size: [2]u32) -> gpu.Page {
			r := (^Pf_Sink)(user)
			append(&r.pictures, size)
			r.next += 1
			return r.next
		},
		destroy = proc(user: rawptr, page: gpu.Page) {},
	}
}

@(private = "file")
pf_sink_destroy :: proc(r: ^Pf_Sink) {
	delete(r.pictures)
	delete(r.uploads)
}

}
