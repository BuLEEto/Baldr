#+build windows
package win32

// Opening a file the app itself made, and showing one in its folder.
// ShellExecuteW "open" hands the file to whatever Windows has registered
// for its extension, and Explorer's /select shows it in its folder with the
// file picked out, which is what "Show in folder" means on Windows.
//
// The toolkit has already checked the path (baldr/path_open.odin): it
// exists, it is a regular file (or a folder, for reveal), it is not
// executable and it is not a .desktop. ShellExecuteW takes a bare string
// rather than a command line, so nothing in the path becomes an argument.
//
// Explorer is the one place a command line is unavoidable: it takes
// `/select,<path>` as one argument, passed as a single parameter string,
// not through a shell. SHOpenFolderAndSelectItems does the same through COM
// at the cost of an ITEMIDLIST, a CoInitialize and two frees per path out.
//
// Both answer at once — a value over 32 means a handler was started — so
// Ev_Url is queued for the pump the app is in, with the ask's token.

import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

@(private)
open_path :: proc(b: ^platform.Backend, path: string, reveal: bool, token: u64) -> bool {
	w := (^Win32)(b.data)
	ta := context.temp_allocator
	ok: bool
	if reveal {
		// Explorer wants backslashes; a forward slash in /select, leaves it
		// showing Documents instead of the folder that was asked for.
		win_path, _ := strings.replace_all(path, "/", "\\", ta)
		args := fmt.tprintf("/select,\"%s\"", win_path)
		r := win.ShellExecuteW(nil, nil, win.utf8_to_wstring("explorer.exe", ta),
			win.utf8_to_wstring(args, ta), nil, win.SW_SHOWNORMAL)
		ok = uintptr(r) > 32
	} else {
		r := win.ShellExecuteW(nil, win.utf8_to_wstring("open", ta),
			win.utf8_to_wstring(path, ta), nil, nil, win.SW_SHOWNORMAL)
		ok = uintptr(r) > 32
	}
	append(&w.queue, platform.Ev_Url{token = token, ok = ok})
	return true
}
