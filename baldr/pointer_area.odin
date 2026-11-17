package baldr

// Pointer area: a plain node that takes the pointer the way a picture is
// handled (the wheel, a double-click, a pointer shape of its own) without
// becoming a control.

// Pointer_Area is what a pointer area answers and remembers.
@(private)
Pointer_Area :: struct($Msg: typeid) {
	double:   Maybe(Msg),
	cursor:   Cursor,
	picture:  ^Image,  // the cursor as a picture the app drew (a brush outline), when set
	hotspot:  [2]int,  // …its pixel that is the pointer's point
	wheel:    bool,   // it gave the node its on_scroll (and takes it away again)
	press_ms: f64,    // its last press, for a double-click (0: none to pair with)
	press_at: [2]f32,
}

// pointer_area lets node `n` (a picture in a viewer) take the pointer
// without becoming a control: no role, no focus, no hover or press look.
// `on_scroll` is a wheel or touchpad scroll over it, with `Scroll.pos` where
// the pointer is over it (a zoom about the pointer); a scroll view around
// it no longer takes the wheel there. `on_double_click` is two presses on
// it in quick succession, close together (a double-tap too): fit ↔ 100 %.
// `cursor` is the pointer's shape over it and, while a press that started
// on it is held, anywhere (Grab over a picture that pans, Grabbing while
// it does, Hidden in a slideshow once the pointer has been still);
// `cursor_image` makes it a picture the app drew instead (a brush's
// outline, which moves with the pointer as a drawn outline cannot), in the
// screen's pixels (`device_scale`), with `hotspot` the pixel that is the
// pointer's point; change the picture (a new `version`) and the cursor
// follows. A pen over it takes the same cursor. A control inside it keeps
// its own presses, wheel and shape. Call it every build with what it
// answers now; all nil and `.Default` removes it. Give what it does a
// keyboard route too (a key, a button): it adds nothing to the
// accessibility tree. With `pointer_track` for where the pointer is and
// whether it is held, that is a draggable picture.
//
//	baldr.pointer_area(ui, pic, on_scroll = zoom_at, on_double_click = Msg.Fit_Or_Actual,
//		cursor = .Grabbing if s.panning else .Grab if s.pannable else .Default)
pointer_area :: proc(ui: ^Ui($Msg), n: Node, on_scroll: Handler(Msg, Scroll) = nil, on_double_click: Maybe(Msg) = nil,
	cursor: Cursor = .Default, cursor_image: ^Image = nil, hotspot: [2]int = {}) {
	if node_get(&ui.tree, n) == nil do return
	pa, was := ui.pointer_areas[n]
	wheel := handler_live(on_scroll)
	if wheel {
		use := ui.on_scroll[n] // the part of a step left over stays across builds, as a button's does
		use.handler = on_scroll
		ui.on_scroll[n] = use
	} else if was && pa.wheel {
		delete_key(&ui.on_scroll, n)
	}
	_, double := on_double_click.?
	if !wheel && !double && cursor == .Default && cursor_image == nil {
		if was do delete_key(&ui.pointer_areas, n)
		if ui.pointer.area_held == n do ui.pointer.area_held = NODE_NONE
		return
	}
	pa.double, pa.cursor, pa.wheel = on_double_click, cursor, wheel
	pa.picture, pa.hotspot = cursor_image, hotspot
	if cursor_image != nil do pa.cursor = .Picture
	ui.pointer_areas[n] = pa
}

// pointer_area_press is a left press at `pos`: the innermost pointer area
// under it, unless a control inside that area took the press, is held, and
// its second press close in time and place is a double-click.
@(private)
pointer_area_press :: proc(ui: ^Ui($Msg), pos: [2]f32) {
	if len(ui.pointer_areas) == 0 do return
	t := &ui.tree
	for cur := hit_test(t, pos); cur != NODE_NONE; cur = node_parent(t, cur) {
		if cur == ui.pointer.hover do return // a control inside it: the press is the control's
		pa, is := &ui.pointer_areas[cur]
		if !is do continue
		if .Disabled in node_get(t, cur).flags do return
		ui.pointer.area_held = cur
		now := ui.pointer.time_ms // the press's own time, never the frame clock (events.odin)
		m, answers := pa.double.?
		if answers && pa.press_ms > 0 && now >= pa.press_ms && now - pa.press_ms <= MULTI_CLICK_MS &&
			abs(pos.x - pa.press_at.x) <= MULTI_CLICK_PX && abs(pos.y - pa.press_at.y) <= MULTI_CLICK_PX {
			append(&ui.msgs, m)
			pa.press_ms = 0 // a third press starts a new pair
			return
		}
		pa.press_ms, pa.press_at = now, pos
		return
	}
}

// pointer_area_cursor is the shape a pointer area asks for where the
// pointer is: the held one's, else the innermost one's under the pointer
// that no control inside it covers. False: none has a say.
@(private)
pointer_area_cursor :: proc(ui: ^Ui($Msg)) -> (Cursor, bool) {
	n := pointer_area_shaping(ui)
	if n == NODE_NONE do return .Default, false
	return ui.pointer_areas[n].cursor, true
}

// pointer_area_shaping is the pointer area whose cursor the pointer has:
// the held one's, else the innermost one's under the pointer that no
// control inside it covers.
@(private)
pointer_area_shaping :: proc(ui: ^Ui($Msg)) -> Node {
	if len(ui.pointer_areas) == 0 do return NODE_NONE
	if pa, held := ui.pointer_areas[ui.pointer.area_held]; held && pa.cursor != .Default do return ui.pointer.area_held
	t := &ui.tree
	for cur := hit_test(t, ui.pointer.pos); cur != NODE_NONE; cur = node_parent(t, cur) {
		if cur == ui.pointer.hover do break // a control's own shape
		if pa, is := ui.pointer_areas[cur]; is && pa.cursor != .Default do return cur
	}
	return NODE_NONE
}

// pointer_area_picture is the picture the pointer is now, and its hotspot,
// when an area's cursor is one.
pointer_area_picture :: proc(ui: ^Ui($Msg)) -> (^Image, [2]int, bool) {
	n := pointer_area_shaping(ui)
	if n == NODE_NONE do return nil, {}, false
	pa := ui.pointer_areas[n]
	if pa.cursor != .Picture || pa.picture == nil || pa.picture.pixels == nil do return nil, {}, false
	return pa.picture, pa.hotspot, true
}
