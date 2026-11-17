package baldr

import "core:fmt"
import "core:strings"

// Accessibility data lives on every node from birth. Roles and actions mirror
// the AccessKit / ARIA vocabulary so each platform bridge (AT-SPI2, UI
// Automation, NSAccessibility) is a 1:1 mapping.

Role :: enum u8 {
	None, Window, Generic, Group, Region,
	Text, Heading, Label, Image,
	Button, Toggle_Button, Link, Checkbox, Radio, Radio_Group, Switch, Slider, Spin_Button,
	Text_Input, Search_Box, Combo_Box,
	List, List_Item, Table, Row, Cell, Column_Header, Tree, Tree_Item,
	Tab_List, Tab, Tab_Panel,
	Menu_Bar, Menu, Menu_Item,
	Dialog, Alert, Status, Progress, Tooltip, Separator, Scroll_Area, Toolbar,
	Terminal,
}

A11y_State :: enum u8 {
	Focusable, Focused, Disabled, Checked, Mixed, Selected, Expanded, Collapsed,
	Required, Invalid, Busy, Readonly, Pressed, Modal,
	Default, // the button Enter activates in its dialog
	Has_Popup, // opens a menu, list or picker (a menu_chip, a select, a submenu row)
}

Live :: enum u8 { Off, Polite, Assertive }

Access :: struct {
	role:                  Role,
	name:                  string,
	describe:              string,
	name_owned, desc_owned: bool,
	value, value_min, value_max: f32,
	has_value:             bool,
	value_text:            string, // text_input hook: a field's contents (bullets for password); aliases the widget's storage
	states:                bit_set[A11y_State; u16],
	live:                  Live,
	labelled_by, described_by, controls: Node,
	active:                Node, // the item a field's keys act on while it keeps focus: its active descendant (set_active_item)
}

// INTERACTIVE_ROLES must have an accessible name; the lint enforces it.
INTERACTIVE_ROLES :: bit_set[Role; u64]{
	.Button, .Toggle_Button, .Link, .Checkbox, .Radio, .Switch, .Slider, .Spin_Button,
	.Text_Input, .Search_Box, .Combo_Box, .Tab, .Menu_Item, .Row, .Column_Header, .List_Item, .Tree_Item,
}

// set_live makes `n` a live region: something a reader says out loud when
// it changes although nothing took focus — a toast, a status line, "3 of 8
// copied". Polite waits for a gap in the speech, Assertive interrupts. The
// tree keeps the set of them, so the accessibility bridge can watch a
// handful of nodes instead of the whole window.
set_live :: proc(t: ^Tree, n: Node, live: Live) {
	d := node_get(t, n)
	if d == nil do return
	d.access.live = live
	if live == .Off {
		delete_key(&t.lives, n)
	} else {
		t.lives[n] = {}
	}
}

// live marks the node just built as a live region: something a screen
// reader says out loud when it changes although nothing took focus — a
// status line, "3 of 8 copied", an error raised somewhere else on the
// screen. Polite waits for a gap in the speech, Assertive interrupts, and
// `.Off` stops it being one. Use it for what the app is *doing*; a toast
// and the busy spinner are live already.
//
//	baldr.live(ui, baldr.text(ui, s.progress), .Polite)
live :: proc(ui: ^Ui($Msg), n: Node, level: Live = .Polite, loc := #caller_location) {
	set_live(&ui.tree, n, level)
}

set_role :: proc(t: ^Tree, n: Node, role: Role) {
	if d := node_get(t, n); d != nil do d.access.role = role
}

// set_name sets the accessible name (what a screen reader announces).
// Widgets call it with their label; apps override with `label = …`.
set_name :: proc(t: ^Tree, n: Node, name: string) {
	d := node_get(t, n)
	if d == nil || d.access.name == name do return
	if d.access.name_owned do delete(d.access.name, t.allocator)
	d.access.name = strings.clone(name, t.allocator)
	d.access.name_owned = true
}

