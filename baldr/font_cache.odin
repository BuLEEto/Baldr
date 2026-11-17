package baldr

// The font index kept on disk and built off the UI thread.
//
// Walking every installed font can take seconds on a cold, slow disk. An
// app's engine (fonts_start) keeps the index in a cache file with the
// modification time of every directory it walked, as fontconfig does. The
// first ask reads that file and uses it at once; a worker then checks those
// directories and walks them again only when one changed (or there was no
// cache), rewriting the cache. The UI thread never waits for a disk: until
// an index arrives, a family asked for is pending (drawn in the theme's
// face, not reported missing) and a fallback finds nothing. When one
// arrives, fonts_take swaps it in, the families and fallbacks are looked
// for again, and every view's text is laid out again.
//
// Headless engines (tests, tools) have no scanner and walk the directories
// when first asked, without the cache.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// FONT_CACHE_VERSION is in the cache file's name and first line: a
// different layout is never read as this one.
@(private)
FONT_CACHE_VERSION :: 3 // bump when a record's fields or what is indexed changes

// Font_Scanner is the worker that builds the index, and what it hands back.
@(private)
Font_Scanner :: struct {
	wake:       proc(user: rawptr), // wakes the loop when an index arrives; nil: headless, no scanner
	wake_user:  rawptr,
	cache_path: string, // owned; "" keeps no cache
	asked:      bool,   // the index has been asked for (UI thread)
	thread:     ^thread.Thread,
	again:      bool,   // a walk was asked for while one ran: start it when that one is done
	quit:       bool,   // atomic: the engine is going; stop early
	done:       bool,   // atomic: the worker finished
	check:      Font_Index, // the cached index's directories, for the worker to check (its own copy)
	mu:         sync.Mutex,
	result:     Font_Index, // under mu: a new index, waiting for fonts_take
	has_result: bool,
}

// fonts_start gives an app's engine its scanner: the index kept in the
// cache file and built on a worker, `wake` called (from the worker) when a
// new one is ready for fonts_take.
@(private)
fonts_start :: proc(te: ^Text_Engine, wake: proc(user: rawptr), wake_user: rawptr) {
	sc := &te.font_scanner
	sc.wake, sc.wake_user = wake, wake_user
	sc.cache_path = font_cache_path(te.allocator)
}

// font_scan_start sets the worker going: checking the cached index's
// directories first when `check` (walking only if one changed), or walking
// them straight away. A walk asked for while one runs follows it.
@(private)
font_scan_start :: proc(te: ^Text_Engine, check: bool) {
	sc := &te.font_scanner
	if sc.thread != nil {
		if !check do sc.again = true
		return
	}
	font_index_destroy(&sc.check)
	if check do font_dirs_copy(&sc.check, &te.font_index)
	sync.atomic_store(&sc.done, false)
	sc.thread = thread.create_and_start_with_data(sc, font_scan_main)
	if sc.thread == nil { // no thread to be had: here and now, as headless
		font_scan_main(sc)
		sc.thread = nil
	}
}

// font_scan_main is the worker: the cached directories checked, else every
// directory walked, the cache written, and the new index handed back.
@(private)
font_scan_main :: proc(p: rawptr) {
	sc := (^Font_Scanner)(p)
	heap := runtime.heap_allocator()
	context.allocator = heap
	defer sync.atomic_store(&sc.done, true)
	if sc.check.allocator.procedure != nil && font_dirs_unchanged(&sc.check) do return // the cache is true
	idx: Font_Index
	font_index_build(&idx, heap, &sc.quit)
	if !idx.built {
		font_index_destroy(&idx)
		return
	}
	if sc.cache_path != "" do font_cache_write(&idx, sc.cache_path)
	sync.mutex_lock(&sc.mu)
	if sc.has_result do font_index_destroy(&sc.result)
	sc.result, sc.has_result = idx, true
	sync.mutex_unlock(&sc.mu)
	if sc.wake != nil do sc.wake(sc.wake_user)
}

// fonts_take swaps in an index the worker built, true when it did: the
// families and fallbacks are looked for again and every tree's text must
// be laid out again (tree_fonts_changed).
@(private)
fonts_take :: proc(te: ^Text_Engine) -> bool {
	if te == nil do return false
	sc := &te.font_scanner
	if sc.thread != nil && sync.atomic_load(&sc.done) {
		thread.destroy(sc.thread) // finished: joins at once
		sc.thread = nil
		if sc.again {
			sc.again = false
			font_scan_start(te, check = false)
		}
	}
	sync.mutex_lock(&sc.mu)
	got := sc.has_result
	fresh := sc.result
	sc.result, sc.has_result = {}, false
	sync.mutex_unlock(&sc.mu)
	if !got do return false
	font_index_destroy(&te.font_index)
	te.font_index = fresh
	fonts_arrived(te)
	return true
}

