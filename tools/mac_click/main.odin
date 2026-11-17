#+build darwin
// mac_click — inject pointer input through CGEvent for live interaction tests
// on macOS. The twin of tools/wl_click, with the same command line, so a test
// recipe reads the same on both platforms.
//
//   mac_click <x> <y> [--button left|right|middle] [--move-only] [--scroll DY] [--drag X2 Y2 [--steps N]]
//
// **Coordinates are global display pixels with the origin at the TOP LEFT.**
// That is CGEvent's convention and it is upside down from `NSWindow.frame`
// and `locationInWindow`, which put the origin at the bottom left. Mixing the
// two silently clicks the mirror image of where you meant, so convert once,
// at the boundary, and say which you are holding.
//
// Needs Accessibility permission for whatever process runs it (System
// Settings → Privacy & Security → Accessibility). Without it every call
// silently does nothing: the posts succeed and no event is delivered, which
// looks exactly like a broken application.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

foreign import core_graphics "system:CoreGraphics.framework"
foreign import core_foundation "system:CoreFoundation.framework"

CGPoint :: struct { x, y: f64 }

CGEventRef       :: rawptr
CGEventSourceRef :: rawptr

// kCGHIDEventTap: post at the lowest level, so the event goes through the
// whole system exactly as a real device's would.
TAP_HID :: u32(0)

Event_Type :: enum u32 {
	LeftMouseDown    = 1,
	LeftMouseUp      = 2,
	RightMouseDown   = 3,
	RightMouseUp     = 4,
	MouseMoved       = 5,
	LeftMouseDragged = 6,
	OtherMouseDown   = 25,
	OtherMouseUp     = 26,
}

Button :: enum u32 { Left = 0, Right = 1, Middle = 2 }

// kCGScrollEventUnitPixel = 0, kCGScrollEventUnitLine = 1. Lines are what a
// notched wheel sends; pixels are what a trackpad sends.
SCROLL_LINE :: u32(1)

@(default_calling_convention = "c")
foreign core_graphics {
	CGEventCreateMouseEvent :: proc(source: CGEventSourceRef, mouseType: Event_Type, mouseCursorPosition: CGPoint, mouseButton: Button) -> CGEventRef ---
	CGEventCreateScrollWheelEvent :: proc(source: CGEventSourceRef, units: u32, wheelCount: u32, wheel1: i32) -> CGEventRef ---
	CGEventPost :: proc(tap: u32, event: CGEventRef) ---
}

@(default_calling_convention = "c")
foreign core_foundation {
	CFRelease :: proc(cf: rawptr) ---
}

post :: proc(e: CGEventRef) {
	if e == nil do return
	CGEventPost(TAP_HID, e)
	CFRelease(e)
}

move :: proc(p: CGPoint, dragging: bool, button: Button) {
	kind := Event_Type.MouseMoved
	if dragging do kind = .LeftMouseDragged
	post(CGEventCreateMouseEvent(nil, kind, p, button))
}

press :: proc(p: CGPoint, button: Button, down: bool) {
	kind: Event_Type
	switch button {
	case .Left:   kind = down ? .LeftMouseDown : .LeftMouseUp
	case .Right:  kind = down ? .RightMouseDown : .RightMouseUp
	case .Middle: kind = down ? .OtherMouseDown : .OtherMouseUp
	}
	post(CGEventCreateMouseEvent(nil, kind, p, button))
}

usage :: proc() -> ! {
	fmt.eprintln("usage: mac_click <x> <y> [--button left|right|middle] [--move-only] [--scroll DY] [--drag X2 Y2 [--steps N]]")
	fmt.eprintln("  coordinates are global display pixels, origin TOP LEFT (CGEvent's convention)")
	os.exit(2)
}

num :: proc(s: string) -> f64 {
	v, ok := strconv.parse_f64(s)
	if !ok do usage()
	return v
}

main :: proc() {
	args := os.args[1:]
	if len(args) < 2 do usage()
	from := CGPoint{num(args[0]), num(args[1])}

	button := Button.Left
	move_only, do_drag, do_scroll := false, false, false
	to := from
	scroll_dy := 0
	steps := 24

	i := 2
	for i < len(args) {
		switch args[i] {
		case "--move-only":
			move_only = true
			i += 1
		case "--button":
			if i + 1 >= len(args) do usage()
			switch args[i + 1] {
			case "left":   button = .Left
			case "right":  button = .Right
			case "middle": button = .Middle
			case:          usage()
			}
			i += 2
		case "--scroll":
			if i + 1 >= len(args) do usage()
			do_scroll = true
			scroll_dy = int(num(args[i + 1]))
			i += 2
		case "--drag":
			if i + 2 >= len(args) do usage()
			do_drag = true
			to = CGPoint{num(args[i + 1]), num(args[i + 2])}
			i += 3
		case "--steps":
			if i + 1 >= len(args) do usage()
			steps = max(1, int(num(args[i + 1])))
			i += 2
		case:
			usage()
		}
	}

	// Always move first: a press at a position the pointer is not already at
	// is delivered, but the window under it never sees the enter, so hover
	// state is wrong and the click can land on the wrong view.
	move(from, false, button)
	time.sleep(20 * time.Millisecond)

	switch {
	case do_scroll:
		post(CGEventCreateScrollWheelEvent(nil, SCROLL_LINE, 1, i32(scroll_dy)))
	case do_drag:
		press(from, button, true)
		// Glide rather than jump: a live resize or a drag gesture only starts
		// when the system sees movement while the button is held, and one
		// giant step reads as a teleport.
		for s in 1 ..= steps {
			t := f64(s) / f64(steps)
			move(CGPoint{from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t}, true, button)
			time.sleep(8 * time.Millisecond)
		}
		press(to, button, false)
	case move_only:
	// the move above was the whole job
	case:
		press(from, button, true)
		time.sleep(20 * time.Millisecond)
		press(from, button, false)
	}
}
