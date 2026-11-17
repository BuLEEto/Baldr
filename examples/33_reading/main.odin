// 33_reading — a page in colours of its own, its controls included. A
// reader offers Paper, Sepia, Dusk and Night; without `theme_area` it could
// colour only what it drew itself, and a Light desktop would put a white bar
// over a Night page.
//
// The bar, the page and the controls below all sit inside one
// `theme_area`, so the ghost buttons hover in the page's own colour and
// their focus rings are drawn in its accent. The menu the "Appearance"
// button opens keeps the window's theme on purpose: a popup is its own
// surface over the whole window rather than part of the page.
//
// It is also the place to look at what `theme_on_ground` derives: press
// Tab to see the focus ring on each ground, hover the chapter buttons, and
// compare the page against the strip outside the area at the foot.
package main

import "core:strings"
import "baldr:baldr"

Msg :: union {
	Pick,
	Open_Menu,
	Close_Menu,
	Chapter,
}
Pick       :: struct { ground: int }
Open_Menu  :: struct {}
Close_Menu :: struct {}
Chapter    :: struct { by: int }

Ground :: struct {
	name:            string,
	bg, ink, accent: baldr.Color,
}

// Four grounds a reader offers. The hexes are sRGB, as a designer writes
// them; `rgb` converts to the linear colour the renderer wants.
GROUNDS := []Ground{
	{"Paper", baldr.rgb(0xFBF8F2), baldr.rgb(0x1E1B17), baldr.rgb(0x8A4B1C)},
	{"Sepia", baldr.rgb(0xF2E6CE), baldr.rgb(0x3A2E21), baldr.rgb(0x7A3E12)},
	{"Dusk",  baldr.rgb(0x2A2826), baldr.rgb(0xD8D2C6), baldr.rgb(0xE3A65F)},
	{"Night", baldr.rgb(0x0A0A0A), baldr.rgb(0xA8A29A), baldr.rgb(0xC08A4E)},
}

// The \ufffc is an OBJECT REPLACEMENT CHARACTER: a box the app draws
// itself, as a book that sets names as small images mid-sentence needs.
// Typesetting makes room for the picture and says where it landed, and the
// app draws it there.
PROSE :: "Everything starts somewhere, although many physicists disagree. But people have always been dimly aware of the problem with the start of things. The scholar \ufffc wondered aloud how the snowplough driver gets to work, or how the makers of dictionaries look up the spellings of the words."

// SEAL_W, SEAL_H are the room the picture asks for, and SEAL_DROP how far
// below the baseline it sits — a little, as a letter with a descender does.
SEAL_W   :: f32(22)
SEAL_H   :: f32(22)
SEAL_DROP :: f32(4)

State :: struct {
	ground:  int,
	chapter: int,
	menu:    bool,
	page:    baldr.Typeset,  // the prose, laid out once per ground and width
	page_w:  f32,
	page_ink: baldr.Color,
	seal:    baldr.Image,    // the name set as a picture, drawn where the page says
}

// seal_image makes the little red name stamp the page sets inline. An app
// would decode a picture here; what matters is that it is the app's, drawn
// by the app, at the rectangle the typesetter hands back.
seal_image :: proc() -> baldr.Image {
	w, h := int(SEAL_W), int(SEAL_H)
	px := make([]u8, w * h * 4)
	defer delete(px)
	for y in 0 ..< h do for x in 0 ..< w {
		i := (y * w + x) * 4
		edge := x < 2 || y < 2 || x >= w - 2 || y >= h - 2
		mark := (x >= 6 && x < w - 6 && y >= h / 2 - 1 && y < h / 2 + 1) || (y >= 6 && y < h - 6 && x >= w / 2 - 1 && x < w / 2 + 1)
		r, g, b: u8 = 0xC0, 0x25, 0x20
        if mark { r, g, b = 0xFF, 0xF4, 0xEC }
		if edge { r, g, b = 0xA0, 0x18, 0x14 }
		px[i], px[i + 1], px[i + 2], px[i + 3] = r, g, b, 0xFF
	}
	img, _ := baldr.image_from_rgba(w, h, px)
	return img
}

