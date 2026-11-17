// x11_check — does the libxcb binding actually talk to an X server?
//
// The first thing to get wrong in a new backend is a struct layout: X is a
// fixed-layout wire protocol, so `Setup` and `Screen` either match or the
// numbers are nonsense. This connects, walks the screens and prints them,
// which is a check anyone can read — a screen 2560x1440 is right, a screen
// 51200x0 is a layout that slipped.
//
//   ./build.sh spike x11_check run
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import x11 "baldr:platform/x11"

main :: proc() {
	ok, missing := x11.load()
	if !ok {
		fmt.eprintfln("libxcb did not load: %v", missing)
		os.exit(1)
	}
	fmt.println("libxcb loaded")

	screen_num: c.int
	conn := x11.api.connect(nil, &screen_num)
	if conn == nil || x11.api.connection_has_error(conn) != 0 {
		fmt.eprintfln("no X connection (DISPLAY=%s)", os.get_env("DISPLAY", context.temp_allocator))
		os.exit(1)
	}
	defer x11.api.disconnect(conn)
	fmt.printfln("connected to %s, fd %d, default screen %d",
		os.get_env("DISPLAY", context.temp_allocator), x11.api.get_file_descriptor(conn), screen_num)

	// `--close <window-id>` sends WM_DELETE_WINDOW to somebody else's
	// window, which is how a close button reaches an X client — for a
	// machine with no xdotool and no compositor verb that does it.
	if len(os.args) >= 3 && os.args[1] == "--close" {
		id, idok := strconv.parse_uint(os.args[2])
		if !idok {
			fmt.eprintfln("not a window id: %s", os.args[2])
			os.exit(2)
		}
		close_window(conn, x11.Window(u32(id)))
		return
	}

	// `--resize <window-id> <w> <h>` asks for another client's window to be
	// resized. On a window the window manager owns this becomes a
	// ConfigureRequest that it may or may not honour, which is X: the app
	// finds out from the ConfigureNotify either way.
	if len(os.args) >= 5 && os.args[1] == "--resize" {
		id, idok := strconv.parse_uint(os.args[2])
		w, wok := strconv.parse_uint(os.args[3])
		h, hok := strconv.parse_uint(os.args[4])
		if !idok || !wok || !hok {
			fmt.eprintln("usage: x11_check --resize <window-id> <w> <h>")
			os.exit(2)
		}
		wh := [2]u32{u32(w), u32(h)}
		x11.api.configure_window(conn, x11.Window(u32(id)),
			x11.CONFIG_WINDOW_WIDTH | x11.CONFIG_WINDOW_HEIGHT, raw_data(wh[:]))
		x11.api.flush(conn)
		fmt.printfln("asked window %d for %dx%d", u32(id), w, h)
		return
	}

	// `--maximize <window-id>` asks the window manager to maximise somebody
	// else's window, the EWMH way: a _NET_WM_STATE message to the root. A
	// window manager honours this where it ignores a bare resize request,
	// which makes it the way to drive a real resize of a running app.
	if len(os.args) >= 3 && os.args[1] == "--maximize" {
		id, idok := strconv.parse_uint(os.args[2])
		if !idok {
			fmt.eprintfln("not a window id: %s", os.args[2])
			os.exit(2)
		}
		maximize(conn, x11.Window(u32(id)), screen_num)
		return
	}

	// `--fullscreen <window-id>` toggles _NET_WM_STATE_FULLSCREEN, the same
	// message the backend sends, so a running app can be driven into and out
	// of full screen without anyone pressing a key.
	if len(os.args) >= 3 && os.args[1] == "--fullscreen" {
		id, idok := strconv.parse_uint(os.args[2])
		if !idok do os.exit(2)
		wm_state(conn, x11.Window(u32(id)), screen_num, "_NET_WM_STATE_FULLSCREEN", 2) // 2 = toggle
		return
	}

	// `--drag <window-id> <text>` performs a whole XDND source sequence
	// against somebody else's window: an independent implementation to test
	// the backend's target half against.
	if len(os.args) >= 6 && os.args[1] == "--drag" {
		id, idok := strconv.parse_uint(os.args[2])
		px, xok := strconv.parse_int(os.args[3])
		py, yok := strconv.parse_int(os.args[4])
		if !idok || !xok || !yok {
			fmt.eprintln("usage: x11_check --drag <window-id> <root-x> <root-y> <mime> [text]")
			os.exit(2)
		}
		mime := os.args[5]
		text := os.args[6] if len(os.args) > 6 else "dragged from x11_check"
		drag_to(conn, x11.Window(u32(id)), px, py, mime, text, screen_num)
		return
	}

	// `--warp <x> <y>` moves the pointer, for a machine without xdotool.
	if len(os.args) >= 4 && os.args[1] == "--warp" {
		px, xok := strconv.parse_int(os.args[2])
		py, yok := strconv.parse_int(os.args[3])
		if !xok || !yok do os.exit(2)
		setup := x11.api.get_setup(conn)
		it := x11.api.setup_roots_iterator(setup)
		for _ in 0 ..< int(screen_num) do x11.api.screen_next(&it)
		x11.api.warp_pointer(conn, x11.WINDOW_NONE, it.data.root, 0, 0, 0, 0, i16(px), i16(py))
		x11.api.flush(conn)
		fmt.printfln("pointer warped to %d,%d", px, py)
		return
	}

	setup := x11.api.get_setup(conn)
	fmt.printfln("X%d.%d, vendor release %d, %d screen(s), keycodes %d..%d",
		setup.protocol_major_version, setup.protocol_minor_version, setup.release_number,
		setup.roots_len, setup.min_keycode, setup.max_keycode)

	it := x11.api.setup_roots_iterator(setup)
	for i := 0; it.rem > 0; i += 1 {
		s := it.data
		fmt.printfln("  screen %d: %dx%d px, %dx%d mm, depth %d, root %d, visual %d",
			i, s.width_in_pixels, s.height_in_pixels, s.width_in_millimeters, s.height_in_millimeters,
			s.root_depth, u32(s.root), u32(s.root_visual))
		x11.api.screen_next(&it)
	}

	// An atom round-trip exercises a request and its reply, which is the
	// other half of the binding.
	name :: "WM_DELETE_WINDOW"
	cookie := x11.api.intern_atom(conn, 0, u16(len(name)), name)
	err: ^x11.Generic_Error
	reply := x11.api.intern_atom_reply(conn, cookie, &err)
	if reply != nil {
		fmt.printfln("atom %s = %d", name, u32(reply.atom))
		x11.free_reply(reply)
	} else {
		fmt.eprintfln("intern_atom failed")
		os.exit(1)
	}

	it2 := x11.api.setup_roots_iterator(setup)
	for _ in 0 ..< int(screen_num) do x11.api.screen_next(&it2)
	open_window(conn, it2.data)
}

