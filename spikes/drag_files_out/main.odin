package main

// A drag whose files are made as it leaves the window, and handed to the
// other program once they exist.
//
// A file manager looking inside an archive has nothing a path can name
// until it extracts it. So a drag out of one carries paths to files that
// do not exist yet — and the program it is dropped in opens them the
// moment it has the list. The toolkit's answer is a second callback for
// the way out (`files_out`) which may hand back a promise
// (`baldr.files_later_new`), and the forms are written into the other
// program only when the promise is kept.
//
// Driven, because the proof is a *sequence* and not a picture: run one of
// these as the source and another as the receiver, drag the row from the
// first window into the second, and read the lines. The receiver must
// print the drop AFTER the source printed that it had written the file,
// however late that was, and the path it prints must exist.
//
//	# in the nested harness (tools/nested-harness.sh), two processes:
//	build/drag_files_out --receive &          # app_id dev.baldr.drag_in
//	DRAG_DELAY_MS=1200 build/drag_files_out & # app_id dev.baldr.drag_out
//	# …then press on the row, move across into the other window, release:
//	compositor-msg seat move  <x1> <y1>; compositor-msg seat press left
//	compositor-msg seat move  … ; compositor-msg seat release left
//
// `DRAG_DELAY_MS` is how long the "extraction" takes (0: the file is there
// before the drag starts). `DRAG_GIVE_UP=1` makes the work fail instead,
// which must reach the other program as a drop of nothing rather than as a
// wait with no end.
//
// X11 is a separate check, and needs its own session, because the source
// half there works the other way round: X answers a request for selection
// data on the thread it arrived on, so the request is parked and the loop
// writes the property when a thread of ours has the form. Xwayland will not
// do — it has no reparenting window manager and bridges its selections — so
// use `tools/nested-x.sh` (Xephyr and openbox) with two processes:
//
//	tools/nested-x.sh start
//	DISPLAY=:2 BALDR_BACKEND=x11 VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
//	  build/drag_files_out --receive &
//	DISPLAY=:2 BALDR_BACKEND=x11 VK_ICD_FILENAMES=… DRAG_DELAY_MS=600 build/drag_files_out &
//	# xdotool windowmove them apart, then mousemove / mousedown 1 / mousemove… / mouseup 1
//
// Keep the work under a second there: the reading side on X11 fetches a
// drop's data with a blocking pump bounded at SELECTION_WAIT_MS. The drop
// should land a few milliseconds after the promise is kept, which is the
// parked request being answered.
//
// Drive an X11 drag slowly. XDND is a conversation — enter, position, and
// the target's status back — so a drag released before the target has
// answered looks like a refused drop. About 60 ms a step and half a second
// before the release is enough.
//
// `DRAG_FILES=N` drags N paths (`DRAG_PAD=N` lengthens each name, a cheaper
// way to make a long list than making more files), and `DRAG_EACH=1` makes
// `--receive` report one line per file. A list over 64 KiB crosses Wayland's
// `pipe_writer` partial-write and EAGAIN path; on X11 one over `chunk_size`
// (the server's maximum request length, usually a megabyte) goes out as INCR.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "baldr:baldr"

DIR :: "/tmp/baldr-drag-files-out"
PHOTO :: "a photo, out of the archive\n"

State :: struct {
	t0:      time.Tick,
	path:    string,   // the first file the drag's paths name, made as it leaves
	paths:   []string, // …and all of them: DRAG_FILES of them (1 by default)
	inside:  string,   // what the source calls the first one among its own windows
	delay:   int,      // how long making it takes
	give_up: bool,   // …or whether it fails instead
	asked:   int,    // times the way out was asked for
	each:    bool,   // report a dropped list one line per file, however long it is
	working: bool,
	log:     string, // the last line, shown in the window too
}

Msg :: union { Said, baldr.Drop }

Said :: struct { line: string }

// Work is the "extraction": a thread, the promise, and the file it writes.
Work :: struct {
	paths:   []string,
	delay:   int,
	give_up: bool,
	t0:      time.Tick,
	promise: ^baldr.Files_Later,
}

