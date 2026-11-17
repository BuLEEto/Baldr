package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Compact controls: a small button for a tile's arrow, and controls named
// without a visible label.


@(private = "file")
CompactControls_CMsg :: union { int }

// A Small icon-only button is 26 × 26 round its 16 px icon (a regular one is
// 30), with the same role, name and focus; a Small button's label is 12 px.
@(test)
small_buttons_are_compact :: proc(t: ^testing.T) {
	ui: Ui(CompactControls_CMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	row(&ui, padding = .lg, gap = .sm, align = .Start)
	small := button(&ui, "Wi-Fi settings", CompactControls_CMsg(1), variant = .Ghost, icon = .Chevron_Right, icon_only = true, size = .Small)
	regular := button(&ui, "Bluetooth settings", CompactControls_CMsg(2), variant = .Ghost, icon = .Chevron_Right, icon_only = true)
	labelled := button(&ui, "Edit", CompactControls_CMsg(3), variant = .Ghost, size = .Small)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 200})
	sd, rd := node_get(&ui.tree, small), node_get(&ui.tree, regular)
	testing.expect_value(t, [2]f32{sd.abs.w, sd.abs.h}, [2]f32{BUTTON_SMALL, BUTTON_SMALL})
	testing.expect_value(t, [2]f32{rd.abs.w, rd.abs.h}, [2]f32{30, 30})
	testing.expect(t, sd.access.role == .Button && sd.access.name == "Wi-Fi settings" && .Focusable in sd.flags, "a focusable Button named by its label")
	icon := node_get(&ui.tree, sd.first)
	testing.expect_value(t, icon.abs.w, ICON_SIZE)
	lk, is_text := node_get(&ui.tree, node_get(&ui.tree, labelled).last).kind.(Text_Kind)
	testing.expect(t, is_text && lk.size == BUTTON_SMALL_TEXT, "a Small button's label is 12 px")
	testing.expect(t, lint(&ui.tree) == 0)
}

// A switch or a checkbox with hide_label keeps its label as its name without
// drawing it, and the name stays put from one build to the next.
@(test)
controls_keep_a_hidden_label_as_their_name :: proc(t: ^testing.T) {
	ui: Ui(CompactControls_CMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(CompactControls_CMsg)) -> (sw, shown, box: Node) {
		begin_view(ui)
		column(ui, padding = .lg, gap = .sm, align = .Start)
		sw = toggle(ui, true, "Wi-Fi", CompactControls_CMsg(1), hide_label = true)
		shown = toggle(ui, true, "Wi-Fi", CompactControls_CMsg(1))
		box = checkbox(ui, false, "Select all", CompactControls_CMsg(2), hide_label = true)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 200})
		return
	}
	sw, shown, box := build(&ui)
	has_text :: proc(tr: ^Tree, n: Node) -> bool {
		for c := node_get(tr, n).first; c != NODE_NONE; c = node_get(tr, c).next do if _, ok := node_get(tr, c).kind.(Text_Kind); ok do return true
		return false
	}
	testing.expect(t, node_get(&ui.tree, sw).access.name == "Wi-Fi" && !has_text(&ui.tree, sw), "the switch is named Wi-Fi and draws no label")
	testing.expect(t, has_text(&ui.tree, shown) && node_get(&ui.tree, sw).abs.w < node_get(&ui.tree, shown).abs.w, "one with its label shown is wider")
	testing.expect(t, node_get(&ui.tree, box).access.name == "Select all" && !has_text(&ui.tree, box), "the checkbox too")
	name_before := raw_data(node_get(&ui.tree, sw).access.name)
	build(&ui)
	testing.expect(t, raw_data(node_get(&ui.tree, sw).access.name) == name_before, "the name isn't set again on the next build")
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Switch \"Wi-Fi\"") && strings.contains(dump, "Checkbox \"Select all\""), dump)
	testing.expect(t, lint(&ui.tree) == 0)
}

} // when ODIN_TEST