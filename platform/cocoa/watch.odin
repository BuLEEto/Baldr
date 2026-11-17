#+build darwin
package cocoa

// File watches through FSEvents.
//
// A watched file is its parent directory, filtered to the file's name, as on
// Linux: an editor usually saves by writing a new file and renaming it over
// the old, so a watch on the file's own inode sees the rename and nothing
// after.
//
// FSEvents is recursive with no flag to stop it, and the contract is a
// directory and its entries, one level, so anything deeper is dropped here.
//
// The stream is scheduled on the main run loop, which `pump` turns, so
// callbacks arrive inside a pump and appending to the queue needs no lock.

import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "baldr:platform"

foreign import cs "system:CoreServices.framework"
foreign import cf "system:CoreFoundation.framework"

@(private) @(objc_class = "NSFileManager")
File_Manager :: struct {using _: NS.Object}

@(private) Stream_Ref :: rawptr
@(private) Run_Loop_Ref :: rawptr

@(private)
Stream_Context :: struct {
	version: c.long,
	info:    rawptr,
	retain:  rawptr,
	release: rawptr,
	describe: rawptr,
}

@(private)
Stream_Callback :: proc "c" (stream: Stream_Ref, info: rawptr, count: c.size_t,
	paths: rawptr, flags: [^]u32, ids: [^]u64)

foreign cs {
	FSEventStreamCreate :: proc "c" (allocator: rawptr, callback: Stream_Callback, context_: ^Stream_Context,
		paths_to_watch: rawptr, since_when: u64, latency: f64, flags: u32) -> Stream_Ref ---
	FSEventStreamScheduleWithRunLoop :: proc "c" (stream: Stream_Ref, run_loop: Run_Loop_Ref, mode: rawptr) ---
	FSEventStreamStart :: proc "c" (stream: Stream_Ref) -> NS.BOOL ---
	FSEventStreamStop :: proc "c" (stream: Stream_Ref) ---
	FSEventStreamInvalidate :: proc "c" (stream: Stream_Ref) ---
	FSEventStreamRelease :: proc "c" (stream: Stream_Ref) ---
}

foreign cf {
	CFRunLoopGetMain :: proc "c" () -> Run_Loop_Ref ---
	kCFRunLoopDefaultMode: rawptr
}

// The flags this reads. FSEvents has many more; these are the ones that
// answer "was it made, changed or taken away".
@(private) CREATE_FILE_EVENTS :: u32(0x00000010) // kFSEventStreamCreateFlagFileEvents
@(private) CREATE_NO_DEFER    :: u32(0x00000002) // report the first event at once rather than after the latency
@(private) EVENT_SINCE_NOW    :: u64(0xFFFFFFFFFFFFFFFF)
@(private) FLAG_CREATED       :: u32(0x00000100)
@(private) FLAG_REMOVED       :: u32(0x00000200)
@(private) FLAG_RENAMED       :: u32(0x00000800) // both ends of a move; existence tells them apart
@(private) FLAG_MODIFIED      :: u32(0x00001000)
@(private) FLAG_INODE_META    :: u32(0x00000400)

@(private)
Watch :: struct {
	token:  u64,
	stream: Stream_Ref,
	dir:    string, // the directory being watched (owned)
	name:   string, // the entry to report, "" = every entry one level down (owned)
	cocoa:  ^Cocoa,
}

// b_watch starts reporting changes under `path` as Ev_Watch carrying
// `token`. A path that is a file is watched through its directory.
@(private)
b_watch :: proc(b: ^platform.Backend, path: string, token: u64) -> bool {
	c := self(b)
	if path == "" do return false
	dir, name := watch_split(path)
	w := new(Watch, c.allocator)
	if w == nil do return false
	w.token = token
	w.cocoa = c
	// FSEvents reports resolved paths, so the directory is resolved too or
	// nothing matches: `/tmp` is a symlink to `/private/tmp` on every Mac.
	w.dir = strings.clone(real_path(dir, context.temp_allocator), c.allocator) or_else ""
	w.name = strings.clone(name, c.allocator) or_else ""

	paths := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^NS.MutableArray, NS.MutableArray, "alloc"), "init")
	if paths == nil {
		watch_free(c, w)
		return false
	}
	defer intrinsics.objc_send(nil, paths, "release")
	s := ns_str(w.dir)
	if s == nil {
		watch_free(c, w)
		return false
	}
	defer s->release()
	intrinsics.objc_send(nil, paths, "addObject:", s)

	ctx := Stream_Context{info = w}
	// 0.2 s: FSEvents coalesces inside the latency, so a build writing a
	// thousand files does not wake the app a thousand times, and a save
	// still feels immediate. NO_DEFER delivers the first event of a quiet
	// period at once.
	w.stream = FSEventStreamCreate(nil, watch_callback, &ctx, paths, EVENT_SINCE_NOW, 0.2,
		CREATE_FILE_EVENTS | CREATE_NO_DEFER)
	if w.stream == nil {
		watch_free(c, w)
		return false
	}
	FSEventStreamScheduleWithRunLoop(w.stream, CFRunLoopGetMain(), kCFRunLoopDefaultMode)
	if !bool(FSEventStreamStart(w.stream)) {
		FSEventStreamInvalidate(w.stream)
		FSEventStreamRelease(w.stream)
		w.stream = nil
		watch_free(c, w)
		return false
	}
	append(&c.watches, w)
	if c.debug_files {
		fmt.eprintfln("baldr/cocoa: watching %s%s (token %d)%s", w.dir,
			fmt.tprintf(" for %q", w.name) if w.name != "" else " and its entries", token,
			fmt.tprintf(" — %s resolved", dir) if w.dir != dir else "")
	}
	return true
}

