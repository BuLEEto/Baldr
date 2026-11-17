#+build linux
// Connection tests over a socketpair: no bus needed. One end is wrapped in a
// Connection (connect_fd: pre-authenticated), the other end is a fake peer
// we write raw encoded messages into.
package dbus

@(require) import "core:sys/linux"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Pair :: struct {
	conn: ^Connection,
	peer: linux.Fd,
	rbuf: [dynamic]u8, // bytes the peer has read but not yet framed
}

@(private = "file")
pair_make :: proc(t: ^testing.T) -> (p: Pair, ok: bool) {
	fds: [2]linux.Fd
	if err := linux.socketpair(.UNIX, .STREAM, .HOPOPT, &fds); err != .NONE {
		testing.fail_now(t, "socketpair failed")
	}
	p.conn = connect_fd(fds[0])
	p.peer = fds[1]
	p.rbuf = make([dynamic]u8, context.temp_allocator)
	return p, true
}

@(private = "file")
pair_close :: proc(p: ^Pair) {
	disconnect(p.conn)
	if p.peer >= 0 do linux.close(p.peer)
}

// peer_send encodes m and writes it into the peer end.
@(private = "file")
peer_send :: proc(t: ^testing.T, p: ^Pair, m: ^Message) {
	bytes, err := encode_message(m, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	n, werr := linux.write(p.peer, bytes)
	testing.expect_value(t, werr, linux.Errno.NONE)
	testing.expect_value(t, n, len(bytes))
}

// peer_read_message returns the next complete message the connection wrote
// to the peer end, reading more (with a 2 s poll bound, never forever) as
// needed. Several messages may arrive in one read, so it frames.
@(private = "file")
peer_read_message :: proc(t: ^testing.T, p: ^Pair) -> (msg: Message, ok: bool) {
	for {
		total, st := frame_length(p.rbuf[:])
		if st == .Bad {
			testing.fail_now(t, "peer got a malformed frame")
		}
		if st == .Ok && total <= len(p.rbuf) {
			m, derr := decode_message(p.rbuf[:total], context.temp_allocator)
			testing.expect_value(t, derr, Error.None)
			remove_range(&p.rbuf, 0, total)
			return m, derr == .None
		}
		fds := [1]linux.Poll_Fd{{fd = p.peer, events = {.IN}}}
		if n, _ := linux.poll(fds[:], 2000); n <= 0 {
			testing.fail_now(t, "peer read timed out")
		}
		buf: [4096]u8
		n, rerr := linux.read(p.peer, buf[:])
		if rerr != .NONE || n <= 0 {
			testing.fail_now(t, "peer read failed")
		}
		append(&p.rbuf, ..buf[:n])
	}
}

@(private = "file")
Sig_Count :: struct {
	count:     int,
	last_ns:   string,
	last_key:  string,
	last_u32:  u32,
	saw_fds:   int,
}

@(private = "file")
on_setting_changed :: proc(conn: ^Connection, sig: ^Message, user: rawptr) {
	c := (^Sig_Count)(user)
	c.count += 1
	if len(sig.body) == 3 {
		c.last_ns, _ = as_string(sig.body[0])
		c.last_key, _ = as_string(sig.body[1])
		c.last_u32, _ = as_u32(sig.body[2])
	}
	c.saw_fds = len(sig.fds)
}

@(test)
conn_dispatch_routes_signal_to_handler :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)

	counts: Sig_Count
	id := on_signal(p.conn, "org.freedesktop.portal.Settings", "SettingChanged", on_setting_changed, &counts, path = "/org/freedesktop/portal/desktop")
	testing.expect(t, id != 0)
	// A handler with a different member must not fire.
	other: Sig_Count
	on_signal(p.conn, "org.freedesktop.portal.Settings", "Other", on_setting_changed, &other)

	// Synthetic SettingChanged: ("org.freedesktop.appearance", "color-scheme", <u32 2>).
	body := [3]Value{"org.freedesktop.appearance", "color-scheme", variant(u32(2), context.temp_allocator)}
	sig := signal("/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", body[:])
	sig.sender = ":1.39"
	sig.serial = 77
	peer_send(t, &p, &sig)
	// And a second one in the same write burst, on a path the handler ignores.
	sig2 := sig
	sig2.path = "/elsewhere"
	sig2.serial = 78
	peer_send(t, &p, &sig2)

	n, derr := dispatch(p.conn)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, counts.count, 1)
	testing.expect_value(t, counts.last_ns, "org.freedesktop.appearance")
	testing.expect_value(t, counts.last_key, "color-scheme")
	testing.expect_value(t, counts.last_u32, u32(2))
	testing.expect_value(t, other.count, 0)

	// Nothing pending: dispatch returns 0 without blocking.
	n2, derr2 := dispatch(p.conn)
	testing.expect_value(t, derr2, Error.None)
	testing.expect_value(t, n2, 0)

	// Removing the handler stops delivery.
	off_signal(p.conn, id)
	sig.serial = 79
	peer_send(t, &p, &sig)
	dispatch(p.conn)
	testing.expect_value(t, counts.count, 1)
}

