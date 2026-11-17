#+build linux
package x11

// The event pump: wait on the descriptors, drain what X sent, turn it into
// platform.Events.
//
// The X connection, the eventfd `wake` posts to, the session bus and any
// watched descriptors are polled together, so the loop sleeps until one has
// something.
//
// X has no configure/ack: a ConfigureNotify is the new size. Nor is there a
// frame callback, so `surface_request_frame` is answered at once.

import "base:runtime"
import "core:mem/virtual"
import "core:time"
import "core:sys/linux"
import "baldr:dbus"
import "baldr:platform"

@(private)
text_allocator :: proc(x: ^X11) -> runtime.Allocator {
	return virtual.arena_allocator(&x.text)
}

@(private)
push :: proc(x: ^X11, ev: platform.Event) {
	append(&x.queue, ev)
}

@(private)
pump :: proc(b: ^platform.Backend, timeout_ms: i32) -> []platform.Event {
	x := data(b)
	x.ctx = context
	clear(&x.out)
	// What the last pump returned is the caller's no longer; the strings in
	// it live in the arena, freed here unless something queued between
	// pumps still needs it.
	if len(x.queue) == 0 do virtual.arena_free_all(&x.text)
	x.woken = false

	start := time.tick_now()
	for {
		drain_x(x)
		selection_wait_serve(x)   // a form of a drag or a copy that somebody is waiting for, now made
		drop_timeout(x)           // …and a drop we asked for that nobody ever answered
		xdg_poll(x)
		frames_tick(x)   // the display's own rate, while a surface asks for it
		flush_frames(x)
		if len(x.queue) > 0 || x.woken do break

		wait := timeout_ms
		if timeout_ms > 0 {
			elapsed := i32(time.duration_milliseconds(time.tick_since(start)))
			wait = max(timeout_ms - elapsed, 0)
			if wait == 0 do break
		} else if timeout_ms == 0 {
			break
		}
		// A drop we are waiting on never sleeps past its deadline, or an
		// idle app would never notice it expire.
		if left, waiting := drop_wait_ms(x); waiting {
			wait = left if wait < 0 else min(wait, left)
		}
		// A surface asking for frames never waits past the next one.
		if frames_any(x) {
			due := frames_wait_ms(x)
			wait = due if wait < 0 else min(wait, due)
		}
		if !wait_for_something(x, wait) do break
	}

	api.flush(x.conn)
	x.queue, x.out = x.out, x.queue
	return x.out[:]
}

// wait_for_something sleeps until the X connection, the wake eventfd or the
// session bus has something, or the timeout runs out. False when the
// connection is gone.
@(private)
wait_for_something :: proc(x: ^X11, timeout_ms: i32) -> bool {
	// The four the backend always has, plus whatever the toolkit asked us to
	// watch (watch_fd): the accessibility bus, so a reader's question wakes
	// the loop instead of waiting for something else to.
	fds := make([dynamic]linux.Poll_Fd, 0, 4 + len(x.extra_fds), context.temp_allocator)
	append(&fds,
		linux.Poll_Fd{fd = x.fd,      events = {.IN}},
		linux.Poll_Fd{fd = x.wake_fd, events = {.IN}},
		linux.Poll_Fd{fd = linux.Fd(dbus.fd(x.xdg.bus)), events = {.IN}}, // -1 with no bus: poll ignores it
		linux.Poll_Fd{fd = watch_fd_of(x), events = {.IN}},               // -1 without inotify, likewise
	)
	for f in x.extra_fds do append(&fds, linux.Poll_Fd{fd = f, events = {.IN}})
	n, err := linux.poll(fds[:], timeout_ms)
	if err != .NONE && err != .EINTR do return false
	if n <= 0 do return true
	if fds[1].revents & {.IN} != {} {
		buf: [8]u8
		_, _ = linux.read(x.wake_fd, buf[:])
		x.woken = true
	}
	if fds[0].revents & {.ERR, .HUP} != {} {
		push(x, platform.Ev_Quit{lost = true})
		return false
	}
	return true
}