// ---------------------------------------------------------------- a window

// open_window maps a window with the properties a window manager reads, and
// runs an event loop that ends when the close button is pressed. No Vulkan,
// so a failure here is a failure in the X half.
open_window :: proc(conn: x11.Connection, screen: ^x11.Screen) {
	wid := x11.Window(x11.api.generate_id(conn))

	// The event mask is the whole of what the server will tell us about.
	values := [2]u32{
		screen.black_pixel,
		x11.EVENT_MASK_EXPOSURE | x11.EVENT_MASK_STRUCTURE_NOTIFY |
		x11.EVENT_MASK_KEY_PRESS | x11.EVENT_MASK_BUTTON_PRESS |
		x11.EVENT_MASK_POINTER_MOTION | x11.EVENT_MASK_FOCUS_CHANGE,
	}
	x11.api.create_window(conn, x11.COPY_FROM_PARENT, wid, screen.root,
		0, 0, 640, 400, 0, x11.WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual,
		x11.CW_BACK_PIXEL | x11.CW_EVENT_MASK, raw_data(values[:]))

	title := "Baldr X11 check" // a variable, not a constant: raw_data needs a typed string
	x11.api.change_property(conn, x11.PROP_MODE_REPLACE, wid, x11.ATOM_WM_NAME, x11.ATOM_STRING,
		8, u32(len(title)), raw_data(title))
	if utf8 := atom(conn, "UTF8_STRING"); utf8 != x11.ATOM_NONE {
		if net_name := atom(conn, "_NET_WM_NAME"); net_name != x11.ATOM_NONE {
			x11.api.change_property(conn, x11.PROP_MODE_REPLACE, wid, net_name, utf8, 8, u32(len(title)), raw_data(title))
		}
	}
	class := "x11_check\x00Baldr\x00" // WM_CLASS is instance then class, NUL-separated
	x11.api.change_property(conn, x11.PROP_MODE_REPLACE, wid, x11.Atom(67), x11.ATOM_STRING, 8, u32(len(class)), raw_data(class))

	// WM_DELETE_WINDOW: without this the close button kills the connection
	// instead of telling the app, which is the X equivalent of pulling the
	// plug.
	wm_protocols := atom(conn, "WM_PROTOCOLS")
	wm_delete := atom(conn, "WM_DELETE_WINDOW")
	if wm_protocols != x11.ATOM_NONE && wm_delete != x11.ATOM_NONE {
		d := wm_delete
		x11.api.change_property(conn, x11.PROP_MODE_REPLACE, wid, wm_protocols, x11.ATOM_ATOM, 32, 1, &d)
	}

	x11.api.map_window(conn, wid)
	x11.api.flush(conn)
	fmt.printfln("window %d mapped, 640x400 - close it to end", u32(wid))

	// BALDR_X11_SECONDS ends it without anyone clicking, for a scripted run.
	deadline := time.tick_now()
	limit := 0
	if v := os.get_env("BALDR_X11_SECONDS", context.temp_allocator); v != "" {
		limit, _ = strconv.parse_int(v)
	}

	size := [2]u16{640, 400}
	resized := false
	for {
		// Three seconds in, ask for a different size: that exercises
		// configure_window and the ConfigureNotify that answers it, with no
		// one to drag an edge.
		if !resized && time.duration_seconds(time.tick_since(deadline)) > 3 {
			resized = true
			wh := [2]u32{900, 560}
			x11.api.configure_window(conn, wid, x11.CONFIG_WINDOW_WIDTH | x11.CONFIG_WINDOW_HEIGHT, raw_data(wh[:]))
			x11.api.flush(conn)
			fmt.println("asked the server for 900x560")
		}
		if limit > 0 && time.duration_seconds(time.tick_since(deadline)) > f64(limit) {
			fmt.println("time is up; closing")
			x11.api.destroy_window(conn, wid)
			x11.api.flush(conn)
			return
		}
		// poll rather than wait, so the deadline is checked; a real backend
		// waits on the descriptor with a timeout instead of spinning.
		ev := x11.api.poll_for_event(conn)
		if ev == nil {
			if x11.api.connection_has_error(conn) != 0 do break
			time.sleep(5 * time.Millisecond)
			continue
		}
		kind := ev.response_type & 0x7f // the top bit means another client sent it
		switch kind {
		case x11.EXPOSE:
			e := (^x11.Expose_Event)(ev)
			if e.count == 0 do fmt.printfln("expose %dx%d at %d,%d", e.width, e.height, e.x, e.y)
		case x11.CONFIGURE_NOTIFY:
			e := (^x11.Configure_Notify_Event)(ev)
			// Named, not written inline in the condition: Odin reads the `{`
			// of a composite literal there as the if's own block.
			now := [2]u16{e.width, e.height}
			if now != size {
				size = now
				fmt.printfln("resized to %dx%d at %d,%d", e.width, e.height, e.x, e.y)
			}
		case x11.MAP_NOTIFY:
			fmt.println("mapped")
		case x11.CLIENT_MESSAGE:
			e := (^x11.Client_Message_Event)(ev)
			if x11.Atom(e.data.data32[0]) == wm_delete {
				fmt.println("close asked for (WM_DELETE_WINDOW)")
				x11.free_reply(ev)
				x11.api.destroy_window(conn, wid)
				x11.api.flush(conn)
				return
			}
		case 2: // KeyPress — reported, not acted on: the key that started
			// this program arrives here the moment the window takes focus.
			fmt.println("a key was pressed")
		}
		x11.free_reply(ev)
	}
}

