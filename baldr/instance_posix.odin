#+build linux, darwin
package baldr

// One instance of an app, and what a second launch does: not a second copy,
// but the first one showing its window and being told what the second was
// asked to open.
//
// Here that is a unix socket named after the app, in the run-time
// directory. Owning the socket is owning the instance: the second launch
// connects, hands over its arguments and exits, and the first hears them as
// a message. A socket left by a crash has nobody listening, so a refused
// connection means the path is stale and it is taken over. Not a lock file:
// that cannot carry the arguments, and telling a stale one from a live one
// by its pid is a race.
//
// The socket lives only in a folder this user owns and nobody else can
// enter, so whoever is listening, and whoever connects, is this user: no
// one else can claim the name first and be handed a launch's files.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Instance is the first copy's listening socket and the thread watching it.
@(private)
Instance :: struct {
	fd:     posix.FD,
	path:   string, // owned; unlinked on the way out
	stop:   bool,   // read by the thread between accepts
	worker: ^thread.Thread,
	alloc:  runtime.Allocator,
}

// instance_path is where the socket lives: in the run-time directory where
// there is one (Linux), the per-user temporary directory otherwise (macOS),
// and /tmp when a desktop offers neither — the folder itself when only this
// user can enter it, else a folder of our own inside it. "" when no private
// folder can be had, and then there is no single instance.
@(private)
instance_path :: proc(app_id: string, allocator := context.allocator) -> string {
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if base == "" do base = os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	return instance_path_in(base, app_id, allocator)
}

@(private)
instance_path_in :: proc(base: string, app_id: string, allocator := context.allocator) -> string {
	root := strings.trim_right(base, "/")
	dir := root
	if !dir_private(dir) {
		dir = fmt.tprintf("%s/baldr-%d", root, posix.geteuid())
		posix.mkdir(strings.clone_to_cstring(dir, context.temp_allocator), posix.S_IRWXU) // fails harmlessly when it is there
		if !dir_private(dir) do return ""
	}
	// The id is the app's own and may hold anything; a path separator in it
	// would put the socket somewhere else entirely.
	safe := strings.builder_make(context.temp_allocator)
	for r in app_id {
		if r == '/' || r == 0 {
			strings.write_rune(&safe, '_')
		} else {
			strings.write_rune(&safe, r)
		}
	}
	return strings.concatenate({dir, "/baldr-", strings.to_string(safe), ".sock"}, allocator)
}

// dir_private says whether a folder is this user's and closed to everyone
// else. lstat, so a link someone planted is not followed.
@(private = "file")
dir_private :: proc(path: string) -> bool {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK do return false
	return posix.S_ISDIR(st.st_mode) && st.st_uid == posix.geteuid() && st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) == {}
}

// instance_claim tries to become *the* instance of this app.
//
// `owner` is true when nothing else was listening and this copy now is.
// False means another copy owns it and has been handed `args`; the caller
// should exit quietly.
@(private)
instance_claim :: proc(app_id: string, args: []string, allocator := context.allocator) -> (inst: Instance, owner: bool) {
	path := instance_path(app_id, allocator)
	if path == "" do return {}, true // nowhere private for it: the app runs, as more than one copy
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) { // a path too long for the struct: no single instance
		delete(path, allocator)
		return {}, true
	}
	copy(addr.sun_path[:], transmute([]u8)path)

	// Is somebody listening? A refused connection means the file is stale.
	probe := posix.socket(.UNIX, .STREAM)
	if probe != -1 {
		if posix.connect(probe, (^posix.sockaddr)(&addr), size_of(addr)) == .OK {
			instance_tell(probe, args)
			posix.close(probe)
			delete(path, allocator)
			return {}, false
		}
		posix.close(probe)
	}

	posix.unlink(cpath) // stale, or never there
	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 {
		delete(path, allocator)
		return {}, true // no socket to be had: carry on rather than refuse to start
	}
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(fd, 8) != .OK {
		posix.close(fd)
		delete(path, allocator)
		return {}, true
	}
	// Non-blocking, so the thread notices `stop` between arrivals instead of
	// sitting in accept() and keeping a quitting app alive.
	flags := posix.fcntl(fd, .GETFL, 0)
	posix.fcntl(fd, .SETFL, flags | i32(posix.O_NONBLOCK))
	return Instance{fd = fd, path = path, alloc = allocator}, true
}

