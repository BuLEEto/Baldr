package platform

// File watches on Linux through inotify, for any Linux backend to poll:
// one inotify fd, one watch descriptor per directory. A watched file is
// its parent directory filtered to the file's name, so a save that
// writes a new file and renames it over the old one is still seen.

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sys/linux"

Inotify :: struct {
	fd:      linux.Fd, // -1 when inotify is unavailable
	watches: [dynamic]Inotify_Watch,
}

Inotify_Watch :: struct {
	token: u64,
	wd:    linux.Wd,
	name:  string, // owned: the entry to report, "" = every entry (a directory watch)
}

@(private)
INOTIFY_MASK :: linux.Inotify_Event_Mask{.MODIFY, .ATTRIB, .CLOSE_WRITE, .MOVED_FROM, .MOVED_TO, .CREATE, .DELETE, .DELETE_SELF, .MOVE_SELF}

// inotify_open makes the fd (non-blocking, for a poll set).
inotify_open :: proc(n: ^Inotify) -> bool {
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	n.fd = fd if err == .NONE else -1
	return err == .NONE
}

inotify_close :: proc(n: ^Inotify) {
	for w in n.watches do delete(w.name)
	delete(n.watches)
	n.watches = nil
	if n.fd >= 0 do linux.close(n.fd)
	n.fd = -1
}

// inotify_watch starts reporting `path` under `token`: a directory as it
// is, a file (present or not yet) through its parent.
inotify_watch :: proc(n: ^Inotify, path: string, token: u64) -> bool {
	if n.fd < 0 || len(path) == 0 do return false
	dir, name := path, ""
	if !os.is_directory(path) {
		dir, name = os.split_path(path)
		if len(dir) == 0 do dir = "."
	}
	cpath := strings.clone_to_cstring(dir, context.temp_allocator)
	wd, err := linux.inotify_add_watch(n.fd, cpath, INOTIFY_MASK)
	if err != .NONE do return false
	append(&n.watches, Inotify_Watch{token = token, wd = wd, name = strings.clone(name)})
	return true
}

// inotify_unwatch stops `token`; the directory's descriptor goes when no
// other token shares it.
inotify_unwatch :: proc(n: ^Inotify, token: u64) {
	for w, i in n.watches {
		if w.token != token do continue
		wd := w.wd
		delete(w.name)
		ordered_remove(&n.watches, i)
		shared := false
		for o in n.watches do if o.wd == wd { shared = true; break }
		if !shared do linux.inotify_rm_watch(n.fd, wd)
		return
	}
}

// inotify_drain reads what changed and appends one Ev_Watch per watch it
// concerns; names live in `allocator`. Repeats within one drain collapse.
inotify_drain :: proc(n: ^Inotify, out: ^[dynamic]Event, allocator: runtime.Allocator) {
	if n.fd < 0 do return
	raw: [512]u64 // aligned for the event headers
	buf := ([^]u8)(&raw[0])[:size_of(raw)]
	for {
		got, err := linux.read(n.fd, buf)
		if err != .NONE || got <= 0 do break
		off := 0
		for off + size_of(linux.Inotify_Event) <= got {
			ev := (^linux.Inotify_Event)(&buf[off])
			name := ""
			if ev.len > 0 do name = string(cstring(&buf[off + size_of(linux.Inotify_Event)]))
			if kind, changed := inotify_kind(ev.mask); changed {
				self := ev.mask & {.DELETE_SELF, .MOVE_SELF} != {}
				for w in n.watches {
					if w.wd != ev.wd do continue
					if w.name != "" && name != w.name && !self do continue
					report := name if w.name == "" else ""
					if inotify_dup(out[:], w.token, report, kind) do continue
					append(out, Ev_Watch{token = w.token, name = strings.clone(report, allocator), kind = kind})
				}
			}
			off += size_of(linux.Inotify_Event) + int(ev.len)
		}
	}
}

@(private)
inotify_kind :: proc(mask: linux.Inotify_Event_Mask) -> (Watch_Kind, bool) {
	if mask & {.CREATE, .MOVED_TO} != {} do return .Created, true
	if mask & {.DELETE, .MOVED_FROM, .DELETE_SELF, .MOVE_SELF} != {} do return .Removed, true
	if mask & {.MODIFY, .CLOSE_WRITE, .ATTRIB} != {} do return .Modified, true
	return .Modified, false
}

@(private)
inotify_dup :: proc(out: []Event, token: u64, name: string, kind: Watch_Kind) -> bool {
	for e in out {
		if w, is := e.(Ev_Watch); is && w.token == token && w.kind == kind && w.name == name do return true
	}
	return false
}
