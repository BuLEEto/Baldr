#+build windows
package win32

// File watches on Windows, for the toolkit's `watch` subscription
// (Backend.watch).
//
// The shape follows platform/inotify_linux.odin, so the two platforms
// behave the same:
//
//   - A watched file is its parent directory, filtered to the name. A
//     save that writes a new file and renames it over the old one replaces
//     the inode (or the file id), and a watch on the file itself would be
//     left holding the old one. Watching the parent sees the rename.
//   - Several tokens on one directory share its handle, as inotify shares a
//     watch descriptor, and the handle closes when the last one goes.
//   - `name` is the entry that changed for a directory watch, and "" for a
//     file watch (the caller already knows the name).
//   - Repeats inside one drain collapse: a single save arrives as several
//     notifications and an app wants one message.
//
// ReadDirectoryChangesW is asynchronous, so each directory keeps an
// OVERLAPPED with an event, and the pump waits on those events alongside
// the message queue — otherwise a change is only noticed the next time
// something else wakes the loop.

import "base:runtime"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

// WATCH_BUF is one directory's notification buffer. Changes that arrive
// while a read is not armed are lost, and Windows says so by completing the
// read with zero bytes — see watch_drain, which reports that rather than
// hiding it.
@(private = "file") WATCH_BUF :: 16 * 1024

// MAX_WAIT is Win32's MAXIMUM_WAIT_OBJECTS. The pump spends one on the
// message queue, so that many directories less one can be watched at once.
@(private) MAX_WAIT :: 64

// ERROR_IO_INCOMPLETE: the read is still running, which is the usual answer.
@(private = "file") ERROR_IO_INCOMPLETE :: win.DWORD(996)

@(private = "file")
WATCH_FILTER :: win.DWORD(
	win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME |
	win.FILE_NOTIFY_CHANGE_ATTRIBUTES | win.FILE_NOTIFY_CHANGE_SIZE |
	win.FILE_NOTIFY_CHANGE_LAST_WRITE | win.FILE_NOTIFY_CHANGE_CREATION)

// Watch_Dir is one directory being read. Heap-allocated so the pointers
// held in `watches` survive the list growing.
@(private)
Watch_Dir :: struct {
	path:   string, // owned
	handle: win.HANDLE,
	ov:     win.OVERLAPPED,
	armed:  bool,
	// DWORD-aligned, which ReadDirectoryChangesW requires and a [N]u8 field
	// here would not be: misaligned, the read arms and never completes, with
	// no error. Declared as u32s for the alignment.
	buf:    [WATCH_BUF / size_of(u32)]u32,
}

@(private)
Watch :: struct {
	token: u64,
	dir:   ^Watch_Dir,
	name:  string, // owned: the entry to report, "" = every entry (a directory watch)
}

// watch starts reporting `path` under `token` (Backend.watch).
@(private)
watch :: proc(b: ^platform.Backend, path: string, token: u64) -> bool {
	w := data(b)
	if len(path) == 0 do return false
	dir, name := path, ""
	if !is_directory(path) {
		dir, name = os.split_path(path)
		if len(dir) == 0 do dir = "."
	}
	d := watch_dir_for(w, dir)
	if d == nil {
		debugf(w, "watch %q: cannot open %q for changes (error %d)", path, dir, u32(win.GetLastError()))
		return false
	}
	append(&w.watches, Watch{token = token, dir = d, name = strings.clone(name, w.allocator)})
	debugf(w, "watch %q -> directory %q, entry %q (token %d)", path, dir, name, token)
	return true
}

// unwatch stops `token`; the directory closes when no other token wants it.
@(private)
unwatch :: proc(b: ^platform.Backend, token: u64) {
	w := data(b)
	for it, i in w.watches {
		if it.token != token do continue
		d := it.dir
		delete(it.name, w.allocator)
		ordered_remove(&w.watches, i)
		for o in w.watches do if o.dir == d do return // still wanted
		watch_dir_close(w, d)
		return
	}
}

// watch_dir_for opens `dir` for reading changes, or hands back the one
// already open for it.
@(private = "file")
watch_dir_for :: proc(w: ^Win32, dir: string) -> ^Watch_Dir {
	for d in w.watch_dirs do if d.path == dir do return d
	if len(w.watch_dirs) >= MAX_WAIT - 1 do return nil // the pump can wait on no more
	h := win.CreateFileW(
		win.utf8_to_wstring(dir, context.temp_allocator),
		win.FILE_LIST_DIRECTORY,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil, win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OVERLAPPED, // BACKUP_SEMANTICS is how a directory is opened
		nil)
	if h == win.INVALID_HANDLE_VALUE do return nil
	d := new(Watch_Dir, w.allocator)
	d.path = strings.clone(dir, w.allocator)
	d.handle = h
	// Manual reset, so a change that lands between the wait and the drain is
	// still signalled when the drain looks.
	d.ov.hEvent = win.CreateEventW(nil, true, false, nil)
	if d.ov.hEvent == nil {
		win.CloseHandle(h)
		free(d, w.allocator)
		return nil
	}
	append(&w.watch_dirs, d)
	watch_arm(d, w)
	return d
}

// is_directory asks Windows directly rather than trust `os.is_directory`
// across Odin versions. Getting it wrong is silent: the folder is watched
// as a file, through its parent, and nothing inside it is ever reported.
@(private = "file")
is_directory :: proc(path: string) -> bool {
	attrs := win.GetFileAttributesW(win.utf8_to_wstring(path, context.temp_allocator))
	if attrs == win.INVALID_FILE_ATTRIBUTES do return false
	return attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0
}