@(test)
conn_call_matches_reply_serial_and_queues_others :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)

	// Pre-load the peer with: an unrelated signal, a reply to serial 2 (not
	// ours yet), and the reply to serial 1 (ours). call must skip the first
	// two (queuing them) and return the third.
	noise := signal("/n", "a.b", "Noise")
	noise.serial = 500
	peer_send(t, &p, &noise)
	wrong := Message{type = .Method_Return, serial = 501, reply_serial = 2}
	peer_send(t, &p, &wrong)
	body := [1]Value{":1.7"}
	right := Message{type = .Method_Return, serial = 502, reply_serial = 1, body = body[:]}
	peer_send(t, &p, &right)

	counts: Sig_Count
	on_signal(p.conn, "a.b", "Noise", on_setting_changed, &counts)

	m := method_call("org.example", "/obj", "org.example.I", "Hello")
	reply, err := call(p.conn, &m, 1000, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, reply.reply_serial, u32(1))
	name, _ := as_string(reply.body[0])
	testing.expect_value(t, name, ":1.7")
	testing.expect_value(t, counts.count, 0) // handlers never run inside call

	// The peer saw our call with serial 1 and the right header.
	sent, sok := peer_read_message(t, &p)
	if sok {
		testing.expect_value(t, sent.type, Message_Type.Method_Call)
		testing.expect_value(t, sent.serial, u32(1))
		testing.expect_value(t, sent.destination, "org.example")
		testing.expect_value(t, sent.member, "Hello")
	}
	// The queued signal is delivered by the next dispatch.
	n, derr := dispatch(p.conn)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, n, 2) // noise + the orphan reply (dropped silently)
	testing.expect_value(t, counts.count, 1)
}

@(test)
conn_call_times_out_and_error_reply_is_a_value :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)

	m := method_call("org.example", "/obj", "org.example.I", "Slow")
	_, err := call(p.conn, &m, 30, context.temp_allocator)
	testing.expect_value(t, err, Error.Timeout)
	testing.expect(t, is_connected(p.conn))

	// An ERROR reply to serial 2 surfaces as .Remote with name and text.
	sent, _ := peer_read_message(t, &p) // drain the Slow call
	testing.expect_value(t, sent.serial, u32(1))
	m2 := method_call("org.example", "/obj", "org.example.I", "Boom")
	fake_call := Message{serial = 2, sender = ":1.1"}
	e := error_reply(&fake_call, "org.example.Error.Boom", "kaboom", context.temp_allocator)
	e.serial = 900
	peer_send(t, &p, &e)
	reply, err2 := call(p.conn, &m2, 1000, context.temp_allocator)
	testing.expect_value(t, err2, Error.Remote)
	testing.expect_value(t, reply.error_name, "org.example.Error.Boom")
	testing.expect_value(t, error_text(&reply), "kaboom")
}

@(private = "file")
Async_Result :: struct {
	calls: int,
	err:   Error,
	value: u32,
}

@(private = "file")
on_async :: proc(conn: ^Connection, reply: ^Message, err: Error, user: rawptr) {
	r := (^Async_Result)(user)
	r.calls += 1
	r.err = err
	if reply != nil && len(reply.body) == 1 do r.value, _ = as_u32(reply.body[0])
}

