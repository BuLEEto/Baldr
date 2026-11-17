#+build darwin
package cocoa

// Opening a link in the person's browser, and a file or folder in the
// Finder, through NSWorkspace.
//
// NSWorkspace is not in the Odin bindings, so the class is declared here for
// the objc runtime as `file_dialog` declares NSOpenPanel. Three selectors
// cover both procs: `sharedWorkspace`, `openURL:` and
// `selectFile:inFileViewerRootedAtPath:`.
//
// The toolkit has already checked what it hands over (`baldr/url.odin`:
// http, https and mailto only; `open_path`: it exists and is not
// executable), and neither selector takes a command line, so nothing in a
// URL or path can become an argument.
//
// Both answer with `Ev_Url` carrying the command's token (one counter feeds
// both), queued for the next pump, as on Windows.

import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "baldr:platform"

@(private) @(objc_class = "NSWorkspace")
Workspace :: struct {using _: NS.Object}

// `sharedWorkspace` is a class method, so the type is the receiver, as in
// `general_pasteboard`.
@(private)
shared_workspace :: proc "contextless" () -> ^Workspace {
	return intrinsics.objc_send(^Workspace, Workspace, "sharedWorkspace")
}

@(private)
b_open_url :: proc(b: ^platform.Backend, url: string, token: u64) -> bool {
	// `token` is a Wayland activation token; macOS has no equivalent.
	c := self(b)
	ok := false
	if ws := shared_workspace(); ws != nil {
		s := ns_str(url)
		defer s->release()
		// URLWithString: answers nil for a URL macOS cannot parse.
		if u := intrinsics.objc_send(^NS.URL, NS.URL, "URLWithString:", s); u != nil {
			ok = bool(intrinsics.objc_send(NS.BOOL, ws, "openURL:", u))
		}
	}
	append(&c.queue, platform.Ev_Url{token = token, ok = ok})
	return true
}

@(private)
b_open_path :: proc(b: ^platform.Backend, path: string, reveal: bool, token: u64) -> bool {
	c := self(b)
	ok := false
	if ws := shared_workspace(); ws != nil {
		p := ns_str(path)
		defer p->release()
		if reveal {
			// Shows the file selected in the Finder. Not deprecated, and takes
			// strings where the newer selector needs an NSArray of URLs. A nil
			// root means wherever the file is.
			ok = bool(intrinsics.objc_send(NS.BOOL, ws, "selectFile:inFileViewerRootedAtPath:", p, (^NS.String)(nil)))
		} else if u := NS.URL.alloc()->initFileURLWithPath(p); u != nil {
			defer u->release()
			ok = bool(intrinsics.objc_send(NS.BOOL, ws, "openURL:", u))
		}
	}
	append(&c.queue, platform.Ev_Url{token = token, ok = ok})
	return true
}