// wake: safe from any thread. Writing to the eventfd is what breaks the
// poll; everything else about the backend is the loop thread's.
@(private)
wake :: proc(b: ^platform.Backend) {
	x := data(b)
	if x.wake_fd == 0 do return
	one := u64(1)
	_, _ = linux.write(x.wake_fd, ([^]u8)(&one)[:8])
}

// drain_x takes everything the server has sent without waiting.
@(private)
drain_x :: proc(x: ^X11) {
	if x.conn == nil do return
	for {
		ev := api.poll_for_event(x.conn)
		if ev == nil {
			if api.connection_has_error(x.conn) != 0 {
				push(x, platform.Ev_Quit{lost = true})
			}
			return
		}
		// A vblank, an XI2 motion, or an ordinary event.
		if !present_event(x, ev) && !xi2_event(x, ev) do handle(x, ev)
		free_reply(ev) // libxcb malloc'ed it; Odin's free would not do
	}
}

@(private)
handle :: proc(x: ^X11, ev: ^Generic_Event) {
	// The top bit says another client sent it with SendEvent, which changes
	// nothing the backend does about it.
	switch ev.response_type & 0x7f {
	case CONFIGURE_NOTIFY:
		e := (^Configure_Notify_Event)(ev)
		// The root window resizing is the screen layout changing: a monitor
		// plugged in, unplugged, moved or set to another mode. Not RandR's
		// ScreenChangeNotify, so a rearrangement that keeps the root's size
		// (two monitors swapping places) goes unseen.
		if x.screen != nil && e.window == x.screen.root {
			if outputs_refresh(x) {
				debugf(x, "the screen layout changed: %d screen(s)", len(x.screens))
				push(x, platform.Ev_Outputs{})
			}
			return
		}
		s := surface_of_window(x, e.window)
		if s == nil || !s.live do return
		// A window being dragged sends one per pointer motion. A move is not
		// a configure: Ev_Configure carries no position, and each would cost
		// a relayout and repaint. The position is only recorded.
		s.pos = {i32(e.x), i32(e.y)}
		size := [2]u32{u32(e.width), u32(e.height)}
		if size == s.size_px && s.configured do return
		s.size_px = size
		s.configured = true
		emit_configure(x, s)

	case EXPOSE:
		e := (^Expose_Event)(ev)
		s := surface_of_window(x, e.window)
		// count is how many more Expose events are coming for this damage;
		// the last one is enough, since the whole surface is redrawn.
		if s != nil && s.live && e.count == 0 do s.frame_requested = true

	case MAP_NOTIFY:
		e := (^Map_Notify_Event)(ev)
		s := surface_of_window(x, e.window)
		if s == nil || !s.live do return
		s.mapped = true
		// By mapping time the window manager has decided whether it is
		// maximised: read it before the first configure, not just after.
		read_wm_state(x, s)
		if !s.configured {
			s.configured = true
			emit_configure(x, s) // some window managers map without configuring first
		} else {
			emit_configure(x, s)
		}

	case UNMAP_NOTIFY:
		e := (^Map_Notify_Event)(ev) // same shape
		if s := surface_of_window(x, e.window); s != nil do s.mapped = false

	case DESTROY_NOTIFY:
		e := (^Map_Notify_Event)(ev) // same shape: event + window
		if s := surface_of_window(x, e.window); s != nil && s.live {
			s.live = false
			push(x, platform.Ev_Close{surface = s.id, reason = .Compositor})
		}

	case KEY_PRESS:      on_key(x, (^Input_Event)(ev), true)
	case KEY_RELEASE:    on_key(x, (^Input_Event)(ev), false)
	case BUTTON_PRESS:   on_button(x, (^Input_Event)(ev), true)
	case BUTTON_RELEASE: on_button(x, (^Input_Event)(ev), false)
	case MOTION_NOTIFY:  on_motion(x, (^Input_Event)(ev))
	case ENTER_NOTIFY:   on_crossing(x, (^Crossing_Event)(ev), true)
	case LEAVE_NOTIFY:   on_crossing(x, (^Crossing_Event)(ev), false)
	case FOCUS_IN:       on_focus(x, (^Focus_Event)(ev), true)
	case FOCUS_OUT:      on_focus(x, (^Focus_Event)(ev), false)

	case SELECTION_NOTIFY:
		// A drop's answer, parked by drag_receive. A paste's answer is taken
		// by convert_and_wait in its own call, on a different property.
		drop_answered(x, (^Selection_Notify_Event)(ev))

	case SELECTION_CLEAR:   on_selection_clear(x, (^Selection_Clear_Event)(ev))
	case SELECTION_REQUEST:
		e := (^Selection_Request_Event)(ev)
		// A drag's data goes through its own selection, so that comes first.
		if !drag_out_request(x, e) do on_selection_request(x, e)

	case PROPERTY_NOTIFY:
		e := (^Property_Notify_Event)(ev)
		if x.screen != nil && e.window == x.screen.root && e.atom == ATOM_RESOURCE_MANAGER {
			// The desktop changed Xft.dpi: every window's logical size moves
			// with it, so every window hears a configure.
			if sc := session_scale(x); sc != x.scale {
				debugf(x, "session scale %.2f -> %.2f", x.scale, sc)
				x.scale = sc
				for s in x.surfaces do if s != nil && s.live && s.configured do emit_configure(x, s)
			}
			return
		}
		if s := surface_of_window(x, e.window); s != nil && s.live && e.atom == x.atoms.net_wm_state {
			wm_state_changed(x, s)
			return
		}
		// A requestor deleting the property is asking for the next piece of
		// an INCR transfer this app is sending (incr.odin).
		incr_continue(x, e)

	case CLIENT_MESSAGE:
		e := (^Client_Message_Event)(ev)
		s := surface_of_window(x, e.window)
		if s == nil || !s.live do return
		if e.type == x.atoms.wm_protocols && Atom(e.data.data32[0]) == x.atoms.wm_delete_window {
			push(x, platform.Ev_Close{surface = s.id, reason = .User})
			return
		}
		if xdnd_message(x, e) do return   // a drag from another program (xdnd.odin)
		drag_out_message(x, e)            // …or a target answering one of ours (xdnd_source.odin)
	}
}