@(test)
conn_call_async_and_unknown_method_reply :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)

	res: Async_Result
	m := method_call("org.example", "/obj", "org.example.I", "Get")
	serial, err := call_async(p.conn, &m, on_async, &res)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, serial, u32(1))
	body := [1]Value{u32(99)}
	reply := Message{type = .Method_Return, serial = 10, reply_serial = serial, body = body[:]}
	peer_send(t, &p, &reply)

	// Someone calls a method on us: we must answer UnknownMethod.
	incoming := method_call(":1.2", "/", "org.freedesktop.DBus.Peer", "Ping")
	incoming.serial = 11
	incoming.sender = ":1.9"
	peer_send(t, &p, &incoming)

	n, derr := dispatch(p.conn)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, res.calls, 1)
	testing.expect_value(t, res.err, Error.None)
	testing.expect_value(t, res.value, u32(99))

	peer_read_message(t, &p) // our Get call
	answer, aok := peer_read_message(t, &p)
	if aok {
		testing.expect_value(t, answer.type, Message_Type.Error)
		testing.expect_value(t, answer.reply_serial, u32(11))
		testing.expect_value(t, answer.destination, ":1.9")
		testing.expect_value(t, answer.error_name, ERROR_UNKNOWN_METHOD)
	}
}

@(test)
conn_malformed_frame_disconnects_without_panic :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)

	junk := [24]u8{'l', 1, 0, 1, 0xff, 0xff, 0xff, 0x7f, 1, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0}
	linux.write(p.peer, junk[:])
	_, derr := dispatch(p.conn)
	testing.expect_value(t, derr, Error.Protocol)
	testing.expect(t, !is_connected(p.conn))
	_, cerr := dispatch(p.conn)
	testing.expect_value(t, cerr, Error.Disconnected)
	m := method_call("org.example", "/obj", "org.example.I", "X")
	_, serr := send(p.conn, &m)
	testing.expect_value(t, serr, Error.Not_Connected)
}

// A message that frames but will not decode (here a string that is not
// UTF-8) is dropped alone: the connection, and the message after it, carry on.
@(test)
conn_a_message_that_will_not_decode_costs_only_itself :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)

	body := []Value{"zz"}
	bad := signal("/obj", "org.example.I", "Bad", body)
	bad.serial = 5
	bytes, err := encode_message(&bad, context.temp_allocator)
	if !testing.expect_value(t, err, Error.None) do return
	for i in 0 ..< len(bytes) - 1 do if bytes[i] == 'z' && bytes[i + 1] == 'z' {
		bytes[i], bytes[i + 1] = 0xFF, 0xFE
		break
	}
	linux.write(p.peer, bytes)
	counts: Sig_Count
	on_signal(p.conn, "org.example.I", "Good", on_setting_changed, &counts, path = "/obj")
	good := signal("/obj", "org.example.I", "Good")
	good.serial = 6
	peer_send(t, &p, &good)
	_, derr := dispatch(p.conn)
	testing.expect_value(t, derr, Error.None)
	testing.expect(t, is_connected(p.conn), "still connected")
	testing.expect_value(t, counts.count, 1)
}

@(test)
conn_peer_close_fails_pending_async :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)

	res: Async_Result
	m := method_call("org.example", "/obj", "org.example.I", "Get")
	call_async(p.conn, &m, on_async, &res)
	linux.close(p.peer)
	p.peer = -1
	_, derr := dispatch(p.conn)
	testing.expect_value(t, derr, Error.Disconnected)
	testing.expect_value(t, res.calls, 1)
	testing.expect_value(t, res.err, Error.Disconnected)
}

@(test)
conn_address_parsing :: proc(t: ^testing.T) {
	path, abstract, ok := parse_address("unix:path=/run/user/1000/bus")
	testing.expect(t, ok)
	testing.expect_value(t, path, "/run/user/1000/bus")
	testing.expect_value(t, abstract, false)
	path2, abstract2, ok2 := parse_address("unix:abstract=/tmp/dbus-AbC123,guid=deadbeef")
	testing.expect(t, ok2)
	testing.expect_value(t, path2, "/tmp/dbus-AbC123")
	testing.expect_value(t, abstract2, true)
	// tcp first, then a usable unix entry; %-escapes decoded.
	path3, _, ok3 := parse_address("tcp:host=localhost,port=1234;unix:path=/tmp/with%20space")
	testing.expect(t, ok3)
	testing.expect_value(t, path3, "/tmp/with space")
	_, _, ok4 := parse_address("tcp:host=x")
	testing.expect_value(t, ok4, false)
	_, _, ok5 := parse_address("")
	testing.expect_value(t, ok5, false)
}

