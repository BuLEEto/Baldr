#+build linux
// Package portal wraps xdg-desktop-portal (org.freedesktop.portal.Desktop at
// /org/freedesktop/portal/desktop) on top of baldr:dbus: the Settings portal
// for system appearance (colour scheme, accent, contrast, reduce-motion),
// the FileChooser portal for native open/save dialogs, and OpenURI.
//
// Portal calls that show UI follow the Request/Response pattern: the method
// returns an org.freedesktop.portal.Request object path and the result
// arrives later as a `Response` signal on that path. We pick the
// handle_token ourselves so the path is known before the call is made and
// the signal can never be missed (the portal docs' recommended flow).
//
// Every call fails gracefully (ok = false / Response.Failed) when no portal
// is running, and never blocks past its timeout: a portal that is
// installed but not running is auto-started by the bus, which can take a
// second — DEFAULT_TIMEOUT_MS allows for that.
//
// Callback values (uris, Appearance strings) are valid only during the
// callback; clone what you keep.
package portal

import "base:runtime"
import "core:fmt"
import "core:strings"
import "baldr:dbus"

DESKTOP_DEST :: "org.freedesktop.portal.Desktop"
DESKTOP_PATH :: "/org/freedesktop/portal/desktop"
IFACE_SETTINGS :: "org.freedesktop.portal.Settings"
IFACE_FILE_CHOOSER :: "org.freedesktop.portal.FileChooser"
IFACE_OPEN_URI :: "org.freedesktop.portal.OpenURI"
IFACE_REQUEST :: "org.freedesktop.portal.Request"

// DEFAULT_TIMEOUT_MS bounds the blocking calls (ReadAll, AddMatch, the
// Request handle reply). 3 s covers bus-activation of a sleeping portal.
DEFAULT_TIMEOUT_MS :: i32(3000)

// Response is the first argument of org.freedesktop.portal.Request.Response.
// Failed is ours: the call itself failed (no portal, D-Bus error, timeout).
Response :: enum u8 {
	Success   = 0,
	Cancelled = 1,
	Other     = 2,
	Failed    = 255,
}

// Response_Proc receives the parsed Response signal: `results` is the a{sv}
// results dict (a dbus.Dict Value, or nil), valid during the call only.
@(private)
Response_Proc :: #type proc(req: ^Request, response: Response, results: dbus.Value)

// Request is one in-flight portal request. Allocated by request_start and
// freed when the Response arrives or the call fails.
@(private)
Request :: struct {
	conn:        ^dbus.Connection,
	allocator:   runtime.Allocator,
	token:       string,
	path:        string, // request object path we listen on
	rule:        string, // match rule added for it
	handler:     dbus.Handler_Id,
	on_response: Response_Proc,
	cb:          rawptr, // the caller's typed callback
	user:        rawptr,
	done:        bool,
}

// request_path predicts the Request object path for our unique name and a
// token: /org/freedesktop/portal/desktop/request/<sender>/<token>, where
// <sender> is the unique name without the leading ':' and with '.' → '_'.
request_path :: proc(unique_name, token: string, allocator := context.allocator) -> string {
	sender := unique_name
	if len(sender) > 0 && sender[0] == ':' do sender = sender[1:]
	safe, _ := strings.replace_all(sender, ".", "_", context.temp_allocator)
	return fmt.aprintf("%s/request/%s/%s", DESKTOP_PATH, safe, token, allocator = allocator)
}

