#+build windows
package win32

// Opening a link in the person's own browser or mail app.
// ShellExecuteW hands the URL to whatever Windows has registered for its
// scheme, which is the desktop's business, not the toolkit's.
//
// The toolkit has already checked the URL (baldr/url.odin): http, https and
// mailto only. ShellExecuteW takes a bare string, never a command line, so
// nothing in the URL can become an argument of its own.
//
// ShellExecuteW answers at once — a value over 32 means a handler was
// started — so Ev_Url is queued for the pump the app is in.

import win "core:sys/windows"
import "baldr:platform"

@(private)
open_url :: proc(b: ^platform.Backend, url: string, token: u64) -> bool {
	w := (^Win32)(b.data)
	wide := win.utf8_to_wstring(url, context.temp_allocator)
	r := win.ShellExecuteW(nil, win.utf8_to_wstring("open", context.temp_allocator), wide, nil, nil, win.SW_SHOWNORMAL)
	ok := uintptr(r) > 32 // the documented "it started something" line
	append(&w.queue, platform.Ev_Url{token = token, ok = ok})
	return true
}