@(private)
emit_configure :: proc(x: ^X11, s: ^Surface) {
	sc := x.scale if x.scale > 0 else 1
	push(x, platform.Ev_Configure{
		surface    = s.id,
		size       = {f32(s.size_px.x) / sc, f32(s.size_px.y) / sc},
		size_px    = s.size_px,
		scale      = sc,
		maximized  = s.maximized,
		fullscreen = s.fullscreen,
		activated  = s.focused,
	})
	debugf(x, "surface %d configure: %dx%d at %d,%d", s.id, s.size_px.x, s.size_px.y, s.pos.x, s.pos.y)
}

// flush_frames answers surface_request_frame. X sends nothing when a frame
// is due, so a surface that asked is told to draw straight away.
@(private)
flush_frames :: proc(x: ^X11) {
	for s in x.surfaces {
		if s == nil || !s.live || !s.frame_requested || !s.mapped do continue
		s.frame_requested = false
		push(x, platform.Ev_Redraw{surface = s.id})
	}
}

// xdg_poll gives the session bus its turn: the portal's replies and the
// notification server's signals arrive here (platform/xdg).
@(private)
xdg_poll :: proc(x: ^X11) {
	xdg_dispatch(x)
	ime_poll(x) // the input method runs on its own bus, not the session one
	platform.inotify_drain(&x.inotify, &x.queue, text_allocator(x))
}