// page_for lays the chapter out again when the measure or the colours
// change — the reader's own loop, in miniature. The ink goes into the runs
// so the words are the ground's, not the theme's default.
page_for :: proc(s: ^State, ui: ^baldr.Ui(Msg), width: f32) {
	g := GROUNDS[s.ground]
	if s.page_w == width && s.page_ink == g.ink do return
	baldr.typeset_destroy(&s.page)
	runs := []baldr.Typeset_Run{{end = len(PROSE), ink = g.ink}}
	objects := []baldr.Typeset_Object{
		{at = strings.index(PROSE, "\ufffc"), size = {SEAL_W, SEAL_H}, baseline = SEAL_DROP, label = "Li Bai"},
	}
	style := baldr.Typeset_Style{
		size = 18, wrap_width = width, justify = true, indent = 18,
		breaking = .Even, runs = runs, objects = objects,
	}
	if ts, ok := baldr.typeset(&ui.tree, PROSE, style); ok {
		s.page, s.page_w, s.page_ink = ts, width, g.ink
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	g := GROUNDS[s.ground]
	page := baldr.theme_on_ground(ui.tree.theme, g.bg, g.ink, g.accent, g.name)

	baldr.column(ui, flex = 1); defer baldr.end(ui)
	// Everything in here is the reader's own: the bar, the page and the
	// controls under it.
	area := baldr.column(ui, flex = 1, bg = page.color.bg); {
		defer baldr.end(ui)
		baldr.theme_area(ui, area, page)

		{ // the bar
			baldr.row(ui, padding = .sm, gap = .sm, align = .Center); {
				defer baldr.end(ui)
				baldr.button(ui, "Previous chapter", Chapter{-1}, variant = .Ghost, icon = .Chevron_Left, icon_only = true)
				baldr.button(ui, "Next chapter", Chapter{+1}, variant = .Ghost, icon = .Chevron_Right, icon_only = true)
				baldr.text(ui, fmt_chapter(s.chapter), role = .Caption, flex = 1, align = .Center)
				menu := baldr.button(ui, "Appearance", Open_Menu{}, variant = .Ghost)
				// …and the menu it opens is the window's, not the page's: it is
				// a surface over the whole window.
				if baldr.popover(ui, menu, s.menu, Close_Menu{}) {
					defer baldr.end(ui)
					baldr.column(ui, padding = .sm, gap = .xs); {
						defer baldr.end(ui)
						for gr, i in GROUNDS {
							baldr.button(ui, gr.name, Pick{i}, variant = .Ghost if i != s.ground else .Secondary, key = u64(i) + 1)
						}
					}
				}
			}
		}
		baldr.separator(ui)
		{ // the page
			baldr.column(ui, padding = .xl, gap = .md, flex = 1); {
				defer baldr.end(ui)
				page_for(s, ui, 420)
				if len(s.page.lines) > 0 {
					// A stack: the page, and the app's own pictures over it at
					// the rectangles the typesetter handed back. Nothing about
					// the picture is the toolkit's — it only kept the room.
					baldr.stack(ui); {
						defer baldr.end(ui)
						baldr.typeset_view(ui, &s.page, ink = g.ink)
						for o, i in s.page.objects {
							// the offset is a container's, so each picture rides in
							// one placed where the line left room for it
							baldr.column(ui, offset = {o.rect.x, o.rect.y}, key = u64(i) + 1); {
								defer baldr.end(ui)
								baldr.image(ui, &s.seal, width = o.rect.w, height = o.rect.h, radius = 3, label = o.label)
							}
						}
					}
				}
				baldr.text(ui, "Page 1 of 92", role = .Caption, muted = true, align = .Center)
			}
		}
	}
	// Outside the area: the window's own theme, for comparison.
	baldr.row(ui, padding = .sm, gap = .sm, align = .Center); {
		defer baldr.end(ui)
		baldr.text(ui, "outside the reading area — the desktop's theme", role = .Caption, muted = true, flex = 1)
		baldr.button(ui, "Shelf", Chapter{0}, variant = .Ghost)
	}
}

fmt_chapter :: proc(n: int) -> string {
	NAMES := [?]string{"Begin Reading", "The Hogswatch", "Teatime", "The Castle of Bones"}
	return NAMES[clamp(n, 0, len(NAMES) - 1)]
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Reading", app_id = "baldr.reading", size = {620, 620},
		init = proc() -> State { return {seal = seal_image()} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Pick:
				s.ground, s.menu = v.ground, false
				s.page_w = 0 // the ink changed: lay the page out again
			case Open_Menu:  s.menu = true
			case Close_Menu: s.menu = false
			case Chapter:    s.chapter = clamp(s.chapter + v.by, 0, 3)
			}
			return {}
		},
		view = view,
	})
}
