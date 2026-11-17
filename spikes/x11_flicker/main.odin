// x11_flicker — does a window go black while it is being resized?
//
// A flicker is gone by the time anyone looks and a screenshot almost never
// catches it, so this measures it instead.
//
// X will hand back the pixels of any window on request, so this samples two
// small patches of one — its middle, and a patch near its bottom-right
// corner — as fast as the server will answer, and says how many of those
// samples came back **uniformly black**. That is the signature of the
// server clearing a window to its background colour and the application not
// yet having drawn at the new size: the middle going black means the whole
// window was cleared, the corner alone means only the newly exposed strip
// was.
//
//   build/x11_flicker <window-id> [--ms 5000]
//   # …while something drags that window's corner
//
// The window id is what `xdotool search --name <title>` prints. Nothing is
// injected from here: drive the resize however the desktop allows and watch
// the timeline.
package main

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import x11 "baldr:platform/x11"

Geometry_Cookie :: struct { sequence: c.uint }
Image_Cookie    :: struct { sequence: c.uint }

Geometry_Reply :: struct {
	response_type: u8,
	depth:         u8,
	sequence:      u16,
	length:        u32,
	root:          x11.Window,
	x, y:          i16,
	width, height: u16,
	border_width:  u16,
	pad0:          [2]u8,
}

Image_Reply :: struct {
	response_type: u8,
	depth:         u8,
	sequence:      u16,
	length:        u32,
	visual:        u32,
	pad0:          [20]u8,
}

Api :: struct {
	get_geometry:       proc "c" (conn: x11.Connection, d: x11.Window) -> Geometry_Cookie,
	get_geometry_reply: proc "c" (conn: x11.Connection, ck: Geometry_Cookie, e: ^^x11.Generic_Error) -> ^Geometry_Reply,
	get_image:          proc "c" (conn: x11.Connection, format: u8, d: x11.Window, x, y: i16, w, h: u16, plane_mask: u32) -> Image_Cookie,
	get_image_reply:    proc "c" (conn: x11.Connection, ck: Image_Cookie, e: ^^x11.Generic_Error) -> ^Image_Reply,
	get_image_data:     proc "c" (r: ^Image_Reply) -> [^]u8,
}

PATCH :: 24 // the side of each patch sampled, in pixels

// Sample is one reading of one patch.
Sample :: struct {
	ok:    bool,
	black: int, // pixels that are exactly black
	total: int,
	luma:  int, // mean brightness of the patch, 0..255
}

