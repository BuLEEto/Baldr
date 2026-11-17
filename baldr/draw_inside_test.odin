package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Every widget draws inside the part of the window a repaint of it clears,
// whatever it is given: awkward text (empty, one unbreakable word, hard
// breaks, Japanese, Arabic, emoji) at narrow and wide widths, through the
// text options and the container and control options apps set least.
// Anything drawn outside is left on screen when the widget changes.

@(private = "file")
Inside_Msg :: union { int, bool, string }

@(private = "file")
INSIDE_STRINGS := [?]string{
	"",
	"Short",
	"A sentence long enough to need more than one line in any narrow column of a table",
	"Supercalifragilisticexpialidocious_with_no_place_to_break_at_all",
	"Line one\nLine two\nLine three",
	"これは狭い列には収まらない長い日本語のテキストです",
	"مرحبا بالعالم، هذا نص طويل باللغة العربية للاختبار",
	"👍🏽 thumbs up, 🇬🇧 a flag and 👩‍👩‍👧 a family",
}

@(private = "file")
INSIDE_WIDTHS := [?]f32{40, 120, 600}

@(private = "file")
inside_view :: proc(ui: ^Ui(Inside_Msg), s: string, w: f32, md: ^Markdown_Doc) {
	grey := Color{0.5, 0.5, 0.5, 1}
	label := s if s != "" else "Go"
	options := []string{s, "Two"}
	parts := []string{s, "Two", "Three"}
	begin_view(ui)
	column(ui, width = w, gap = .sm)
	{
		text(ui, s)
		text(ui, s, nowrap = true)
		text(ui, s, ellipsis = .End)
		text(ui, s, ellipsis = .Middle, max_lines = 2)
		text(ui, s, max_width = w / 2)
		text(ui, s, ellipsis = .End, max_width = w / 2)
		text(ui, s, nowrap = true, width = w / 3)
		text(ui, s, align = .Center)
		text(ui, s, align = .End, ellipsis = .End)
		text(ui, s, role = .Display, ellipsis = .End)
		text(ui, s, mono = true, tabular = true)

		row(ui, gap = .sm)
		text(ui, s, flex = 1)
		text(ui, s, ellipsis = .End, flex = 1)
		text(ui, "fixed", width = 60)
		end(ui)

		row(ui, height = 14, padding = .xs) // a bar shorter than a line
		text(ui, s)
		icon(ui, .Settings)
		end(ui)

		stack(ui, padding = .md, align = .Center, max_width = w * 0.8, bg = grey, radius = 8)
		text(ui, s)
		end(ui)

		wrap(ui, gap = .sm, padding = .sm, max_width = w, bg = grey, radius = 6)
		chip(ui, label)
		chip(ui, "x")
		text(ui, s)
		end(ui)

		card(ui, max_height = 60)
		text(ui, s)
		text(ui, s)
		end(ui)

		scroll(ui, height = 60, content_width = w * 1.5, align = .Center)
		text(ui, s)
		end(ui)

		row(ui, gap = .sm)
		button(ui, label, Inside_Msg(1))
		button(ui, label, Inside_Msg(2), icon = .Settings, variant = .Ghost, size = .Small)
		end(ui)

		list_row(ui, label, Inside_Msg(3), detail = s, value = s)
		chip(ui, label, on_close = Inside_Msg(4))
		select(ui, -1, options, placeholder = label, width = min(w, 200))
		segmented(ui, 0, parts, flex = 1)
		text_input(ui, nil, placeholder = s, label = "Field", compact = true)
		text_input(ui, nil, placeholder = s, label = "Quiet field", quiet = true, width = w / 2)
		styled_text(ui, s, max_width = w / 2)
		styled_text(ui, s, size = 22)
		markdown_view(ui, md, label = "Reply", width = w)
		icon_toggle(ui, .Star, true, "Star", size = 28)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {w + 40, 3000})
}