say :: proc(s: ^State, format: string, args: ..any) {
	line := fmt.tprintf(format, ..args)
	fmt.eprintfln("drag_files_out: %7.3f s  %s", time.duration_seconds(time.tick_since(s.t0)), line)
	s.log = strings.clone(line)
}

// ---------------------------------------------------------------- the source

// files_inside: what a drop in one of this app's own windows gets — a name
// of the source's own, which nothing outside it could open.
files_inside :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> []string {
	s := (^State)(user)
	out := make([]string, len(s.paths), allocator)
	for p, i in s.paths do out[i] = s.inside if i == 0 else fmt.aprintf("archive:/tmp/Photos.zip!/%s", filepath.base(p), allocator = allocator)
	return out
}

// files_outside: the way out. The paths are the ones it *will* write, and
// the promise is what makes the other program wait for them.
files_outside :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> ([]string, ^baldr.Files_Later) {
	s := (^State)(user)
	s.asked += 1
	out := make([]string, len(s.paths), allocator)
	copy(out, s.paths)
	if s.delay <= 0 && !s.give_up {
		for p in s.paths do os.write_entire_file(p, PHOTO) or_continue
		say(s, "asked for the way out (%d): %d path(s) from %s, written already", s.asked, len(out), s.path)
		return out, nil
	}
	if s.working { // asked again in the same drag: the same answer, and the work is already going
		say(s, "asked for the way out (%d): the same paths, already being made", s.asked)
		return out, nil
	}
	s.working = true
	promise := baldr.files_later_new()
	w := new(Work)
	w^ = {paths = s.paths, delay = s.delay, give_up = s.give_up, t0 = s.t0, promise = promise}
	say(s, "asked for the way out (%d): %d path(s) from %s, not there yet — %d ms of work", s.asked, len(out), s.path, s.delay)
	if thread.create_and_start_with_data(w, extract, self_cleanup = true) == nil {
		baldr.files_later_failed(promise)
		baldr.files_later_release(promise)
		free(w)
		say(s, "no thread to extract on: the drag goes out empty")
		return out, nil
	}
	return out, promise
}

// extract is the app's own thread: it makes the file (or does not), and
// says so. Nothing about the toolkit is touched from here but the promise,
// which is what it is for.
extract :: proc(p: rawptr) {
	w := (^Work)(p)
	time.sleep(time.Duration(w.delay) * time.Millisecond)
	elapsed := time.duration_seconds(time.tick_since(w.t0))
	if w.give_up {
		fmt.eprintfln("drag_files_out: %7.3f s  extracting failed: the promise is given up", elapsed)
		baldr.files_later_failed(w.promise)
	} else {
		made, failed := 0, 0
		for p in w.paths {
			if os.write_entire_file(p, PHOTO) == nil { made += 1 } else { failed += 1 }
		}
		fmt.eprintfln("drag_files_out: %7.3f s  extracted %d file(s), %d failed: the promise is %s",
			elapsed, made, failed, "kept" if failed == 0 else "given up")
		if failed == 0 { baldr.files_later_ready(w.promise) } else { baldr.files_later_failed(w.promise) }
	}
	baldr.files_later_release(w.promise)
	free(w)
}

source_view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Photos.zip", role = .Title)
	baldr.text(ui, "Drag the row out of this window.", role = .Caption, muted = true)
	n := baldr.row(ui, height = 40, width = 240, padding = .sm, align = .Center)
	baldr.text(ui, "2019/beach.jpg")
	baldr.end(ui)
	baldr.draggable(ui, n, "file", tag = 1, user = s,
		files = files_inside, files_out = files_outside,
		on_drag_out = proc(e: baldr.Ev(baldr.Drop)) -> Msg {
			first := e.value.files[0] if len(e.value.files) > 0 else "nothing"
			return Said{fmt.tprintf("the other program took it (%v): %s", e.value.action, first)}
		})
	baldr.text(ui, s.log, role = .Caption, nowrap = true, ellipsis = .Middle)
}

