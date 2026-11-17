package baldr

// File IO as commands: `read_file` and `write_file` return at once and
// the outcome arrives as a message. The work runs on one IO thread with
// its own core:nbio event loop (io_uring / IOCP / kqueue), started the
// first time it is needed; where nbio cannot run (io_uring locked down)
// each operation falls back to a thread of its own with blocking calls.
// Either way the run loop never waits on a disk.

import "base:runtime"
import "core:fmt"
import "core:nbio"
import "core:os"
import "core:sync"
import "core:thread"

// File_Read is a read's outcome. `data` lives only while the message is
// handled — clone what you keep. `error` names what failed when not ok.
File_Read :: struct {
	path:  string,
	data:  []u8,
	ok:    bool,
	error: string,
}

// File_Written is a write's outcome.
File_Written :: struct {
	path:  string,
	ok:    bool,
	error: string,
}

// read_file reads all of `path` off the main thread; the handler gets
// File_Read (with `tag`) when it is done.
//
//	case Open: return baldr.read_file(Msg, v.path, proc(e: baldr.Ev(baldr.File_Read)) -> Msg { return Loaded{e.value} })
read_file :: proc($Msg: typeid, path: string, on_done: Handler(Msg, File_Read), tag: u64 = 0) -> Cmd(Msg) {
	return {kind = .Read_File, path = temp_clone(path), on_read = on_done, tag = tag}
}

// write_file replaces `path` with `data` (created when missing) off the
// main thread; the handler gets File_Written (with `tag`) when it is
// done. `data` is copied.
write_file :: proc($Msg: typeid, path: string, data: []u8, on_done: Handler(Msg, File_Written) = nil, tag: u64 = 0) -> Cmd(Msg) {
	bytes := make([]u8, len(data), context.temp_allocator) // the command outlives the update it was written in
	copy(bytes, data)
	return {kind = .Write_File, path = temp_clone(path), bytes = bytes, on_write = on_done, tag = tag}
}

// ------------------------------------------------------------- runtime

// File_Op is one read or write in flight; its outcome is posted to the
// mailbox and the handle freed once the message was handled.
@(private)
File_Op :: struct($Msg: typeid) {
	write:    bool,
	path:     string, // owned
	data:     []u8,   // owned: what was read, or what to write
	error:    string, // owned
	ok:       bool,
	tag:      u64,
	on_read:  Handler(Msg, File_Read),
	on_write: Handler(Msg, File_Written),
	mailbox:  ^Mailbox(Msg),
	io:       ^Io,   // the thread it was handed to, nil when a fallback thread ran it
	filled:   int,   // a read: how much of `data` holds the file so far
	handle:   nbio.Handle,
	allocator: runtime.Allocator, // the caller's: everything the op owns comes from it, on whichever thread
}

// Io is the IO thread: one nbio event loop, ticked while operations are
// in flight and parked on `wake` when none are.
@(private)
Io :: struct {
	thread:   ^thread.Thread,
	loop:     ^nbio.Event_Loop,
	loop_mu:  sync.Mutex, // held while the thread gives the loop up: a stop never wakes one that has gone
	ready:    sync.Sema,
	wake:     sync.Sema, // posted when an operation is handed over, and to stop
	inflight: int,       // handed to the loop, outcome not posted yet
	ticks:    int,       // how often the thread went round; the tests watch it for a spin
	stop:     bool,
	ok:       bool, // the loop is running
	tried:    bool,
}

// io_began and io_done bracket one operation on the loop: the count is
// what tells the IO thread whether there is anything to tick for.
@(private)
io_began :: proc(io: ^Io) {
	sync.atomic_add(&io.inflight, 1)
	sync.sema_post(&io.wake)
}

@(private)
io_done :: proc(io: ^Io) {
	if io == nil do return // a fallback thread ran it; the loop never saw it
	sync.atomic_sub(&io.inflight, 1)
}

// io_start brings the IO thread up once; false when nbio cannot run here.
@(private)
io_start :: proc(io: ^Io) -> bool {
	if io.tried do return io.ok
	io.tried = true
	io.thread = thread.create_and_start_with_data(io, io_main)
	if io.thread == nil do return false
	sync.sema_wait(&io.ready)
	return io.ok
}

