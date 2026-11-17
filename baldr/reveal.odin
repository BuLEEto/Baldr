package baldr

// Reveal on hover: a node shown only while the pointer is over what it
// belongs to, or focus is inside it — an album cover's Play, a tab's close,
// a row's actions. Hover does not rebuild the view, so this
// is decided as the tree paints and hit-tests: a revealed node fades in
// over the theme's fast duration, and one that is not shown is not drawn
// and cannot be hit, so a click on its place lands on what it belongs to.

// Reveal is what a revealed node belongs to, and whether its builder shows
// it anyway (the keyboard's current item).
@(private)
Reveal :: struct {
	owner: Node,
	shown: bool,
}

// reveal_within shows node `n` only while the pointer is over `owner` (or
// anything in it, `n` included) or focus is inside `owner` — or while
// `shown` says so: the item the keyboard is on, whose action should be
// in sight. Call it every build; a node built without it again is always
// shown. Its action must be reachable some other way too — the keyboard
// reaches it through focus, which reveals it — as a hidden control is
// nothing to someone who cannot hover.
reveal_within :: proc(ui: ^Ui($Msg), n: Node, owner: Node, shown := false) {
	t := &ui.tree
	if node_get(t, n) == nil do return
	r := Reveal{owner = owner, shown = shown}
	if old, had := t.reveals[n]; !had || old != r do mark_paint_dirty(t, n)
	t.reveals[n] = r
	t.reveals_built[n] = true
}

// reveals_sweep forgets the reveals a build no longer asked for.
@(private)
reveals_sweep :: proc(t: ^Tree) {
	for n in t.reveals do if !t.reveals_built[n] {
		delete_key(&t.reveals, n)
		mark_paint_dirty(t, n)
	}
	clear(&t.reveals_built)
}

// reveal_shown: whether `n`, revealed within its owner, is shown now.
@(private)
reveal_shown :: proc(t: ^Tree, n: Node, r: Reveal) -> bool {
	if r.shown do return true
	if t.hover != NODE_NONE && (node_within(t, t.hover, r.owner) || node_within(t, t.hover, n)) do return true
	if t.focus != NODE_NONE && node_within(t, t.focus, r.owner) do return true
	return false
}

// reveals_touch: hover or focus moved from `old` to `new`; the revealed
// nodes whose owners hold either paint again.
@(private)
reveals_touch :: proc(t: ^Tree, old, new: Node) {
	if len(t.reveals) == 0 do return
	for n, r in t.reveals {
		if (old != NODE_NONE && node_within(t, old, r.owner)) || (new != NODE_NONE && node_within(t, new, r.owner)) do mark_paint_dirty(t, n)
	}
}