// ------------------------------------------------------------------ serving

@(private = "file")
Served :: struct {
	calls: int,
	last:  string,
}

@(test)
a_connection_can_serve_objects :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)
	served: Served
	serve(p.conn, proc(conn: ^Connection, call: ^Message, user: rawptr) -> bool {
		s := (^Served)(user)
		s.calls += 1
		s.last = call.member
		if call.member == "Unknown" do return false // let the connection answer for us
		if call.member == "Fails" {
			reply_error(conn, call, "org.example.Error.No", "not today")
			return true
		}
		reply(conn, call, {i32(7), "seven"})
		return true
	}, &served)

	// a call we answer
	call := method_call("", "/org/example/obj", "org.example.Iface", "Get")
	call.serial = 11
	call.sender = ":1.9"
	peer_send(t, &p, &call)
	dispatch(p.conn)
	testing.expect_value(t, served.calls, 1)
	testing.expect_value(t, served.last, "Get")
	m, got := peer_read_message(t, &p)
	testing.expect(t, got, "an answer came back")
	testing.expect_value(t, m.type, Message_Type.Method_Return)
	testing.expect_value(t, m.reply_serial, u32(11))
	testing.expect_value(t, m.signature, "is")
	if len(m.body) == 2 {
		testing.expect_value(t, m.body[0].(i32), 7)
		testing.expect_value(t, m.body[1].(string), "seven")
	}

	// one we answer with an error
	call.member = "Fails"
	call.serial = 12
	peer_send(t, &p, &call)
	dispatch(p.conn)
	m, got = peer_read_message(t, &p)
	testing.expect(t, got && m.type == .Error, "an error came back")
	testing.expect_value(t, m.error_name, "org.example.Error.No")

	// one we decline: the connection says UnknownMethod
	call.member = "Unknown"
	call.serial = 13
	peer_send(t, &p, &call)
	dispatch(p.conn)
	m, got = peer_read_message(t, &p)
	testing.expect(t, got && m.type == .Error, "declined: an error came back")
	testing.expect_value(t, m.error_name, ERROR_UNKNOWN_METHOD)

	// and with no server at all, the same
	serve(p.conn, nil, nil)
	call.member = "Get"
	call.serial = 14
	peer_send(t, &p, &call)
	dispatch(p.conn)
	m, got = peer_read_message(t, &p)
	testing.expect(t, got && m.type == .Error && m.error_name == ERROR_UNKNOWN_METHOD, "no server: UnknownMethod")
	testing.expect_value(t, served.calls, 3)
}

@(test)
emit_broadcasts_a_signal :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)
	err := emit(p.conn, "/org/a11y/atspi/accessible/7", "org.a11y.atspi.Event.Object", "StateChanged", {"focused", i32(1), i32(0)})
	testing.expect_value(t, err, Error.None)
	m, got := peer_read_message(t, &p)
	testing.expect(t, got, "the signal went out")
	testing.expect_value(t, m.type, Message_Type.Signal)
	testing.expect_value(t, m.path, "/org/a11y/atspi/accessible/7")
	testing.expect_value(t, m.member, "StateChanged")
	testing.expect_value(t, m.signature, "sii")
}

// A reply that cannot go on the wire (a string holding a NUL, which D-Bus
// forbids) still answers, with an error: a caller left with no reply at all
// waits out its whole timeout.
@(test)
conn_reply_that_cannot_be_encoded_still_answers :: proc(t: ^testing.T) {
	p, ok := pair_make(t)
	if !ok do return
	defer pair_close(&p)
	call := method_call(":1.2", "/obj", "org.freedesktop.DBus.Properties", "Get")
	call.serial = 21
	call.sender = ":1.9"
	body := [1]Value{"React\x00on message 61"}
	err := reply(p.conn, &call, body[:])
	testing.expect_value(t, err, Error.Invalid_Message)
	answer, aok := peer_read_message(t, &p)
	if !testing.expect(t, aok, "the caller got an answer") do return
	testing.expect_value(t, answer.type, Message_Type.Error)
	testing.expect_value(t, answer.reply_serial, u32(21))
	testing.expect_value(t, answer.error_name, "org.freedesktop.DBus.Error.Failed")
}

} // when ODIN_TEST
