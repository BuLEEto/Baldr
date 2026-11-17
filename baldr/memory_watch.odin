package baldr

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"

// BALDR_DEBUG_MEMORY=1 watches the heap for growth while an app runs.
//
// An app's state lives until the process ends (there is no teardown hook),
// so what is left at exit is mostly the app's own model; a leak shows as
// growth instead. Every ten seconds of activity
// (`BALDR_DEBUG_MEMORY=<seconds>` for another period)
// the run loop prints the live heap and the process's size, then the lines
// of code whose live allocations grew since the last report, net. Drive the
// same thing round repeatedly: caches fill on the first lap and stop, and a
// leak is a line that is up in every report by about the same amount.
//
//	baldr/memory: 9.7 MB live in 5,118 allocations (peak 9.8 MB); process 160.5 MB; since the last: +30 allocations, +5.5 KB
//	       +12     +5.2 KB  runa/cache.odin:179 shape_text_cached
//
// Allocations go through mem.Tracking_Allocator, so everything is slower;
// judge speed without it. Worker threads' allocations are not counted
// (workers start with their own context), nor is what the GPU driver or
// platform libraries hold; the process line grows with those too. A free
// of memory allocated before the run is passed to the heap; the tracker
// only counts it.

@(private)
Memory_Watch :: struct {
	using track: mem.Tracking_Allocator, // first: the bad-free callback gets this pointer
	on:          bool,
	period_ms:   f64,
	last_groups: map[[2]uintptr]Memory_Group, // what each line held at the last report (backing memory: not tracked)
	last_ms:     f64,
	last_count:  int,
	last_bytes:  i64,
	untracked_frees: int, // frees of memory made before the watch began
}

@(private)
Memory_Group :: struct {
	file:      string,
	line:      i32,
	procedure: string,
	count:     int,
	bytes:     int,
}

// memory_watch_start begins watching when BALDR_DEBUG_MEMORY is set; nil
// when it is not. The watch is on the heap and is never freed: a map or a
// Document the app made during the run keeps the tracker as its allocator,
// and may be freed after `run` has returned.
@(private)
memory_watch_start :: proc() -> ^Memory_Watch {
	v := os.get_env("BALDR_DEBUG_MEMORY", context.temp_allocator)
	if v == "" || v == "0" do return nil
	period := f64(10_000)
	if secs, ok := strconv.parse_f64(v); ok && secs >= 1 do period = secs * 1000
	w := memory_watch_make(period)
	fmt.eprintfln("baldr/memory: watching the heap; a report every %.0f s of activity", w.period_ms / 1000)
	return w
}

// memory_watch_make is a watch over context.allocator, reporting every
// `period_ms`.
@(private)
memory_watch_make :: proc(period_ms: f64) -> ^Memory_Watch {
	w := new(Memory_Watch)
	mem.tracking_allocator_init(&w.track, context.allocator, context.allocator) // its `backing` is the heap the run would have used
	w.bad_free_callback = memory_watch_untracked_free
	w.last_groups = make(map[[2]uintptr]Memory_Group, w.backing)
	w.period_ms = period_ms
	w.on = true
	return w
}

// memory_watch_allocator is the allocator a run uses: the watch's tracker,
// or the current one when nothing is watched. Set it at the run's own
// scope: a context changed inside an `if` lasts for that block only.
@(private)
memory_watch_allocator :: proc(w: ^Memory_Watch) -> runtime.Allocator {
	return mem.tracking_allocator(&w.track) if w != nil else context.allocator
}

// memory_watch_untracked_free frees, on the heap it came from, memory the
// tracker never saw allocated; the tracker alone would drop it and leak.
// Called with the tracker's lock held.
@(private)
memory_watch_untracked_free :: proc(t: ^mem.Tracking_Allocator, memory: rawptr, loc: runtime.Source_Code_Location) {
	w := (^Memory_Watch)(t)
	w.untracked_frees += 1
	mem.free(memory, w.backing, loc)
}

// memory_watch_tick prints a report when a period has passed since the
// last one. The run loop calls it once a wake-up; an idle app does not
// wake, so it does not report either.
@(private)
memory_watch_tick :: proc(w: ^Memory_Watch, now_ms: f64) {
	if w == nil || !w.on do return
	if w.last_ms == 0 {
		w.last_ms = now_ms
		return
	}
	if now_ms - w.last_ms < w.period_ms do return
	w.last_ms = now_ms
	memory_watch_report(w, "")
}

// memory_watch_stop prints what is still live once the run has torn
// itself down: the app's own state and anything the toolkit failed to
// free. The tracker stays: what the app frees later still goes through it.
@(private)
memory_watch_stop :: proc(w: ^Memory_Watch) {
	if w == nil || !w.on do return
	clear(&w.last_groups) // everything live counts as new
	w.last_count, w.last_bytes = 0, 0
	memory_watch_report(w, "left after the run (the app's own state is here too)")
	w.on = false
}