@(private)
b_unwatch :: proc(b: ^platform.Backend, token: u64) {
	c := self(b)
	for w, i in c.watches {
		if w.token != token do continue
		watch_stop(w)
		watch_free(c, w)
		ordered_remove(&c.watches, i)
		return
	}
}

@(private)
watch_shutdown :: proc(c: ^Cocoa) {
	for w in c.watches {
		watch_stop(w)
		watch_free(c, w)
	}
	delete(c.watches)
}

@(private = "file")
watch_stop :: proc(w: ^Watch) {
	if w.stream == nil do return
	FSEventStreamStop(w.stream)
	FSEventStreamInvalidate(w.stream)
	FSEventStreamRelease(w.stream)
	w.stream = nil
}

@(private = "file")
watch_free :: proc(c: ^Cocoa, w: ^Watch) {
	delete(w.dir, c.allocator)
	delete(w.name, c.allocator)
	free(w, c.allocator)
}

// watch_split decides what to watch and what to report. A path with a
// trailing separator, or one that is a directory on disk, is watched as a
// directory; anything else is its parent, filtered to its own name.
@(private = "file")
watch_split :: proc(path: string) -> (dir: string, name: string) {
	clean := strings.trim_right(path, "/")
	if clean == "" do return "/", ""
	if is_directory(clean) do return clean, ""
	return dir_of(clean), base_of(clean)
}

// real_path is the path with every symlink resolved, the form FSEvents
// reports in. Falls back to the path as given when it does not exist yet, so
// a directory about to be made can still be watched.
@(private = "file")
real_path :: proc(path: string, allocator := context.allocator) -> string {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	resolved := posix.realpath(c_path)
	if resolved == nil do return path
	out, err := strings.clone(string(resolved), allocator)
	posix.free(rawptr(resolved))
	return out if err == nil else path
}

// dir_of and base_of split a path without allocating, returning slices of
// the caller's string: `core:path/filepath`'s `dir` allocates, and this runs
// per event under the backend's allocator, so it would leak.
@(private = "file")
dir_of :: proc(path: string) -> string {
	for i := len(path) - 1; i > 0; i -= 1 {
		if path[i] == '/' do return path[:i]
	}
	return "/"
}

@(private = "file")
base_of :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' do return path[i + 1:]
	}
	return path
}

@(private = "file")
is_directory :: proc(path: string) -> bool {
	p := intrinsics.objc_send(^NS.Object, File_Manager, "defaultManager")
	if p == nil do return false
	s := ns_str(path)
	if s == nil do return false
	defer s->release()
	is_dir: NS.BOOL
	exists := intrinsics.objc_send(NS.BOOL, p, "fileExistsAtPath:isDirectory:", s, &is_dir)
	return bool(exists) && bool(is_dir)
}

// watch_callback runs on the main run loop, inside a pump.
@(private = "file")
watch_callback :: proc "c" (stream: Stream_Ref, info: rawptr, count: c.size_t,
	paths: rawptr, flags: [^]u32, ids: [^]u64) {
	w := (^Watch)(info)
	if w == nil || w.cocoa == nil do return
	c := w.cocoa
	context = c.ctx
	list := ([^]cstring)(paths)
	woke := false
	for i in 0 ..< int(count) {
		path := string(list[i])
		if path == "" do continue
		name, want := watch_entry(w, path)
		if !want do continue
		kind := watch_kind(flags[i], path)
		append(&c.queue, platform.Ev_Watch{token = w.token, name = arena_str(c, name), kind = kind})
		woke = true
		// The flags are in the line because they are cumulative per path
		// per batch, so a kind that looks wrong is usually two events in one.
		if c.debug_files do fmt.eprintfln("baldr/cocoa: watch %d: %v %s (flags %#x)", w.token, kind, path, flags[i])
	}
	if woke do b_wake(&c.backend)
}

// watch_entry decides whether this path is one this watch reports, and what
// to call it: the entry's name for a directory watch, "" for a file watch
// (the path itself, which is what the contract asks for).
@(private = "file")
watch_entry :: proc(w: ^Watch, path: string) -> (name: string, want: bool) {
	parent := dir_of(path)
	base := base_of(path)
	if parent != w.dir do return "", false // deeper than one level: FSEvents is recursive, the contract is not
	if w.name != "" do return "", base == w.name // a watched file: the path itself
	return base, true
}

// watch_kind reads FSEvents' flags, which are cumulative for a path over a
// stream's life, not a description of the latest change. For
// `touch a.txt; echo hi >> a.txt; rm a.txt`:
//
//     0x10100  IsFile + Created                      the touch
//     0x11100  IsFile + Created + Modified           the append
//     0x11300  IsFile + Created + Modified + Removed the rm
//
// So whether the path exists now decides, and the flags only separate a
// file nothing has written to from one that changed. A rename needs no case:
// renamed here, it exists; renamed away, it does not. Unlike inotify, a
// file created and written in one batch arrives as Modified; knowing better
// would mean listing every watched directory.
@(private = "file")
watch_kind :: proc(flag: u32, path: string) -> platform.Watch_Kind {
	if !path_exists(path) do return .Removed
	if flag & FLAG_CREATED != 0 && flag & (FLAG_MODIFIED | FLAG_INODE_META) == 0 do return .Created
	return .Modified
}

@(private = "file")
path_exists :: proc(path: string) -> bool {
	p := intrinsics.objc_send(^NS.Object, File_Manager, "defaultManager")
	if p == nil do return false
	s := ns_str(path)
	if s == nil do return false
	defer s->release()
	return bool(intrinsics.objc_send(NS.BOOL, p, "fileExistsAtPath:", s))
}
