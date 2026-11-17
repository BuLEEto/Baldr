// Package baldr is a retained-mode GUI toolkit for Odin.
//
// The core is a persistent node tree (see node.odin) laid out with a
// constraints-down / sizes-up protocol (layout.odin), painted into cached
// per-layer draw lists with damage tracking (paint.odin), and described by
// scoped builder procs that reconcile against the tree (build.odin). Every
// node carries accessibility data from birth (access.odin).
//
// Everything in this package runs headless: no window, GPU, or platform is
// needed to lay out, paint into draw lists, or run the tests. Rendering and
// windowing live in the gpu and platform packages.
package baldr

import "core:math"

VERSION :: "0.0.1-dev"

// Error is the value returned by fallible entry points. Zero means success.
Error :: enum u8 {
	None,
	Invalid_Node,
	Unbalanced_Scope,
	Out_Of_Memory,
	Platform, // no usable windowing backend (see stderr for the reason)
	Gpu,      // Vulkan loader / device / surface failure
	Text,     // fonts could not be loaded
	// Disconnected: the desktop dropped the connection while the app was
	// running, so the run ended without the app asking. Report it rather
	// than treating it as a clean exit; the reason is on stderr.
	Disconnected,
	// Already_Running: this app asked for a single instance and another
	// copy owns it; this launch's arguments were handed to it. Nothing is
	// wrong: exit 0 (see run_failed).
	Already_Running,
}

// run_failed says whether what `run` answered with is worth reporting.
//
// Every error is, except `.Already_Running`: a second launch of a
// single-instance app handed its arguments to the first and stopped, which
// is what asking for one means.
//
//	if baldr.run_failed(baldr.run(app)) do os.exit(1)
run_failed :: proc(err: Error) -> bool {
	return err != .None && err != .Already_Running
}

// Rect is an axis-aligned rectangle in logical pixels.
Rect :: struct {
	x, y, w, h: f32,
}

// Color is linear RGBA, 0..1. Author colours in sRGB with rgb()/rgba() —
// the renderer writes to an sRGB swapchain, so values here must be linear.
Color :: [4]f32

// rgb builds a Color from an sRGB hex value like 0x2F6FED.
rgb :: proc "contextless" (hex: u32, alpha: f32 = 1) -> Color {
	return {
		srgb_to_linear(f32((hex >> 16) & 0xff) / 255),
		srgb_to_linear(f32((hex >> 8) & 0xff) / 255),
		srgb_to_linear(f32(hex & 0xff) / 255),
		alpha,
	}
}

// rgba builds a Color from sRGB components in 0..1 plus alpha.
rgba :: proc "contextless" (r, g, b: f32, a: f32 = 1) -> Color {
	return {srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b), a}
}

srgb_to_linear :: proc "contextless" (c: f32) -> f32 {
	if c <= 0.04045 do return c / 12.92
	return math.pow((c + 0.055) / 1.055, 2.4)
}

linear_to_srgb :: proc "contextless" (c: f32) -> f32 {
	if c <= 0.0031308 do return c * 12.92
	return 1.055 * math.pow(c, 1 / 2.4) - 0.055
}

rect_union :: proc "contextless" (a, b: Rect) -> Rect {
	if a.w <= 0 || a.h <= 0 do return b
	if b.w <= 0 || b.h <= 0 do return a
	x0 := min(a.x, b.x)
	y0 := min(a.y, b.y)
	x1 := max(a.x + a.w, b.x + b.w)
	y1 := max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

rect_contains :: proc "contextless" (r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
}