// memory_watch_measure counts what is live by the line that allocated it,
// and returns the lines that hold more than at the last measure — `count`
// and `bytes` in each are the change — largest first, in the backing
// allocator (the caller deletes it). It becomes the new last measure.
@(private)
memory_watch_measure :: proc(w: ^Memory_Watch) -> (grew: [dynamic]Memory_Group, n: int, live, peak: i64, untracked: int) {
	// Count under the lock, with the backing allocator: an allocation
	// through the tracker here would wait on the lock we hold.
	groups := make(map[[2]uintptr]Memory_Group, max(len(w.last_groups), 64), w.backing)
	sync.mutex_lock(&w.track.mutex)
	n = len(w.allocation_map)
	live = w.current_memory_allocated
	peak = w.peak_memory_allocated
	untracked = w.untracked_frees
	for _, e in w.allocation_map {
		key := [2]uintptr{uintptr(raw_data(e.location.file_path)), uintptr(e.location.line)} // the file string's address and the line
		g, ok := &groups[key]
		if !ok {
			groups[key] = {file = e.location.file_path, line = e.location.line, procedure = e.location.procedure}
			g = &groups[key]
		}
		g.count += 1
		g.bytes += e.size
	}
	sync.mutex_unlock(&w.track.mutex)

	grew = make([dynamic]Memory_Group, 0, 32, w.backing)
	for key, g in groups {
		was := w.last_groups[key]
		if g.count > was.count || g.bytes > was.bytes {
			d := g
			d.count -= was.count
			d.bytes -= was.bytes
			append(&grew, d)
		}
	}
	slice.sort_by(grew[:], proc(a, b: Memory_Group) -> bool {return a.bytes > b.bytes || (a.bytes == b.bytes && a.count > b.count)})
	delete(w.last_groups)
	w.last_groups = groups
	return
}

// memory_watch_report prints the totals, then the lines of code whose live
// allocations grew since the last report. Net, not new: text laid out
// again in place of the last nets to nothing.
@(private)
memory_watch_report :: proc(w: ^Memory_Watch, title: string) {
	grew, n, live, peak, untracked := memory_watch_measure(w)
	defer delete(grew)

	b := strings.builder_make(w.backing)
	defer strings.builder_destroy(&b)
	if title != "" {
		fmt.sbprintf(&b, "baldr/memory: %s: %s in %s allocations", title, memory_size(live), memory_count(n))
	} else {
		fmt.sbprintf(&b, "baldr/memory: %s live in %s allocations (peak %s)", memory_size(live), memory_count(n), memory_size(peak))
		if rss := memory_process_bytes(w.backing); rss > 0 do fmt.sbprintf(&b, "; process %s", memory_size(rss))
		d := n - w.last_count
		fmt.sbprintf(&b, "; since the last: %s%s allocations, %s%s", "+" if d >= 0 else "", memory_count(d), "+" if live >= w.last_bytes else "-", memory_size(abs(live - w.last_bytes)))
	}
	if untracked > 0 do fmt.sbprintf(&b, "; %d frees of memory from before the run", untracked)
	fmt.eprintln(strings.to_string(b))
	shown := 0
	for g in grew {
		if shown == 12 do break
		strings.builder_reset(&b)
		fmt.sbprintf(&b, "  %8s  %10s  %s:%d %s", memory_signed(g.count, memory_count(g.count)), memory_signed(g.bytes, memory_size(i64(abs(g.bytes)))), memory_short_path(g.file), g.line, g.procedure)
		fmt.eprintln(strings.to_string(b))
		shown += 1
	}
	if len(grew) > shown do fmt.eprintfln("  … and %d more lines that grew", len(grew) - shown)
	w.last_count, w.last_bytes = n, live
}

@(private)
memory_signed :: proc(v: int, s: string) -> string {
	if v > 0 do return strings.concatenate({"+", s}, context.temp_allocator)
	if v == 0 do return "0"
	if strings.has_prefix(s, "-") do return s
	return strings.concatenate({"-", s}, context.temp_allocator)
}

// memory_short_path keeps a path's last two parts: "baldr/widget_table.odin".
@(private)
memory_short_path :: proc(path: string) -> string {
	cut, seen := 0, 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			seen += 1
			if seen == 2 {
				cut = i + 1
				break
			}
		}
	}
	return path[cut:]
}

@(private)
memory_size :: proc(bytes: i64) -> string {
	f := f64(bytes)
	switch {
	case bytes < 1024:        return fmt.tprintf("%d B", bytes)
	case bytes < 1024 * 1024: return fmt.tprintf("%.1f KB", f / 1024)
	case:                     return fmt.tprintf("%.1f MB", f / (1024 * 1024))
	}
}

@(private)
memory_count :: proc(n: int) -> string {
	digits := fmt.tprintf("%d", abs(n))
	b := strings.builder_make(context.temp_allocator)
	if n < 0 do strings.write_byte(&b, '-')
	for ch, i in digits {
		if i > 0 && (len(digits) - i) % 3 == 0 do strings.write_byte(&b, ',')
		strings.write_rune(&b, ch)
	}
	return strings.to_string(b)
}

// memory_process_bytes is the process's resident size, or 0 where it is
// not known.
@(private)
memory_process_bytes :: proc(allocator: runtime.Allocator) -> i64 {
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file("/proc/self/status", allocator)
		if err != nil do return 0
		defer delete(data, allocator)
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if !strings.has_prefix(line, "VmRSS:") do continue
			kb := 0
			for c in line do if c >= '0' && c <= '9' do kb = kb * 10 + int(c - '0')
			return i64(kb) * 1024
		}
	}
	return 0
}
