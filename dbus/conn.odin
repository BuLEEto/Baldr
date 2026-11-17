#+build linux
// Connection: a session-bus (or any Unix-socket) D-Bus connection over
// core:sys/linux. Blocking socket; timeouts are implemented with poll, and
// `dispatch` uses MSG_DONTWAIT so it never blocks. Single-threaded: use one
// connection from one thread (the pump thread).
//
// Lifetimes: values passed to Reply_Callback / Signal_Callback live in the
// connection's arena and are valid until the next top-level `dispatch`
// (calling `call` inside a callback is fine; it appends to the arena).
// `call` returns a reply allocated from the allocator you pass. File
// descriptors attached to dispatched messages are closed after the callback
// returns — dup() one to keep it. Replies from `call` hand their fds to you.
//
// Set BALDR_DBUS_DEBUG=1 to hex-dump every message on stderr.
package dbus

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:time"

// DBUS_SERVICE / DBUS_PATH / DBUS_INTERFACE address the message bus itself.
DBUS_SERVICE :: "org.freedesktop.DBus"
DBUS_PATH :: "/org/freedesktop/DBus"
DBUS_INTERFACE :: "org.freedesktop.DBus"

// ERROR_UNKNOWN_METHOD is what we answer method calls nobody handles with.
ERROR_UNKNOWN_METHOD :: "org.freedesktop.DBus.Error.UnknownMethod"

// DEFAULT_TIMEOUT_MS bounds connect/auth/Hello and add_match.
DEFAULT_TIMEOUT_MS :: i32(5000)

// Handler_Id names a signal handler registered with `on_signal`. 0 = none.
Handler_Id :: distinct u32

// Reply_Callback receives the reply to a `call_async`. `err` is .None for a
// METHOD_RETURN, .Remote for an ERROR (see reply.error_name / error_text),
// .Disconnected if the connection died first (reply is then nil).
Reply_Callback :: #type proc(conn: ^Connection, reply: ^Message, err: Error, user: rawptr)

// Signal_Callback receives a matching SIGNAL message.
Signal_Callback :: #type proc(conn: ^Connection, sig: ^Message, user: rawptr)

// Method_Callback answers method calls addressed to this connection: an
// accessibility bridge serving its object tree, say. Return true when the
// call was answered (send a method_return or an error_reply from inside);
// false lets the connection answer UnknownMethod itself. The message and
// everything in it live until the callback returns.
Method_Callback :: #type proc(conn: ^Connection, call: ^Message, user: rawptr) -> bool

@(private)
Pending :: struct {
	cb:   Reply_Callback,
	user: rawptr,
}

@(private)
Signal_Handler :: struct {
	id:        Handler_Id,
	interface: string, // "" = any (all four filters are ANDed; strings are cloned)
	member:    string,
	path:      string,
	sender:    string,
	cb:        Signal_Callback,
	user:      rawptr,
	dead:      bool, // removed during dispatch; compacted afterwards
}

// Raw_Message is a framed-but-not-yet-dispatched message (set aside while a
// blocking `call` waited for its reply).
@(private)
Raw_Message :: struct {
	bytes: []u8,
	fds:   []i32,
}

// Connection is one authenticated socket to a bus. Create with
// connect_session / connect_address / connect_fd; free with disconnect.
Connection :: struct {
	fd:          linux.Fd,
	allocator:   runtime.Allocator,
	unique_name: string, // ":1.42" after hello; "" for a connect_fd peer
	server_guid: string,
	unix_fd_ok:  bool, // NEGOTIATE_UNIX_FD agreed: fds may be sent and received
	connected:   bool,
	debug:       bool, // BALDR_DBUS_DEBUG: dump each message's header
	debug_body:  bool, // BALDR_DBUS_DEBUG=body: and its body, where a password or a secret travels

	next_serial:  u32,
	rbuf:         [dynamic]u8, // bytes read, not yet framed; rbuf[rpos:] is live
	rpos:         int,
	fds_in:       [dynamic]i32, // SCM_RIGHTS fds received, not yet attached to a message
	queued:       [dynamic]Raw_Message,
	pending:      map[u32]Pending,
	handlers:     [dynamic]Signal_Handler,
	next_handler: Handler_Id,
	serve_cb:     Method_Callback, // objects this connection serves (nil: none, and every call is answered UnknownMethod)
	serve_user:   rawptr,
	arena:        virtual.Arena, // decoded messages for callbacks
	in_dispatch:  int,
}

// ------------------------------------------------------------------ connect

