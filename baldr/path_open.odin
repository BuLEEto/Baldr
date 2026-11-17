package baldr

// Opening a file the app itself made, and showing one in its folder: an
// exported spreadsheet opened in the person's spreadsheet program, or its
// folder shown so they can attach it to an email.
//
// Deliberately not `open_url`, which takes URLs out of content and so
// allows only http, https and mailto. A path is the app's own; what is
// checked here is what it is, so a mistake upstream cannot turn "open my
// spreadsheet" into "run this".

import "core:os"
import "core:path/filepath"
import "core:strings"

// PATH_MAX_LEN is the longest path handed on. Every filesystem in use stops
// far below this; it is here so a runaway string cannot become an argument.
PATH_MAX_LEN :: 4096

// Path_Opened is what became of `open_path` or `reveal_path`: the path as it
// was asked for, and whether the desktop took it. False means no handler is
// registered for that kind of file, the desktop refused, the person
// dismissed a chooser, or the path was not one Baldr opens — the app can
// then say where the file is instead. The string lives only while the
// message is handled; clone what you keep.
Path_Opened :: struct {
	path: string,
	ok:   bool,
}

// open_path asks the desktop to open a local file with whatever the person
// uses for that kind of file. The toolkit never picks the program and never
// runs a command line; the desktop's handler does (the OpenURI portal on
// Linux, ShellExecuteW on Windows). A folder opens as itself in the file
// manager, unlike `reveal_path`.
//
// The path must exist, be a regular file or a folder, and not be
// executable (`path_openable`); a refused path comes back at once as
// `on_done` with `ok = false`.
//
//	case Open_Export: return baldr.open_path(Msg, s.export_path, proc(e: baldr.Ev(baldr.Path_Opened)) -> Msg {
//		return Tell_Them_Where_It_Is{} if !e.value.ok else Nothing{}
//	})
open_path :: proc($Msg: typeid, path: string, on_done: Handler(Msg, Path_Opened) = nil) -> Cmd(Msg) {
	return {kind = .Open_Path, path = temp_clone(path), on_path = on_done}
}

// reveal_path asks the desktop to show a local file in its folder, picked
// out where the file manager can do that ("Show in folder").
//
// A folder is revealed as a file is: its parent opens with the folder
// picked out (Explorer's `/select,`, the portal's OpenDirectory). To show a
// folder's contents, use `open_path`. Where there is no portal the folder
// opens with nothing picked out, since no file manager selects a file from
// a command line; the handler is told the same either way.
reveal_path :: proc($Msg: typeid, path: string, on_done: Handler(Msg, Path_Opened) = nil) -> Cmd(Msg) {
	return {kind = .Reveal_Path, path = temp_clone(path), on_path = on_done}
}

// path_openable says whether Baldr will hand this path to the desktop. It
// is about what the path *is*, not where it came from:
//
//   - not empty, no NUL, no longer than PATH_MAX_LEN;
//   - it exists, and `stat` can say what it is;
//   - a regular file, or — when `dir_ok` — a folder;
//   - not executable by anyone;
//   - not a kind of file a desktop runs rather than opens, whatever its
//     permissions say: a program, a script, an installer, a shortcut or a
//     launcher (`PATH_RUNS`), and on macOS an application bundle.
//
// Handing a handler any of those turns "open" into "run". Windows reports
// no execute bit on a file at all, and a `.app` is a folder, so the bits
// alone would let a saved attachment named `report.pdf.exe` start. `open_path`
// and `reveal_path` both allow folders; `dir_ok` lets an app ask the narrower
// question.
path_openable :: proc(path: string, dir_ok := false) -> bool {
	if len(path) == 0 || len(path) > PATH_MAX_LEN do return false
	if strings.index_byte(path, 0) >= 0 do return false
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil do return false
	#partial switch fi.type {
	case .Regular:
	case .Directory: if !dir_ok do return false
	case:            return false // a device, a socket, a pipe: not a document
	}
	if fi.type == .Regular && fi.mode & {.Execute_User, .Execute_Group, .Execute_Other} != {} do return false
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if fi.type == .Directory {
		when ODIN_OS == .Darwin {
			for b in PATH_BUNDLES do if ext == b do return false // the Finder launches these
		}
		return true
	}
	for r in PATH_RUNS do if ext == r do return false
	when ODIN_OS == .Windows {
		// and whatever this machine adds to the programs it runs by name
		for e in strings.split(os.get_env("PATHEXT", context.temp_allocator), ";", context.temp_allocator) {
			if e != "" && ext == strings.to_lower(e, context.temp_allocator) do return false
		}
	}
	return true
}

