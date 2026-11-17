package xdg

// Opening a link in the person's own browser or mail app. The desktop
// decides which program that is: the OpenURI portal asks it, and without a
// portal `xdg-open` does the same job from the same desktop files.
//
// The toolkit has already checked the URL (baldr/url.odin): http, https and
// mailto only, so no URL can be turned into a command. Here it is passed on
// as it is, never through a shell.
//
// Either way the answer comes back later as Ev_Url with the ask's token: the
// portal's Response, or the exit status of xdg-open (0 means a handler took
// it). An app that hears `ok = false` shows the link for copying instead.

import "core:os"
import "core:time"
import "baldr:platform"
import portal "baldr:sys/portal"

// URL_CHILD_WAIT is how long an opener is given to say how it went. Past
// that the ask is called opened — the handler is up, and its window may
// outlive the app — and the child is only reaped from then on.
@(private)
URL_CHILD_WAIT :: 10 * time.Second

// Url_Child is one `xdg-open` still running (the fallback path).
@(private)
Url_Child :: struct {
	process:  os.Process,
	token:    u64,
	started:  time.Tick,
	reported: bool,
}

// Url_Req is one portal ask, freed when the portal answers.
@(private)
Url_Req :: struct {
	x:    ^Xdg,
	token: u64,
}

// open_url hands the URL to the desktop (Backend.open_url).
open_url :: proc(x: ^Xdg, url: string, token: u64) -> bool {
	
	if x.bus != nil {
		req := new(Url_Req)
		req^ = {x = x, token = token}
		if portal.open_uri(x.bus, url, "", on_url_response, req) {
			debugf(x, "open_url %q through the portal (token %d)", url, token)
			return true
		}
		free(req)
	}
	return url_spawn(x, url, token)
}

// on_url_response: the portal's answer (runs inside dispatch, i.e.
// inside pump).
@(private)
on_url_response :: proc(user: rawptr, response: portal.Response) {
	req := (^Url_Req)(user)
	x := req.x
	ok := response == .Success
	debugf(x, "open_url (token %d): portal says %v", req.token, response)
	push(x, platform.Ev_Url{token = req.token, ok = ok})
	free(req)
}

// url_spawn runs `xdg-open URL` with no shell in between, and watches it
// for its exit status (url_children_poll).
@(private)
url_spawn :: proc(x: ^Xdg, url: string, token: u64) -> bool {
	cmd := [2]string{"xdg-open", url}
	p, err := os.process_start({command = cmd[:], stdout = nil, stderr = nil, stdin = nil})
	if err != nil {
		debugf(x, "open_url %q: no portal and xdg-open would not start (%v)", url, err)
		return false
	}
	append(&x.url_children, Url_Child{process = p, token = token, started = time.tick_now()})
	debugf(x, "open_url %q through xdg-open, pid %d (token %d)", url, p.pid, token)
	return true
}

// url_children_poll asks after each opener without waiting on it: the first
// answer becomes Ev_Url, and the child is dropped once it has gone.
@(private)
url_children_poll :: proc(x: ^Xdg) {
	for i := len(x.url_children) - 1; i >= 0; i -= 1 {
		c := &x.url_children[i]
		state, err := os.process_wait(c.process, 0)
		if err == nil && state.exited {
			if !c.reported do push(x, platform.Ev_Url{token = c.token, ok = state.exit_code == 0})
			debugf(x, "open_url (token %d): xdg-open exited %d", c.token, state.exit_code)
			unordered_remove(&x.url_children, i)
			continue
		}
		if err != nil && err != os.General_Error.Timeout { // gone without a status: nothing more to hear
			if !c.reported do push(x, platform.Ev_Url{token = c.token, ok = false})
			unordered_remove(&x.url_children, i)
			continue
		}
		if !c.reported && time.tick_since(c.started) > URL_CHILD_WAIT {
			c.reported = true // it is taking its time because the handler is up
			push(x, platform.Ev_Url{token = c.token, ok = true})
		}
	}
}

// url_children_drop waits briefly for the openers still running as the
// backend shuts down, so none is left a zombie of this process.
@(private)
url_children_drop :: proc(x: ^Xdg) {
	for c in x.url_children do _, _ = os.process_wait(c.process, time.Second)
	delete(x.url_children)
	x.url_children = nil
}
