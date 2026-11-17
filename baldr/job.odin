package baldr

// Background work. `job` runs a proc on a thread of its own; the proc
// gets a Job to `post` messages through (progress, results) and asks
// `cancelled` whether to stop; when it returns, `on_done` becomes a
// message. Every message reaches `update` on the main thread, so a
// worker never touches State and the view never waits on one. Posting
// wakes the run loop, which otherwise sleeps.

import "core:sync"
import "core:thread"
import "core:time"

// Job is a background job's handle, made by the runtime for the `job`
// command and given to the work proc. `data` is what the command passed;
// `tag` is echoed in the done message.
Job :: struct($Msg: typeid) {
	data:     rawptr,
	tag:      u64,
	mailbox:  ^Mailbox(Msg),
	on_done:  Handler(Msg, Job_Done),
	work:     proc(^Job(Msg)),
	thread:   ^thread.Thread,
	stop:     bool, // set by `cancel`, read by `cancelled` (atomically)
	finished: bool, // the work proc returned (atomically)
}

// Job_Done is a job's outcome: whether it was cancelled before the work
// returned. Results travel in the messages the job posted.
Job_Done :: struct {
	cancelled: bool,
}

// Mailbox carries messages from worker threads to the run loop.
Mailbox :: struct($Msg: typeid) {
	mu:        sync.Mutex,
	mail:      [dynamic]Mail(Msg),
	wake:      proc(user: rawptr), // interrupts the blocked run loop; nil in headless use
	wake_user: rawptr,
	finished:  [dynamic]^File_Op(Msg), // delivered file ops, freed by mailbox_release once handled
	secrets:   [dynamic]^Secret_Op(Msg), // …and delivered keychain calls, the same
	secret_queue: [dynamic]^Secret_Op(Msg), // keychain calls waiting their turn (secret.odin): one runs at a time
	secret_busy:  bool,                     // …and this says one is running now
	pictures:  [dynamic]^Picture_Op(Msg), // delivered pastes of pictures, the same
	relaunches: [dynamic]^Relaunch_Op(Msg), // …and later launches of this app (instance_*.odin), the same
	canvas_host:    ^Canvas_Host,                      // the runtime's Gpu, whose reads come back here (canvas.odin)
	canvas_waiting: map[u32]Canvas_Waiting(Msg),       // their handlers, by read
	canvas_bytes:   [dynamic][]u8,                     // delivered reads' texels, freed once handled
}

@(private)
Mail :: struct($Msg: typeid) {
	msg:  Msg,
	done: ^Job(Msg),     // set: the job's work returned (msg unused)
	file: ^File_Op(Msg), // set: a read or write finished (msg unused)
	secret: ^Secret_Op(Msg), // set: a keychain call finished (msg unused)
	picture: ^Picture_Op(Msg), // set: a paste of a picture finished (msg unused)
	relaunch: ^Relaunch_Op(Msg), // set: this app was launched again (msg unused)
	canvas:       bool, // the CPU reference's canvas reads are ready (msg unused)
	canvas_batch: u64,  // set: this GPU canvas batch is done (msg unused)
}

// How long quitting waits for workers to notice `cancelled`.
@(private)
JOB_QUIT_GRACE :: 1 * time.Second

// job runs `work` on a thread of its own. The worker posts progress and
// results as messages and returns when finished, or when `cancelled`
// says to stop; `on_done` (optional) then becomes a message carrying
// Job_Done and the job's `tag`. `data` is handed to the worker untouched:
// give it something the worker owns (and frees), never a pointer into
// State.
//
//	case Start: return baldr.job(Msg, transfer, new_clone(Req{url = v.url}), on_done = Msg(Finished{}), tag = v.id)
job :: proc($Msg: typeid, work: proc(^Job(Msg)), data: rawptr = nil, on_done: Handler(Msg, Job_Done) = nil, tag: u64 = 0) -> Cmd(Msg) {
	return {kind = .Job, work = work, data = data, on_done = on_done, tag = tag}
}

// cancel asks every running job with `tag` to stop: their `cancelled`
// turns true, and each one's done message reports it once the worker
// returns. A worker that never asks runs to its end.
cancel :: proc($Msg: typeid, tag: u64) -> Cmd(Msg) {
	return {kind = .Cancel, tag = tag}
}

// batch runs several commands from one update, in order.
//
//	return baldr.batch(Msg, baldr.job(Msg, transfer, a, tag = 1), baldr.job(Msg, transfer, b, tag = 2))
batch :: proc($Msg: typeid, cmds: ..Cmd(Msg)) -> Cmd(Msg) {
	if len(cmds) == 0 do return {}
	if len(cmds) == 1 do return cmds[0]
	list := make([]Cmd(Msg), len(cmds), context.temp_allocator) // a command outlives the update it was written in
	copy(list, cmds)
	return {kind = .Batch, list = list}
}