// connect_session connects and authenticates to the session bus named by
// DBUS_SESSION_BUS_ADDRESS (falling back to $XDG_RUNTIME_DIR/bus), then
// says Hello. Failure modes: .No_Address, .Bad_Address (only unix:path=,
// unix:abstract= and unix:runtime=yes are spoken), .Socket, .Auth,
// .Timeout, .Protocol. On failure nothing is left allocated.
connect_session :: proc(allocator := context.allocator, want_unix_fds := true, timeout_ms := DEFAULT_TIMEOUT_MS) -> (^Connection, Error) {
	addr := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	if addr == "" {
		rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		if rt == "" do return nil, .No_Address
		path := fmt.tprintf("%s/bus", rt)
		if !os.exists(path) do return nil, .No_Address
		addr = fmt.tprintf("unix:path=%s", path)
	}
	return connect_address(addr, allocator, want_unix_fds, timeout_ms)
}

// connect_address connects to a D-Bus address string ("transport:key=val,…"
// entries separated by ';'; the first one we can speak is used), runs SASL
// EXTERNAL, optionally negotiates fd passing, and calls Hello.
connect_address :: proc(address: string, allocator := context.allocator, want_unix_fds := true, timeout_ms := DEFAULT_TIMEOUT_MS) -> (^Connection, Error) {
	path, abstract, aok := parse_address(address)
	if !aok do return nil, .Bad_Address
	sock, serr := socket_connect(path, abstract)
	if serr != .None do return nil, serr
	conn := connect_fd(sock, allocator)
	deadline := time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	if err := sasl(conn, want_unix_fds, deadline); err != .None {
		disconnect(conn)
		return nil, err
	}
	if err := hello(conn, timeout_ms); err != .None {
		disconnect(conn)
		return nil, err
	}
	return conn, .None
}

// connect_fd wraps an already-connected, already-authenticated stream socket
// (a socketpair peer in tests, or a transport you authenticated yourself).
// No bytes are exchanged; call `hello` yourself if the peer is a bus. The
// connection owns fd and closes it in disconnect.
connect_fd :: proc(sock: linux.Fd, allocator := context.allocator) -> ^Connection {
	conn := new(Connection, allocator)
	conn.fd = sock
	conn.allocator = allocator
	conn.connected = true
	dbg := os.get_env("BALDR_DBUS_DEBUG", context.temp_allocator)
	conn.debug = dbg == "1" || dbg == "body"
	conn.debug_body = dbg == "body"
	conn.next_serial = 1
	conn.rbuf = make([dynamic]u8, allocator)
	conn.fds_in = make([dynamic]i32, allocator)
	conn.queued = make([dynamic]Raw_Message, allocator)
	conn.pending = make(map[u32]Pending, allocator)
	conn.handlers = make([dynamic]Signal_Handler, allocator)
	conn.next_handler = 1
	_ = virtual.arena_init_growing(&conn.arena)
	return conn
}

// hello performs org.freedesktop.DBus.Hello and records the unique name.
// Required exactly once on a bus connection before anything else.
hello :: proc(conn: ^Connection, timeout_ms := DEFAULT_TIMEOUT_MS) -> Error {
	m := method_call(DBUS_SERVICE, DBUS_PATH, DBUS_INTERFACE, "Hello")
	reply, err := call(conn, &m, timeout_ms, context.temp_allocator)
	if err != .None do return err
	if len(reply.body) != 1 do return .Protocol
	name, ok := as_string(reply.body[0])
	if !ok || !bus_name_valid(name) do return .Protocol
	conn.unique_name = strings.clone(name, conn.allocator)
	return .None
}

// disconnect closes the socket, fails every outstanding call_async with
// .Disconnected, closes received-but-unclaimed fds, and frees the
// connection. Never call it from inside a callback of this connection.
disconnect :: proc(conn: ^Connection) {
	if conn == nil do return
	mark_disconnected(conn)
	if conn.fd >= 0 do linux.close(conn.fd)
	conn.fd = -1
	for fdv in conn.fds_in do linux.close(linux.Fd(fdv))
	for &q in conn.queued do raw_free(conn, &q)
	for h in conn.handlers do handler_free(conn, h)
	delete(conn.unique_name, conn.allocator)
	delete(conn.server_guid, conn.allocator)
	delete(conn.rbuf)
	delete(conn.fds_in)
	delete(conn.queued)
	delete(conn.pending)
	delete(conn.handlers)
	virtual.arena_destroy(&conn.arena)
	free(conn, conn.allocator)
}

