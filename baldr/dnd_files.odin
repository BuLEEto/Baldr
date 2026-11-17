package baldr

// Files a drag source is still making as the drag leaves the window.
//
// A source that has its paths already answers `drag_files` and nothing
// here applies. A source whose files do not exist yet — the entries of an
// archive being looked inside, a document still being exported — uses
// names inside its own window that are not paths another program can open,
// and the paths it will use are not there when the drag crosses the
// window's edge, while the program it is dropped in opens them at once.
//
// So a drag that leaves asks a second callback, `drag_files_out`, which
// may hand back a `Files_Later` along with its paths. The forms the other
// program reads (text/uri-list, the GNOME form, plain text) are then
// written only once the source says the files are there — on the thread
// that writes that program's pipe, never the one drawing the window:
//
//	// in the app, answering drag_files_out:
//	paths := cache_paths_for(sel, allocator)   // the paths it *will* write
//	later := baldr.files_later_new()           // …and the promise
//	start_extracting(sel, later)               // a thread of the app's own
//	return paths, later
//
//	// in that thread, when they are written (or never will be):
//	baldr.files_later_ready(later)             // …or files_later_failed
//	baldr.files_later_release(later)           // the reference files_later_new gave
//
// A promise nobody keeps is not a hang: FILES_LATER_TIMEOUT_MS after the
// drag left, every form goes out empty, which the other program reads as
// a drop of nothing.

import "base:runtime"
import "core:sync"
import "core:time"
import "baldr:platform"

// Files_Out gives a drag source's files for a drag that is leaving the
// window: real paths another program can open, for `tag` (and `count` of
// them when a selection drags whole). `wait` may be nil, which says the
// paths are there already and makes this exactly a `Files_Of`; otherwise
// it is a promise that they will be, from `files_later_new`.
//
// `drag_files` answers drops inside the app (including another window of
// it), where a source may use names of its own; this one answers the way
// out. A source that gives only this one is asked it for both the drag out
// and the `on_drag_out` report, and its in-app drops carry no files.
//
// Returning the same promise twice in one drag (out, back in, out again) is
// fine: the toolkit takes a reference of its own each time, so the source
// neither retains nor releases anything for it.
Files_Out :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> (paths: []string, wait: ^Files_Later)

// How long one form of a leaving drag waits for the files to be made
// before it is written empty: a minute, the same wait the backend reading a
// drop gives a source, so neither side of a drag between two Baldr windows
// gives up before the other.
FILES_LATER_TIMEOUT_MS :: platform.DROP_WAIT_MS

@(private) FILES_LATER_MAKING :: 0 // still being made: a form waits
@(private) FILES_LATER_READY  :: 1 // there: the forms go out
@(private) FILES_LATER_GONE   :: 2 // given up: the forms go out empty

// Files_Later is a drag source's promise that the files its paths name
// will exist, shared by counting with every form waiting on it. Make one
// with `files_later_new`, say how it ended with `files_later_ready` or
// `files_later_failed`, and give your reference back with
// `files_later_release`; those three are safe from any thread, and safe
// after the drag has ended (the forms are gone, and nothing waits).
Files_Later :: struct {
	state:    sync.Futex, // FILES_LATER_MAKING, _READY, _GONE
	refs:     int,
	deadline: time.Tick, // when a form stops waiting; set as the drag leaves
	timed:    int,       // atomic: the deadline is set (and so published)
}

// files_later_new makes a promise with one reference, the caller's: give
// it back with `files_later_release` once the files are made or given up
// on. The toolkit takes references of its own for the forms that wait on
// it, so it outlives this one if the drag is still going.
files_later_new :: proc() -> ^Files_Later {
	f := new(Files_Later, runtime.heap_allocator())
	f.refs = 1
	return f
}

// files_later_ready says the files the paths name are there. Every form
// waiting goes out with its paths; one asked for afterwards does not wait
// at all.
files_later_ready :: proc(f: ^Files_Later) {
	files_later_tell(f, FILES_LATER_READY)
}

// files_later_failed says they never will be — the extraction failed, or
// the drag was dropped nowhere and the work was abandoned. Every form
// waiting goes out empty, which the program reading it sees as a drop
// carrying nothing.
files_later_failed :: proc(f: ^Files_Later) {
	files_later_tell(f, FILES_LATER_GONE)
}

// files_later_retain takes one more reference (the toolkit does this for
// each form of a leaving drag). A source keeping the promise past the
// thread it made it for needs it too.
files_later_retain :: proc(f: ^Files_Later) {
	if f == nil do return
	sync.atomic_add(&f.refs, 1)
}

// files_later_release gives a reference back; the last one frees it.
files_later_release :: proc(f: ^Files_Later) {
	if f == nil do return
	if sync.atomic_sub(&f.refs, 1) == 1 do free(f, runtime.heap_allocator())
}