// PATH_RUNS are the kinds of file some desktop runs rather than opens:
// programs (Windows' own, and Linux runs them too through Wine), scripts,
// installers, shortcuts and launchers. Refused everywhere: an app has no
// reason to "open" one as a document.
@(private)
PATH_RUNS :: [?]string{
	".exe", ".com", ".bat", ".cmd", ".pif", ".scr", ".cpl", ".msi", ".msp", ".mst", ".msix", ".appx",
	".appinstaller", ".application", ".appref-ms", ".lnk", ".url", ".scf", ".hta", ".chm", ".js", ".jse",
	".vbs", ".vbe", ".wsf", ".wsh", ".ps1", ".psm1", ".reg", ".inf", ".msc", ".gadget", ".diagcab",
	".settingcontent-ms", ".library-ms", ".search-ms", ".xll", ".jar",
	".desktop", ".sh", ".bash", ".zsh", ".csh", ".ksh", ".fish", ".run", ".appimage", ".flatpakref",
	".command", ".tool", ".terminal", ".workflow", ".action", ".shortcut", ".pkg", ".mpkg",
	".fileloc", ".webloc", ".inetloc", ".prefpane",
}

// PATH_BUNDLES are the folders macOS treats as one thing it launches.
@(private)
PATH_BUNDLES :: [?]string{".app", ".pkg", ".mpkg", ".prefpane", ".saver", ".bundle", ".plugin", ".workflow"}

// path_open_start runs the open_path / reveal_path commands: the path is
// checked here, so no backend sees one the toolkit would not open, and an
// answer always comes back — at once when it cannot be asked for, else as
// Ev_Url with this ask's token.
@(private)
path_open_start :: proc(rt: ^Runtime($State, $Msg), cmd: Cmd(Msg)) {
	b := rt.backend
	reveal := cmd.kind == .Reveal_Path
	// A folder is allowed either way: open_path opens it as itself and
	// reveal_path picks it out in its parent.
	if !path_openable(cmd.path, dir_ok = true) || b == nil || b.open_path == nil {
		handler_deliver(cmd.on_path, Path_Opened{path = cmd.path, ok = false}, 0, &rt.msgs)
		return
	}
	rt.next_token += 1
	token := rt.next_token
	if !b.open_path(b, cmd.path, reveal, token) {
		handler_deliver(cmd.on_path, Path_Opened{path = cmd.path, ok = false}, 0, &rt.msgs)
		return
	}
	rt.pending_paths[token] = Path_Ask(Msg){on_done = cmd.on_path, path = strings.clone(cmd.path)}
}

// Path_Ask is an open_path waiting for the desktop's answer; `path` is owned.
@(private)
Path_Ask :: struct($Msg: typeid) {
	on_done: Handler(Msg, Path_Opened),
	path:    string,
}

// path_open_done delivers the desktop's answer to the app. It shares
// Ev_Url and the token counter with open_url — one kind of answer for every
// "ask the desktop to open something" — so the token says which map it
// belongs to. False when this token was not one of ours.
@(private)
path_open_done :: proc(rt: ^Runtime($State, $Msg), token: u64, ok: bool) -> bool {
	ask, waiting := rt.pending_paths[token]
	if !waiting do return false
	delete_key(&rt.pending_paths, token)
	handler_deliver(ask.on_done, Path_Opened{path = ask.path, ok = ok}, 0, &rt.msgs)
	append(&rt.spent_asks, ask.path) // the message points into it: freed once update has run
	return true
}