// post queues `m` for update from the worker thread and wakes the run
// loop. The message is copied; anything it points to must stay valid
// until update has handled it (heap-allocate strings and let update own
// them).
post :: proc(j: ^Job($Msg), m: Msg) {
	mailbox_post(j.mailbox, Mail(Msg){msg = m})
}

// Poster is a way into the run loop for code Baldr did not start: a C
// library calling back on its own thread (libmpv's wakeup, sd-bus,
// PipeWire). `post_from` queues a message from any thread and wakes the
// loop, as a job's `post` does — no polling job, no latency.
// Get one with the `poster` command. It is valid for the life of the
// process: a callback firing after the run has ended (between `run`
// returning and the library being shut down) posts nowhere, safely, so its
// few bytes are never freed.
Poster :: struct($Msg: typeid) {
	box: ^Poster_Box(Msg),
}

@(private)
Poster_Box :: struct($Msg: typeid) {
	mu:      sync.Mutex,
	mailbox: ^Mailbox(Msg), // nil once the run has ended
}

// poster makes a Poster and delivers it through `on_done`: keep it in State
// and hand it (as user data) to the library that calls back.
//
//	case Started: return baldr.poster(Msg, proc(e: baldr.Ev(baldr.Poster(Msg))) -> Msg { return Got_Poster{e.value} })
//	// on mpv's thread:  baldr.post_from(p, Msg(Mpv_Event{}))
poster :: proc($Msg: typeid, on_done: Handler(Msg, Poster(Msg))) -> Cmd(Msg) {
	return {kind = .Poster, on_poster = on_done}
}

// post_from queues `m` for update from any thread and wakes the run loop.
// The message is copied; what it points to must stay valid until update
// has handled it. False when the run has ended (nothing is delivered then)
// or the Poster is the zero value.
post_from :: proc(p: Poster($Msg), m: Msg) -> bool {
	if p.box == nil do return false
	sync.mutex_lock(&p.box.mu)
	defer sync.mutex_unlock(&p.box.mu)
	if p.box.mailbox == nil do return false
	mailbox_post(p.box.mailbox, Mail(Msg){msg = m})
	return true
}

// poster_shut: the run is ending; the Poster posts nowhere from now on.
@(private)
poster_shut :: proc(box: ^Poster_Box($Msg)) {
	sync.mutex_lock(&box.mu)
	box.mailbox = nil
	sync.mutex_unlock(&box.mu)
}

// cancelled is true once `cancel` was asked for the job or the app is
// quitting; a worker checks it between steps and returns.
cancelled :: proc(j: ^Job($Msg)) -> bool {
	return sync.atomic_load(&j.stop)
}

// ------------------------------------------------------------- runtime

// job_start begins the job's thread; nil when no thread could be made.
@(private)
job_start :: proc(mb: ^Mailbox($Msg), work: proc(^Job(Msg)), data: rawptr, on_done: Handler(Msg, Job_Done), tag: u64) -> ^Job(Msg) {
	if work == nil do return nil
	j := new(Job(Msg))
	j.mailbox = mb
	j.work = work
	j.data = data
	j.on_done = on_done
	j.tag = tag
	job_main :: proc(p: rawptr) {
		j := (^Job(Msg))(p)
		j.work(j)
		sync.atomic_store(&j.finished, true)
		mailbox_post(j.mailbox, Mail(Msg){done = j}) // last: nothing posted after this is delivered
	}
	j.thread = thread.create_and_start_with_data(j, job_main)
	if j.thread == nil {
		free(j)
		return nil
	}
	return j
}

@(private)
job_stop :: proc(j: ^Job($Msg)) {
	sync.atomic_store(&j.stop, true)
}

// job_reap joins the finished job's thread and frees the handle.
@(private)
job_reap :: proc(jobs: ^[dynamic]^Job($Msg), j: ^Job(Msg)) {
	thread.destroy(j.thread) // joins first
	for x, i in jobs {
		if x == j {
			ordered_remove(jobs, i)
			break
		}
	}
	free(j)
}

@(private)
mailbox_post :: proc(mb: ^Mailbox($Msg), m: Mail(Msg)) {
	sync.mutex_lock(&mb.mu)
	append(&mb.mail, m)
	sync.mutex_unlock(&mb.mu)
	if mb.wake != nil do mb.wake(mb.wake_user)
}

