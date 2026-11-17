package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// A conversation list's rows. An unread row says how many, says it in the
// ordinary text colour rather than the muted one, puts its time in the
// accent and shows the start bar; a search result shows which words
// matched; and a tab can ask to be noticed.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Lru_Msg :: union { Lru_Pick }
@(private = "file")
Lru_Pick :: struct { i: int }

@(private = "file")
lru_build :: proc(ui: ^Ui(Lru_Msg), unread: int, mark: [2]int = {}) -> Node {
	set_viewport(&ui.tree, {360, 200})
	begin_view(ui)
	column(ui, width = 320, padding = .sm)
	n := list_row(ui, "Ada Lovelace", Lru_Msg(Lru_Pick{1}), glyph = "A",
		detail = "see you at the bridge then", detail_mark = mark,
		unread = unread, value = "09:12", variant = .Avatar, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {360, 200})
	return n
}

@(private = "file")
lru_texts :: proc(t: ^Tree, at: Node, out: ^[dynamic]Node) {
	for c := node_first(t, at); c != NODE_NONE; c = node_next(t, c) {
		if _, ok := node_get(t, c).kind.(Text_Kind); ok do append(out, c)
		lru_texts(t, c, out)
	}
}

@(private = "file")
lru_find :: proc(t: ^Tree, row: Node, s: string) -> Node {
	all := make([dynamic]Node, context.temp_allocator)
	lru_texts(t, row, &all)
	for c in all {
		if tk, ok := node_get(t, c).kind.(Text_Kind); ok && tk.str == s do return c
	}
	return NODE_NONE
}

// The count is drawn as a pill and said in the description, because an
// accent circle is no use to someone who cannot see it.
@(test)
an_unread_row_shows_its_count_and_says_it :: proc(t: ^testing.T) {
	ui: Ui(Lru_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	n := lru_build(&ui, 0)
	testing.expect_value(t, lru_find(&ui.tree, n, "3"), NODE_NONE) // nothing unread, no pill
	testing.expect(t, !strings.contains(node_get(&ui.tree, n).access.describe, "unread"))

	n2 := lru_build(&ui, 3)
	badge := lru_find(&ui.tree, n2, "3")
	testing.expect(t, badge != NODE_NONE, "the count is drawn")
	testing.expect(t, strings.contains(node_get(&ui.tree, n2).access.describe, "3 unread"),
		"and a screen reader hears it")

	// past ninety-nine a count stops being a count
	lru_build(&ui, 100)
	testing.expect(t, lru_find(&ui.tree, n2, "99+") != NODE_NONE, "100 reads as 99+")
	testing.expect(t, strings.contains(node_get(&ui.tree, n2).access.describe, "100 unread"),
		"…but the description still says the real number")
}

// Unread emphasis: the last message in the ordinary colour, the time in
// the accent, and the start bar: the same bar the selected row gets,
// because both mean "look here".
@(test)
an_unread_row_is_emphasised :: proc(t: ^testing.T) {
	ui: Ui(Lru_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	th := &ui.tree.theme

	read := lru_build(&ui, 0)
	read_time := lru_find(&ui.tree, read, "09:12")
	testing.expect(t, read_time != NODE_NONE)
	was_muted := node_get(&ui.tree, read_time).style.fg
	mark_read, _ := ui.tree.button_marks[read]
	testing.expect_value(t, mark_read.mark.length, f32(0)) // no bar

	unread := lru_build(&ui, 2)
	un_time := lru_find(&ui.tree, unread, "09:12")
	testing.expect(t, node_get(&ui.tree, un_time).style.fg != was_muted, "the time changes colour when unread")
	mark_un, has := ui.tree.button_marks[unread]
	testing.expect(t, has && mark_un.mark.length > 0, "and the start bar is shown")
	testing.expect_value(t, mark_un.mark.color, th.color.primary)
}

// A search result shows which words matched, so the eye finds why the row
// is in the list.
@(test)
a_marked_detail_splits_so_the_match_stands_out :: proc(t: ^testing.T) {
	ui: Ui(Lru_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	plain := lru_build(&ui, 0)
	testing.expect(t, lru_find(&ui.tree, plain, "see you at the bridge then") != NODE_NONE,
		"with no mark the detail is one text")

	// "bridge" is at 15..21
	at := strings.index("see you at the bridge then", "bridge")
	n := lru_build(&ui, 0, {at, at + len("bridge")})
	match := lru_find(&ui.tree, n, "bridge")
	testing.expect(t, match != NODE_NONE, "the matched words are their own run")
	testing.expect(t, lru_find(&ui.tree, n, "see you at the ") != NODE_NONE, "with what came before")
	testing.expect(t, lru_find(&ui.tree, n, " then") != NODE_NONE, "and after")

	tk, _ := node_get(&ui.tree, match).kind.(Text_Kind)
	testing.expect_value(t, tk.weight, Font_Weight.Semibold) // heavier than its neighbours

	// a nonsense range is ignored rather than crashing or slicing wrongly
	bad := lru_build(&ui, 0, {20, 5})
	testing.expect(t, lru_find(&ui.tree, bad, "see you at the bridge then") != NODE_NONE)
	past := lru_build(&ui, 0, {0, 9999})
	testing.expect(t, lru_find(&ui.tree, past, "see you at the bridge then") != NODE_NONE)
}

// A tab can ask to be noticed while it is not the one you are on, and says
// so as well as showing it.
@(test)
a_tab_can_ask_for_attention_until_it_is_selected :: proc(t: ^testing.T) {
	ui: Ui(Lru_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Lru_Msg), sel: int) -> Node {
		set_viewport(&ui.tree, {360, 120})
		begin_view(ui)
		column(ui, padding = .sm)
		labels := []string{"Chats", "Requests (3)"}
		tones := []Tone{.Neutral, .Danger}
		bar := tab_bar(ui, sel, labels, tones = tones, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {360, 120})
		return bar
	}
	nth :: proc(t: ^Tree, bar: Node, i: int) -> Node {
		n := node_first(t, bar)
		for _ in 0 ..< i do n = node_next(t, n)
		return n
	}

	bar := build(&ui, 0) // Chats selected, Requests is not
	req := nth(&ui.tree, bar, 1)
	testing.expect_value(t, node_get(&ui.tree, req).access.describe, "needs attention")

	plain := nth(&ui.tree, bar, 0)
	testing.expect_value(t, node_get(&ui.tree, plain).access.describe, "")

	// its label is drawn in a different colour from an ordinary unselected tab
	req_lbl, plain_lbl := node_first(&ui.tree, req), node_first(&ui.tree, plain)
	testing.expect(t, node_get(&ui.tree, req_lbl).style.fg != node_get(&ui.tree, plain_lbl).style.fg,
		"a tab asking for attention does not look like the one beside it")

	// selected, it is an ordinary tab again
	bar2 := build(&ui, 1)
	req2 := nth(&ui.tree, bar2, 1)
	testing.expect_value(t, node_get(&ui.tree, req2).access.describe, "")
}

}