// font_scanner_stop ends the worker (the engine is going).
@(private)
font_scanner_stop :: proc(te: ^Text_Engine) {
	sc := &te.font_scanner
	if sc.thread != nil {
		sync.atomic_store(&sc.quit, true)
		thread.destroy(sc.thread) // joins: a walk stops at its next file
	}
	font_index_destroy(&sc.check)
	if sc.has_result do font_index_destroy(&sc.result)
	delete(sc.cache_path, te.allocator)
	sc^ = {}
}

// fonts_arrived looks for what was not found before: the families asked for
// while there was no index get ids of their own when found now (so a view
// holding the old id sees a change), the fallbacks' searches start over, and
// text laid out with the theme's face in their place is laid out again.
@(private)
fonts_arrived :: proc(te: ^Text_Engine) {
	for key, id in te.family_ids {
		e := family_of(te, id)
		if e == nil || e.ok do continue
		e.pending = false
		fresh := family_load(te, e.asked)
		if !fresh.ok {
			family_destroy(te, &fresh)
			continue
		}
		append(&te.families, fresh)
		te.family_ids[key] = Family_Id(len(te.families))
		for f in fresh.faces do if f != nil do face_id(te, f)
	}
	_ = theme_families_look(te) // the theme's own families: found now, if they were not before
	fallback_forget(te)
	typeset_faces_refresh(te)
	for k, &e in te.lines {
		lines_free(te, e.lines)
		delete(k.str, te.allocator)
	}
	clear(&te.lines)
}

// tree_fonts_changed lays every node out and paints it again: the fonts
// behind its text changed (a family found, a fallback that draws what was a
// box). Editors drop the line layouts they keep.
@(private)
tree_fonts_changed :: proc(t: ^Tree) {
	if te := t.text; te != nil do t.ui_family, t.mono_family, t.role_family = te.ui_family, te.mono_family, te.role_family // what it is being laid out in
	for &d, i in t.nodes {
		if i == 0 || .Alive not_in d.flags do continue
		d.flags += {.Dirty_Layout, .Dirty_Paint}
	}
	for n, _ in t.layers do if d := node_get(t, n); d != nil do d.flags += {.Layer_Dirty}
	for _, &s in t.areas {
		s.tops_valid = false
		for _, &c in s.rich_cache do rich_free(&c.lay, t.allocator)
		clear(&s.rich_cache)
	}
	// …and so do the paragraphs and replies that keep a layout of their own:
	// measured before a fallback arrived, their widths are a missing glyph's
	for _, &s in t.styled {
		rich_free(&s.lay, t.allocator)
		s.have = false
	}
	for _, &s in t.md_views do md_view_cache_clear(t, &s)
	for _, &st in t.terminals do term_forget_draws(&st) // a family found: its faces draw the cells
	mark_layout_dirty(t, t.root)
}

// font_dir_mtime is when a directory last changed, -1 when it is not there.
@(private)
font_dir_mtime :: proc(path: string) -> i64 {
	mt, err := os.modification_time_by_path(path)
	if err != nil do return -1
	return time.to_unix_nanoseconds(mt)
}

// font_dirs_copy copies an index's directories (not its families) for the
// worker to check on its own.
@(private)
font_dirs_copy :: proc(dst, src: ^Font_Index) {
	heap := runtime.heap_allocator()
	dst.allocator = heap
	dst.roots = make([dynamic]Font_Dir, 0, len(src.roots), heap)
	dst.dirs = make([dynamic]Font_Dir, 0, len(src.dirs), heap)
	for d in src.roots do append(&dst.roots, Font_Dir{strings.clone(d.path, heap), d.mtime})
	for d in src.dirs do append(&dst.dirs, Font_Dir{strings.clone(d.path, heap), d.mtime})
}

// font_dirs_unchanged says whether the directories an index was built from
// are the ones looked in now and none of them changed since.
@(private)
font_dirs_unchanged :: proc(idx: ^Font_Index) -> bool {
	now := font_dirs(context.temp_allocator)
	if len(now) != len(idx.roots) do return false
	for d, i in idx.roots do if d.path != now[i] || font_dir_mtime(d.path) != d.mtime do return false
	for d in idx.dirs do if font_dir_mtime(d.path) != d.mtime do return false
	return true
}

// font_cache_path is where the index is kept: the user's cache directory.
@(private)
font_cache_path :: proc(allocator := context.allocator) -> string {
	name := fmt.tprintf("fonts-v%d.idx", FONT_CACHE_VERSION)
	when ODIN_OS == .Windows {
		base := os.get_env("LOCALAPPDATA", context.temp_allocator)
		if base == "" do return ""
		return strings.concatenate({base, "\\baldr\\", name}, allocator)
	} else when ODIN_OS == .Darwin {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do return ""
		return strings.concatenate({home, "/Library/Caches/baldr/", name}, allocator)
	} else {
		base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
		if base == "" {
			home := os.get_env("HOME", context.temp_allocator)
			if home == "" do return ""
			base = strings.concatenate({home, "/.cache"}, context.temp_allocator)
		}
		return strings.concatenate({base, "/baldr/", name}, allocator)
	}
}

