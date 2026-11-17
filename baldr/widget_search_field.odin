package baldr

// search_field: the box at the top of a sidebar — a magnifier, a
// placeholder, and a clear cross once there is something to clear.
//
// It is a `text_input` inside its own frame, so selection, input methods,
// the clipboard, the context menu and the caret are the one machinery
// every field uses. What is its own is the behaviour: Escape clears it
// (and only goes on to close what is around it once it is empty), the
// cross appears with the text and does not take the keyboard away from
// the field, and it reads as a Search_Box.


SEARCH_ICON_SIZE :: f32(15)
SEARCH_CLEAR_SIZE :: f32(18)

@(private)
SEARCH_PART_FIELD :: u64(1)
@(private)
SEARCH_PART_ICON :: u64(2)
@(private)
SEARCH_PART_CLEAR :: u64(3)

// search_field is a search box over the app's own `Text` buffer.
//
// `on_change` fires on every keystroke (debounce it in the app if the
// search is expensive: the toolkit cannot know what a query costs) and
// `on_submit` on Enter, for a search that should
// run at once. `on_cancel` is sent when Escape is pressed on a field that
// is already empty, so a sidebar can close its search bar; Escape on a
// field with text clears it and sends `on_change`. The cross clears the
// field, sends `on_change` and leaves the keyboard in the field.
//
// Accessibility: role Search_Box named by `label` (else the placeholder);
// the magnifier is decoration and the cross is a Button named "Clear
// search", the Tab stop after the field.
search_field :: proc(
	ui: ^Ui($Msg),
	value: ^Text,
	placeholder := "Search",
	on_change: Handler(Msg, string) = nil,
	on_submit: Handler(Msg, string) = nil,
	on_cancel: Maybe(Msg) = nil,
	label := "",
	width: f32 = 0,
	flex: f32 = 0,
	disabled := false,
	focus := false,
	tag: u64 = 0,
	key: u64 = 0,
	loc := #caller_location,
) -> Node {
	t := &ui.tree
	th := &t.theme
	lk := field_look(th)
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created do d.access.role = .None // the field inside carries the role
	set_layout(t, n, Layout_Props{
		axis = .Row, align = .Center, gap = lk.search.gap,
		width = width, flex = flex, min_w = TEXT_INPUT_MIN_WIDTH if width == 0 && flex == 0 else 0,
		padding = {0, lk.inset, 0, lk.inset}, // no vertical padding: the field inside carries the height
	})
	// The frame is the row's, so the magnifier and the cross sit inside it
	// and the whole thing reads as one control rather than three.
	st := d.style
	st.bg = lk.fill
	st.radius = lk.radius
	st.border_w = lk.border_width
	st.border = lk.border
	set_style(t, n, st)

	open_scope(ui, n, loc)
	defer close_scope(ui)

	ic := lk.icon
	if disabled do ic.a *= th.state.disabled_alpha
	baldr_icon(ui, .Search, lk.search.icon_size, ic, loc, key = SEARCH_PART_ICON)

	f := text_input(ui, value, placeholder = placeholder, on_change = on_change, on_submit = on_submit,
		on_cancel = on_cancel, label = label, flex = 1, disabled = disabled, quiet = true,
		focus = focus, tag = tag, key = SEARCH_PART_FIELD, loc = loc)
	set_role(t, f, .Search_Box)
	if s := &t.inputs[f]; s != nil do s.search = true // Escape clears it first

	// The frame follows the field's focus, as the field's own border would
	// have: the person is typing into this box, whichever part has the node.
	if .Focused in node_get(t, f).flags && !disabled {
		st.border = lk.focus_border
		st.border_w = lk.focus_border_width
		set_style(t, n, st)
	}

	// The cross only exists while there is something to clear: an
	// always-present one invites a click that does nothing.
	if value != nil && len(str(value^)) > 0 && !disabled {
		c, c_made := reconcile_child(ui, .Box, SEARCH_PART_CLEAR, loc)
		cd := node_get(t, c)
		if c_made {
			cd.access.role = .Button
			cd.flags += {.Focusable}
		}
		set_name(t, c, "Clear search")
		set_layout(t, c, Layout_Props{axis = .Row, align = .Center, justify = .Center,
			width = lk.search.clear_size, height = lk.search.clear_size})
		cs := cd.style
		cs.radius = lk.search.clear_size / 2 // a circle at any size
		set_style(t, c, cs)
		ui.search_clears[c] = Search_Clear_Ref(Msg){field = f, on_change = on_change}
		open_scope(ui, c, loc)
		x := text(ui, "×", size = lk.search.clear_text_size, color = lk.icon, nowrap = true, loc = loc)
		set_role(t, x, .None)
		close_scope(ui)
	}
	return n
}

// Search_Clear_Ref is what a cross knows: the field it empties, and the
// handler to tell afterwards.
Search_Clear_Ref :: struct($Msg: typeid) {
	field:     Node,
	on_change: Handler(Msg, string),
}

// search_clear_click empties the field and leaves the keyboard in it, so
// the next query can be typed without reaching for the pointer again.
@(private)
search_clear_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	ref, is_clear := ui.search_clears[n]
	if !is_clear do return false
	t := &ui.tree
	d := node_get(t, ref.field)
	s := &t.inputs[ref.field]
	if d == nil || s == nil do return false
	if len(input_src(s)) > 0 {
		input_replace(ui, ref.field, d, s, 0, len(input_src(s)), "")
		input_fire(ui, ref.field, ref.on_change, "")
	}
	set_focus(t, ref.field, false)
	return true
}

// search_text is the field's contents, for an app that would rather read
// the widget than keep its own copy. It aliases the `Text` the app passed
// in, so it lives as long as that does.
search_text :: proc(ui: ^Ui($Msg), n: Node) -> string {
	t := &ui.tree
	for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
		if s := &t.inputs[c]; s != nil do return input_src(s)
	}
	return ""
}

