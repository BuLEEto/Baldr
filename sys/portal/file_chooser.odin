#+build linux
// org.freedesktop.portal.FileChooser: OpenFile / SaveFile through the
// Request/Response pattern. The dialog is the desktop's native one, works
// inside Flatpak, and the result is a list of URIs (file:// for local
// files; document-portal paths when sandboxed).
package portal

import "base:runtime"
import "baldr:dbus"

// File_Filter is one entry of the dialog's type filter; patterns are shell
// globs ("*.png") or MIME types ("image/png") — `mime` picks which.
File_Filter :: struct {
	name:     string,
	patterns: []string,
	mime:     bool,
}

// Open_Options configures file_chooser_open. Zero values mean "portal
// default": a single-file, non-directory picker titled by the portal.
Open_Options :: struct {
	title:          string,
	parent_window:  string, // "wayland:<export handle>", "x11:<window id in hex>", or ""
	accept_label:   string, // button text, "" = default ("Open")
	multiple:       bool,
	directory:      bool, // pick folders instead of files (portal ≥ 3)
	current_folder: string, // absolute path to start in
	filters:        []File_Filter,
}

// Save_Options configures file_chooser_save.
Save_Options :: struct {
	title:          string,
	parent_window:  string,
	accept_label:   string,
	current_name:   string, // suggested file name
	current_folder: string, // absolute path to start in
	current_file:   string, // absolute path of the file being re-saved
	filters:        []File_Filter,
}

// File_Result is delivered to File_Callback. `uris` is valid during the
// callback only (clone to keep); empty unless response == .Success.
File_Result :: struct {
	response: Response,
	uris:     []string,
}

// File_Callback receives the dialog outcome (from dbus.dispatch).
File_Callback :: #type proc(user: rawptr, result: File_Result)

// file_chooser_open shows the native open dialog. Returns false if the
// request could not be sent (no bus / no portal); otherwise cb is called
// exactly once, with .Failed if the portal rejected the call.
file_chooser_open :: proc(conn: ^dbus.Connection, opts: Open_Options, cb: File_Callback, user: rawptr, allocator := context.allocator) -> bool {
	ta := context.temp_allocator
	args := [2]dbus.Value{opts.parent_window, opts.title}
	entries := open_options_entries(opts, ta)
	return request_start(conn, IFACE_FILE_CHOOSER, "OpenFile", args[:], entries, on_file_response, rawptr(cb), user, allocator)
}

// file_chooser_save shows the native save dialog; the single URI in the
// result is where to write.
file_chooser_save :: proc(conn: ^dbus.Connection, opts: Save_Options, cb: File_Callback, user: rawptr, allocator := context.allocator) -> bool {
	ta := context.temp_allocator
	args := [2]dbus.Value{opts.parent_window, opts.title}
	entries := save_options_entries(opts, ta)
	return request_start(conn, IFACE_FILE_CHOOSER, "SaveFile", args[:], entries, on_file_response, rawptr(cb), user, allocator)
}

// open_options_entries builds the OpenFile options a{sv} entries (without
// handle_token, which request_start adds). Exposed for tests.
open_options_entries :: proc(opts: Open_Options, allocator: runtime.Allocator) -> []dbus.Dict_Entry {
	out := make([dynamic]dbus.Dict_Entry, allocator)
	append(&out, dbus.Dict_Entry{"modal", true})
	append(&out, dbus.Dict_Entry{"multiple", opts.multiple})
	append(&out, dbus.Dict_Entry{"directory", opts.directory})
	if opts.accept_label != "" do append(&out, dbus.Dict_Entry{"accept_label", opts.accept_label})
	if opts.current_folder != "" do append(&out, dbus.Dict_Entry{"current_folder", path_bytes(opts.current_folder, allocator)})
	if len(opts.filters) > 0 do append(&out, dbus.Dict_Entry{"filters", filters_value(opts.filters, allocator)})
	return out[:]
}