// The cache file is text, a record a line, fields split by tabs (a tab,
// newline or backslash in a name or path escaped as \t, \n, \\):
//
//	baldr-fonts 1
//	root <mtime> <path>
//	dir <mtime> <path>
//	face <family> <path> <face> <weight> <min> <max> <italic> <fixed> <variable> <width> <r0> <r1> <r2> <r3> <glyphs>

// font_cache_write writes `idx` to `path` (through a temporary file, so a
// reader never sees half of one). Failing is harmless: the next run walks
// the directories again.
@(private)
font_cache_write :: proc(idx: ^Font_Index, path: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "baldr-fonts\t%d\n", FONT_CACHE_VERSION)
	esc :: proc(b: ^strings.Builder, s: string) {
		for c in transmute([]u8)s {
			switch c {
			case '\t': strings.write_string(b, "\\t")
			case '\n': strings.write_string(b, "\\n")
			case '\\': strings.write_string(b, "\\\\")
			case:      strings.write_byte(b, c)
			}
		}
	}
	for d in idx.roots {
		fmt.sbprintf(&b, "root\t%d\t", d.mtime)
		esc(&b, d.path)
		strings.write_byte(&b, '\n')
	}
	for d in idx.dirs {
		fmt.sbprintf(&b, "dir\t%d\t", d.mtime)
		esc(&b, d.path)
		strings.write_byte(&b, '\n')
	}
	for name in idx.names do for f in idx.families[name] {
		strings.write_string(&b, "face\t")
		esc(&b, name)
		strings.write_byte(&b, '\t')
		esc(&b, f.path)
		fmt.sbprintf(&b, "\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", f.face, f.weight, f.weights[0], f.weights[1], int(f.italic), int(f.fixed), int(f.variable), f.width, f.ranges[0], f.ranges[1], f.ranges[2], f.ranges[3], f.glyphs)
	}
	dir := path
	for i := len(path) - 1; i >= 0; i -= 1 do if path[i] == '/' || path[i] == '\\' {
		dir = path[:i]
		break
	}
	_ = os.make_directory_all(dir)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file_from_bytes(tmp, transmute([]u8)strings.to_string(b)) != nil do return
	if os.rename(tmp, path) != nil do _ = os.remove(tmp)
}

// font_cache_read fills `idx` from the cache file at `path`; false, with
// `idx` untouched, when there is none or it is not one this version wrote.
// Whether it is still true is the worker's to check.
@(private)
font_cache_read :: proc(idx: ^Font_Index, path: string, allocator: runtime.Allocator) -> bool {
	if path == "" do return false
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return false
	text := string(data)
	first, _ := strings.split_lines_iterator(&text)
	if first != fmt.tprintf("baldr-fonts\t%d", FONT_CACHE_VERSION) do return false
	unesc :: proc(s: string, allocator: runtime.Allocator) -> string {
		if strings.index_byte(s, '\\') < 0 do return strings.clone(s, allocator)
		b := strings.builder_make(allocator)
		for i := 0; i < len(s); i += 1 {
			if s[i] == '\\' && i + 1 < len(s) {
				i += 1
				switch s[i] {
				case 't': strings.write_byte(&b, '\t')
				case 'n': strings.write_byte(&b, '\n')
				case:     strings.write_byte(&b, s[i])
				}
				continue
			}
			strings.write_byte(&b, s[i])
		}
		return strings.to_string(b)
	}
	out: Font_Index
	out.allocator = allocator
	out.families = make(map[string][dynamic]Font_Face_File, allocator)
	out.names = make([dynamic]string, allocator)
	out.roots = make([dynamic]Font_Dir, allocator)
	out.dirs = make([dynamic]Font_Dir, allocator)
	for line in strings.split_lines_iterator(&text) {
		if line == "" do continue
		fields := strings.split(line, "\t", context.temp_allocator)
		switch fields[0] {
		case "root", "dir":
			if len(fields) != 3 do continue
			mtime, ok := strconv.parse_i64(fields[1])
			if !ok do continue
			d := Font_Dir{unesc(fields[2], allocator), mtime}
			append(&out.roots if fields[0] == "root" else &out.dirs, d)
		case "face":
			if len(fields) != 16 do continue
			n: [13]int
			good := true
			for k in 0 ..< 13 {
				v, ok := strconv.parse_int(fields[3 + k])
				if !ok do good = false
				n[k] = v
			}
			if !good do continue
			f := Font_Face_File{
				path = unesc(fields[2], allocator), face = n[0], weight = n[1], weights = {n[2], n[3]},
				italic = n[4] != 0, fixed = n[5] != 0, variable = n[6] != 0, width = n[7],
				ranges = {u32(n[8]), u32(n[9]), u32(n[10]), u32(n[11])}, glyphs = n[12],
			}
			family := unesc(fields[1], context.temp_allocator)
			files, has := &out.families[family]
			if !has {
				key := strings.clone(family, allocator)
				out.families[key] = make([dynamic]Font_Face_File, allocator)
				append(&out.names, key)
				files = &out.families[key]
			}
			append(files, f)
		}
	}
	if len(out.roots) == 0 {
		font_index_destroy(&out)
		return false
	}
	out.built = true
	font_index_destroy(idx)
	idx^ = out
	return true
}