@(private)
io_main :: proc(p: rawptr) {
	io := (^Io)(p)
	if err := nbio.acquire_thread_event_loop(); err != nil {
		sync.sema_post(&io.ready)
		return
	}
	io.loop = nbio.current_thread_event_loop()
	io.ok = true
	sync.sema_post(&io.ready)
	tidied := false
	for !sync.atomic_load(&io.stop) {
		sync.atomic_add(&io.ticks, 1)
		if sync.atomic_load(&io.inflight) == 0 {
			// Nothing in flight. nbio.tick only waits while the loop has work:
			// on Windows it returns at once when it has none, so waiting for
			// the next operation is ours to do, or the thread spins a core.
			// One last non-blocking tick first, for the tidying the loop
			// queues itself (read_entire_file closes the file it read).
			if !tidied {
				tidied = true
				if nbio.tick(0) != nil do break
				continue
			}
			sync.sema_wait(&io.wake)
			continue
		}
		tidied = false
		if nbio.tick(nbio.NO_TIMEOUT) != nil do break
	}
	sync.lock(&io.loop_mu)
	io.loop = nil // from here nobody may wake it
	sync.unlock(&io.loop_mu)
	nbio.release_thread_event_loop()
}

@(private)
io_stop :: proc(io: ^Io) {
	if io.thread == nil do return
	sync.atomic_store(&io.stop, true)
	sync.lock(&io.loop_mu) // the thread cannot give the loop up while this is held
	if io.loop != nil do nbio.wake_up(io.loop) // it may be ticking one
	sync.unlock(&io.loop_mu)
	sync.sema_post(&io.wake) // …or parked with nothing in flight
	thread.destroy(io.thread) // joins
	io.thread = nil
	io.ok = false
}

// file_read starts a read; the outcome reaches the mailbox as a file mail.
@(private)
file_read :: proc(io: ^Io, mb: ^Mailbox($Msg), jobs: ^[dynamic]^Job(Msg), path: string, on_done: Handler(Msg, File_Read), tag: u64) {
	op := new(File_Op(Msg))
	op.allocator = context.allocator
	op.path = clone_string(path)
	op.on_read = on_done
	op.tag = tag
	op.mailbox = mb
	if io_start(io) {
		// Read what is there, not what stat says: a file stat calls empty may
		// have contents (/proc, /sys), and one that grew since has more. The
		// buffer starts a byte past stat's size, so it is never empty (nbio
		// asserts on an empty read); a buffer that fills grows and reads on.
		on_open :: proc(o: ^nbio.Operation, op: ^File_Op(Msg)) { // IO thread, as are the four below
			if o.open.err != .None {
				op.error = fs_error_text(.Open, o.open.err, op.allocator)
				read_finish(op)
				return
			}
			op.handle = o.open.handle
			nbio.stat_poly(op.handle, op, on_stat)
		}
		on_stat :: proc(o: ^nbio.Operation, op: ^File_Op(Msg)) {
			if o.stat.err != .None || o.stat.type != .Regular {
				op.error = fs_error_text(.Stat, o.stat.err if o.stat.err != .None else .Unsupported, op.allocator)
				nbio.close_poly(op.handle, op, on_close)
				return
			}
			op.data = make([]u8, max(int(o.stat.size) + 1, FILE_READ_CHUNK), op.allocator)
			// One read at a time, and on_read asks for the next: nbio's own
			// `all = true` never calls back on Windows for a file shorter
			// than the buffer.
			nbio.read_poly(op.handle, 0, op.data, op, on_read)
		}
		on_read :: proc(o: ^nbio.Operation, op: ^File_Op(Msg)) {
			op.filled += o.read.read
			if o.read.err != .None && o.read.err != .EOF {
				op.error = fs_error_text(.Read, o.read.err, op.allocator)
				delete(op.data, op.allocator)
				op.data = nil
				nbio.close_poly(op.handle, op, on_close)
				return
			}
			// A read that stops short is not the end of the file — only EOF
			// (or nothing read at all) is. Asking again from where it stopped
			// is what makes one read at a time correct.
			if o.read.err != .EOF && o.read.read > 0 {
				if op.filled == len(op.data) { // full: there may be more
					grown := make([]u8, len(op.data) * 2, op.allocator)
					copy(grown, op.data)
					delete(op.data, op.allocator)
					op.data = grown
				}
				nbio.read_poly(op.handle, op.filled, op.data[op.filled:], op, on_read)
				return
			}
			op.data = op.data[:op.filled]
			op.ok = true
			nbio.close_poly(op.handle, op, on_close)
		}
		on_close :: proc(o: ^nbio.Operation, op: ^File_Op(Msg)) {
			read_finish(op)
		}
		read_finish :: proc(op: ^File_Op(Msg)) {
			io_done(op.io)
			mailbox_post(op.mailbox, Mail(Msg){file = op})
		}
		op.io = io
		io_began(io)
		nbio.open_poly(op.path, op, on_open, mode = {.Read}, l = io.loop)
		return
	}
	blocking :: proc(j: ^Job(Msg)) { // fallback thread
		op := (^File_Op(Msg))(j.data)
		op.data, op.ok, op.error = read_blocking(op.path, op.allocator)
		mailbox_post(op.mailbox, Mail(Msg){file = op})
	}
	file_fallback(mb, jobs, op, blocking)
}