// save_options_entries builds the SaveFile options entries. Exposed for tests.
save_options_entries :: proc(opts: Save_Options, allocator: runtime.Allocator) -> []dbus.Dict_Entry {
	out := make([dynamic]dbus.Dict_Entry, allocator)
	append(&out, dbus.Dict_Entry{"modal", true})
	if opts.accept_label != "" do append(&out, dbus.Dict_Entry{"accept_label", opts.accept_label})
	if opts.current_name != "" do append(&out, dbus.Dict_Entry{"current_name", opts.current_name})
	if opts.current_folder != "" do append(&out, dbus.Dict_Entry{"current_folder", path_bytes(opts.current_folder, allocator)})
	if opts.current_file != "" do append(&out, dbus.Dict_Entry{"current_file", path_bytes(opts.current_file, allocator)})
	if len(opts.filters) > 0 do append(&out, dbus.Dict_Entry{"filters", filters_value(opts.filters, allocator)})
	return out[:]
}

// path_bytes encodes a path as the portal wants it: `ay` with a trailing NUL.
@(private)
path_bytes :: proc(path: string, allocator: runtime.Allocator) -> dbus.Value {
	b := make([]u8, len(path) + 1, allocator)
	copy(b, path)
	b[len(path)] = 0
	return b
}

// filters_value encodes a(sa(us)): array of (name, array of (kind, pattern)),
// kind 0 = glob, 1 = MIME type.
@(private)
filters_value :: proc(filters: []File_Filter, allocator: runtime.Allocator) -> dbus.Value {
	items := make([]dbus.Value, len(filters), allocator)
	for f, i in filters {
		pats := make([]dbus.Value, len(f.patterns), allocator)
		for p, j in f.patterns {
			fields := make([]dbus.Value, 2, allocator)
			fields[0] = u32(1 if f.mime else 0)
			fields[1] = p
			pats[j] = dbus.Struct{fields = fields}
		}
		outer := make([]dbus.Value, 2, allocator)
		outer[0] = f.name
		outer[1] = dbus.Array{sig = "(us)", items = pats}
		items[i] = dbus.Struct{fields = outer}
	}
	return dbus.Array{sig = "(sa(us))", items = items}
}

// on_file_response extracts results["uris"] (as) and calls the caller.
@(private)
on_file_response :: proc(req: ^Request, response: Response, results: dbus.Value) {
	if req.cb == nil do return
	cb := File_Callback(req.cb)
	res := File_Result{response = response}
	if response == .Success {
		if uris, ok := dbus.dict_get(results, "uris"); ok {
			res.uris, _ = dbus.as_strings(uris, context.temp_allocator)
		}
	}
	cb(req.user, res)
}

// uri_to_path turns a portal "file://" URI into a local path, decoding
// percent escapes ("file:///home/user/a%20b.txt" → "/home/user/a b.txt").
// Returns false for any other scheme (a document-portal path is still a
// file:// URI, so it goes through).
uri_to_path :: proc(uri: string, allocator := context.allocator) -> (path: string, ok: bool) {
	rest := uri
	if len(rest) < 7 || rest[:7] != "file://" do return "", false
	rest = rest[7:]
	// an authority ("file://localhost/x") is skipped; a bare "file:///x" has none
	if len(rest) > 0 && rest[0] != '/' {
		i := 0
		for i < len(rest) && rest[i] != '/' do i += 1
		rest = rest[i:]
	}
	out := make([dynamic]u8, 0, len(rest), allocator)
	i := 0
	for i < len(rest) {
		c := rest[i]
		if c == '%' && i + 2 < len(rest) + 0 && i + 2 <= len(rest) - 1 {
			h, hok := hex_nibble(rest[i + 1])
			l, lok := hex_nibble(rest[i + 2])
			if hok && lok {
				append(&out, u8(h << 4 | l))
				i += 3
				continue
			}
		}
		append(&out, c)
		i += 1
	}
	return string(out[:]), true
}

@(private)
hex_nibble :: proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9': return c - '0', true
	case 'a' ..= 'f': return c - 'a' + 10, true
	case 'A' ..= 'F': return c - 'A' + 10, true
	}
	return 0, false
}