// fd returns the socket for poll/epoll integration: when it is readable,
// call dispatch. -1 once disconnected.
fd :: proc(conn: ^Connection) -> linux.Fd {
	if conn == nil do return -1
	return conn.fd
}

// unique_name_of is the name the bus gave this connection (":1.42"), which
// is how anything else addresses our objects. "" before hello.
unique_name_of :: proc(conn: ^Connection) -> string {
	return conn.unique_name if conn != nil else ""
}

// is_connected reports whether the socket is still usable.
is_connected :: proc(conn: ^Connection) -> bool {
	return conn != nil && conn.connected
}

// next_serial hands out the next message serial (never 0). Public so callers
// can mint unique tokens (portal handle_token) tied to this connection.
next_serial :: proc(conn: ^Connection) -> u32 {
	s := conn.next_serial
	conn.next_serial += 1
	if conn.next_serial == 0 do conn.next_serial = 1
	return s
}

// ------------------------------------------------------------------ address

// parse_address picks the first usable entry of a D-Bus address string.
@(private)
parse_address :: proc(address: string) -> (path: string, abstract: bool, ok: bool) {
	rest := address
	for len(rest) > 0 {
		entry := rest
		if i := strings.index_byte(rest, ';'); i >= 0 {
			entry = rest[:i]
			rest = rest[i + 1:]
		} else {
			rest = ""
		}
		colon := strings.index_byte(entry, ':')
		if colon < 0 || entry[:colon] != "unix" do continue
		kvs := entry[colon + 1:]
		for len(kvs) > 0 {
			kv := kvs
			if i := strings.index_byte(kvs, ','); i >= 0 {
				kv = kvs[:i]
				kvs = kvs[i + 1:]
			} else {
				kvs = ""
			}
			eq := strings.index_byte(kv, '=')
			if eq < 0 do continue
			key, val := kv[:eq], unescape_address(kv[eq + 1:])
			switch key {
			case "path":
				if val != "" do return val, false, true
			case "abstract":
				if val != "" do return val, true, true
			case "runtime":
				if val == "yes" {
					rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
					if rt != "" do return fmt.tprintf("%s/bus", rt), false, true
				}
			}
		}
	}
	return "", false, false
}

// unescape_address decodes %XX escapes (into the temp allocator when needed).
@(private)
unescape_address :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			hi, hok := hex_nibble(s[i + 1])
			lo, lok := hex_nibble(s[i + 2])
			if hok && lok {
				append(&out, hi << 4 | lo)
				i += 2
				continue
			}
		}
		append(&out, s[i])
	}
	return string(out[:])
}

@(private)
hex_nibble :: proc(c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9': return c - '0', true
	case c >= 'a' && c <= 'f': return c - 'a' + 10, true
	case c >= 'A' && c <= 'F': return c - 'A' + 10, true
	}
	return 0, false
}

// socket_connect opens SOCK_STREAM|CLOEXEC and connects to a filesystem or
// abstract Unix address, passing the exact address length (an abstract name
// padded with NULs would be a different name).
@(private)
socket_connect :: proc(path: string, abstract: bool) -> (linux.Fd, Error) {
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	n := len(path)
	if n == 0 || n > len(addr.sun_path) - (2 if abstract else 1) do return -1, .Bad_Address
	off := 0
	if abstract {
		addr.sun_path[0] = 0
		off = 1
	}
	copy(addr.sun_path[off:], path)
	length := size_of(addr.sun_family) + off + n
	if !abstract do length += 1 // trailing NUL

	sock, serr := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if serr != .NONE do return -1, .Socket
	ret := linux.syscall(linux.SYS_connect, sock, &addr, uintptr(length))
	if ret < 0 {
		linux.close(sock)
		return -1, .Socket
	}
	return sock, .None
}

// ------------------------------------------------------------------ SASL