// atom interns a name, or ATOM_NONE when the server will not.
atom :: proc(conn: x11.Connection, name: string) -> x11.Atom {
	cookie := x11.api.intern_atom(conn, 0, u16(len(name)), cstring(raw_data(name)))
	err: ^x11.Generic_Error
	reply := x11.api.intern_atom_reply(conn, cookie, &err)
	if reply == nil do return x11.ATOM_NONE
	defer x11.free_reply(reply)
	return reply.atom
}

// close_window asks `target` to close, the way a title bar's button does: a
// WM_PROTOCOLS client message carrying WM_DELETE_WINDOW. A well-behaved
// client hears it and decides; one that ignores it stays open, which is the
// whole point of the protocol.
close_window :: proc(conn: x11.Connection, target: x11.Window) {
	wm_protocols := atom(conn, "WM_PROTOCOLS")
	wm_delete := atom(conn, "WM_DELETE_WINDOW")
	if wm_protocols == x11.ATOM_NONE || wm_delete == x11.ATOM_NONE {
		fmt.eprintln("the server would not intern the atoms")
		os.exit(1)
	}
	ev := x11.Client_Message_Event{
		response_type = x11.CLIENT_MESSAGE,
		format        = 32,
		window        = target,
		type          = wm_protocols,
	}
	ev.data.data32[0] = u32(wm_delete)
	ev.data.data32[1] = 0 // CurrentTime
	x11.api.send_event(conn, 0, target, 0, &ev)
	x11.api.flush(conn)
	fmt.printfln("asked window %d to close", u32(target))
}