@(private)
files_later_tell :: proc(f: ^Files_Later, state: u32) {
	if f == nil do return
	// The first answer stands: a source that says "ready" and then tidies
	// up with "failed" has already handed the files over.
	if _, swapped := sync.atomic_compare_exchange_strong(&f.state, sync.Futex(FILES_LATER_MAKING), sync.Futex(state)); !swapped do return
	sync.futex_broadcast(&f.state)
}

// files_later_start sets the deadline, if it has none: the clock runs
// from the moment the drag first left the window, not from each form
// being asked for, so a slow reader cannot extend it.
@(private)
files_later_start :: proc(f: ^Files_Later) {
	if f == nil || sync.atomic_load(&f.timed) != 0 do return
	f.deadline = time.tick_add(time.tick_now(), FILES_LATER_TIMEOUT_MS * time.Millisecond)
	sync.atomic_store(&f.timed, 1) // …and published: a waiter that sees this sees the deadline
}

// files_later_settled: whether a form would be written now, and with what,
// without waiting.
@(private)
files_later_settled :: proc(f: ^Files_Later) -> (settled: bool, ready: bool) {
	if f == nil do return true, true
	switch u32(sync.atomic_load(&f.state)) {
	case FILES_LATER_READY: return true, true
	case FILES_LATER_GONE:  return true, false
	}
	// Out of time counts as settled, and as nothing: a source that never
	// answers must not leave another program reading a pipe for ever.
	if sync.atomic_load(&f.timed) != 0 && time.tick_diff(time.tick_now(), f.deadline) <= 0 do return true, false
	return false, false
}

// files_later_wait blocks the calling thread until the files are made,
// given up on, or out of time. True: they are there.
@(private)
files_later_wait :: proc(f: ^Files_Later) -> bool {
	if f == nil do return true
	// A deadline of this thread's as well as the promise's, so a wait on a
	// promise whose clock nobody started still ends.
	own := time.tick_add(time.tick_now(), FILES_LATER_TIMEOUT_MS * time.Millisecond)
	for {
		if settled, ready := files_later_settled(f); settled do return ready
		left := time.tick_diff(time.tick_now(), own)
		if sync.atomic_load(&f.timed) != 0 {
			if d := time.tick_diff(time.tick_now(), f.deadline); d < left do left = d
		}
		if left <= 0 do return false
		sync.futex_wait_with_timeout(&f.state, FILES_LATER_MAKING, left)
	}
}

// Files_Form is one form of a leaving drag's file list: its bytes, made
// when the drag left, given out once the source says the files behind them
// exist. It is a platform.Clip_Later, so the backend offers it and waits
// for it exactly as it does a copied picture's PNG — on the thread writing
// the other program's pipe.
@(private)
Files_Form :: struct {
	using later: platform.Clip_Later, // first: a ^Clip_Later is its ^Files_Form
	wait_on:     ^Files_Later,
	bytes:       []u8,
}

// files_form_new copies `bytes` and holds a reference on `wait`. One
// reference, the caller's: hand the item to the backend (which takes its
// own) and then release it.
@(private)
files_form_new :: proc(bytes: []u8, wait: ^Files_Later) -> ^Files_Form {
	heap := runtime.heap_allocator()
	p := new(Files_Form, heap)
	p.bytes = make([]u8, len(bytes), heap)
	copy(p.bytes, bytes)
	p.refs = 1
	p.wait_on = wait
	files_later_retain(wait)
	files_later_start(wait)
	p.wait = proc(l: ^platform.Clip_Later) -> []u8 {
		p := (^Files_Form)(l)
		if !files_later_wait(p.wait_on) do return nil
		return p.bytes
	}
	p.free = proc(l: ^platform.Clip_Later) {
		p := (^Files_Form)(l)
		heap := runtime.heap_allocator()
		files_later_release(p.wait_on)
		delete(p.bytes, heap)
		free(p, heap)
	}
	return p
}

// clip_files_waiting is `clip_files_items` for a leaving drag whose files
// are still being made: the same forms, each given out only once `wait`
// says they are there. Every item's `later` carries one reference for the
// caller — pass them to the platform, which takes its own, and release
// them with clip_files_waiting_release.
@(private)
clip_files_waiting :: proc(paths: []string, wait: ^Files_Later, allocator := context.temp_allocator) -> []Clip_Item {
	bytes := clip_files_items(paths, false, allocator)
	items := make([]Clip_Item, len(bytes), allocator)
	for it, i in bytes {
		items[i] = {mime = it.mime, later = &files_form_new(it.data, wait).later}
	}
	return items
}

@(private)
clip_files_waiting_release :: proc(items: []Clip_Item) {
	for it in items do if it.later != nil do platform.clip_later_release(it.later)
}