// sasl runs "\0 AUTH EXTERNAL <hex uid>" → OK, optional NEGOTIATE_UNIX_FD,
// BEGIN. Any line we do not understand is a protocol error.
@(private)
sasl :: proc(conn: ^Connection, want_unix_fds: bool, deadline: time.Tick) -> Error {
	uid := fmt.tprintf("%d", u32(linux.getuid()))
	hex := make([]u8, len(uid) * 2, context.temp_allocator)
	digits := "0123456789abcdef"
	for c, i in transmute([]u8)uid {
		hex[2 * i] = digits[c >> 4]
		hex[2 * i + 1] = digits[c & 15]
	}
	if err := write_all(conn, transmute([]u8)fmt.tprintf("\x00AUTH EXTERNAL %s\r\n", string(hex)), nil); err != .None do return err
	for {
		line, lerr := read_line(conn, deadline)
		if lerr != .None do return lerr
		switch {
		case strings.has_prefix(line, "OK "):
			conn.server_guid = strings.clone(strings.trim_space(line[3:]), conn.allocator)
		case strings.has_prefix(line, "DATA"):
			if err := write_all(conn, transmute([]u8)string("DATA\r\n"), nil); err != .None do return err
			continue
		case strings.has_prefix(line, "REJECTED"), strings.has_prefix(line, "ERROR"):
			return .Auth
		case:
			return .Protocol
		}
		break
	}
	if want_unix_fds {
		if err := write_all(conn, transmute([]u8)string("NEGOTIATE_UNIX_FD\r\n"), nil); err != .None do return err
		line, lerr := read_line(conn, deadline)
		if lerr != .None do return lerr
		switch {
		case strings.has_prefix(line, "AGREE_UNIX_FD"): conn.unix_fd_ok = true
		case strings.has_prefix(line, "ERROR"):         conn.unix_fd_ok = false
		case:                                           return .Protocol
		}
	}
	return write_all(conn, transmute([]u8)string("BEGIN\r\n"), nil)
}

// read_line returns the next CRLF-terminated line (without CRLF) from the
// stream, blocking up to `deadline`. Only used during SASL, when the peer
// sends nothing but lines. The returned string aliases rbuf: use it now.
@(private)
read_line :: proc(conn: ^Connection, deadline: time.Tick) -> (string, Error) {
	for {
		live := conn.rbuf[conn.rpos:]
		if i := strings.index(string(live), "\r\n"); i >= 0 {
			line := string(live[:i])
			conn.rpos += i + 2
			return line, .None
		}
		if len(live) > 4096 do return "", .Protocol
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return "", .Timeout
		readable, perr := wait_readable(conn, i32(max(left / time.Millisecond, 1)))
		if perr != .None do return "", perr
		if !readable do return "", .Timeout
		if err := read_available(conn); err != .None do return "", err
	}
}

// ------------------------------------------------------------------ I/O

// wait_readable polls the socket for up to timeout_ms (-1 = forever).
// Returns false on timeout. Use it in a spike; a real pump polls `fd`
// alongside its other descriptors.
wait_readable :: proc(conn: ^Connection, timeout_ms: i32) -> (bool, Error) {
	if !is_connected(conn) do return false, .Not_Connected
	fds := [1]linux.Poll_Fd{{fd = conn.fd, events = {.IN}}}
	n, perr := linux.poll(fds[:], timeout_ms)
	if perr == .EINTR do return false, .None
	if perr != .NONE do return false, .Socket
	if n == 0 do return false, .None
	if fds[0].revents & {.HUP, .ERR} != {} && .IN not_in fds[0].revents {
		mark_disconnected(conn)
		return false, .Disconnected
	}
	return true, .None
}

// write_all sends bytes (blocking) with optional SCM_RIGHTS fds on the first
// chunk. EPIPE/ECONNRESET mark the connection disconnected.
@(private)
write_all :: proc(conn: ^Connection, bytes: []u8, fds: []i32) -> Error {
	if !is_connected(conn) do return .Not_Connected
	off := 0
	first := true
	for off < len(bytes) {
		left := len(bytes) - off
		remaining := uint(left)
		iov := [1]linux.IO_Vec{{base = raw_data(bytes[off:]), len = remaining}}
		hdr := linux.Msg_Hdr{iov = iov[:]}
		ctrl: [CMSG_HDR_SIZE + 8 * 64]u8
		if first && len(fds) > 0 {
			if len(fds) > 64 || !conn.unix_fd_ok do return .Invalid_Message
			clen := CMSG_HDR_SIZE + 4 * len(fds)
			(^uint)(&ctrl[0])^ = uint(clen)
			(^i32)(&ctrl[8])^ = SOL_SOCKET
			(^i32)(&ctrl[12])^ = SCM_RIGHTS
			copy(ctrl[CMSG_HDR_SIZE:], slice.to_bytes(fds))
			hdr.control = ctrl[:(clen + 7) &~ 7]
		}
		first = false
		n, err := linux.sendmsg(conn.fd, &hdr, {.NOSIGNAL})
		if err == .EINTR do continue
		if err == .EPIPE || err == .ECONNRESET {
			mark_disconnected(conn)
			return .Disconnected
		}
		if err != .NONE || n <= 0 do return .Socket
		off += n
	}
	return .None
}

