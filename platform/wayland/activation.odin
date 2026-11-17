package wayland

// Bringing a window forward (xdg-activation-v1): for MPRIS's Raise, a second
// launch or a notification's click. With a token the app was handed (a D-Bus
// caller's, a launcher's) it activates at once; without one it asks the
// desktop for a token first, tied to its latest input when there was any. A
// window not shown yet is activated as it first shows, as is a process's
// first window with its launcher's XDG_ACTIVATION_TOKEN. The desktop decides
// whether that raises the window or only marks it as wanting attention.

import "core:strings"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

@(private)
surface_activate :: proc(b: ^platform.Backend, s: platform.Surface, token: string) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil do return
	if st.activation == nil {
		debugf(st, "activate surface %d: the compositor has no xdg_activation_v1", s)
		return
	}
	if !ss.mapped { // not on screen yet: as it first shows (on_frame_done)
		ss.activate_pending = true
		delete(ss.activate_token)
		ss.activate_token = strings.clone(token)
		return
	}
	activate_now(st, ss, token)
}

// activate_on_show: surface `s` has just shown for the first time. An
// activation asked for before is done now; else a process's first window
// takes its launcher's token.
@(private)
activate_on_show :: proc(st: ^State, s: ^Surface_State) {
	if st.activation == nil do return
	if s.activate_pending {
		s.activate_pending = false
		activate_now(st, s, s.activate_token)
		delete(s.activate_token)
		s.activate_token = ""
		return
	}
	if st.launch_token != "" && s.toplevel != nil {
		activate_now(st, s, st.launch_token)
		delete(st.launch_token)
		st.launch_token = ""
	}
}

// Activation_Ask is a token asked for, to activate `surface` with when the
// desktop answers.
@(private)
Activation_Ask :: struct {
	st:      ^State,
	surface: platform.Surface,
	l:       wl.Xdg_Activation_Token_V1_Listener,
}

@(private)
activate_now :: proc(st: ^State, s: ^Surface_State, token: string) {
	if token != "" {
		debugf(st, "activate surface %d with a token", s.id)
		wl.xdg_activation_v1_activate(st.activation, strings.clone_to_cstring(token, context.temp_allocator), s.wl_surface)
		wl.display_flush(st.display)
		return
	}
	// none handed over: ask for one, tied to the latest input if there was some
	tok := wl.xdg_activation_v1_get_activation_token(st.activation)
	if tok == nil do return
	ask := new(Activation_Ask)
	ask.st, ask.surface = st, s.id
	ask.l = wl.xdg_activation_token_v1_listener_noop()
	ask.l.done = on_activation_token
	wl.xdg_activation_token_v1_add_listener(tok, &ask.l, ask)
	if st.seat != nil && st.input_serial != 0 do wl.xdg_activation_token_v1_set_serial(tok, st.input_serial, st.seat)
	wl.xdg_activation_token_v1_set_surface(tok, s.wl_surface)
	wl.xdg_activation_token_v1_commit(tok)
	wl.display_flush(st.display)
	debugf(st, "activate surface %d: asked for a token", s.id)
}

@(private)
on_activation_token :: proc "c" (data: rawptr, p: wl.Proxy, token: cstring) {
	ask := (^Activation_Ask)(data)
	st := ask.st
	context = st.ctx
	if s := lookup(st, ask.surface); s != nil && s.wl_surface != nil { // it may have closed meanwhile
		wl.xdg_activation_v1_activate(st.activation, token, s.wl_surface)
		wl.display_flush(st.display)
		debugf(st, "activate surface %d with the token asked for", ask.surface)
	}
	wl.xdg_activation_token_v1_destroy(p)
	free(ask)
}
