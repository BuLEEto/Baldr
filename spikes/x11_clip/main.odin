// x11_clip — does a Baldr app's clipboard talk to a real X client?
//
// Text should round-trip both ways with a non-Baldr app, and `xclip` is
// exactly that: a plain X client speaking ICCCM selections, with no Wayland
// bridge in the middle.
//
//   ./build.sh spike x11_clip
//   BALDR_BACKEND=x11 build/x11_clip copy "some text"   # own the selection
//   xclip -selection clipboard -o                        # ...and read it
//
//   echo hello | xclip -selection clipboard -i
//   BALDR_BACKEND=x11 build/x11_clip paste               # ...and paste it
//
// `copy` stays up until closed, because an X selection lives only as long
// as the program that owns it — that is X, not a bug.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:baldr"

State :: struct { said: string, mode: string, arg: string, done: bool }
Msg :: union { Go, Got }
Go :: struct {}
Got :: struct { p: baldr.Pasted }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "clipboard", app_id = "baldr.clip", size = {420, 160},
		init = proc() -> State {
			s := State{mode = "paste", said = "..."}
			if len(os.args) > 1 do s.mode = os.args[1]
			if len(os.args) > 2 do s.arg = os.args[2]
			return s
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 400, Go{}) },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Go:
				if s.done do return {}
				s.done = true
				switch s.mode {
				case "copy-file":
					// A file's contents, for a payload past the one-property
					// ceiling: that is an INCR transfer and nothing else.
					data, rerr := os.read_entire_file(s.arg, context.allocator)
					if rerr != nil {
						fmt.eprintfln("cannot read %s", s.arg)
						return baldr.quit(Msg)
					}
					text := string(data)
					s.said = fmt.aprintf("copied %d bytes", len(text))
					fmt.println(s.said)
					os.flush(os.stdout)
					return baldr.copy_text(Msg, text)
				case "copy-files":
					// Two forms of the same thing at once: the uri-list a
					// file manager wants, and the plain text anything else
					// will take.
					uris := "file:///tmp/a.txt\r\nfile:///tmp/b.txt\r\n"
					names := "/tmp/a.txt /tmp/b.txt"
					items := []baldr.Clip_Item{
						{mime = "text/uri-list", data = transmute([]u8)uris},
						{mime = "text/plain;charset=utf-8", data = transmute([]u8)names},
					}
					s.said = "copied 2 files, two ways"
					fmt.println(s.said)
					os.flush(os.stdout)
					return baldr.copy_files(Msg, []string{"/tmp/a.txt", "/tmp/b.txt"})
				case "types":
					s.said = "asking what is on the clipboard"
					return baldr.paste(Msg, proc(e: baldr.Ev(baldr.Pasted)) -> Msg { return Got{e.value} })
				case "copy":
					text := s.arg if s.arg != "" else "from Baldr on X11"
					s.said = fmt.aprintf("copied %q - it lives while this runs", text)
					fmt.println(s.said)
					os.flush(os.stdout)
					return baldr.copy_text(Msg, text)
				case "paste":
					return baldr.paste(Msg, proc(e: baldr.Ev(baldr.Pasted)) -> Msg { return Got{e.value} })
				case "paste-primary":
					return baldr.paste(Msg, proc(e: baldr.Ev(baldr.Pasted)) -> Msg { return Got{e.value} }, primary = true)
				}
			case Got:
				// Print a digest, not two megabytes of it.
				head := v.p.text[:min(len(v.p.text), 40)]
				tail := v.p.text[max(len(v.p.text) - 40, 0):]
				s.said = fmt.aprintf("pasted %d bytes, %d file(s): %q ... %q", len(v.p.text), len(v.p.files), head, tail)
				for f in v.p.files do fmt.printfln("  file: %s", f)
				fmt.println(s.said)
				os.flush(os.stdout)
				return baldr.quit(Msg)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "clipboard", role = .Headline)
			baldr.text(ui, s.said, muted = true)
		},
	})
}
