#+build darwin
package main

// Drive platform/cocoa through the real `platform.Backend` interface — the
// macOS twin of spikes/wayland_check and spikes/win32_check, and the step
// that turns "the primitives work" (spikes/cocoa_window) into "the backend
// works".
//
// There is no renderer here on purpose: Baldr commits macOS to native Metal
// rather than MoltenVK, so `vk_create_surface` answers false and nothing is
// drawn. (The Metal renderer is reached through `drawable_create`, not
// this path.) Everything *else* a
// Baldr app does with a backend happens here — init, a surface, the event
// loop, resize, focus, close, shutdown — and each event is printed as the
// toolkit would receive it.
//
// Exits on its own after BUDGET seconds so an ssh session never hangs —
// `COCOA_CHECK_SECONDS=90` for longer, which is what a hand-check wants:
// flipping a switch in System Settings and watching what arrives takes more
// than twenty seconds if the pane is not already open.
//
//	./build.sh spike cocoa_check run                 # 22 s
//	COCOA_CHECK_SECONDS=90 ./build/cocoa_check       # …and time to go looking

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "baldr:platform"
import "baldr:platform/cocoa"

BUDGET :: 22 // seconds, unless COCOA_CHECK_SECONDS says otherwise

main :: proc() {
	b := cocoa.backend()
	ok, why := b.init(b)
	if !ok {
		fmt.eprintfln("cocoa_check: init failed: %s", why)
		return
	}
	defer b.shutdown(b)
	fmt.printfln("backend %q up, caps=%v, theme dark=%v", b.name, b.caps, b.system_theme(b).dark)

	s, made := b.surface_create(b, platform.Surface_Desc{
		title = "Baldr — cocoa_check (no renderer)",
		size  = {720, 480},
	})
	if !made {
		fmt.eprintln("cocoa_check: surface_create failed")
		return
	}
	size, size_px, scale := b.surface_geometry(b, s)
	fmt.printfln("surface %d: %.0fx%.0f logical, %dx%d px, scale %.2f",
		u32(s), size.x, size.y, size_px.x, size_px.y, scale)

	// the drag corner in CGEvent coordinates, for tools/mac_click
	fmt.printfln("DRAG_CORNER %s", cocoa.drag_corner_hint(b, s))

	// The renderer seam, said out loud: it is answered by Metal, not here.
	if _, vk_ok := b.vk_create_surface(b, s, nil); !vk_ok {
		fmt.println("vk_create_surface: false, as expected — macOS gets Metal, not MoltenVK")
	}

	counts: map[string]int
	defer delete(counts)
	start := time.tick_now()
	closed := false
	budget := f64(BUDGET)
	if v, ok := strconv.parse_f64(os.get_env("COCOA_CHECK_SECONDS", context.temp_allocator)); ok && v > 0 {
		budget = v
		fmt.printfln("running for %.0f s (COCOA_CHECK_SECONDS)", budget)
	}
	for time.duration_seconds(time.tick_since(start)) < budget && !closed {
		for ev in b.pump(b, 16) {
			switch e in ev {
			case platform.Ev_Configure:
				counts["Ev_Configure"] += 1
				fmt.printfln("Ev_Configure  %.0fx%.0f  %dx%d px  scale %.2f",
					e.size.x, e.size.y, e.size_px.x, e.size_px.y, e.scale)
			case platform.Ev_Key:
				counts["Ev_Key"] += 1
				if e.pressed {
					fmt.printfln("Ev_Key        %v (native %d) mods=%v repeat=%v", e.key, e.native, e.mods, e.repeat)
				}
			case platform.Ev_Text:
				counts["Ev_Text"] += 1
				fmt.printfln("Ev_Text       %q", e.text)
			case platform.Ev_Pointer_Button:
				counts["Ev_Pointer_Button"] += 1
				fmt.printfln("Ev_Pointer_Button %v %v at %.0f,%.0f mods=%v",
					e.button, e.pressed ? "down" : "up", e.pos.x, e.pos.y, e.mods)
			case platform.Ev_Pointer_Motion:
				counts["Ev_Pointer_Motion"] += 1
			case platform.Ev_Pointer_Enter:
				counts["Ev_Pointer_Enter"] += 1
				fmt.printfln("Ev_Pointer_Enter at %.0f,%.0f", e.pos.x, e.pos.y)
			case platform.Ev_Pointer_Leave:
				counts["Ev_Pointer_Leave"] += 1
			case platform.Ev_Scroll:
				counts["Ev_Scroll"] += 1
				fmt.printfln("Ev_Scroll     %.2f,%.2f precise=%v", e.delta.x, e.delta.y, e.precise)
			case platform.Ev_Focus:
				counts["Ev_Focus"] += 1
				fmt.printfln("Ev_Focus      %v", e.focused)
			case platform.Ev_Close:
				counts["Ev_Close"] += 1
				fmt.printfln("Ev_Close      reason=%v — the app decides, and this one agrees", e.reason)
				closed = true
			case platform.Ev_Frame:
				counts["Ev_Frame"] += 1
			// Printed, not counted. Flip something in System Settings >
			// Accessibility > Display while this runs, or from another shell:
			//   defaults write com.apple.universalaccess reduceMotion 1
			//   defaults write -g AppleInterfaceStyle Dark
			case platform.Ev_Theme:
				fmt.printfln("  Ev_Theme dark=%v reduce_motion=%v reduce_transparency=%v high_contrast=%v accent=%v text_scale=%.2f",
					e.dark, e.reduce_motion, e.reduce_transparency, e.high_contrast, e.has_accent, e.text_scale)
			case platform.Ev_Popup_Configure, platform.Ev_Popup_Done, platform.Ev_Backdrop,
			     platform.Ev_Redraw, platform.Ev_Touch, platform.Ev_Pen, platform.Ev_Input_Caps,
			     platform.Ev_Caps, platform.Ev_Outputs, platform.Ev_Surface_Output, platform.Ev_Lock,
			     platform.Ev_Keyboard, platform.Ev_Url, platform.Ev_Notify, platform.Ev_Toplevels,
			     platform.Ev_Workspaces, platform.Ev_Slot, platform.Ev_Ime,
			     platform.Ev_Quit, platform.Ev_Watch, platform.Ev_Files, platform.Ev_Drag_Data,
			     platform.Ev_Drag_Enter, platform.Ev_Drag_Motion, platform.Ev_Drag_Leave,
			     platform.Ev_Drag_Drop, platform.Ev_Drag_End, platform.Ev_Backdrop_Map,
			     platform.Ev_Tray:
				counts["other"] += 1
			}
		}
	}

	fmt.println("--- events seen ---")
	for name, n in counts do fmt.printfln("  %-20s %d", name, n)
	b.surface_destroy(b, s)
	fmt.println("surface destroyed, shutting down")
}
