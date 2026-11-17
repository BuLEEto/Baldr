package baldr

// toast: a brief message that slides up at the bottom of the window and
// goes away by itself. The app decides which toasts exist (a list in its
// state); each one sends `on_close` when its time is up, when its × is
// pressed, or when its `action` is taken (after `on_action`). The pointer
// resting on a toast keeps it. Several stack upwards. Accessibility: a
// Status announced politely (assertively for the Danger tone) with a
// "Dismiss" button.
//
//	for tst in s.toasts do baldr.toast(ui, tst.text, Msg(Toast_Done{tst.id}), action = "Undo", on_action = Msg(Undo{}), key = tst.id)

import "base:runtime"
import "core:hash"

TOAST_KEEP_MS :: 1500.0 // a hovered toast stays at least this long after the pointer leaves

toast :: proc(ui: ^Ui($Msg), text: string, on_close: Msg, action: string = "", on_action: Maybe(Msg) = nil,
	duration_ms: f32 = 5000, tone: Tone = .Neutral, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	k := key if key != 0 else toast_key(text)
	n, created := overlay_begin(ui, k, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Status
		set_live(t, n, .Assertive if tone == .Danger else .Polite)
		transition(ui, n, .Fade_Up, .Fade, th.motion.base)
		ui.toast_deadline[n] = t.now_ms + f64(max(duration_ms, 500))
		tree_wake_at(t, ui.toast_deadline[n], n)
	}
	set_name(t, n, text)
	ui.toast_close[n] = on_close
	// After overlay_begin: it may have put the popup's theme in force.
	lk := toast_look(th)
	bg, fg := tone_colors(th, tone)
	if tone == .Neutral do bg, fg = lk.fill, lk.ink
	st := d.style
	st.bg = bg
	st.radius = lk.radius
	st.border_w = lk.border_width
	st.border = lk.border
	st.shadow = lk.shadow
	set_style(t, n, st)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = lk.gap, padding = lk.padding, max_w = lk.max_width})
	t.overlay_rules[n] = {edge = .Bottom, stack = ui.toast_count, edge_margin = lk.margin, stack_gap = lk.stack_gap}
	ui.toast_count += 1
	lbl := baldr_text(ui, text, fg, lk.text, loc)
	set_role(t, lbl, .None)
	if action != "" {
		if m, has := on_action.?; has {
			button(ui, action, m, variant = .Ghost, loc = loc)
		}
	}
	x, xcreated := reconcile_child(ui, .Box, 0xC105E, loc)
	xd := node_get(t, x)
	if xcreated {
		xd.access.role = .Button
		xd.flags += {.Focusable}
	}
	set_name(t, x, "Dismiss")
	set_layout(t, x, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = lk.close_size, height = lk.close_size})
	xs := xd.style
	xs.radius = lk.close_size / 2
	set_style(t, x, xs)
	ui.clicks[x] = on_close
	open_scope(ui, x, loc)
	baldr_icon(ui, .X, lk.close_icon_size, fg, loc)
	close_scope(ui)
	end(ui)
	return n
}

@(private)
toast_key :: proc(text: string) -> u64 { return (hash.fnv64a(transmute([]byte)text) ~ 0x70A5_7000_0000_0000) | 1 }

@(private)
baldr_text :: proc(ui: ^Ui($Msg), s: string, fg: Color, tl: Text_Look, loc: runtime.Source_Code_Location) -> Node {
	return text(ui, s, role = tl.role, size = tl.size, color = fg, max_lines = 3, ellipsis = .End, weight = tl.weight, family = look_family(&ui.tree, tl.family), loc = loc)
}

// toast_tick sends on_close for toasts whose time is up; a toast under the
// pointer waits.
@(private)
toast_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	t := &ui.tree
	if len(ui.toast_deadline) == 0 do return
	hovered := NODE_NONE
	if ui.pointer.inside {
		for cur := hit_test(t, ui.pointer.pos); cur != NODE_NONE; {
			if _, is_toast := ui.toast_deadline[cur]; is_toast { hovered = cur; break }
			d := node_get(t, cur)
			if d == nil do break
			cur = d.parent
		}
	}
	done := make([dynamic]Node, context.temp_allocator)
	for n, &deadline in ui.toast_deadline {
		if n == hovered {
			if deadline < now_ms + TOAST_KEEP_MS {
				deadline = now_ms + TOAST_KEEP_MS
				tree_wake_at(t, deadline, n)
			}
			continue
		}
		if now_ms >= deadline do append(&done, n)
	}
	for n in done {
		if m, has := ui.toast_close[n]; has do append(&ui.msgs, m)
		delete_key(&ui.toast_deadline, n)
	}
}
