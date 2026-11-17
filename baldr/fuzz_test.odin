package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:unicode/utf8"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Seeded random input, so a failure names its seed and replays exactly:
// markdown streamed in random pieces, and an editor driven by random keys.

@(private = "file")
Fuzz_Rng :: struct { s: u64 }

@(private = "file")
fuzz_next :: proc(r: ^Fuzz_Rng, n: int) -> int {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return int(r.s % u64(max(n, 1)))
}

@(private = "file")
FUZZ_MD_PIECES := [?]string{
	"# ", "## ", "- ", "1. ", "> ", "- [ ] ", "- [x] ", "---\n", "```odin\n", "```\n", "```",
	"| a | b |\n", "|---|---|\n", "| 1 | 2<br>3 |\n", "**", "*", "`", "~~", "[link](https://example.com)",
	"<https://example.com>", "www.example.com ", "[^1]", "\n", "\n\n", "\r\n", "word ", "two words ",
	"averyveryverylongwordwithnobreaks", "日本語のテキスト", "مرحبا بالعالم", "שלום", "👍🏽", "👩‍👩‍👧",
	"é", "\t", "  ", "\\", "<br>", "&amp;", "\xff", "\xe2\x82", "\x00",
}

@(private = "file")
Fuzz_Msg :: union { int }

@(test)
markdown_survives_random_streams :: proc(t: ^testing.T) {
	ui: Ui(Fuzz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	md_init(&md)
	defer md_destroy(&md)
	for seed in 1 ..= 200 {
		r := Fuzz_Rng{u64(seed) * 0x9E3779B97F4A7C15 + 1}
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 1 + fuzz_next(&r, 40) do strings.write_string(&b, FUZZ_MD_PIECES[fuzz_next(&r, len(FUZZ_MD_PIECES))])
		doc := strings.to_string(b)
		switch fuzz_next(&r, 3) {
		case 0: md_clear(&md)
		case 1: md_set(&md, doc[:fuzz_next(&r, len(doc) + 1)]) // something there already, often longer than what follows
		}
		w := f32(40 + fuzz_next(&r, 560))
		at := 0
		for at < len(doc) {
			n := 1 + fuzz_next(&r, 12)
			to := min(at + n, len(doc))
			md_append(&md, doc[at:to])
			at = to
			if fuzz_next(&r, 3) == 0 {
				set_viewport(&ui.tree, {w + 40, 4000})
				begin_view(&ui)
				column(&ui, width = w)
				markdown_view(&ui, &md, label = "Reply", width = w)
				end(&ui)
				end_view(&ui)
				frame(&ui.tree, {w + 40, 4000})
			}
		}
		if len(ui.tree.bounds_faults) > 0 {
			f := ui.tree.bounds_faults[0]
			testing.expectf(t, false, "seed %d: %s drew a %v at %v outside %v", seed, f.builder, f.cmd, f.drawn, f.bounds)
			clear(&ui.tree.bounds_faults)
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
FUZZ_TYPED := [?]string{"a", "b", " ", "word", "日本", "مر", "👍🏽", "é", "\t", ".", "‍"}

@(private = "file")
Fuzz_Area :: struct {
	ui:  Ui(Fuzz_Msg),
	doc: Document,
	n:   Node,
}

@(private = "file")
fuzz_area_view :: proc(fx: ^Fuzz_Area, w: f32) {
	set_viewport(&fx.ui.tree, {w + 40, 600})
	begin_view(&fx.ui)
	column(&fx.ui)
	fx.n = text_area(&fx.ui, &fx.doc, label = "Notes", width = w)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {w + 40, 600})
}

// fuzz_pos_ok says a position is inside the document and on a character's start.
@(private = "file")
fuzz_pos_ok :: proc(doc: ^Document, p: Pos) -> bool {
	if p.block < 0 || p.block >= block_count(doc) do return false
	s := block_str(doc, p.block)
	if p.off < 0 || p.off > len(s) do return false
	return p.off == len(s) || utf8.rune_start(s[p.off])
}

@(test)
an_editor_survives_random_keys :: proc(t: ^testing.T) {
	keys := [?]Key{.Backspace, .Delete, .Left, .Right, .Up, .Down, .Home, .End, .Enter, .Page_Up, .Page_Down}
	for seed in 1 ..= 60 {
		r := Fuzz_Rng{u64(seed) * 0xD1B54A32D192ED03 + 7}
		fx: Fuzz_Area
		ui_init(&fx.ui)
		fx.doc = document_make("Start here.\nSecond line")
		w := f32(60 + fuzz_next(&r, 400))
		fuzz_area_view(&fx, w)
		set_focus(&fx.ui.tree, fx.n, true)
		frame(&fx.ui.tree, {w + 40, 600})
		bad := ""
		for step in 0 ..< 120 {
			switch fuzz_next(&r, 6) {
			case 0, 1:
				text_area_text(&fx.ui, FUZZ_TYPED[fuzz_next(&r, len(FUZZ_TYPED))])
			case 2, 3:
				mods: Mods
				if fuzz_next(&r, 3) == 0 do mods += {.Shift}
				if fuzz_next(&r, 4) == 0 do mods += {.Ctrl}
				key_event(&fx.ui, keys[fuzz_next(&r, len(keys))], true, mods)
			case 4:
				switch fuzz_next(&r, 3) {
				case 0: key_event(&fx.ui, .A, true, {.Ctrl})
				case 1: key_event(&fx.ui, .Z, true, {.Ctrl})
				case 2: key_event(&fx.ui, .Y, true, {.Ctrl})
				}
			case 5:
				fuzz_area_view(&fx, f32(60 + fuzz_next(&r, 400))) // a rebuild at another width
			}
			s, ok := &fx.ui.tree.areas[fx.n]
			if !ok { bad = "the editor lost its state"; break }
			if !fuzz_pos_ok(&fx.doc, s.caret) || !fuzz_pos_ok(&fx.doc, s.anchor) {
				bad = fmt.tprintf("step %d: caret %v / anchor %v outside the document or inside a character", step, s.caret, s.anchor)
				break
			}
		}
		testing.expectf(t, bad == "", "seed %d: %s", seed, bad)
		// What undo takes back, redo puts back exactly.
		before := document_text(&fx.doc, context.temp_allocator)
		undone := 0
		for _ in 0 ..< 20 {
			prev := document_text(&fx.doc, context.temp_allocator)
			key_event(&fx.ui, .Z, true, {.Ctrl})
			if document_text(&fx.doc, context.temp_allocator) == prev do break
			undone += 1
		}
		for _ in 0 ..< undone do key_event(&fx.ui, .Y, true, {.Ctrl})
		after := document_text(&fx.doc, context.temp_allocator)
		testing.expectf(t, after == before, "seed %d: %d undos and redos gave %q, not %q", seed, undone, after, before)
		ui_destroy(&fx.ui)
		document_destroy(&fx.doc)
		free_all(context.temp_allocator)
	}
}

} // when ODIN_TEST
