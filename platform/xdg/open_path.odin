package xdg

// Opening a local file in its default app, and showing one in its folder.
//
// The portal's OpenFile and OpenDirectory take an open descriptor rather
// than a path, so nothing is re-resolved between the toolkit's checks and
// the handler's open, and the handler gets the file even where it could not
// open the name itself. The descriptor goes over the socket with
// SCM_RIGHTS; the portal receives a copy and this one is closed here.
//
// Without a portal, `xdg-open` takes a path. For `reveal` that is the
// parent folder, opened with nothing selected: no file manager picks a file
// out from a command line.
//
// The answer comes back as Ev_Url with the ask's token, as for open_url.

import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import portal "baldr:sys/portal"

// open_path hands a local path to the desktop (Backend.open_path).
open_path :: proc(x: ^Xdg, path: string, reveal: bool, token: u64) -> bool {
	
	if x.bus != nil {
		// Not O_PATH: the handler reads through the descriptor. Close-on-exec
		// so nothing this process spawns inherits it. OpenDirectory takes the
		// file itself, so the file manager can pick it out.
		want := path
		flags := linux.Open_Flags{.CLOEXEC}
		cpath := strings.clone_to_cstring(want, context.temp_allocator)
		fd, err := linux.open(cpath, flags)
		if err == .NONE {
			req := new(Url_Req)
			req^ = {x = x, token = token}
			sent := portal.open_directory(x.bus, i32(fd), "", on_url_response, req) if reveal else
			        portal.open_file(x.bus, i32(fd), "", on_url_response, req)
			linux.close(fd) // the portal has its own copy
			if sent {
				debugf(x, "open_path %q (reveal %v) through the portal (token %d)", want, reveal, token)
				return true
			}
			free(req)
		} else {
			debugf(x, "open_path %q: cannot open it (%v)", want, err)
		}
	}
	// No portal: xdg-open can open a folder but not pick anything out in it.
	// A reveal opens the parent, for a folder as much as a file, matching
	// OpenDirectory and Explorer's `/select,`; opening a folder as itself is
	// a plain open_path.
	if reveal {
		target := filepath.dir(path)
		defer delete(target)
		return url_spawn(x, target, token)
	}
	return url_spawn(x, path, token)
}