// ---------------------------------------------------------------- the receiver

receive_view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md, justify = .Center, align = .Center); defer baldr.end(ui)
	baldr.text(ui, "Drop files here", role = .Title)
	baldr.text(ui, s.log, role = .Caption, nowrap = true, ellipsis = .Middle)
	zone := baldr.column(ui, flex = 1, width = 320, justify = .Center, align = .Center)
	baldr.text(ui, "another program's window", muted = true)
	baldr.end(ui)
	baldr.drop_target(ui, zone, proc(e: baldr.Ev(baldr.Drop)) -> Msg { return e.value }, accepts = "")
}

// ---------------------------------------------------------------- both

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch e in m {
	case Said:
		say(s, "%s", e.line)
	case baldr.Drop:
		if len(e.files) == 0 {
			say(s, "dropped: nothing at all (the source gave up, or it ran out of time)")
			return {}
		}
		if len(e.files) <= 4 || s.each {
			for p in e.files {
				size := -1
				if data, rerr := os.read_entire_file(p, context.temp_allocator); rerr == nil do size = len(data)
				say(s, "dropped: %s (%d bytes on disk)", p, size)
			}
			return {}
		}
		there, bytes, uris := 0, 0, 0
		for p in e.files {
			uris += len(p) + 9 // file:// and the CRLF: what the list cost
			if data, rerr := os.read_entire_file(p, context.temp_allocator); rerr == nil {
				there += 1
				bytes += len(data)
			}
		}
		say(s, "dropped: %d paths (about %d bytes of uri-list); %d on disk, %d bytes between them",
			len(e.files), uris, there, bytes)
	}
	return {}
}

main :: proc() {
	receive := false
	for a in os.args[1:] do if a == "--receive" do receive = true
	err := baldr.run(baldr.App(State, Msg){
		title = "Drop files here" if receive else "Photos.zip",
		app_id = "dev.baldr.drag_in" if receive else "dev.baldr.drag_out",
		size = {420, 300},
		init = proc() -> (s: State) {
			s.t0 = time.tick_now()
			s.delay = 1200
			if v := os.get_env("DRAG_DELAY_MS", context.temp_allocator); v != "" {
				if n, ok := strconv.parse_int(v); ok do s.delay = n
			}
			s.give_up = os.get_env("DRAG_GIVE_UP", context.temp_allocator) == "1"
			s.each = os.get_env("DRAG_EACH", context.temp_allocator) == "1"
			s.inside = "archive:/tmp/Photos.zip!/2019/beach.jpg"
			n := 1
			if v := os.get_env("DRAG_FILES", context.temp_allocator); v != "" {
				if m, ok := strconv.parse_int(v); ok && m > 0 do n = m
			}
			pad := 0
			if v := os.get_env("DRAG_PAD", context.temp_allocator); v != "" {
				if m, ok := strconv.parse_int(v); ok && m > 0 do pad = min(m, 160)
			}
			padding := strings.repeat("x", pad, context.temp_allocator)
			os.make_directory(DIR)
			s.paths = make([]string, n)
			for i in 0 ..< n {
				name := "beach.jpg" if n == 1 && pad == 0 else fmt.tprintf("beach-%04d%s.jpg", i, padding)
				s.paths[i], _ = filepath.join({DIR, name})
				os.remove(s.paths[i]) // an honest run: nothing is there to begin with
			}
			s.path = s.paths[0]
			uris := 0
			for p in s.paths do uris += len(p) + 9
			fmt.eprintfln("drag_files_out: %s; %d ms to make %d file(s) from %s (about %d bytes of uri-list)%s",
				"receiving" if len(os.args) > 1 else "the source", s.delay, n, s.path, uris,
				", and then giving up" if s.give_up else "")
			return
		},
		update = update,
		view = receive_view if receive else source_view,
	})
	if baldr.run_failed(err) {
		fmt.eprintln("drag_files_out: exit:", err)
		os.exit(1)
	}
}