@(private) CMSG_HDR_SIZE :: 16 // size_t len + int level + int type (x86-64 / arm64)
@(private) SOL_SOCKET :: i32(1)
@(private) SCM_RIGHTS :: i32(1)

// read_available drains the socket without blocking (MSG_DONTWAIT), appending
// to rbuf and collecting SCM_RIGHTS fds. Returns .Disconnected on EOF.
@(private)
read_available :: proc(conn: ^Connection) -> Error {
	if !is_connected(conn) do return .Not_Connected
	if conn.rpos > 0 && conn.rpos >= len(conn.rbuf) / 2 {
		copy(conn.rbuf[:], conn.rbuf[conn.rpos:])
		mem.zero_slice(conn.rbuf[len(conn.rbuf) - conn.rpos:]) // messages read: a password or a secret may have been one
		resize(&conn.rbuf, len(conn.rbuf) - conn.rpos)
		conn.rpos = 0
	}
	chunk: [16384]u8
	ctrl: [1024]u8
	for {
		chunk_len := uint(len(chunk))
		iov := [1]linux.IO_Vec{{base = raw_data(chunk[:]), len = chunk_len}}
		hdr := linux.Msg_Hdr{iov = iov[:], control = ctrl[:]}
		n, err := linux.recvmsg(conn.fd, &hdr, {.DONTWAIT, .CMSG_CLOEXEC})
		if err == .EINTR do continue
		if err == .EAGAIN do return .None
		if err == .ECONNRESET || n == 0 {
			mark_disconnected(conn)
			return .Disconnected
		}
		if err != .NONE do return .Socket
		collect_fds(conn, hdr.control)
		append(&conn.rbuf, ..chunk[:n])
		if len(conn.rbuf) - conn.rpos > MAX_MESSAGE_LEN + 16 {
			mark_disconnected(conn)
			return .Protocol
		}
		if n < len(chunk) do return .None
	}
}

// collect_fds walks the control buffer recvmsg filled in for SCM_RIGHTS.
@(private)
collect_fds :: proc(conn: ^Connection, ctrl: []u8) {
	off := 0
	for off + CMSG_HDR_SIZE <= len(ctrl) {
		clen := int((^uint)(&ctrl[off])^)
		if clen < CMSG_HDR_SIZE || off + clen > len(ctrl) do return
		level := (^i32)(&ctrl[off + 8])^
		typ := (^i32)(&ctrl[off + 12])^
		if level == SOL_SOCKET && typ == SCM_RIGHTS {
			count := (clen - CMSG_HDR_SIZE) / 4
			for i := 0; i < count; i += 1 {
				fdv := (^i32)(&ctrl[off + CMSG_HDR_SIZE + 4 * i])^
				if conn.unix_fd_ok do append(&conn.fds_in, fdv)
				else do linux.close(linux.Fd(fdv))
			}
		}
		off += (clen + 7) &~ 7
	}
}

@(private)
mark_disconnected :: proc(conn: ^Connection) {
	if !conn.connected do return
	conn.connected = false
	// Fail outstanding async calls. Copy first: callbacks may touch the map.
	failed := make([dynamic]Pending, context.temp_allocator)
	for _, p in conn.pending do append(&failed, p)
	clear(&conn.pending)
	for p in failed do if p.cb != nil do p.cb(conn, nil, .Disconnected, p.user)
}