// The second half: fields and pickers, collections and their spacing, panes.
@(private = "file")
inside_view_more :: proc(ui: ^Ui(Inside_Msg), s: string, w: f32, md: ^Markdown_Doc) {
	label := s if s != "" else "Item"
	parts := []string{label, "Two", s}
	options := []string{label, "Second option"}
	cols := []Column{{title = label}, {title = "Size", width = 60, numeric = true}, {title = s, min_width = 20}}
	vals := []f32{1, 3, 2, 5, 4}
	begin_view(ui)
	column(ui, width = w, gap = .sm)
	{
		date_field(ui, Date{2026, 11, 17}, label = label, width = w)
		time_field(ui, Time_Of_Day{9, 41, 0, 0}, label = label, width = w / 2)
		color_field(ui, Color{0.2, 0.4, 0.8, 1}, label = label, width = w / 2)
		number_input(ui, 12345.678, label = label, width = w / 3)
		slider(ui, 0.4, label = label, width = w)
		checkbox(ui, true, label)
		radio(ui, 0, options, label = label, horizontal = true)
		toggle(ui, true, label)
		progress(ui, 0.5, label = label, width = w)
		badge(ui, label)
		breadcrumbs(ui, parts, label = label)
		tab_bar(ui, 0, parts)
		if expander(ui, label, true) {
			text(ui, s)
			end(ui)
		}
		sparkline(ui, vals, width = w / 2, height = 20)

		row(ui, height = 120)
		split(ui, w / 3, min = 10)
		pane(ui, padding = .sm, align = .Center)
		text(ui, s)
		end(ui)
		pane(ui)
		text(ui, label)
		end(ui)
		end(ui)
		end(ui)

		tf, tl := table(ui, cols, 30, height = 120, label = "Table")
		for i in tf ..< tl {
			table_row(ui, i)
			cell_text(ui, s)
			cell_text(ui, "12 KB")
			cell_text(ui, label)
			end(ui)
		}
		end(ui)

		lf, ll := list(ui, 30, row_height = 40, height = 100, tail_pad = 16, padding = .sm, gap = .xs, label = "List")
		for i in lf ..< ll do list_row(ui, s if i % 2 == 0 else label, Inside_Msg(i), detail = s)
		end(ui)

		tree_view(ui, label = "Tree", height = 100, indent = 24, padding = .sm)
		if tree_item(ui, label, Inside_Msg(1), expanded = true, icon = .Folder, key = 1) {
			tree_item(ui, s if s != "" else "leaf", Inside_Msg(2), icon = .File, key = 2)
			end(ui)
		}
		end(ui)

		vf, vl := icon_view(ui, 12, nil, gap = .sm, padding = .sm, height = 140, gutter = true, label = "Icons")
		for i in vf ..< vl do icon_item(ui, i, .File, s if i % 2 == 0 else label)
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {w + 40, 3000})
}

@(private = "file")
inside_sweep :: proc(t: ^testing.T, real_text: bool) {
	te: Text_Engine
	ui: Ui(Inside_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	if real_text {
		if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: the embedded fonts did not load")
		tree_use_text_engine(&ui.tree, &te)
	}
	defer if real_text do text_engine_destroy(&te)
	ui.tree.debug_bounds = true
	md: Markdown_Doc
	md_init(&md)
	defer md_destroy(&md)
	faults := 0
	for s in INSIDE_STRINGS {
		for w in INSIDE_WIDTHS {
			md_set(&md, fmt.tprintf("%s\n\n- %s\n\n```\ncode %s\n```\n", s, s, s))
			set_viewport(&ui.tree, {w + 40, 3000})
			inside_view(&ui, s, w, &md)
			inside_view_more(&ui, s, w, &md)
			for f in ui.tree.bounds_faults {
				faults += 1
				if faults <= 8 do testing.expectf(t, false, "%s (line %d) drew a %v at %v outside %v, given %q at %v px (real text: %v)",
					f.builder, f.loc.line, f.cmd, f.drawn, f.bounds, s, w, real_text)
			}
			clear(&ui.tree.bounds_faults)
		}
	}
	testing.expectf(t, faults == 0, "%d drawings outside their boxes", faults)
}

@(test)
awkward_content_draws_inside_its_box :: proc(t: ^testing.T) {
	inside_sweep(t, false)
}

@(test)
awkward_content_draws_inside_its_box_with_real_fonts :: proc(t: ^testing.T) {
	inside_sweep(t, true)
}

} // when ODIN_TEST