// maximize sends the _NET_WM_STATE message a window manager listens for.
// It goes to the *root* window, not the target: the window manager is what
// acts on it, and SubstructureRedirect is how it is told to.
maximize :: proc(conn: x11.Connection, target: x11.Window, screen_num: c.int) {
	state := atom(conn, "_NET_WM_STATE")
	horz := atom(conn, "_NET_WM_STATE_MAXIMIZED_HORZ")
	vert := atom(conn, "_NET_WM_STATE_MAXIMIZED_VERT")
	if state == x11.ATOM_NONE || horz == x11.ATOM_NONE || vert == x11.ATOM_NONE {
		fmt.eprintln("this window manager does not advertise _NET_WM_STATE")
		os.exit(1)
	}
	setup := x11.api.get_setup(conn)
	it := x11.api.setup_roots_iterator(setup)
	for _ in 0 ..< int(screen_num) do x11.api.screen_next(&it)
	root := it.data.root

	ev := x11.Client_Message_Event{
		response_type = x11.CLIENT_MESSAGE,
		format        = 32,
		window        = target,
		type          = state,
	}
	ev.data.data32[0] = x11.NET_WM_STATE_ADD
	ev.data.data32[1] = u32(horz)
	ev.data.data32[2] = u32(vert)
	ev.data.data32[3] = 1 // the request comes from an application
	x11.api.send_event(conn, 0, root,
		x11.EVENT_MASK_SUBSTRUCTURE_NOTIFY | x11.EVENT_MASK_SUBSTRUCTURE_REDIRECT, &ev)
	x11.api.flush(conn)
	fmt.printfln("asked the window manager to maximise window %d", u32(target))
}

// wm_state sends one _NET_WM_STATE change for a single property.
wm_state :: proc(conn: x11.Connection, target: x11.Window, screen_num: c.int, name: string, action: u32) {
	state := atom(conn, "_NET_WM_STATE")
	which := atom(conn, name)
	if state == x11.ATOM_NONE || which == x11.ATOM_NONE {
		fmt.eprintfln("the window manager does not advertise %s", name)
		os.exit(1)
	}
	setup := x11.api.get_setup(conn)
	it := x11.api.setup_roots_iterator(setup)
	for _ in 0 ..< int(screen_num) do x11.api.screen_next(&it)
	ev := x11.Client_Message_Event{
		response_type = x11.CLIENT_MESSAGE, format = 32, window = target, type = state,
	}
	ev.data.data32[0] = action
	ev.data.data32[1] = u32(which)
	ev.data.data32[3] = 1
	x11.api.send_event(conn, 0, it.data.root,
		x11.EVENT_MASK_SUBSTRUCTURE_NOTIFY | x11.EVENT_MASK_SUBSTRUCTURE_REDIRECT, &ev)
	x11.api.flush(conn)
	fmt.printfln("asked the window manager for %s on window %d", name, u32(target))
}

