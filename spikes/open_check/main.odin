package main

// "Open website" and "Open folder": `open_url`, `open_path` and
// `reveal_path`, on whichever desktop it is run.
//
// Worth its own instrument on macOS in particular: these go through the objc
// runtime by selector name, and an unrecognised selector does not fail, it
// aborts the process. Three `ok`s here mean the calls are sound, not merely
// that they compiled.
//
// It declares no window, so it can be run over ssh through the bundle:
//
//	./build.sh spike open_check run                      # a browser and a file manager open
//	OPEN_CHECK_PATH=/some/dir OPEN_CHECK_URL=https://… build/open_check
//	OPEN_CHECK_URL=- build/open_check                    # paths only, no browser

import "core:fmt"
import "core:os"
import "baldr:baldr"

State :: struct {
	path: string,
	url:  string,
	step: int,
	bad:  int,
}

Msg :: union { Start, baldr.Path_Opened, baldr.Url_Opened }

Start :: struct {}

say :: proc(s: ^State, ok: bool, format: string, args: ..any) {
	if !ok do s.bad += 1
	fmt.eprintf("open: %s ", "ok  " if ok else "BAD ")
	fmt.eprintfln(format, ..args)
}

on_path :: proc(e: baldr.Ev(baldr.Path_Opened)) -> Msg { return e.value }
on_url :: proc(e: baldr.Ev(baldr.Url_Opened)) -> Msg { return e.value }

next :: proc(s: ^State) -> baldr.Cmd(Msg) {
	s.step += 1
	switch s.step {
	case 1: return baldr.reveal_path(Msg, s.path, on_path)
	case 2: return baldr.open_path(Msg, s.path, on_path)
	case 3:
		if s.url == "-" {
			fmt.eprintln("open: (no URL asked for)")
			break
		}
		return baldr.open_url(Msg, s.url, on_url)
	}
	fmt.eprintfln("open: %s", "all of it answered ok" if s.bad == 0 else "SOMETHING IS WRONG above")
	return baldr.quit(Msg)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch e in m {
	case Start:
		fmt.eprintfln("open: path %q, url %q", s.path, s.url)
		return next(s)
	case baldr.Path_Opened:
		say(s, e.ok, "%s: %q", "reveal_path" if s.step == 1 else "open_path", e.path)
		return next(s)
	case baldr.Url_Opened:
		say(s, e.ok, "open_url: %q", e.url)
		return next(s)
	}
	return {}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "Open check", app_id = "dev.baldr.open_check",
		init = proc() -> (s: State) {
			s.path = os.get_env("OPEN_CHECK_PATH", context.allocator)
			s.url = os.get_env("OPEN_CHECK_URL", context.allocator)
			if s.path == "" do s.path = os.get_env("HOME", context.allocator)
			if s.url == "" do s.url = "https://example.com"
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 1, Start{}) },
		update = update,
		surfaces = proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {}, // no window
		keep_running = proc(s: ^State) -> bool { return true },
	})
	if baldr.run_failed(err) {
		fmt.eprintln("open_check: exit:", err)
		os.exit(1)
	}
}