// next_message frames one complete message from rbuf, decodes it into
// `allocator`, and detaches its fds from fds_in. have=false when the buffer
// holds no complete message. A frame that cannot be told apart from the next
// disconnects (.Protocol); a message that frames but will not decode is
// dropped alone.
@(private)
next_message :: proc(conn: ^Connection, allocator: runtime.Allocator) -> (raw: Raw_Message, m: Message, have: bool, err: Error) {
	for {
		live := conn.rbuf[conn.rpos:]
		total, st := frame_length(live)
		switch st {
		case .Incomplete:
			return {}, {}, false, .None
		case .Bad:
			mark_disconnected(conn)
			return {}, {}, false, .Protocol
		case .Ok:
		}
		if total > len(live) do return {}, {}, false, .None
		bytes := make([]u8, total, conn.allocator)
		copy(bytes, live[:total])
		conn.rpos += total
		if conn.debug do hexdump(conn, "recv", bytes)
		dm, derr := decode_message(bytes, allocator, conn.fds_in[:])
		if derr != .None {
			// The bus checks every message against the specification, so one
			// that fails here is past our own limits (MAX_ARRAY_ITEMS), which
			// any process on the bus can send: it costs that message, not the
			// connection. Descriptors that came with it go too; it no longer
			// says how many were its own.
			mem.zero_slice(bytes)
			delete(bytes, conn.allocator)
			for fdv in conn.fds_in do linux.close(linux.Fd(fdv))
			clear(&conn.fds_in)
			continue
		}
		nfds := len(dm.fds)
		fds: []i32
		if nfds > 0 {
			fds = slice.clone(conn.fds_in[:nfds], conn.allocator)
			remove_range(&conn.fds_in, 0, nfds)
			dm.fds = fds
		}
		return Raw_Message{bytes = bytes, fds = fds}, dm, true, .None
	}
}

@(private)
raw_free :: proc(conn: ^Connection, r: ^Raw_Message) {
	mem.zero_slice(r.bytes) // as the read buffer is
	delete(r.bytes, conn.allocator)
	for fdv in r.fds do linux.close(linux.Fd(fdv))
	delete(r.fds, conn.allocator)
	r^ = {}
}

// hexdump prints a message's fixed header and header fields, and its body
// only with BALDR_DBUS_DEBUG=body: a debug log is pasted into bug reports,
// and a body carries passwords and keyring secrets.
@(private)
hexdump :: proc(conn: ^Connection, tag: string, bytes: []u8) {
	shown := bytes
	if !conn.debug_body && len(bytes) >= 16 {
		fields := u32(bytes[12]) | u32(bytes[13]) << 8 | u32(bytes[14]) << 16 | u32(bytes[15]) << 24
		if bytes[0] == 'B' do fields = u32(bytes[15]) | u32(bytes[14]) << 8 | u32(bytes[13]) << 16 | u32(bytes[12]) << 24
		head := 16 + ((int(fields) + 7) &~ 7)
		if head < len(bytes) do shown = bytes[:head]
	}
	fmt.eprintf("dbus %s %d bytes:", tag, len(bytes))
	for b, i in shown {
		if i % 32 == 0 do fmt.eprintf("\n  ")
		fmt.eprintf("%02x", b)
	}
	if len(shown) < len(bytes) do fmt.eprintf("\n  (body of %d bytes not shown; BALDR_DBUS_DEBUG=body shows it)", len(bytes) - len(shown))
	fmt.eprintln()
}

// ------------------------------------------------------------------ send / call

// send encodes and writes m, assigning its serial (returned). Fire-and-
// forget; set .No_Reply_Expected in m.flags for method calls you will not
// wait for so the bus does not synthesise replies.
send :: proc(conn: ^Connection, m: ^Message) -> (serial: u32, err: Error) {
	if !is_connected(conn) do return 0, .Not_Connected
	if len(m.fds) > 0 && !conn.unix_fd_ok do return 0, .Invalid_Message
	m.serial = next_serial(conn)
	bytes, eerr := encode_message(m, context.temp_allocator)
	if eerr != .None do return 0, eerr
	if conn.debug do hexdump(conn, "send", bytes)
	werr := write_all(conn, bytes, m.fds)
	mem.zero_slice(bytes) // what was sent may have been a secret
	if werr != .None do return 0, werr
	return m.serial, .None
}

// call sends m and blocks until its reply arrives or timeout_ms passes.
// The reply (METHOD_RETURN, or ERROR with err = .Remote) is decoded into
// `allocator`; its fds are yours to close. Other messages that arrive
// meanwhile are queued for the next `dispatch`, so signal handlers never run
// from inside call. Failure modes: .Timeout (a late reply is dropped),
// .Disconnected, .Protocol, encode errors.
call :: proc(conn: ^Connection, m: ^Message, timeout_ms: i32 = DEFAULT_TIMEOUT_MS, allocator := context.allocator) -> (reply: Message, err: Error) {
	serial, serr := send(conn, m)
	if serr != .None do return {}, serr
	deadline := time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	arena := virtual.arena_allocator(&conn.arena)
	for {
		for {
			raw, dm, have, ferr := next_message(conn, arena)
			if ferr != .None do return {}, ferr
			if !have do break
			if (dm.type == .Method_Return || dm.type == .Error) && dm.reply_serial == serial {
				out, derr := decode_message(raw.bytes, allocator, raw.fds)
				if derr != .None {
					raw_free(conn, &raw)
					mark_disconnected(conn)
					return {}, .Protocol
				}
				out.fds = slice.clone(raw.fds, allocator)
				delete(raw.bytes, conn.allocator)
				delete(raw.fds, conn.allocator)
				return out, .Remote if out.type == .Error else .None
			}
			append(&conn.queued, raw)
		}
		left := time.tick_diff(time.tick_now(), deadline)
		if timeout_ms >= 0 && left <= 0 do return {}, .Timeout
		wait_ms := i32(-1) if timeout_ms < 0 else i32(max(left / time.Millisecond, 1))
		readable, perr := wait_readable(conn, wait_ms)
		if perr != .None do return {}, perr
		if readable {
			if rerr := read_available(conn); rerr != .None do return {}, rerr
		}
	}
}

