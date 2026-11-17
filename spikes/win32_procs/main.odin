#+build windows
package main

// Windows Backend procs, driven at the backend itself rather than through a
// view, because they are the backend's contract.
//
//   key_name                what Windows calls a handful of keys. No
//                           window, no desktop: it prints and that is that.
//   surface_set_fullscreen  a window asks for the whole screen, and the
//                           geometry says whether it got it. This one has
//                           to run where there is a desktop — a window in
//                           the service session has no monitor to fill.
//   surface_post_close      asked for, and an Ev_Close must come back on a
//                           later pump: a window drawing its own title bar
//                           closes the way a decorated one does.

import "core:fmt"
import "core:time"
import win "core:sys/windows"
import "baldr:platform"
import "baldr:platform/win32"

main :: proc() {
	b := win32.backend()
	ok, why := b.init(b)
	if !ok {
		fmt.eprintfln("init failed: %s", why)
		return
	}
	defer b.shutdown(b)

	fmt.println("--- key_name")
	for k in ([]struct{vk: u32, what: string}{
		{win.VK_RETURN, "Return"}, {win.VK_ESCAPE, "Escape"}, {win.VK_LEFT, "Left"},
		{win.VK_F5, "F5"}, {win.VK_SPACE, "Space"}, {0x41, "A"},
	}) {
		name := b.key_name(b, k.vk, context.temp_allocator) if b.key_name != nil else "<no key_name>"
		fmt.printfln("  VK %-4d (%-6s) -> %q", k.vk, k.what, name)
	}

	s, made := b.surface_create(b, platform.Surface_Desc{
		kind = .Window, title = "win32 procs", size = {520, 340},
	})
	if !made {
		fmt.eprintln("no window: the rest needs one")
		return
	}
	pump :: proc(b: ^platform.Backend, ms: int) -> (fullscreen, closed: bool) {
		end := time.tick_now()
		for time.duration_milliseconds(time.tick_since(end)) < f64(ms) {
			for ev in b.pump(b, 16) {
				#partial switch e in ev {
				case platform.Ev_Configure:
					fmt.printfln("  configure: %.0fx%.0f fullscreen=%v", e.size.x, e.size.y, e.fullscreen)
					fullscreen = e.fullscreen
				case platform.Ev_Close:
					fmt.printfln("  Ev_Close, reason %v", e.reason)
					closed = true
				}
			}
		}
		return
	}
	pump(b, 500)

	fmt.println("--- surface_set_fullscreen(true)")
	if b.surface_set_fullscreen == nil {
		fmt.println("  not implemented")
	} else {
		fmt.printfln("  asked: %v", b.surface_set_fullscreen(b, s, true))
		full, _ := pump(b, 1200)
		fmt.printfln("  the desktop says fullscreen=%v", full)
		fmt.println("--- surface_set_fullscreen(false)")
		fmt.printfln("  asked: %v", b.surface_set_fullscreen(b, s, false))
		back, _ := pump(b, 1200)
		fmt.printfln("  the desktop says fullscreen=%v", back)
	}

	fmt.println("--- ime_set")
	if b.ime_set == nil {
		fmt.println("  not implemented")
	} else {
		// Composing itself needs a CJK input method installed; what can be
		// checked anywhere is that turning it on and off is accepted, that a
		// password field is refused one, and that ordinary typing still
		// arrives while the window procedure routes the IME messages.
		b.ime_set(b, platform.Ime_State{surface = s, on = true, caret = {40, 60, 2, 18}})
		pump(b, 200)
		b.ime_set(b, platform.Ime_State{surface = s, on = true, purpose = .Password, caret = {40, 60, 2, 18}})
		pump(b, 200)
		b.ime_set(b, platform.Ime_State{surface = s, on = false})
		pump(b, 200)
		fmt.println("  on / password / off all accepted")

		b.ime_set(b, platform.Ime_State{surface = s, on = true, caret = {40, 60, 2, 18}})
		pump(b, 100)
		// A WM_CHAR posted to our own window: the ordinary typing path,
		// which must still reach Ev_Text.
		hwnd := win.HWND(b.surface_native(b, s)) if b.surface_native != nil else nil
		if hwnd != nil {
			win.PostMessageW(hwnd, win.WM_CHAR, win.WPARAM('Z'), 0)
			typed := false
			end := time.tick_now()
			for time.duration_milliseconds(time.tick_since(end)) < 800 {
				for ev in b.pump(b, 16) {
					#partial switch e in ev {
					case platform.Ev_Text:
						fmt.printfln("  Ev_Text %q — ordinary typing still works", e.text)
						typed = true
					case platform.Ev_Ime:
						fmt.printfln("  Ev_Ime commit=%q preedit=%q", e.commit, e.preedit)
					}
				}
			}
			if !typed do fmt.println("  NO Ev_Text: the IME routing swallowed ordinary typing")
		}
	}

	fmt.println("--- surface_post_close")
	if b.surface_post_close == nil {
		fmt.println("  not implemented")
	} else {
		b.surface_post_close(b, s)
		_, closed := pump(b, 1500)
		fmt.printfln("  Ev_Close arrived: %v", closed)
	}
	fmt.println("--- done")
}