// FILE_READ_CHUNK is the least a read's first buffer holds: what a file stat
// calls empty gets this much to read its contents into, if it has any.
@(private)
FILE_READ_CHUNK :: 4096

// file_write starts a write of `data` (copied) to `path`.
@(private)
file_write :: proc(io: ^Io, mb: ^Mailbox($Msg), jobs: ^[dynamic]^Job(Msg), path: string, data: []u8, on_done: Handler(Msg, File_Written), tag: u64) {
	op := new(File_Op(Msg))
	op.allocator = context.allocator
	op.write = true
	op.path = clone_string(path)
	op.data = make([]u8, len(data))
	copy(op.data, data)
	op.on_write = on_done
	op.tag = tag
	op.mailbox = mb
	if io_start(io) {
		on_open :: proc(o: ^nbio.Operation, op: ^File_Op(Msg)) { // IO thread, as are the two below
			if o.open.err != .None {
				op.error = fs_error_text(.Open, o.open.err, op.allocator)
				io_done(op.io)
				mailbox_post(op.mailbox, Mail(Msg){file = op})
				return
			}
			op.handle = o.open.handle
			if len(op.data) == 0 {
				op.ok = true
				nbio.close_poly(op.handle, op, on_close)
				return
			}
			nbio.write_poly(op.handle, 0, op.data, op, on_write)
		}
		on_write :: proc(o: ^nbio.Operation, op: ^File_Op(Msg)) {
			if o.write.err != .None {
				op.error = fs_error_text(.Write, o.write.err, op.allocator)
			} else {
				op.ok = true
			}
			nbio.close_poly(op.handle, op, on_close)
		}
		on_close :: proc(o: ^nbio.Operation, op: ^File_Op(Msg)) {
			io_done(op.io)
			mailbox_post(op.mailbox, Mail(Msg){file = op})
		}
		op.io = io
		io_began(io)
		nbio.open_poly(op.path, op, on_open, mode = {.Write, .Create, .Trunc}, l = io.loop)
		return
	}
	blocking :: proc(j: ^Job(Msg)) {
		op := (^File_Op(Msg))(j.data)
		op.ok, op.error = write_blocking(op.path, op.data, op.allocator)
		mailbox_post(op.mailbox, Mail(Msg){file = op})
	}
	file_fallback(mb, jobs, op, blocking)
}

// file_fallback runs the blocking form on a job thread; when even that
// fails the outcome is an error at once.
@(private)
file_fallback :: proc(mb: ^Mailbox($Msg), jobs: ^[dynamic]^Job(Msg), op: ^File_Op(Msg), work: proc(^Job(Msg))) {
	if j := job_start(mb, work, op, nil, 0); j != nil {
		append(jobs, j)
		return
	}
	op.error = clone_string("no thread for file io")
	mailbox_post(mb, Mail(Msg){file = op})
}

// fs_error_text names a failed step and its error, owned by the op.
@(private)
fs_error_text :: proc(stage: nbio.Operation_Type, err: nbio.FS_Error, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("%v: %v", stage, err, allocator = allocator)
}

// read_blocking / write_blocking are the fallback thread's plain calls.
@(private)
read_blocking :: proc(path: string, allocator: runtime.Allocator) -> (data: []u8, ok: bool, error: string) {
	err: os.Error
	data, err = os.read_entire_file_from_path(path, allocator)
	ok = err == nil
	if !ok do error = fmt.aprintf("%v", err, allocator = allocator)
	return
}

@(private)
write_blocking :: proc(path: string, data: []u8, allocator: runtime.Allocator) -> (ok: bool, error: string) {
	err := os.write_entire_file_from_bytes(path, data)
	ok = err == nil
	if !ok do error = fmt.aprintf("%v", err, allocator = allocator)
	return
}

@(private)
file_op_free :: proc(op: ^File_Op($Msg)) {
	delete(op.path, op.allocator)
	delete(op.data, op.allocator)
	delete(op.error, op.allocator)
	free(op, op.allocator)
}
