package main

// The desktop's folder picker — `open_files(directory = true)` — on
// whichever desktop it is run: the portal's `directory` on Linux,
// `FOS_PICKFOLDERS` on Windows, `setCanChooseDirectories:` on macOS. A good
// answer is one absolute path that is a directory.
//
//	./build.sh spike folder_pick run
//	FOLDER_PICK_QUIT=30 build/folder_pick     # give up after 30 s
//
// It prints what came back — the absolute path, or that it was cancelled —
// and quits. `FOLDER_PICK_QUIT` (default 60 s) is a bound, so a dialog
// nobody answers cannot leave it running for ever.
//
// The bound does not hold while a dialog is up on macOS or Windows. Both
// are modal in-process — NSOpenPanel's `runModal` and IFileOpenDialog's
// `Show` each run their own event loop — so the app's pump, and every delay
// in it, stops until the dialog is answered. On Linux the portal is
// asynchronous, the loop keeps running, the bound fires, and the dialog
// goes when the app does.
//
// Driving it without a person:
//
//   - macOS: click the panel's Open button through the accessibility tree;
//     synthetic typing goes to whatever is frontmost.
//   - Linux: answer the portal request by hand, which exercises the half
//     Baldr owns (the uris coming back, the file:// decoding, the Ev_Files):
//     `gdbus emit --session --object-path
//     /org/freedesktop/portal/desktop/request/<sender>/<handle_token>
//     --signal org.freedesktop.portal.Request.Response 0
//     "{'uris': <['file:///some/dir']>}"`
//   - Windows: from the interactive session (session 0 can neither see a
//     dialog nor send input to one), e.g. a scheduled task with
//     `/RU <user> /IT`. Run its PowerShell `-WindowStyle Hidden` so it does
//     not cover the dialog, drive by focus (`AppActivate` + SendKeys), and
//     send Enter twice after typing a path: the first takes the edit's
//     autocomplete, the second presses Select Folder.
//
// There is no non-portal fallback on Linux. No bus or no portal means
// `file_dialog` returns false and the toolkit answers the command with
// `ok = false`: the app is told there is no dialog rather than left waiting
// for one.

import "core:fmt"
import "core:os"
import "core:strconv"
import "baldr:baldr"

State :: struct {
	asked:   bool,
	quit_at: f64,
}

Msg :: union { Ask, Give_Up, baldr.Files }

Ask     :: struct {}
Give_Up :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch e in m {
	case Ask:
		s.asked = true
		fmt.eprintln("folder_pick: asking for a folder")
		return baldr.open_files(Msg, proc(e: baldr.Ev(baldr.Files)) -> Msg { return e.value },
			title = "Choose the sync folder", directory = true)
	case Give_Up:
		fmt.eprintln("folder_pick: nobody answered the dialog; giving up")
		return baldr.quit(Msg)
	case baldr.Files:
		if !e.ok {
			fmt.eprintln("folder_pick: cancelled (ok = false), which is its own answer")
			return baldr.quit(Msg)
		}
		fmt.eprintfln("folder_pick: %d path(s) back", len(e.paths))
		for p in e.paths {
			abs := len(p) > 0 && (p[0] == '/' || (len(p) > 2 && p[1] == ':'))
			dir := os.is_dir(p)
			fmt.eprintfln("folder_pick: %s %q  absolute=%v  is a directory=%v",
				"ok  " if abs && dir else "BAD ", p, abs, dir)
		}
		return baldr.quit(Msg)
	}
	return {}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "Folder pick", app_id = "dev.baldr.folder_pick", size = {520, 240},
		init = proc() -> (s: State) {
			s.quit_at, _ = strconv.parse_f64(os.get_env("FOLDER_PICK_QUIT", context.temp_allocator))
			if s.quit_at <= 0 do s.quit_at = 60
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			return baldr.batch(Msg,
				baldr.delay(Msg, 400, Ask{}), // after the window is up: a dialog wants a parent
				baldr.delay(Msg, i64(s.quit_at * 1000), Give_Up{}),
			)
		},
		update = update,
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm, justify = .Center); defer baldr.end(ui)
			baldr.text(ui, "Folder picker", role = .Headline)
			baldr.text(ui, "The desktop's own dialog is open; what it answers is printed.", muted = true)
		},
	})
	if baldr.run_failed(err) {
		fmt.eprintln("folder_pick: exit:", err)
		os.exit(1)
	}
}
