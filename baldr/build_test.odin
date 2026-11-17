package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Test_Msg :: enum { Inc, Dec, Toggle }

@(private = "file")
counter_view :: proc(ui: ^Ui(Test_Msg), count: int) -> (label, minus, plus: Node) {
	begin_view(ui)
	column(ui, gap = .md, padding = .lg)
	label = text(ui, fmt.tprintf("Count: %d", count))
	row(ui, gap = .sm)
	minus = button(ui, "-", Test_Msg.Dec)
	plus = button(ui, "+", Test_Msg.Inc)
	end(ui)
	end(ui)
	end_view(ui)
	return
}

@(private = "file")
live_nodes :: proc(tr: ^Tree) -> (n: int) {
	for d in tr.nodes do if .Alive in d.flags do n += 1
	return
}

@(test)
build_reuses_nodes_across_rebuilds :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	l1, m1, p1 := counter_view(&ui, 0)
	frame(&ui.tree, {400, 300})
	n1 := live_nodes(&ui.tree)

	l2, m2, p2 := counter_view(&ui, 1)
	testing.expect(t, l1 == l2 && m1 == m2 && p1 == p2, "same handles on rebuild")
	testing.expect_value(t, live_nodes(&ui.tree), n1)
	testing.expect_value(t, node_get(&ui.tree, l2).kind.(Text_Kind).str, "Count: 1")
	testing.expect(t, .Dirty_Layout in node_get(&ui.tree, l2).flags, "changed text is layout-dirty")
	testing.expect(t, .Dirty_Layout not_in node_get(&ui.tree, m2).flags, "unchanged button is clean")

	// Only the changed text repaints: one layer rebuild, damage == text rect.
	ui.stats = {}
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, ui.stats.layers_rebuilt, 1)
	testing.expect_value(t, len(ui.diags), 0)
}

@(test)
build_space_tokens_resolve :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	c := column(&ui, gap = .md, padding = 7)
	end(&ui)
	end_view(&ui)
	l := node_get(&ui.tree, c).layout
	testing.expect_value(t, l.gap, f32(12))
	testing.expect_value(t, l.padding, [4]f32{7, 7, 7, 7})
}

@(test)
build_button_click_queues_message :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, minus, plus := counter_view(&ui, 0)
	testing.expect(t, click(&ui, minus))
	testing.expect(t, click(&ui, plus))
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect_value(t, ui.msgs[0], Test_Msg.Dec)
	testing.expect_value(t, ui.msgs[1], Test_Msg.Inc)
}

@(test)
build_removes_children_not_emitted :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	text(&ui, "a"); text(&ui, "b"); c := text(&ui, "c")
	end_view(&ui)
	testing.expect_value(t, node_child_count(&ui.tree, ui.root), 3)

	begin_view(&ui)
	text(&ui, "a")
	end_view(&ui)
	testing.expect_value(t, node_child_count(&ui.tree, ui.root), 1)
	testing.expect(t, !node_valid(&ui.tree, c), "unemitted node destroyed")
}

@(test)
build_keyed_children_follow_their_keys :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view := proc(ui: ^Ui(Test_Msg), ids: []u64) -> map[u64]Node {
		out := make(map[u64]Node, context.temp_allocator)
		begin_view(ui)
		column(ui)
		for id in ids {
			r := row(ui, key = id)
			text(ui, fmt.tprintf("item %d", id))
			end(ui)
			out[id] = r
		}
		end(ui)
		end_view(ui)
		return out
	}
	first := view(&ui, {1, 2, 3})
	second := view(&ui, {3, 1})
	testing.expect(t, first[3] == second[3] && first[1] == second[1], "keyed rows keep their nodes across reorder")
	testing.expect(t, !node_valid(&ui.tree, first[2]), "dropped key destroyed")
	col := node_first(&ui.tree, ui.root)
	kids := [dynamic]Node{}
	defer delete(kids)
	for c := node_first(&ui.tree, col); c != NODE_NONE; c = node_next(&ui.tree, c) do append(&kids, c)
	testing.expect(t, len(kids) == 2 && kids[0] == first[3] && kids[1] == first[1], "sibling order follows the new list")
}

@(private = "file")
comp_calls: int

@(test)
build_component_skips_unchanged_revision :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view := proc(ui: ^Ui(Test_Msg), rev: u64) {
		begin_view(ui)
		if component(ui, "files", rev) {
			comp_calls += 1
			text(ui, fmt.tprintf("rev %d", rev))
			end(ui)
		}
		text(ui, "footer")
		end_view(ui)
	}
	comp_calls = 0
	view(&ui, 1)
	view(&ui, 1)
	view(&ui, 1)
	testing.expect_value(t, comp_calls, 1)
	testing.expect_value(t, node_child_count(&ui.tree, ui.root), 2)
	comp := node_first(&ui.tree, ui.root)
	inner := node_first(&ui.tree, comp)
	testing.expect_value(t, node_get(&ui.tree, inner).kind.(Text_Kind).str, "rev 1")

	view(&ui, 2)
	testing.expect_value(t, comp_calls, 2)
	testing.expect_value(t, node_get(&ui.tree, inner).kind.(Text_Kind).str, "rev 2")
	testing.expect_value(t, len(ui.diags), 0)
}

@(test)
build_unbalanced_scope_is_diagnosed_with_location :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	opener_line := #line - 1
	err := end_view(&ui)
	testing.expect_value(t, err, Error.Unbalanced_Scope)
	testing.expect_value(t, len(ui.diags), 1)
	testing.expect_value(t, ui.diags[0].loc.line, i32(opener_line))
	testing.expect_value(t, len(ui.scopes), 0)
}

