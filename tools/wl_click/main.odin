#+build linux
// wl_click — inject a pointer click through wlr-virtual-pointer for live
// interaction tests on a wlroots compositor. Coordinates are absolute layout
// pixels; the extent defaults to 5120×1440 (two 2560×1440 outputs side by
// side), and --extent gives the real one.
//
//   wl_click <x> <y> [--extent W H] [--button left|right|middle] [--move-only] [--scroll DY] [--drag X2 Y2 [--steps N]]
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import wl "baldr:platform/wayland/wl"

Globals :: struct {
	seat, vp_manager: wl.Proxy,
}

on_global :: proc "c" (data: rawptr, reg: wl.Proxy, name: u32, iface: cstring, version: u32) {
	g := (^Globals)(data)
	switch string(iface) {
	case "wl_seat":
		if g.seat == nil do g.seat = wl.wl_registry_bind(reg, name, &wl.wl_seat_interface, min(version, 5))
	case "zwlr_virtual_pointer_manager_v1":
		g.vp_manager = wl.wl_registry_bind(reg, name, &wl.zwlr_virtual_pointer_manager_v1_interface, min(version, 2))
	}
}

main :: proc() {
	context = runtime.default_context()
	if len(os.args) < 3 {
		fmt.eprintln("usage: wl_click <x> <y> [--extent W H] [--button left|right|middle] [--move-only] [--scroll DY] [--drag X2 Y2 [--steps N]]")
		os.exit(2)
	}
	x, _ := strconv.parse_int(os.args[1])
	y, _ := strconv.parse_int(os.args[2])
	ext := [2]int{5120, 1440}
	button := u32(0x110)
	move_only := false
	scroll_dy := 0
	drag := false
	drag_to := [2]int{}
	steps := 30
	for i := 3; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--extent":
			ext.x, _ = strconv.parse_int(os.args[i + 1])
			ext.y, _ = strconv.parse_int(os.args[i + 2])
			i += 2
		case "--button":
			switch os.args[i + 1] {
			case "right":  button = 0x111
			case "middle": button = 0x112
			}
			i += 1
		case "--move-only":
			move_only = true
		case "--scroll":
			scroll_dy, _ = strconv.parse_int(os.args[i + 1])
			i += 1
		case "--drag":
			drag = true
			drag_to.x, _ = strconv.parse_int(os.args[i + 1])
			drag_to.y, _ = strconv.parse_int(os.args[i + 2])
			i += 2
		case "--steps":
			steps, _ = strconv.parse_int(os.args[i + 1])
			i += 1
		}
	}

	if ok, missing := wl.load(); !ok {
		fmt.eprintln("wl_click: libwayland missing:", missing)
		os.exit(1)
	}
	display := wl.display_connect()
	if display == nil {
		fmt.eprintln("wl_click: no Wayland display")
		os.exit(1)
	}
	g: Globals
	registry := wl.wl_display_get_registry(display)
	rl := wl.wl_registry_listener_noop()
	rl.global = on_global
	wl.wl_registry_add_listener(registry, &rl, &g)
	wl.display_roundtrip(display)
	if g.seat == nil || g.vp_manager == nil {
		fmt.eprintln("wl_click: compositor lacks wl_seat or zwlr_virtual_pointer_manager_v1")
		os.exit(1)
	}
	vp := wl.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(g.vp_manager, g.seat)
	now := proc() -> u32 { return u32(time.duration_milliseconds(time.since(time.Time{})) ) }

	wl.zwlr_virtual_pointer_v1_motion_absolute(vp, now(), u32(x), u32(y), u32(ext.x), u32(ext.y))
	wl.zwlr_virtual_pointer_v1_frame(vp)
	wl.display_roundtrip(display)
	if scroll_dy != 0 {
		// One wheel notch per 15 units, like a real mouse; value in logical px.
		wl.zwlr_virtual_pointer_v1_axis_source(vp, .Wheel)
		wl.zwlr_virtual_pointer_v1_axis(vp, now(), .Vertical_Scroll, wl.f64_to_fixed(f64(scroll_dy)))
		wl.zwlr_virtual_pointer_v1_axis_discrete(vp, now(), .Vertical_Scroll, wl.f64_to_fixed(f64(scroll_dy)), i32(scroll_dy / 15))
		wl.zwlr_virtual_pointer_v1_frame(vp)
		wl.display_roundtrip(display)
		fmt.printfln("wl_click: scrolled %d at (%d, %d)", scroll_dy, x, y)
		move_only = true
	}
	if !move_only {
		time.sleep(30 * time.Millisecond)
		wl.zwlr_virtual_pointer_v1_button(vp, now(), button, .Pressed)
		wl.zwlr_virtual_pointer_v1_frame(vp)
		wl.display_roundtrip(display)
		if drag {
			// Press, then glide to the target in `steps` motions ~8 ms apart (a
			// realistic drag: sliders, scrollbar thumbs, text selection).
			for i in 1 ..= max(steps, 1) {
				f := f64(i) / f64(max(steps, 1))
				px := x + int(f64(drag_to.x - x) * f)
				py := y + int(f64(drag_to.y - y) * f)
				wl.zwlr_virtual_pointer_v1_motion_absolute(vp, now(), u32(px), u32(py), u32(ext.x), u32(ext.y))
				wl.zwlr_virtual_pointer_v1_frame(vp)
				wl.display_roundtrip(display)
				time.sleep(8 * time.Millisecond)
			}
		}
		time.sleep(40 * time.Millisecond)
		wl.zwlr_virtual_pointer_v1_button(vp, now(), button, .Released)
		wl.zwlr_virtual_pointer_v1_frame(vp)
		wl.display_roundtrip(display)
	}
	wl.zwlr_virtual_pointer_v1_destroy(vp)
	wl.display_roundtrip(display)
	wl.display_disconnect(display)
	if drag {
		fmt.printfln("wl_click: dragged (%d, %d) → (%d, %d) in %d steps", x, y, drag_to.x, drag_to.y, steps)
	} else {
		fmt.printfln("wl_click: %s at (%d, %d) of %dx%d", "moved" if move_only else "clicked", x, y, ext.x, ext.y)
	}
}