// timeline squeezes however many samples were taken into a line that can be
// read, keeping a bucket's worst news: a single black frame in a thousand is
// the whole finding, so it must not average away.
timeline :: proc(line: string, width := 120) -> string {
	if len(line) <= width do return line
	out := make([]u8, width, context.temp_allocator)
	per := (len(line) + width - 1) / width
	for i in 0 ..< width {
		lo := i * per
		hi := min(lo + per, len(line))
		c: u8 = '.'
		for j in lo ..< hi {
			if line[j] == 'B' { c = 'B'; break }
			if line[j] == '?' do c = '?'
		}
		out[i] = c
	}
	return string(out)
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: x11_flicker <window-id> [--ms 5000]")
		os.exit(2)
	}
	id_text := os.args[1]
	base := 10
	if strings.has_prefix(id_text, "0x") { id_text, base = id_text[2:], 16 }
	id, id_ok := strconv.parse_u64_of_base(id_text, base)
	if !id_ok {
		fmt.eprintfln("not a window id: %s", os.args[1])
		os.exit(2)
	}
	win := x11.Window(u32(id))

	ms := 5000
	for i in 1 ..< len(os.args) - 1 {
		if os.args[i] == "--ms" do ms, _ = strconv.parse_int(os.args[i + 1])
	}

	if ok, missing := x11.load(); !ok {
		fmt.eprintfln("libxcb did not load: %v", missing)
		os.exit(1)
	}
	screen: c.int
	conn := x11.api.connect(nil, &screen)
	if conn == nil || x11.api.connection_has_error(conn) != 0 {
		fmt.eprintln("no X connection")
		os.exit(1)
	}
	defer x11.api.disconnect(conn)

	lib, lok := dynlib.load_library("libxcb.so.1")
	if !lok {
		fmt.eprintln("libxcb.so.1 did not load")
		os.exit(1)
	}
	a: Api
	sym :: proc(lib: dynlib.Library, $name: string, $T: typeid) -> T {
		p, ok := dynlib.symbol_address(lib, name)
		if !ok {
			fmt.eprintfln("libxcb has no %s", name)
			os.exit(1)
		}
		return (T)(p)
	}
	a.get_geometry       = sym(lib, "xcb_get_geometry",       type_of(a.get_geometry))
	a.get_geometry_reply = sym(lib, "xcb_get_geometry_reply", type_of(a.get_geometry_reply))
	a.get_image          = sym(lib, "xcb_get_image",          type_of(a.get_image))
	a.get_image_reply    = sym(lib, "xcb_get_image_reply",    type_of(a.get_image_reply))
	a.get_image_data     = sym(lib, "xcb_get_image_data",     type_of(a.get_image_data))

	patch :: proc(a: ^Api, conn: x11.Connection, w: x11.Window, px, py: i16) -> (s: Sample) {
		ck := a.get_image(conn, x11.IMAGE_FORMAT_Z_PIXMAP, w, px, py, PATCH, PATCH, max(u32))
		err: ^x11.Generic_Error
		r := a.get_image_reply(conn, ck, &err)
		x11.free_reply(err)
		if r == nil do return // a resize in flight can make the rectangle invalid: not a reading
		defer x11.free_reply(r)
		bytes := int(r.length) * 4
		data := a.get_image_data(r)
		if bytes < PATCH * PATCH * 4 do return
		sum := 0
		for i in 0 ..< PATCH * PATCH {
			b, g, rr := int(data[i * 4]), int(data[i * 4 + 1]), int(data[i * 4 + 2])
			if b == 0 && g == 0 && rr == 0 do s.black += 1
			sum += (rr + g + b) / 3
		}
		s.ok, s.total, s.luma = true, PATCH * PATCH, sum / (PATCH * PATCH)
		return
	}

	// A patch is called black when almost all of it is: an app drawing dark
	// grey is not this bug, a cleared window is.
	is_black :: proc(s: Sample) -> bool { return s.ok && s.black * 10 >= s.total * 9 }

	fmt.printfln("watching window 0x%x for %d ms — drag its corner now", u32(win), ms)
	mid_line, corner_line: strings.Builder
	strings.builder_init(&mid_line);    defer strings.builder_destroy(&mid_line)
	strings.builder_init(&corner_line); defer strings.builder_destroy(&corner_line)

	samples, mid_black, corner_black, failed := 0, 0, 0, 0
	sizes := make([dynamic][2]u16); defer delete(sizes)
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		gck := a.get_geometry(conn, win)
		gerr: ^x11.Generic_Error
		g := a.get_geometry_reply(conn, gck, &gerr)
		x11.free_reply(gerr)
		if g == nil {
			fmt.eprintln("the window has gone")
			break
		}
		w, h := g.width, g.height
		x11.free_reply(g)
		if len(sizes) == 0 || sizes[len(sizes) - 1] != {w, h} do append(&sizes, [2]u16{w, h})
		if w < PATCH * 3 || h < PATCH * 3 do continue

		mid := patch(&a, conn, win, i16(w / 2 - PATCH / 2), i16(h / 2 - PATCH / 2))
		cor := patch(&a, conn, win, i16(int(w) - PATCH - 8), i16(int(h) - PATCH - 8))
		samples += 1
		if !mid.ok || !cor.ok do failed += 1
		if is_black(mid) do mid_black += 1
		if is_black(cor) do corner_black += 1
		// The first readings, printed as numbers: a window with no background
		// shows whatever was behind it until the first frame is presented, and
		// these say whether that is a real artifact or too brief to see.
		if samples <= 8 do fmt.printfln("  sample %d: middle luma %d (%d/%d black), corner luma %d", samples, mid.luma, mid.black, max(mid.total, 1), cor.luma)
		strings.write_byte(&mid_line,    '?' if !mid.ok else 'B' if is_black(mid) else '.')
		strings.write_byte(&corner_line, '?' if !cor.ok else 'B' if is_black(cor) else '.')
	}

	fmt.printfln("\n%d samples, %d could not be read", samples, failed)
	fmt.printfln("sizes seen: %d — %v", len(sizes), sizes[:min(len(sizes), 12)])
	fmt.printfln("middle:  %d black (%.1f%%)  %s", mid_black, 100 * f64(mid_black) / f64(max(samples, 1)), timeline(strings.to_string(mid_line)))
	fmt.printfln("corner:  %d black (%.1f%%)  %s", corner_black, 100 * f64(corner_black) / f64(max(samples, 1)), timeline(strings.to_string(corner_line)))
	switch {
	case mid_black > 0:
		fmt.println("\nthe whole window was cleared: the server is painting it in its background colour")
	case corner_black > 0:
		fmt.println("\nthe newly exposed edge was cleared, the old pixels kept: bit gravity is working, the background is not")
	case samples > 0:
		fmt.println("\nnothing came back black")
	}
}