// request_start subscribes to the Response signal for a fresh token, then
// makes the portal call `method` on `iface` with `args` followed by an
// options dict containing `options` plus handle_token. Returns false when
// the bus refused the match rule or the send failed (nothing is then left
// registered). `on_response` is invoked exactly once, also on failure of
// the call itself (Response.Failed), after which the Request is freed.
@(private)
request_start :: proc(conn: ^dbus.Connection, iface, method: string, args: []dbus.Value, options: []dbus.Dict_Entry, on_response: Response_Proc, cb, user: rawptr, allocator := context.allocator, fds: []i32 = nil) -> bool {
	if !dbus.is_connected(conn) do return false
	req := new(Request, allocator)
	req.conn = conn
	req.allocator = allocator
	req.on_response = on_response
	req.cb = cb
	req.user = user
	req.token = fmt.aprintf("baldr_%d", dbus.next_serial(conn), allocator = allocator)
	req.path = request_path(conn.unique_name, req.token, allocator)
	if !request_listen(req) {
		request_free(req)
		return false
	}

	ta := context.temp_allocator
	entries := make([]dbus.Dict_Entry, len(options) + 1, ta)
	copy(entries, options)
	entries[len(options)] = {"handle_token", req.token}
	body := make([]dbus.Value, len(args) + 1, ta)
	copy(body, args)
	body[len(args)] = dbus.dict_sv(entries, ta)
	m := dbus.method_call(DESKTOP_DEST, DESKTOP_PATH, iface, method, body)
	m.fds = fds // OpenFile and OpenDirectory hand the portal an open descriptor
	if _, err := dbus.call_async(conn, &m, on_request_reply, req); err != .None {
		request_unlisten(req)
		request_free(req)
		return false
	}
	return true
}

// request_listen adds the match rule and signal handler for req.path.
@(private)
request_listen :: proc(req: ^Request) -> bool {
	req.rule = fmt.aprintf("type='signal',interface='%s',member='Response',path='%s'", IFACE_REQUEST, req.path, allocator = req.allocator)
	if err := dbus.add_match(req.conn, req.rule, DEFAULT_TIMEOUT_MS); err != .None do return false
	req.handler = dbus.on_signal(req.conn, IFACE_REQUEST, "Response", on_response_signal, req, path = req.path)
	return req.handler != 0
}

@(private)
request_unlisten :: proc(req: ^Request) {
	if req.handler != 0 do dbus.off_signal(req.conn, req.handler)
	req.handler = 0
	if req.rule != "" do dbus.remove_match(req.conn, req.rule)
}

@(private)
request_free :: proc(req: ^Request) {
	delete(req.token, req.allocator)
	delete(req.path, req.allocator)
	delete(req.rule, req.allocator)
	free(req, req.allocator)
}

// request_finish delivers the outcome once and tears the request down.
@(private)
request_finish :: proc(req: ^Request, response: Response, results: dbus.Value) {
	if req.done do return
	req.done = true
	req.on_response(req, response, results)
	request_unlisten(req)
	request_free(req)
}

// on_request_reply handles the method's own reply: an error means the
// portal is missing or refused; otherwise it carries the Request path,
// which older portals (< 0.9) may choose differently from our prediction.
@(private)
on_request_reply :: proc(conn: ^dbus.Connection, reply: ^dbus.Message, err: dbus.Error, user: rawptr) {
	req := (^Request)(user)
	if err != .None || reply == nil || len(reply.body) != 1 {
		request_finish(req, .Failed, nil)
		return
	}
	actual, ok := dbus.as_object_path(reply.body[0])
	if !ok {
		request_finish(req, .Failed, nil)
		return
	}
	if actual != req.path {
		request_unlisten(req)
		delete(req.path, req.allocator)
		delete(req.rule, req.allocator)
		req.rule = ""
		req.path = strings.clone(actual, req.allocator)
		if !request_listen(req) do request_finish(req, .Failed, nil)
	}
}

// on_response_signal parses Response(u response, a{sv} results).
@(private)
on_response_signal :: proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
	req := (^Request)(user)
	if sig.path != req.path do return
	code: u32 = 2
	results: dbus.Value
	if len(sig.body) >= 1 do code, _ = dbus.as_u32(sig.body[0])
	if len(sig.body) >= 2 do results = sig.body[1]
	resp: Response
	switch code {
	case 0: resp = .Success
	case 1: resp = .Cancelled
	case:   resp = .Other
	}
	request_finish(req, resp, results)
}