// instance_tell hands this launch's arguments to the copy already running,
// NUL between them, and closes. Nothing is read back: the first instance's
// business is its own.
@(private = "file")
instance_tell :: proc(fd: posix.FD, args: []string) {
	b := strings.builder_make(context.temp_allocator)
	for a, i in args {
		if i > 0 do strings.write_byte(&b, 0)
		strings.write_string(&b, a)
	}
	bytes := transmute([]u8)strings.to_string(b)
	sent := 0
	for sent < len(bytes) {
		n := posix.write(fd, raw_data(bytes[sent:]), uint(len(bytes)) - uint(sent))
		if n <= 0 do break
		sent += int(n)
	}
}

// instance_listen starts watching for later launches. Each one becomes a
// Relaunch carrying its arguments, through the same mailbox a job posts to,
// so the loop wakes for it like anything else.
@(private)
instance_listen :: proc(inst: ^Instance, mb: ^Mailbox($Msg), on: Handler(Msg, Relaunch)) {
	if inst.fd == -1 || inst.fd == 0 do return
	Watch :: struct($M: typeid) {
		inst: ^Instance,
		mb:   ^Mailbox(M),
		on:   Handler(M, Relaunch),
	}
	w := new(Watch(Msg), inst.alloc)
	w^ = {inst = inst, mb = mb, on = on}
	inst.worker = thread.create_and_start_with_data(rawptr(w), proc(data: rawptr) {
		w := (^Watch(Msg))(data)
		defer free(w, w.inst.alloc) // the thread owns it, and it ends here
		buf: [4096]u8
		for !sync.atomic_load(&w.inst.stop) {
			conn := posix.accept(w.inst.fd, nil, nil)
			if conn == -1 {
				time.sleep(100 * time.Millisecond) // nothing waiting; look again
				continue
			}
			// Blocking, with a bound: macOS hands the listener's non-blocking
			// mode on, which would read nothing from a launch that has not
			// written yet, and a launch that never writes must not hold this
			// thread, or the app's exit, for ever.
			cflags := posix.fcntl(conn, .GETFL, 0)
			posix.fcntl(conn, .SETFL, cflags &~ i32(posix.O_NONBLOCK))
			tv := posix.timeval{tv_sec = 1}
			posix.setsockopt(conn, posix.SOL_SOCKET, .RCVTIMEO, &tv, size_of(tv))
			n := 0
			for n < len(buf) {
				got := posix.read(conn, raw_data(buf[n:]), uint(len(buf) - n))
				if got <= 0 do break
				n += int(got)
			}
			posix.close(conn)
			// The main thread turns the op into a message and the mailbox
			// frees it once that update has run; app code never runs here.
			// The arguments are copied: `strings.split` slices into `buf`,
			// which this thread reuses, so the text would change under the
			// app and freeing it would free into the middle of a stack array.
			raw := strings.split(string(buf[:n]), "\x00", context.temp_allocator)
			op := new(Relaunch_Op(Msg), w.inst.alloc)
			op.args = make([]string, len(raw), w.inst.alloc)
			for part, i in raw do op.args[i] = strings.clone(part, w.inst.alloc)
			op.on = w.on
			op.allocator = w.inst.alloc
			mailbox_post(w.mb, Mail(Msg){relaunch = op})
		}
	})
}

@(private)
instance_stop :: proc(inst: ^Instance) {
	if inst.fd == -1 || inst.fd == 0 do return
	sync.atomic_store(&inst.stop, true)
	if inst.worker != nil {
		thread.join(inst.worker)
		thread.destroy(inst.worker)
	}
	posix.close(inst.fd)
	if len(inst.path) > 0 {
		posix.unlink(strings.clone_to_cstring(inst.path, context.temp_allocator))
		delete(inst.path, inst.alloc)
	}
	inst^ = {}
}

// Relaunch_Op is one later launch, waiting for the loop to turn it into the
// app's own message. Its memory is the mailbox's to free once the update
// that was handed it has run, since the message points into it.
@(private)
Relaunch_Op :: struct($Msg: typeid) {
	args:      []string,
	on:        Handler(Msg, Relaunch),
	allocator: runtime.Allocator,
}

@(private)
relaunch_op_free :: proc(op: ^Relaunch_Op($Msg)) {
	if op == nil do return
	a := op.allocator
	for s in op.args do delete(s, a)
	delete(op.args, a)
	free(op, a)
}