// drag_to is the XDND source side, start to finish. Every step waits for
// the reply the protocol says comes back, so a target that skips one shows
// up here as a timeout rather than as a drag that silently does nothing.
drag_to :: proc(conn: x11.Connection, target: x11.Window, px, py: int, mime_name, text: string, screen_num: c.int) {
	setup := x11.api.get_setup(conn)
	it := x11.api.setup_roots_iterator(setup)
	for _ in 0 ..< int(screen_num) do x11.api.screen_next(&it)
	screen := it.data

	// A window of our own: XDND names the source window in every message,
	// and the data comes through a selection it has to own.
	src := x11.Window(x11.api.generate_id(conn))
	vals := [1]u32{x11.EVENT_MASK_PROPERTY_CHANGE}
	x11.api.create_window(conn, 0, src, screen.root, 0, 0, 1, 1, 0,
		x11.WINDOW_CLASS_INPUT_ONLY, x11.Visual_Id(0), x11.CW_EVENT_MASK, raw_data(vals[:]))

	enter    := atom(conn, "XdndEnter")
	position := atom(conn, "XdndPosition")
	status   := atom(conn, "XdndStatus")
	drop     := atom(conn, "XdndDrop")
	finished := atom(conn, "XdndFinished")
	selection := atom(conn, "XdndSelection")
	copy_act := atom(conn, "XdndActionCopy")
	// The type is an atom whose *name* is the MIME string: text/uri-list is
	// how files travel, and a toolkit asking for "files" wants that one.
	mime := atom(conn, mime_name)

	// The target asks for the data through this selection.
	x11.api.set_selection_owner(conn, src, selection, x11.CURRENT_TIME)
	x11.api.flush(conn)

	send :: proc(conn: x11.Connection, to: x11.Window, type: x11.Atom, d: [5]u32) {
		ev := x11.Client_Message_Event{
			response_type = x11.CLIENT_MESSAGE, format = 32, window = to, type = type,
		}
		ev.data.data32 = d
		x11.api.send_event(conn, 0, to, 0, &ev)
		x11.api.flush(conn)
	}

	VERSION :: 5
	send(conn, target, enter, {u32(src), VERSION << 24, u32(mime), 0, 0})
	fmt.println("sent XdndEnter")

	// Root coordinates: the target maps them into its own window itself,
	// the half of XdndPosition most easily got wrong.
	//
	// Sent several times, as a real source does on every pointer move: the
	// target answers each Position with what the app last decided, and the
	// app decides only after it has seen the motion and laid out a frame, so
	// a single Position tests that race rather than the drop.
	accepted := false
	for i in 0 ..< 12 {
		send(conn, target, position, {u32(src), 0, (u32(px) << 16) | u32(py), 0, u32(copy_act)})
		if ok := wait_for(conn, status, &accepted); !ok {
			fmt.eprintln("no XdndStatus came back - the target is not answering, which wedges a real drag")
			os.exit(1)
		}
		if accepted do break
		time.sleep(40 * time.Millisecond)
	}
	fmt.printfln("XdndStatus at root %d,%d: accept=%v", px, py, accepted)

	send(conn, target, drop, {u32(src), 0, u32(x11.CURRENT_TIME), 0, 0})
	fmt.println("sent XdndDrop")

	// From here the target converts the selection; answer it, then wait to
	// be told it is finished.
	deadline := time.tick_now()
	for time.duration_seconds(time.tick_since(deadline)) < 5 {
		ev := x11.api.poll_for_event(conn)
		if ev == nil { time.sleep(2 * time.Millisecond); continue }
		kind := ev.response_type & 0x7f
		if kind == 30 { // SelectionRequest
			e := (^x11.Selection_Request_Event)(ev)
			// X11_CHECK_ANSWER_MS stands in for a source still making what
			// it hands over (a file being written, a photo exported). A
			// target that waits for this inside its own call freezes for the
			// whole of it, and one with a short bound refuses a slow source.
			if ms, ok := strconv.parse_int(os.get_env("X11_CHECK_ANSWER_MS", context.temp_allocator)); ok && ms > 0 {
				fmt.printfln("holding the answer back for %d ms", ms)
				time.sleep(time.Duration(ms) * time.Millisecond)
			}
			txt := text
            x11.api.change_property(conn, x11.PROP_MODE_REPLACE, e.requestor, e.property, e.target,
				8, u32(len(txt)), raw_data(txt))
			note := x11.Selection_Notify_Event{
				response_type = 31, time = e.time, requestor = e.requestor,
				selection = e.selection, target = e.target, property = e.property,
			}
			x11.api.send_event(conn, 0, e.requestor, 0, &note)
			x11.api.flush(conn)
			fmt.printfln("answered the data request (%d bytes)", len(txt))
		} else if kind == x11.CLIENT_MESSAGE {
			e := (^x11.Client_Message_Event)(ev)
			if e.type == finished {
				fmt.printfln("XdndFinished: accepted=%v", e.data.data32[1] & 1 != 0)
				x11.free_reply(ev)
				return
			}
		}
		x11.free_reply(ev)
	}
	fmt.eprintln("no XdndFinished - the target never let go of the drag")
	os.exit(1)
}

// wait_for waits for one client message of `type` and reports its accept bit.
wait_for :: proc(conn: x11.Connection, type: x11.Atom, accepted: ^bool) -> bool {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 3 {
		ev := x11.api.poll_for_event(conn)
		if ev == nil { time.sleep(2 * time.Millisecond); continue }
		if ev.response_type & 0x7f == x11.CLIENT_MESSAGE {
			e := (^x11.Client_Message_Event)(ev)
			if e.type == type {
				accepted^ = e.data.data32[1] & 1 != 0
				x11.free_reply(ev)
				return true
			}
		}
		x11.free_reply(ev)
	}
	return false
}
