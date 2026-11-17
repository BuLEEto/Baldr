package main

// Type and shapes drawn into a picture, shown at 1:1.
// A heading in the theme's typeface at a heavy weight, a justified and
// tracked paragraph with a selection and a caret drawn from its geometry,
// right-to-left text, colour emoji, an installed family, and paths filled
// and stroked with dashes and a hole.

import "core:fmt"
import "baldr:baldr"

W :: 880
H :: 560

State :: struct {
	picture: baldr.Image,
	drawn:   bool,
}

Msg :: enum { None }

// set typesets and draws one text, logging what it was set in.
set :: proc(tree: ^baldr.Tree, img: ^baldr.Image, text: string, style: baldr.Typeset_Style, at: [2]f32, color: baldr.Color) -> baldr.Typeset {
	ts, ok := baldr.typeset(tree, text, style)
	if !ok {
		fmt.eprintfln("typeset: %q failed", text)
		return {}
	}
	fmt.eprintfln("typeset: %q in %q at %d, box %v, ink %v, %d lines", text, ts.family, ts.weight, ts.size, ts.ink, len(ts.lines))
	baldr.typeset_draw(&ts, img, at, color)
	return ts
}

// fill paints a rectangle (a selection, a caret) into the picture.
fill :: proc(img: ^baldr.Image, r: baldr.Rect, color: baldr.Color) {
	p := baldr.path_make()
	defer baldr.path_destroy(&p)
	baldr.path_rect(&p, r)
	m, _ := baldr.mask_make({int(r.x) - 1, int(r.y) - 1}, {int(r.w) + 3, int(r.h) + 3})
	defer baldr.mask_destroy(&m)
	baldr.path_fill(&p, &m)
	baldr.image_paint(img, &m, color)
}

draw :: proc(s: ^State, tree: ^baldr.Tree) {
	img := &s.picture
	head := set(tree, img, "Baldr sets type", {size = 72, weight = 800, tracking = -20}, {24, 12}, baldr.rgb(0x1B1F3B))
	baldr.typeset_destroy(&head)

	PARA :: "Pictures take words at the document's size: a heading in any face the machine has, set with tracking and a line height, justified between two edges."
	style := baldr.Typeset_Style{size = 20, wrap_width = 400, justify = true, tracking = 20, line_height = 30}
	at := [2]f32{24, 120}
	if ts, ok := baldr.typeset(tree, PARA, style); ok {
		lo := 27 // "document's size"
		for r in baldr.typeset_rects(&ts, lo, lo + 15, context.temp_allocator) do fill(img, {at.x + r.x, at.y + r.y, r.w, r.h}, baldr.rgb(0x3D7EFF, 0.3))
		c := baldr.typeset_caret(&ts, 57) // before "heading"
		fill(img, {at.x + c.x - 1, at.y + c.y + 3, 2, c.h - 6}, baldr.rgb(0xD0302F))
		baldr.typeset_draw(&ts, img, at, baldr.rgb(0x222222))
		fmt.eprintfln("typeset: paragraph %d lines, box %v; hit at the caret gives %d", len(ts.lines), ts.size, baldr.typeset_hit(&ts, {c.x, c.y + 5}))
		baldr.typeset_destroy(&ts)
	}

	rtl := set(tree, img, "שלום עולם, hello world", {size = 32, wrap_width = 400}, {456, 120}, baldr.rgb(0x0B5D3B))
	baldr.typeset_destroy(&rtl)
	emoji := set(tree, img, "Colour 😀 🎨 ✨", {size = 48}, {456, 190}, baldr.rgb(0x222222))
	baldr.typeset_destroy(&emoji)
	serif := set(tree, img, "An installed family, bold italic", {family = "DejaVu Serif", size = 30, weight = 700, italic = true}, {24, 300}, baldr.rgb(0x6B2C91))
	baldr.typeset_destroy(&serif)
	light := set(tree, img, "Thin 200", {size = 40, weight = 200}, {24, 350}, baldr.rgb(0x222222))
	after := light.size.x
	baldr.typeset_destroy(&light)
	black := set(tree, img, "Black 900", {size = 40, weight = 900}, {24 + after + 24, 350}, baldr.rgb(0x222222))
	baldr.typeset_destroy(&black)

	// shapes: a ring (evenodd), a dashed round-joined zigzag, a lasso-like
	// polygon without anti-aliasing
	ring := baldr.path_make()
	defer baldr.path_destroy(&ring)
	baldr.path_ellipse(&ring, {540, 400}, {70, 70})
	baldr.path_ellipse(&ring, {540, 400}, {40, 40})
	m, _ := baldr.mask_make({460, 320}, {160, 160})
	defer baldr.mask_destroy(&m)
	baldr.path_fill(&ring, &m, .Evenodd)
	baldr.image_paint(img, &m, baldr.rgb(0xE08A1E))
	zig := baldr.path_make()
	defer baldr.path_destroy(&zig)
	baldr.path_move(&zig, {640, 460})
	for i in 1 ..= 4 do baldr.path_line(&zig, {640 + f32(i) * 50, 460 - f32(i % 2) * 90})
	z, _ := baldr.mask_make({600, 330}, {280, 170})
	defer baldr.mask_destroy(&z)
	baldr.path_stroke(&zig, &z, 10, join = .Round, cap = .Round, dashes = {30, 16})
	baldr.image_paint(img, &z, baldr.rgb(0x2F6FED))
	lasso := baldr.path_make()
	defer baldr.path_destroy(&lasso)
	_ = baldr.path_svg(&lasso, "M 40 420 C 90 380 160 520 220 430 S 300 400 330 500 L 60 530 Z")
	l, _ := baldr.mask_make({30, 380}, {320, 160})
	defer baldr.mask_destroy(&l)
	baldr.path_fill(&lasso, &l, antialias = false)
	baldr.image_paint(img, &l, baldr.rgb(0x2AA876, 0.6))
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	if !s.drawn {
		draw(s, &ui.tree)
		s.drawn = true
	}
	baldr.column(ui, flex = 1, padding = .md); defer baldr.end(ui)
	baldr.image(ui, &s.picture, width = W, height = H, label = "Type and shapes", key = 1)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Typeset", app_id = "dev.baldr.typeset", size = {W + 40, H + 40},
		init = proc() -> (s: State) {
			px := make([]u8, W * H * 4, context.temp_allocator)
			for &b in px do b = 250
			s.picture, _ = baldr.image_from_rgba(W, H, px)
			return
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
		view = view,
	})
}
