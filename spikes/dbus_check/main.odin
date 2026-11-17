#+build linux
// dbus_check — live check of baldr:dbus against the session bus: connect +
// SASL EXTERNAL + Hello, org.freedesktop.DBus.ListNames (prints a few),
// GetNameOwner, an error reply surfaced as a value, a call_async dispatched
// through poll/dispatch, and a signal round-trip (we AddMatch for
// NameOwnerChanged and open a second connection so the bus emits one).
//
//   ./build/dbus_check            run everything
//   BALDR_DBUS_DEBUG=1 ./build/dbus_check   also hex-dump every message
package main

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "baldr:dbus"

Async_State :: struct {
	got:  bool,
	err:  dbus.Error,
	name: string,
}

on_owner :: proc(conn: ^dbus.Connection, reply: ^dbus.Message, err: dbus.Error, user: rawptr) {
	st := (^Async_State)(user)
	st.got = true
	st.err = err
	if err == .None && len(reply.body) == 1 {
		s, _ := dbus.as_string(reply.body[0])
		st.name = fmt.aprintf("%s", s) // clone: callback values die with the next dispatch
	}
}

Signal_State :: struct {
	count: int,
	last:  string,
}

on_name_owner_changed :: proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
	st := (^Signal_State)(user)
	st.count += 1
	if len(sig.body) == 3 {
		name, _ := dbus.as_string(sig.body[0])
		old, _ := dbus.as_string(sig.body[1])
		new, _ := dbus.as_string(sig.body[2])
		delete(st.last)
		st.last = fmt.aprintf("%s: %q -> %q", name, old, new)
	}
}

// pump polls the connection and dispatches until `done` reports true or
// timeout_ms passes. Returns false on timeout.
pump :: proc(conn: ^dbus.Connection, timeout_ms: i32, done: proc(user: rawptr) -> bool, user: rawptr) -> bool {
	for i: i32 = 0; i < timeout_ms; i += 20 {
		readable, perr := dbus.wait_readable(conn, 20)
		if perr != .None {
			fmt.eprintln("poll error:", perr)
			return false
		}
		if readable {
			if _, derr := dbus.dispatch(conn); derr != .None {
				fmt.eprintln("dispatch error:", derr)
				return false
			}
		}
		if done(user) do return true
	}
	return false
}

main :: proc() {
	conn, err := dbus.connect_session()
	if err != .None {
		fmt.eprintln("dbus_check: connect failed:", err)
		os.exit(1)
	}
	defer dbus.disconnect(conn)
	fmt.printfln("connected: unique name %s, server guid %s, unix fds %v, fd %d", conn.unique_name, conn.server_guid, conn.unix_fd_ok, dbus.fd(conn))

	// 1. Blocking call with an `as` reply.
	{
		m := dbus.method_call(dbus.DBUS_SERVICE, dbus.DBUS_PATH, dbus.DBUS_INTERFACE, "ListNames")
		reply, cerr := dbus.call(conn, &m, 2000, context.temp_allocator)
		if cerr != .None {
			fmt.eprintln("ListNames failed:", cerr, dbus.error_text(&reply))
			os.exit(1)
		}
		names, ok := dbus.as_strings(reply.body[0], context.temp_allocator)
		if !ok {
			fmt.eprintln("ListNames: unexpected body signature", reply.signature)
			os.exit(1)
		}
		fmt.printfln("ListNames: %d names (signature %q); first few:", len(names), reply.signature)
		shown := 0
		for n in names {
			if n[0] == ':' do continue // skip unique names, show well-known ones
			fmt.printfln("  %s", n)
			shown += 1
			if shown == 8 do break
		}
	}

	// 2. An error reply surfaces as .Remote with the error name and text.
	{
		m := dbus.method_call(dbus.DBUS_SERVICE, dbus.DBUS_PATH, dbus.DBUS_INTERFACE, "NoSuchMethod")
		reply, cerr := dbus.call(conn, &m, 2000, context.temp_allocator)
		fmt.printfln("NoSuchMethod: err=%v name=%s text=%q", cerr, reply.error_name, dbus.error_text(&reply))
		if cerr != .Remote do os.exit(1)
	}

	// 3. Typed args + reply: GetNameOwner(s) -> s, asynchronously.
	{
		st: Async_State
		body := [1]dbus.Value{"org.freedesktop.DBus"}
		m := dbus.method_call(dbus.DBUS_SERVICE, dbus.DBUS_PATH, dbus.DBUS_INTERFACE, "GetNameOwner", body[:])
		if _, aerr := dbus.call_async(conn, &m, on_owner, &st); aerr != .None {
			fmt.eprintln("call_async failed:", aerr)
			os.exit(1)
		}
		ok := pump(conn, 2000, proc(user: rawptr) -> bool { return (^Async_State)(user).got }, &st)
		fmt.printfln("GetNameOwner(org.freedesktop.DBus) async: arrived=%v err=%v owner=%s", ok, st.err, st.name)
		if !ok || st.err != .None do os.exit(1)
	}

	// 4. Signals: match NameOwnerChanged, then make the bus emit one by
	//    connecting and disconnecting a second client.
	{
		st: Signal_State
		rule := "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'"
		if merr := dbus.add_match(conn, rule); merr != .None {
			fmt.eprintln("AddMatch failed:", merr)
			os.exit(1)
		}
		id := dbus.on_signal(conn, dbus.DBUS_INTERFACE, "NameOwnerChanged", on_name_owner_changed, &st)
		other, oerr := dbus.connect_session()
		if oerr != .None {
			fmt.eprintln("second connection failed:", oerr)
			os.exit(1)
		}
		other_name := fmt.aprintf("%s", other.unique_name)
		dbus.disconnect(other)
		ok := pump(conn, 2000, proc(user: rawptr) -> bool { return (^Signal_State)(user).count >= 2 }, &st)
		fmt.printfln("NameOwnerChanged: %d signals (expected 2: %s appeared and vanished), last: %s, arrived=%v", st.count, other_name, st.last, ok)
		dbus.off_signal(conn, id)
		if !ok do os.exit(1)
	}

	// 5. Peer.Ping through the bus to ourselves proves UnknownMethod replies
	//    do not wedge anything (we answer our own call with an error).
	{
		m := dbus.method_call(conn.unique_name, "/", "org.freedesktop.DBus.Peer", "Ping")
		_, aerr := dbus.call_async(conn, &m, proc(conn: ^dbus.Connection, reply: ^dbus.Message, err: dbus.Error, user: rawptr) {
			fmt.printfln("self-call reply: err=%v name=%s", err, reply.error_name if reply != nil else "")
		}, nil)
		if aerr != .None do os.exit(1)
		pump(conn, 500, proc(user: rawptr) -> bool { return false }, nil)
	}

	fmt.printfln("dbus_check: ok (fd %d still connected: %v)", linux.Fd(dbus.fd(conn)), dbus.is_connected(conn))
}