// mailbox_drain moves what the workers posted into `out`, in order. A
// job's done marker becomes its on_done message (after everything it
// posted) and the job is reaped. True when anything arrived.
@(private)
mailbox_drain :: proc(mb: ^Mailbox($Msg), jobs: ^[dynamic]^Job(Msg), out: ^[dynamic]Msg) -> bool {
	sync.mutex_lock(&mb.mu)
	batch := make([]Mail(Msg), len(mb.mail), context.temp_allocator)
	copy(batch, mb.mail[:])
	clear(&mb.mail)
	sync.mutex_unlock(&mb.mu)
	for m in batch {
		if m.file != nil {
			op := m.file
			if op.write {
				handler_deliver(op.on_write, File_Written{path = op.path, ok = op.ok, error = op.error}, op.tag, out)
			} else {
				handler_deliver(op.on_read, File_Read{path = op.path, data = op.data, ok = op.ok, error = op.error}, op.tag, out)
			}
			append(&mb.finished, op) // the message may point into it: freed after update ran
			continue
		}
		if m.secret != nil {
			op := m.secret
			handed := false
			if _, is_proc := op.on_secret.(proc(Ev(Secret)) -> Msg); is_proc do handed = true
			handler_deliver(op.on_secret, Secret{service = op.service, account = op.account,
				value = op.value, status = op.status, error = op.error}, op.tag, out)
			if handed && op.kind == .Secret_Get do op.value = nil // the app's now: it scrubs it
			append(&mb.secrets, op) // the message may point into it: freed after update ran
			mb.secret_busy = false
			secret_next(mb) // the keyring is free: whatever was waiting for it goes now
			continue
		}
		if m.relaunch != nil {
			op := m.relaunch
			handler_deliver(op.on, Relaunch{args = op.args}, 0, out)
			append(&mb.relaunches, op) // the message points into it: freed after update ran
			continue
		}
		if m.canvas || m.canvas_batch != 0 {
			canvas_mail(mb, m.canvas_batch, out)
			continue
		}
		if m.picture != nil {
			op := m.picture
			handed := false
			if _, is_proc := op.on_image.(proc(Ev(Pasted_Image)) -> Msg); is_proc do handed = true
			handler_deliver(op.on_image, Pasted_Image{image = op.image, mime = op.mime, data = op.data, ok = op.ok}, 0, out)
			if handed do op.image = {} // the app's now
			append(&mb.pictures, op) // its mime and bytes: freed after update ran
			continue
		}
		if m.done == nil {
			append(out, m.msg)
			continue
		}
		j := m.done
		handler_deliver(j.on_done, Job_Done{cancelled = sync.atomic_load(&j.stop)}, j.tag, out)
		job_reap(jobs, j)
	}
	return len(batch) > 0
}

// mailbox_release frees the file ops whose messages were handled this
// loop iteration.
@(private)
mailbox_release :: proc(mb: ^Mailbox($Msg)) {
	for op in mb.finished do file_op_free(op)
	clear(&mb.finished)
	for op in mb.secrets do secret_op_free(op) // handed-over values are already nil
	clear(&mb.secrets)
	for op in mb.pictures do picture_op_free(op, image_too = true) // handed over: already emptied
	clear(&mb.pictures)
	for op in mb.relaunches do relaunch_op_free(op)
	clear(&mb.relaunches)
	if h := mb.canvas_host; h != nil do for b in mb.canvas_bytes do delete(b, h.allocator)
	clear(&mb.canvas_bytes)
}

// jobs_shutdown cancels every job and gives the workers a moment to
// return; one that keeps going is left to end with the process.
@(private)
jobs_shutdown :: proc(mb: ^Mailbox($Msg), jobs: ^[dynamic]^Job(Msg)) {
	for j in jobs do job_stop(j)
	start := time.tick_now()
	for len(jobs) > 0 && time.tick_since(start) < JOB_QUIT_GRACE {
		all := true
		for j in jobs do if !sync.atomic_load(&j.finished) do all = false
		if all do break
		time.sleep(time.Millisecond)
	}
	for i := len(jobs) - 1; i >= 0; i -= 1 {
		j := jobs[i]
		if !sync.atomic_load(&j.finished) do continue
		thread.destroy(j.thread)
		ordered_remove(jobs, i)
		free(j)
	}
	sync.mutex_lock(&mb.mu)
	for m in mb.mail {
		if m.file != nil do file_op_free(m.file)
		if m.secret != nil do secret_op_free(m.secret)
		if m.picture != nil do picture_op_free(m.picture, image_too = true)
	}
	clear(&mb.mail)
	sync.mutex_unlock(&mb.mu)
	mailbox_release(mb)
	for op in mb.secret_queue do secret_op_free(op) // queued keychain calls that never got their turn
	delete(mb.secret_queue)
	mb.secret_queue = nil
	delete(mb.finished)
	mb.finished = nil
	delete(mb.secrets)
	mb.secrets = nil
	for op in mb.relaunches do relaunch_op_free(op)
	delete(mb.relaunches)
	mb.relaunches = nil
	delete(mb.pictures)
	mb.pictures = nil
	delete(mb.canvas_waiting)
	delete(mb.canvas_bytes)
	mb.canvas_waiting, mb.canvas_bytes = nil, nil
}

// handler_deliver turns an outcome into the app's message through a
// handler (a plain message, or a proc given Ev{value, tag}); nil delivers
// nothing.
@(private)
handler_deliver :: proc(h: Handler($Msg, $T), v: T, tag: u64, out: ^[dynamic]Msg) -> bool {
	switch f in h {
	case Msg:
		append(out, f)
		return true
	case proc(Ev(T)) -> Msg:
		append(out, f(Ev(T){value = v, tag = tag}))
		return true
	}
	return false
}