@(private = "file")
watch_arm :: proc(d: ^Watch_Dir, w: ^Win32) {
	if d.armed do return
	win.ResetEvent(d.ov.hEvent)
	got: win.DWORD
	ok := win.ReadDirectoryChangesW(d.handle, rawptr(&d.buf[0]), WATCH_BUF, false, WATCH_FILTER, &got, &d.ov, nil)
	err := win.GetLastError()
	d.armed = bool(ok) || err == win.ERROR_IO_PENDING
	if !d.armed do debugf(w, "watch %q: ReadDirectoryChangesW would not start (error %d)", d.path, u32(err))
}

@(private = "file")
watch_dir_close :: proc(w: ^Win32, d: ^Watch_Dir) {
	for it, i in w.watch_dirs {
		if it != d do continue
		ordered_remove(&w.watch_dirs, i)
		break
	}
	if d.armed do win.CancelIo(d.handle)
	if d.ov.hEvent != nil do win.CloseHandle(d.ov.hEvent)
	if d.handle != win.INVALID_HANDLE_VALUE do win.CloseHandle(d.handle)
	delete(d.path, w.allocator)
	free(d, w.allocator)
}

// watch_handles fills `out` with the directories' events, for the pump to
// wait on beside the message queue.
@(private)
watch_handles :: proc(w: ^Win32, out: []win.HANDLE) -> win.DWORD {
	n := 0
	for d in w.watch_dirs {
		if n >= len(out) do break
		if !d.armed do continue
		out[n] = d.ov.hEvent
		n += 1
	}
	return win.DWORD(n)
}

// watch_drain turns completed reads into Ev_Watch and arms the next read.
// Names live in `allocator` — the pump's arena, so they last until the pump
// after the one that made them.
@(private)
watch_drain :: proc(w: ^Win32, out: ^[dynamic]platform.Event, allocator: runtime.Allocator) {
	for d in w.watch_dirs {
		if !d.armed {
			debugf(w, "watch %q: no read is armed", d.path)
			continue
		}
		got: win.DWORD
		if !win.GetOverlappedResult(d.handle, &d.ov, &got, false) {
			if e := win.GetLastError(); e != ERROR_IO_INCOMPLETE {
				debugf(w, "watch %q: the read failed (error %d)", d.path, u32(e))
			}
			continue // still running, or failed
		}
		d.armed = false
		debugf(w, "watch %q: %d bytes of changes", d.path, u32(got))
		if got == 0 {
			// The buffer overflowed and Windows dropped the details. What
			// changed is unknown, so the watch says "something did" rather
			// than nothing: an app re-reads the directory either way.
			watch_report_all(w, d, out, allocator)
			watch_arm(d, w)
			continue
		}
		off := u32(0)
		for {
			bytes := ([^]u8)(&d.buf[0])
			fni := (^FILE_NOTIFY_INFO)(&bytes[off])
			chars := int(fni.file_name_length) / size_of(win.WCHAR)
			name := ""
			if chars > 0 {
				wide := ([^]win.WCHAR)(&fni.file_name[0])[:chars]
				if s, err := win.utf16_to_utf8(wide, context.temp_allocator); err == nil do name = s
			}
			kind := watch_kind(fni.action)
			for it in w.watches {
				if it.dir != d do continue
				if it.name != "" && !path_eq(name, it.name) do continue
				report := name if it.name == "" else ""
				if watch_dup(out[:], it.token, report, kind) do continue
				append(out, platform.Ev_Watch{token = it.token, name = strings.clone(report, allocator), kind = kind})
			}
			if fni.next_entry_offset == 0 do break
			off += fni.next_entry_offset
			if int(off) >= WATCH_BUF do break
		}
		watch_arm(d, w)
	}
}

// watch_report_all says "something changed" for every token on `d`, for the
// overflow case where Windows kept no details.
@(private = "file")
watch_report_all :: proc(w: ^Win32, d: ^Watch_Dir, out: ^[dynamic]platform.Event, allocator: runtime.Allocator) {
	for it in w.watches {
		if it.dir != d do continue
		if watch_dup(out[:], it.token, "", .Modified) do continue
		append(out, platform.Ev_Watch{token = it.token, name = "", kind = .Modified})
	}
}

// path_eq compares entry names the way Windows compares them: without case.
@(private = "file")
path_eq :: proc(a, b: string) -> bool {
	return strings.equal_fold(a, b)
}

@(private = "file")
watch_kind :: proc(action: win.DWORD) -> platform.Watch_Kind {
	switch action {
	case win.FILE_ACTION_ADDED, win.FILE_ACTION_RENAMED_NEW_NAME:   return .Created
	case win.FILE_ACTION_REMOVED, win.FILE_ACTION_RENAMED_OLD_NAME: return .Removed
	}
	return .Modified
}

@(private = "file")
watch_dup :: proc(out: []platform.Event, token: u64, name: string, kind: platform.Watch_Kind) -> bool {
	for e in out {
		if v, is := e.(platform.Ev_Watch); is && v.token == token && v.kind == kind && v.name == name do return true
	}
	return false
}

// watch_shutdown closes everything still open.
@(private)
watch_shutdown :: proc(w: ^Win32) {
	for it in w.watches do delete(it.name, w.allocator)
	delete(w.watches)
	w.watches = nil
	for d in w.watch_dirs {
		if d.armed do win.CancelIo(d.handle)
		if d.ov.hEvent != nil do win.CloseHandle(d.ov.hEvent)
		if d.handle != win.INVALID_HANDLE_VALUE do win.CloseHandle(d.handle)
		delete(d.path, w.allocator)
		free(d, w.allocator)
	}
	delete(w.watch_dirs)
	w.watch_dirs = nil
}
