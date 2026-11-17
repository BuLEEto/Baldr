package baldr

@(require) import "core:strings"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A code editor's gutter is a column of its own. With wrapping off the
// text slides sideways under the line numbers, and the gutter's tinted
// strip does not hide it, so the text column is clipped at the gutter's
// edge.

@(private = "file")
Cg_Msg :: enum { None }

@(private = "file")
Cg_Fx :: struct {
	ui:  Ui(Cg_Msg),
	doc: Document,
}

@(private = "file")
LINE :: "the quick brown fox jumps over the lazy dog and keeps going past the edge of the window"

@(private = "file")
cg_view :: proc(fx: ^Cg_Fx, numbers := true) -> (frame_n, area: Node) {
	ui := &fx.ui
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, padding = .lg)
	frame_n = code_editor(ui, &fx.doc, nil, label = "Source", height = 240)
	editor_options(ui, frame_n, wrap = false, line_numbers = numbers)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	area = ui.tree.area_of_frame[frame_n]
	return
}

// cg_clip_of walks a layer's commands with the clip stack and returns the
// clip in force where the text `str` is drawn (ok = false: no such text).
@(private = "file")
cg_clip_of :: proc(cmds: []Draw_Cmd, str: string) -> (clip: Rect, ok: bool) {
	stack := make([dynamic]Rect, context.temp_allocator)
	cur: Rect
	for c in cmds {
		#partial switch v in c {
		case Draw_Clip_Push:
			append(&stack, cur)
			cur = v.rect
		case Draw_Clip_Pop:
			if len(stack) > 0 do cur = pop(&stack)
		case Draw_Text:
			if strings.contains(v.str, str) do return cur, true
		}
	}
	return
}

@(test)
a_code_editors_text_is_clipped_at_its_gutter :: proc(t: ^testing.T) {
	fx: Cg_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	three := strings.concatenate({LINE, "\n", LINE, "\n", LINE}, context.temp_allocator) // the document copies it
	fx.doc = document_make(three)
	defer document_destroy(&fx.doc)
	_, area := cg_view(&fx)
	tr := &fx.ui.tree
	s := &tr.areas[area]
	testing.expect(t, s != nil && s.code.on && s.code.gutter_w > 0, "a code editor with a gutter")
	if s == nil do return

	// pan sideways, as End on a long line does
	testing.expect(t, scroll_to(tr, area, {300, 0}), "it pans sideways")
	frame(tr, {600, 400})
	d := node_get(tr, area)
	inner := input_inner(d)
	edge := inner.x + s.code.gutter_w - CODE_GUTTER_PAD / 2 // the gutter's hairline

	l, has := &tr.layers[area]
	if !has do l, has = &tr.layers[tr.root]
	testing.expect(t, has, "the editor's commands are in a layer")
	if !has do return

	text_clip, found := cg_clip_of(l.cmds[:], "quick brown")
	testing.expect(t, found, "the line is drawn")
	if !found do return
	testing.expectf(t, text_clip.x >= edge, "the text is clipped at the gutter's edge (%.1f >= %.1f)", text_clip.x, edge)
	testing.expect(t, text_clip.x + text_clip.w <= inner.x + inner.w + 0.5, "…and at the editor's own edge")

	// the numbers are drawn outside that clip, on their own ground
	num_clip, has_num := cg_clip_of(l.cmds[:], "2")
	testing.expect(t, has_num, "a line number is drawn")
	if !has_num do return
	testing.expect(t, num_clip.x < edge, "the gutter is not inside the text's clip")
}

// Without line numbers there is no gutter and nothing to clip: the text
// uses the whole width.
@(test)
a_code_editor_without_a_gutter_clips_nothing_extra :: proc(t: ^testing.T) {
	fx: Cg_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make(LINE)
	defer document_destroy(&fx.doc)
	_, area := cg_view(&fx, numbers = false)
	tr := &fx.ui.tree
	s := &tr.areas[area]
	testing.expect(t, s != nil && s.code.gutter_w == 0, "no gutter")
	if s == nil do return
	d := node_get(tr, area)
	inner := input_inner(d)
	l, has := &tr.layers[area]
	if !has do l, has = &tr.layers[tr.root]
	if !has {
		testing.fail(t)
		return
	}
	clip, found := cg_clip_of(l.cmds[:], "quick brown")
	testing.expect(t, found, "the line is drawn")
	if !found do return
	testing.expectf(t, clip.x <= inner.x + 0.5, "the text has the whole width (%.1f, %.1f)", clip.x, inner.x)
}

}