// portal_available reports whether org.freedesktop.portal.Desktop has an
// owner or can be activated, without triggering activation. Blocking
// (bounded by timeout_ms). Useful for diagnostics; the other calls do not
// need it and fail gracefully on their own.
portal_available :: proc(conn: ^dbus.Connection, timeout_ms := DEFAULT_TIMEOUT_MS) -> (running, activatable: bool) {
	if !dbus.is_connected(conn) do return false, false
	arg := [1]dbus.Value{DESKTOP_DEST}
	m := dbus.method_call(dbus.DBUS_SERVICE, dbus.DBUS_PATH, dbus.DBUS_INTERFACE, "NameHasOwner", arg[:])
	reply, err := dbus.call(conn, &m, timeout_ms, context.temp_allocator)
	if err == .None && len(reply.body) == 1 do running, _ = dbus.as_bool(reply.body[0])
	m2 := dbus.method_call(dbus.DBUS_SERVICE, dbus.DBUS_PATH, dbus.DBUS_INTERFACE, "ListActivatableNames")
	reply2, err2 := dbus.call(conn, &m2, timeout_ms, context.temp_allocator)
	if err2 == .None && len(reply2.body) == 1 {
		names, ok := dbus.as_strings(reply2.body[0], context.temp_allocator)
		if ok do for n in names do if n == DESKTOP_DEST do activatable = true
	}
	return running, activatable
}

// ------------------------------------------------------------------ OpenURI

// Uri_Callback reports the outcome of open_uri (Success once the handler
// application has been launched, Cancelled if the user dismissed a chooser).
Uri_Callback :: #type proc(user: rawptr, response: Response)

// open_uri asks the portal to open `uri` (http(s)://, mailto:, file:// …)
// with the user's default application. `parent_window` is the Wayland
// export handle ("wayland:<handle>") or "" for none. `cb` may be nil.
// Returns false if the request could not even be sent.
open_uri :: proc(conn: ^dbus.Connection, uri: string, parent_window := "", cb: Uri_Callback = nil, user: rawptr = nil, allocator := context.allocator) -> bool {
	args := [2]dbus.Value{parent_window, uri}
	opts := [1]dbus.Dict_Entry{{"ask", false}}
	return request_start(conn, IFACE_OPEN_URI, "OpenURI", args[:], opts[:], on_uri_response, rawptr(cb), user, allocator)
}

// open_file asks the desktop to open the file `fd` is open on with whatever
// the person uses for that kind of file, and open_directory to show it in
// the file manager — the file picked out where the file manager can do that.
//
// They take a descriptor rather than a path on purpose: the portal opens
// what the app already has open, so nothing is re-resolved between the
// app's check and the handler's open, and a sandboxed app can hand over a
// file the handler could not have opened by name. The descriptor stays the
// caller's to close; the portal receives a copy of it.
//
// `Success` means a handler took it, not that the person did anything with
// it. False here means the ask could not be sent at all.
open_file :: proc(conn: ^dbus.Connection, fd: i32, parent_window := "", cb: Uri_Callback = nil, user: rawptr = nil, allocator := context.allocator) -> bool {
	return open_fd(conn, "OpenFile", fd, parent_window, cb, user, allocator)
}

open_directory :: proc(conn: ^dbus.Connection, fd: i32, parent_window := "", cb: Uri_Callback = nil, user: rawptr = nil, allocator := context.allocator) -> bool {
	return open_fd(conn, "OpenDirectory", fd, parent_window, cb, user, allocator)
}

@(private)
open_fd :: proc(conn: ^dbus.Connection, method: string, fd: i32, parent_window: string, cb: Uri_Callback, user: rawptr, allocator: runtime.Allocator) -> bool {
	if fd < 0 do return false
	args := [2]dbus.Value{parent_window, dbus.Unix_Fd(0)} // index 0 of the message's fds
	opts := [1]dbus.Dict_Entry{{"ask", false}}
	one := [1]i32{fd}
	return request_start(conn, IFACE_OPEN_URI, method, args[:], opts[:], on_uri_response, rawptr(cb), user, allocator, one[:])
}

@(private)
on_uri_response :: proc(req: ^Request, response: Response, results: dbus.Value) {
	if req.cb == nil do return
	cb := Uri_Callback(req.cb)
	cb(req.user, response)
}
