package baldr

// Applet surfaces: a Baldr app shown inside a desktop shell's bar, at a
// slot the shell reserved (the rikkiti-applet-v1 protocol). The shell
// starts the app with the slot's token, and `kind = .Applet` binds it. The
// compositor sizes the surface to the slot and says which screen edge the
// bar is on (ui.surface.edge: a clock stacks its lines in a side bar). It
// sits on the bar's glass, so nothing is drawn behind it, and its text
// follows what the compositor measures there; its popups open away from the
// edge; and it tells the shell the length along the bar its content wants,
// again whenever that changes. Closed by the compositor (its slot went, or
// its token was spent), it sends `on_close`, or ends the app when there is
// none, and is not opened again with that token. Without a shell to embed
// it (no token, or a compositor without applets) it opens as a small window.
//
//	surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
//		append(out, baldr.Surface_Desc(Msg){kind = .Applet, title = "Clock", size = {160, 40}})
//	}

import "core:os"

// APPLET_WINDOW_SIZE is the window an applet opens as, with no shell to
// embed it and no size of its own.
APPLET_WINDOW_SIZE :: [2]f32{240, 48}

// applet_size_hint measures the length along its bar an applet's content
// wants at the slot's thickness: the least it can take without breaking a
// word, and its natural length (in a side bar both are its height at the
// bar's width). It leaves the tree to be laid out again at the slot's size.
applet_size_hint :: proc(t: ^Tree, edge: Edge, slot: [2]f32) -> (least, preferred: f32) {
	if edge == .Top || edge == .Bottom do return content_length(t, true, slot.y)
	return content_length(t, false, slot.x)
}

// content_length measures the length a tree's content wants along one axis
// at `thickness` across: the least it can take without breaking a word
// (along x; along y, its natural height) and its natural length, a `flex`
// child counting at its natural size. An applet's size hint and a FIT layer
// surface (fit_sync) both come from it. It leaves the tree to be laid out
// again.
@(private)
content_length :: proc(t: ^Tree, along_x: bool, thickness: f32) -> (least, natural: f32) {
	root := t.root
	if along_x {
		size := layout_node(t, root, {min = {0, thickness}, max = {UNBOUNDED, thickness}})
		natural = size.x
		least = min(min_content_width(t, root), natural)
	} else {
		size := layout_node(t, root, {min = {thickness, 0}, max = {thickness, UNBOUNDED}})
		natural, least = size.y, size.y
	}
	layout_dirty(t, root) // laid out again at the surface's size next; only what that moves repaints
	return
}

// applet_token is the token an applet binds with: its declared one, else
// the one its shell started it with.
@(private)
applet_token :: proc(desc: Surface_Desc($Msg)) -> string {
	return desc.applet.token if desc.applet.token != "" else os.get_env("RIKKITI_APPLET_TOKEN", context.temp_allocator)
}