// set_active_item names `item` as the one field `n`'s keys act on while focus
// stays in the field (a launcher's search field walking its results): its
// active descendant in the accessibility tree. NODE_NONE: none.
set_active_item :: proc(t: ^Tree, n: Node, item: Node) {
	if d := node_get(t, n); d != nil do d.access.active = item
}

set_describe :: proc(t: ^Tree, n: Node, desc: string) {
	d := node_get(t, n)
	if d == nil || d.access.describe == desc do return
	if d.access.desc_owned do delete(d.access.describe, t.allocator)
	d.access.describe = strings.clone(desc, t.allocator)
	d.access.desc_owned = true
}

// popup_states marks a node that opens a popup (a menu, a list, a picker):
// Has_Popup, and Expanded while the popup is open, else Collapsed.
@(private)
popup_states :: proc "contextless" (d: ^Node_Data, open: bool) {
	d.access.states += {.Has_Popup}
	if open {
		d.access.states += {.Expanded}
		d.access.states -= {.Collapsed}
	} else {
		d.access.states += {.Collapsed}
		d.access.states -= {.Expanded}
	}
}

// lint appends a Diag for every accessibility problem the core can see
// statically: interactive nodes without a name. Hidden and inert subtrees
// are skipped.
// Returns how many problems were found.
lint :: proc(t: ^Tree) -> (found: int) {
	return lint_rec(t, t.root) + lint_rec(t, t.overlay)
}

@(private)
lint_rec :: proc(t: ^Tree, n: Node) -> (found: int) {
	d := node_get(t, n)
	if d == nil || d.flags & {.Hidden, .Inert} != {} do return
	if d.access.role in INTERACTIVE_ROLES && len(d.access.name) == 0 && d.access.labelled_by == NODE_NONE {
		diag(t, d.loc, fmt.tprintf("%v has no accessible name; pass label = \"…\" (screen readers will announce nothing)", d.access.role))
		found += 1
	}
	if has_material(d.style.material) && d.style.material.tint.a < GLASS_IN_APP_FLOOR && !popup_candidate(t, n) && !(t.glass.on && t.glass.reported) { // a glass popup's tint follows its own backdrop, and so does a measured surface's (glass_adapt)
		diag(t, d.loc, fmt.tprintf("glass tint alpha %.2f is too transparent for readable text over arbitrary content; use ≥ 0.55 (glass_in_app), or the theme's materials", d.style.material.tint.a))
		found += 1
	}
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		found += lint_rec(t, c)
	}
	return
}

// access_dump renders the accessibility tree as indented text, one node per
// line: `role "name" [states]`. Nodes with role None are transparent;
// hidden and inert subtrees are left out. The text is in the frame's temp
// memory by default: copy it if it must outlive this wake-up.
access_dump :: proc(t: ^Tree, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	dump_rec(t, t.root, 0, &b)
	dump_rec(t, t.overlay, 0, &b) // popovers / dialogs (the overlay root itself is transparent)
	return strings.to_string(b)
}

@(private)
dump_rec :: proc(t: ^Tree, n: Node, depth: int, b: ^strings.Builder) {
	d := node_get(t, n)
	if d == nil || d.flags & {.Hidden, .Inert} != {} do return
	next_depth := depth
	if d.access.role != .None {
		for _ in 0 ..< depth do strings.write_string(b, "  ")
		fmt.sbprintf(b, "%v", d.access.role)
		if len(d.access.name) > 0 do fmt.sbprintf(b, " \"%s\"", d.access.name)
		if d.access.has_value do fmt.sbprintf(b, " =%v", d.access.value)
		if len(d.access.value_text) > 0 do fmt.sbprintf(b, " =%q", d.access.value_text) // text_input hook
		if d.access.states != {} do fmt.sbprintf(b, " %v", d.access.states)
		if item := node_get(t, d.access.active); item != nil do fmt.sbprintf(b, " active=%q", item.access.name)
		strings.write_byte(b, '\n')
		next_depth += 1
	}
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		dump_rec(t, c, next_depth, b)
	}
}
