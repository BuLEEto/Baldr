package baldr

// A key held and let go: an image editor's temporary tools —
// Space held for the hand, Alt held to sample, Shift held for a straight
// line — which need the key's release as much as its press. `shortcut`
// fires on the press alone; `key_capture` takes every key. This takes only
// the keys asked for, and only those the focused control does not use (a
// text field keeps its Space).

// Key_Hold is a key going down or coming up over a node that hears it.
Key_Hold :: struct {
	key:  Key,
	down: bool,
}

// Key_Hold_Area is a node that hears keys held, and which of them are.
@(private)
Key_Hold_Area :: struct($Msg: typeid) {
	keys:    [dynamic]Key,
	held:    [dynamic]Key,
	handler: Handler(Msg, Key_Hold),
}

// key_hold makes node `n` hear `keys` going down and coming up, through
// `on_change`: down once however long the key is held (no repeats), and up
// when it is let go — wherever the focus has gone meanwhile, and when the
// window loses the keyboard. A key goes to it while the focus is inside
// `n` (or nowhere) and the focused control did not use the key itself.
// Either side of a modifier matches the other (.Alt_L also hears .Alt_R).
// Call it every build; nil stops it (and lets go of what it held).
//
//	baldr.key_hold(ui, editor, {.Space, .Alt_L, .Shift_L}, proc(e: baldr.Ev(baldr.Key_Hold)) -> Msg { return Tool_Key{e.value} })
key_hold :: proc(ui: ^Ui($Msg), n: Node, keys: []Key, on_change: Handler(Msg, Key_Hold)) {
	if node_get(&ui.tree, n) == nil do return
	a, has := &ui.key_holds[n]
	if !handler_live(on_change) {
		if has do key_holds_forget(ui, n)
		return
	}
	if !has {
		ui.key_holds[n] = Key_Hold_Area(Msg){keys = make([dynamic]Key, ui.allocator), held = make([dynamic]Key, ui.allocator)}
		a = &ui.key_holds[n]
	}
	clear(&a.keys)
	append(&a.keys, ..keys)
	a.handler = on_change
}

// key_side_less is a key with a modifier's side taken off.
@(private)
key_side_less :: proc(k: Key) -> Key {
	#partial switch k {
	case .Shift_R: return .Shift_L
	case .Ctrl_R:  return .Ctrl_L
	case .Alt_R:   return .Alt_L
	case .Super_R: return .Super_L
	}
	return k
}

// key_hold_event offers a key to the nodes that hear it held: a press once
// the focused control has declined it, a release always. True when one
// took it (a repeat of a held key is taken too, and says nothing new).
@(private)
key_hold_event :: proc(ui: ^Ui($Msg), key: Key, pressed: bool, mods: Mods = {}) -> (taken: bool) {
	if len(ui.key_holds) == 0 do return false
	t := &ui.tree
	k := key_side_less(key)
	for n, &a in ui.key_holds {
		held_at := -1
		for h, i in a.held do if key_side_less(h) == k do held_at = i
		if !pressed {
			if held_at < 0 do continue
			ordered_remove(&a.held, held_at)
			handler_send(ui, a.handler, Key_Hold{key = key, down = false}, n)
			taken = true
			continue
		}
		if held_at >= 0 { // a repeat: still down
			taken = true
			continue
		}
		// A chord is the window's, not a held key's: Z held is a zoom, Ctrl+Z
		// is undo. So a press with Ctrl, Alt or Super down passes on, unless
		// the key is one of those (holding Alt is how an eyedropper is asked
		// for). Shift+key is a key in its own right, so Shift does not count.
		// A key already held stays held whatever comes after it (the
		// `held_at` case above).
		if mods & {.Ctrl, .Alt, .Super} != {} && !key_is_modifier(key) do continue
		wants := false
		for w in a.keys do if key_side_less(w) == k do wants = true
		if !wants || (t.focus != NODE_NONE && !node_within(t, t.focus, n)) do continue
		append(&a.held, key)
		handler_send(ui, a.handler, Key_Hold{key = key, down = true}, n)
		taken = true
	}
	return
}

// key_holds_release lets go of every key held: the window lost the
// keyboard, and no release will come.
@(private)
key_holds_release :: proc(ui: ^Ui($Msg)) {
	for n, &a in ui.key_holds {
		for h in a.held do handler_send(ui, a.handler, Key_Hold{key = h, down = false}, n)
		clear(&a.held)
	}
}

@(private)
key_holds_forget :: proc(ui: ^Ui($Msg), n: Node) {
	a, has := &ui.key_holds[n]
	if !has do return
	for h in a.held do handler_send(ui, a.handler, Key_Hold{key = h, down = false}, n) // a tool held when it went is let go
	delete(a.keys)
	delete(a.held)
	delete_key(&ui.key_holds, n)
}