// call_async sends m and later invokes cb from `dispatch` with the reply.
// The callback also fires with .Disconnected if the connection dies first.
call_async :: proc(conn: ^Connection, m: ^Message, cb: Reply_Callback, user: rawptr) -> (serial: u32, err: Error) {
	serial, err = send(conn, m)
	if err != .None do return 0, err
	conn.pending[serial] = Pending{cb = cb, user = user}
	return serial, .None
}

// error_text returns the human-readable string of an ERROR reply ("" if
// the body has none).
error_text :: proc(m: ^Message) -> string {
	if m == nil || m.type != .Error || len(m.body) == 0 do return ""
	s, _ := as_string(m.body[0])
	return s
}

// ------------------------------------------------------------------ signals

// add_match asks the bus to route signals matching `rule` (e.g.
// "type='signal',interface='org.freedesktop.portal.Settings'") to us.
// Blocking; .Remote if the bus rejects the rule.
add_match :: proc(conn: ^Connection, rule: string, timeout_ms := DEFAULT_TIMEOUT_MS) -> Error {
	body := [1]Value{rule}
	m := method_call(DBUS_SERVICE, DBUS_PATH, DBUS_INTERFACE, "AddMatch", body[:])
	_, err := call(conn, &m, timeout_ms, context.temp_allocator)
	return err
}

// remove_match undoes add_match. Fire-and-forget (errors are not reported).
remove_match :: proc(conn: ^Connection, rule: string) -> Error {
	body := [1]Value{rule}
	m := method_call(DBUS_SERVICE, DBUS_PATH, DBUS_INTERFACE, "RemoveMatch", body[:])
	m.flags = {.No_Reply_Expected}
	_, err := send(conn, &m)
	return err
}

// on_signal registers cb for SIGNAL messages whose interface/member (and
// path/sender when non-empty) all match. Handlers only see signals the bus
// routes to us: pair with add_match. Note that `sender` is compared with the
// message's unique name (":1.7"), not a well-known name. Returns 0 if conn
// is nil.
on_signal :: proc(conn: ^Connection, interface, member: string, cb: Signal_Callback, user: rawptr, path := "", sender := "") -> Handler_Id {
	if conn == nil || cb == nil do return 0
	id := conn.next_handler
	conn.next_handler += 1
	append(&conn.handlers, Signal_Handler{
		id        = id,
		interface = strings.clone(interface, conn.allocator),
		member    = strings.clone(member, conn.allocator),
		path      = strings.clone(path, conn.allocator),
		sender    = strings.clone(sender, conn.allocator),
		cb        = cb,
		user      = user,
	})
	return id
}

// off_signal removes a handler. Safe from inside any callback (the removal
// takes effect after the current dispatch pass).
off_signal :: proc(conn: ^Connection, id: Handler_Id) {
	if conn == nil do return
	for &h, i in conn.handlers {
		if h.id != id do continue
		if conn.in_dispatch > 0 {
			h.dead = true
		} else {
			handler_free(conn, h)
			ordered_remove(&conn.handlers, i)
		}
		return
	}
}

@(private)
handler_free :: proc(conn: ^Connection, h: Signal_Handler) {
	delete(h.interface, conn.allocator)
	delete(h.member, conn.allocator)
	delete(h.path, conn.allocator)
	delete(h.sender, conn.allocator)
}

// ------------------------------------------------------------------ serving

// serve makes this connection answer method calls: `cb` sees every call
// addressed to us and says whether it answered. One callback per connection
// (an object tree routes by path itself); nil stops serving, and every call
// is answered UnknownMethod.
serve :: proc(conn: ^Connection, cb: Method_Callback, user: rawptr) {
	if conn == nil do return
	conn.serve_cb, conn.serve_user = cb, user
}