// A view that returns in the middle leaves its scopes open, and the tree
// has to survive it — not merely avoid crashing.
//
// Two things make that safe and are easy to confuse: the house style closes
// scopes with `defer`, which an early `return` runs, and end_view closes
// whatever is still open. The second is what holds when an app writes a
// plain `baldr.end(ui)` and returns before reaching it. So this pins the
// recovery rather than the diagnostic: the half-built tree is whole, and the
// build after it reconciles onto the same nodes instead of growing a second
// set.
//
// One view proc, called twice, because reconciliation keys on the call
// site: two builds written out separately are two different places and
// would make two different nodes however well the recovery worked.
@(private = "file")
give_up_view :: proc(ui: ^Ui(Test_Msg), give_up: bool, extra := false) -> (col, inner, label: Node) {
	begin_view(ui)
	col = column(ui, gap = .md)
	inner = row(ui, gap = .sm)
	label = text(ui, "half built" if give_up else "whole")
	if give_up do return // …and nothing is closed
	if extra do text(ui, "second")
	end(ui)
	end(ui)
	return
}

@(test)
a_view_that_returned_early_leaves_a_tree_the_next_build_can_use :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})

	col, inner, label := give_up_view(&ui, true)
	err := end_view(&ui)
	testing.expect_value(t, err, Error.Unbalanced_Scope)
	testing.expectf(t, len(ui.diags) == 2, "one diagnostic per scope left open, got %d", len(ui.diags))
	broken_diags := len(ui.diags)

	// The tree is whole: the nesting the view did state is intact, and it
	// lays out rather than tripping over a scope that was never closed.
	testing.expect_value(t, node_get(&ui.tree, inner).parent, col)
	testing.expect_value(t, node_get(&ui.tree, label).parent, inner)
	layout(&ui.tree, {400, 300})
	d := node_get(&ui.tree, label)
	testing.expectf(t, d.abs.w > 0 && d.abs.h > 0, "the text was laid out: %v", d.abs)

	// The next build, balanced, lands on the same nodes and says nothing
	// new. A tree left inconsistent would show up here as fresh ids, a
	// stale child, or a diagnostic nobody caused.
	col2, inner2, label2 := give_up_view(&ui, false)
	testing.expect_value(t, end_view(&ui), Error(nil))
	testing.expect_value(t, col2, col)
	testing.expect_value(t, inner2, inner)
	testing.expect_value(t, label2, label)
	testing.expectf(t, len(ui.diags) == broken_diags, "the build after a broken one adds no diagnostic, got %v", ui.diags[broken_diags:])
	testing.expect_value(t, node_get(&ui.tree, label).kind.(Text_Kind).str, "whole")

	// …and the column has one child, not two: the broken build's nodes were
	// reconciled onto, not left beside a fresh set.
	kids := 0
	for n := node_first(&ui.tree, col); n != NODE_NONE; n = node_next(&ui.tree, n) do kids += 1
	testing.expect_value(t, kids, 1)
}

// …and the sharper half: what the aborted build did *not* reach has to be
// swept, not left standing. A scope that is dropped rather than closed
// keeps every child the previous build made, and those nodes still lay out
// and still draw — a row that quietly keeps yesterday's second label.
//
// This separates end_view closing its dangling scopes from merely
// forgetting them: it fails if that close is ever replaced with a pop.
@(test)
a_view_that_returned_early_sweeps_what_it_did_not_build :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})

	// A full build with two labels in the row.
	_, inner, _ := give_up_view(&ui, false, extra = true)
	testing.expect_value(t, end_view(&ui), Error(nil))
	testing.expect_value(t, row_children(&ui, inner), 2)

	// Now one that gives up after the first label: the second is never
	// visited, and the scope it was in is never closed by the view.
	give_up_view(&ui, true)
	testing.expect_value(t, end_view(&ui), Error.Unbalanced_Scope)
	testing.expectf(t, row_children(&ui, inner) == 1,
		"the label the aborted build never reached is swept, got %d child(ren)", row_children(&ui, inner))
}

@(private = "file")
row_children :: proc(ui: ^Ui(Test_Msg), parent: Node) -> (n: int) {
	for c := node_first(&ui.tree, parent); c != NODE_NONE; c = node_next(&ui.tree, c) do n += 1
	return
}

@(test)
build_end_without_scope_is_diagnosed :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	end(&ui)
	end_view(&ui)
	testing.expect_value(t, len(ui.diags), 1)
}

// An end too many inside a view closes its outer scope early, and only the
// outer scope's own end finds nothing open. The diagnostic names where that
// outer scope was closed, which is the stray end or comes after it — not
// just the innocent end at the view's close.
@(test)
build_an_end_too_many_names_where_the_outer_scope_closed :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	row(&ui)
	row_line := #line - 1
	column(&ui)
	box(&ui, height = 20); end(&ui) // a leaf takes no end: this closes the column
	end(&ui) // meant for the column; closes the row
	closer_line := #line - 1
	text(&ui, "lands in the root")
	end(&ui) // the row's own end: nothing open
	end_view(&ui)
	testing.expect_value(t, len(ui.diags), 1)
	if len(ui.diags) != 1 do return
	msg := ui.diags[0].msg
	testing.expectf(t, strings.contains(msg, fmt.tprintf(":%d was already closed by the end at", row_line)) &&
		strings.contains(msg, fmt.tprintf(":%d,", closer_line)), "names the row's opener and the end that closed it: %s", msg)
}
} // when ODIN_TEST