// reply answers `call` with `body` (a method_return).
reply :: proc(conn: ^Connection, call: ^Message, body: []Value = nil) -> Error {
	m := method_return(call, body)
	_, err := send(conn, &m)
	// A reply that cannot be encoded (a string that is not UTF-8, which the
	// wire format forbids) still answers: a caller left with no reply waits
	// out its whole timeout, 25 s for most clients.
	if err == .Invalid_Message || err == .Too_Large {
		e := error_reply(call, "org.freedesktop.DBus.Error.Failed", "the reply could not be encoded", context.temp_allocator)
		send(conn, &e)
	}
	return err
}

// reply_error answers `call` with a D-Bus error name and message.
reply_error :: proc(conn: ^Connection, call: ^Message, name, text: string) -> Error {
	m := error_reply(call, name, text, context.temp_allocator)
	_, err := send(conn, &m)
	return err
}

// emit broadcasts a signal from `path`.
emit :: proc(conn: ^Connection, path, interface, member: string, body: []Value = nil) -> Error {
	m := signal(path, interface, member, body)
	_, err := send(conn, &m)
	return err
}

// ------------------------------------------------------------------ dispatch

// dispatch reads everything the socket has without blocking and delivers
// it: replies to call_async callbacks, signals to matching handlers, and
// an UnknownMethod error to anyone calling a method on us. Returns how many
// messages were handled. Call it whenever `fd` polls readable (and once
// after any `call`, which may have queued messages). Errors: .Disconnected
// (EOF), .Protocol (malformed frame; connection closed), .Socket.
dispatch :: proc(conn: ^Connection) -> (n: int, err: Error) {
	if conn == nil do return 0, .Not_Connected
	conn.in_dispatch += 1
	defer {
		conn.in_dispatch -= 1
		if conn.in_dispatch == 0 do compact_handlers(conn)
	}
	if conn.in_dispatch == 1 do virtual.arena_free_all(&conn.arena)
	arena := virtual.arena_allocator(&conn.arena)

	// Messages set aside by a blocking call.
	for len(conn.queued) > 0 {
		raw := conn.queued[0]
		ordered_remove(&conn.queued, 0)
		m, derr := decode_message(raw.bytes, arena, raw.fds)
		if derr != .None { // dropped alone, as next_message does
			raw_free(conn, &raw)
			continue
		}
		route(conn, &m)
		raw_free(conn, &raw)
		n += 1
	}
	if !conn.connected do return n, .Disconnected
	if rerr := read_available(conn); rerr != .None && rerr != .Disconnected do return n, rerr
	for {
		raw, m, have, ferr := next_message(conn, arena)
		if ferr != .None do return n, ferr
		if !have do break
		route(conn, &m)
		raw_free(conn, &raw)
		n += 1
	}
	if !conn.connected do return n, .Disconnected
	return n, .None
}

@(private)
route :: proc(conn: ^Connection, m: ^Message) {
	switch m.type {
	case .Method_Return, .Error:
		p, ok := conn.pending[m.reply_serial]
		if !ok do return
		delete_key(&conn.pending, m.reply_serial)
		if p.cb != nil do p.cb(conn, m, .Remote if m.type == .Error else .None, p.user)
	case .Signal:
		for i := 0; i < len(conn.handlers); i += 1 {
			h := conn.handlers[i]
			if h.dead do continue
			if h.interface != "" && h.interface != m.interface do continue
			if h.member != "" && h.member != m.member do continue
			if h.path != "" && h.path != m.path do continue
			if h.sender != "" && h.sender != m.sender do continue
			h.cb(conn, m, h.user)
		}
	case .Method_Call:
		if conn.serve_cb != nil && conn.serve_cb(conn, m, conn.serve_user) do return // an object of ours answered it
		if .No_Reply_Expected in m.flags do return
		text := fmt.tprintf("Method %q on interface %q is not implemented by this client", m.member, m.interface)
		reply := error_reply(m, ERROR_UNKNOWN_METHOD, text, context.temp_allocator)
		_, _ = send(conn, &reply)
	case .Invalid:
	}
}

@(private)
compact_handlers :: proc(conn: ^Connection) {
	for i := 0; i < len(conn.handlers); {
		if conn.handlers[i].dead {
			handler_free(conn, conn.handlers[i])
			ordered_remove(&conn.handlers, i)
		} else {
			i += 1
		}
	}
}
