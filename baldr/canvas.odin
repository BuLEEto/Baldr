package baldr

// Canvases: textures an app draws into and shows, for an image editor's
// layers and tiles, a viewer's filters, a sketch pad. Three bit depths
// (RGBA8, RGBA16, RGBA32F), a colour space on every canvas, and Baldr's own
// operations on them, each with a CPU reference.
//
// An app gets its Gpu with the `gpu_open` command, once the device is up,
// and keeps it for the run. canvas_create makes a canvas; canvas_write,
// canvas_fill and canvas_copy are work on canvases, queued in the order they
// are asked for and run on the GPU after the update that asked (before any
// frame shows them: the loop flushes after handling messages); `canvas_read`
// is a command whose outcome, the texels, arrives as a message. The
// `canvas` node shows one, as `image` shows a picture, its values decoded
// from its colour space for the screen (sRGB for now).
//
// Behind the same calls is a reference that runs on the CPU (gpu_reference):
// what the GPU's work must match, the headless tests' oracle, and the
// fallback where there is no GPU. Its canvases are drawn as pictures.
//
// Everything here runs on the UI thread (update and view).

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"
import "core:os"
import "baldr:gpu"

// Canvas_Format is how a canvas stores a texel: 8 or 16 bits a channel
// (unsigned, 0..1), or 32-bit float (HDR).
Canvas_Format :: gpu.Canvas_Format

// Color_Space is what a canvas's values mean: sRGB, Display P3 or Adobe RGB
// (1998) values encoded by the space's own curve, or Linear light with
// sRGB's primaries.
Color_Space :: gpu.Color_Space

// Canvas names a canvas of a Gpu. 0 is none.
Canvas :: distinct u32

// Gpu is an app's way to its canvases: from `gpu_open`, valid for the run.
// Copy it freely; its fields are Baldr's.
Gpu :: struct {
	host: ^Canvas_Host,
}

// Gpu_Limits is what canvases this Gpu can have: the largest side, the
// device memory, the formats it makes canvases in, those it filters (the
// rest are drawn with the nearest texel) and those a compute shader can
// write, and whether it is the GPU or the CPU reference.
Gpu_Limits :: struct {
	max_side:      int,
	device_memory: u64,
	formats:       bit_set[Canvas_Format],
	filtered:      bit_set[Canvas_Format],
	storage:       bit_set[Canvas_Format], // a compute shader can write (canvas_shader)
	on_gpu:        bool,
}

// Canvas_Read is a read's outcome: the rectangle's texels in the canvas's
// format, rows tightly packed (little-endian 16-bit and 32-bit float
// channels). The bytes live only while the message is handled: copy what
// you keep. `ok` is false when the canvas was gone or the read failed.
Canvas_Read :: struct {
	canvas:     Canvas,
	x, y, w, h: int,
	format:     Canvas_Format,
	pixels:     []u8,
	ok:         bool,
}

// Canvas_Host holds a Gpu's canvases; its fields are Baldr's.
Canvas_Host :: struct {
	r:         ^gpu.Renderer, // nil: the CPU reference
	entries:   [dynamic]Canvas_Entry,
	reads:     map[u32]Canvas_Read, // on the GPU: what each read in flight will be
	done:      [dynamic]Canvas_Done, // reads finished, waiting to go out
	next_read: u32,
	waiters:   int, // threads waiting on batches with reads (atomic)
	// The coverage canvas canvas_strokes lays each stroke into before it is
	// composited. Kept, not made per call: GPU work is queued, so a scratch
	// destroyed inside the call is gone before the batch runs.
	stroke_cover: Canvas,
	// canvas_write_begin's open write, 0 for none. On the GPU the bytes are
	// the renderer's staging memory and canvas_write_end only closes the
	// gate; on the reference they are `write_buf`, which that end copies in.
	writing:    Canvas,
	write_rect: [4]int,
	write_buf:  [dynamic]u8,
	write_said: bool, // a write left open has been reported: once a run, not once a pass
	card_node:  string, // the DRM render node's path, worked out once (canvas_import.odin); owned
	debug:      bool, // BALDR_DEBUG_CANVAS: report what the staging buffers cost, every flush
	allocator: runtime.Allocator,
}

@(private)
Canvas_Entry :: struct {
	used:    bool,
	lost:    bool,      // its page died with the device (a GPU reset): the handle is spent, and the slot is not handed out again
	size:    [2]int,
	format:  Canvas_Format,
	space:   Color_Space,
	version: u64,       // bumped by every change
	page:    gpu.Page,  // on the GPU
	imported: bool,     // a buffer another process made: drawn, never written (canvas_import.odin)
	pixels:  []u8,      // the reference's texels
	display: Image,     // the reference's picture of it, for drawing
	shown:   u64,       // the version `display` is of
}

@(private)
Canvas_Done :: struct {
	id:   u32,
	read: Canvas_Read,
}

// Canvas_Shown is what a canvas node last showed.
@(private)
Canvas_Shown :: struct {
	host:      ^Canvas_Host,
	canvas:    Canvas,
	version:   u64,
	source:    Rect,
	pixels:     Pixels,
	pixel_grid: bool,
}

// gpu_open asks for the app's Gpu: the handler gets it once the device is
// up (when the first surface has been made), or at once with the CPU
// reference where there is no GPU. Every ask gets the same one.
//
//	start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return Gpu_Ready{e.value} }) },
gpu_open :: proc($Msg: typeid, on_done: Handler(Msg, Gpu)) -> Cmd(Msg) {
	return {kind = .Gpu_Open, on_gpu = on_done}
}

// gpu_reference is a Gpu that runs on the CPU, for a headless test or a
// tool with no window. The caller's: gpu_close.
gpu_reference :: proc(allocator := context.allocator) -> Gpu {
	h := new(Canvas_Host, allocator)
	h.allocator = allocator
	h.entries = make([dynamic]Canvas_Entry, allocator)
	h.done = make([dynamic]Canvas_Done, allocator)
	h.reads = make(map[u32]Canvas_Read, allocator)
	h.write_buf = make([dynamic]u8, allocator)
	return {host = h}
}

// gpu_close frees a Gpu from gpu_reference and every canvas it holds.
gpu_close :: proc(g: ^Gpu) {
	if g.host == nil do return
	canvas_host_destroy(g.host)
	g.host = nil
}

// gpu_limits says what canvases `g` can have.
gpu_limits :: proc(g: Gpu) -> Gpu_Limits {
	h := g.host
	if h == nil do return {}
	if h.r == nil do return {max_side = 1 << 15, formats = ~bit_set[Canvas_Format]{}, filtered = ~bit_set[Canvas_Format]{}}
	l := gpu.limits(h.r)
	return {max_side = int(l.max_side), device_memory = l.device_memory, formats = l.formats, filtered = l.filtered, storage = l.storage, on_gpu = true}
}

// canvas_create makes a `size` canvas of `format` whose values are in
// `space`, clear (every texel 0). False when the Gpu cannot make it: a side
// not positive or past gpu_limits, a format it lacks, no memory.
//
// `.R8` and `.R16` hold one channel of coverage (a selection, a mask, a
// stroke); they have no colour space and read as a texel of (r, 0, 0, 1).
// `mips = false` gives one level, for a canvas never shown scaled down (a
// scratch, an undo copy, a layer under the composite): a mip chain costs a
// third more memory and a rebuild over the touched rect after every batch.
canvas_create :: proc(g: Gpu, size: [2]int, format := Canvas_Format.RGBA8, space := Color_Space.sRGB, mips := true) -> (c: Canvas, ok: bool) {
	h := g.host
	if h == nil || size.x <= 0 || size.y <= 0 do return
	lim := gpu_limits(g)
	if size.x > lim.max_side || size.y > lim.max_side || format not_in lim.formats do return
	e := Canvas_Entry{used = true, size = size, format = format, space = space, version = 1}
	if h.r != nil {
		e.page = gpu.canvas_create(h.r, {u32(size.x), u32(size.y)}, format, space, mips)
		if e.page == 0 do return
	} else {
		pixels, err := make([]u8, size.x * size.y * gpu.canvas_bpp(format), h.allocator)
		if err != nil do return
		e.pixels = pixels
	}
	for &slot, i in h.entries do if !slot.used {
		slot = e
		return Canvas(i + 1), true
	}
	append(&h.entries, e)
	return Canvas(len(h.entries)), true
}

// canvas_valid says whether `c` is still a canvas of `g`. It stops being
// one when it is destroyed, and when the GPU is reset — canvases live in
// VRAM and have no copy, so a reset takes them (App.gpu_reset).
canvas_valid :: proc(g: Gpu, c: Canvas) -> bool {
	return canvas_entry(g, c) != nil
}

// gpu_renderer is the renderer behind a Gpu, or nil for the CPU reference.
// For tools that have to speak to the device itself — a recovery probe, a
// profiler — not for drawing.
gpu_renderer :: proc(g: Gpu) -> ^gpu.Renderer {
	return g.host.r if g.host != nil else nil
}

// canvas_destroy frees a canvas; its queued work goes with it. On the GPU
// it waits for the device to be idle: not for every frame.
canvas_destroy :: proc(g: Gpu, c: Canvas) {
	if e := canvas_entry_lost(g, c); e != nil { // a handle a reset spent: the slot is free again
		e^ = {}
		return
	}
	e := canvas_entry(g, c)
	if e == nil do return
	if g.host.r != nil && e.page != 0 do gpu.atlas_destroy(g.host.r, e.page)
	delete(e.pixels, g.host.allocator)
	image_destroy(&e.display)
	e^ = {}
}

// canvas_info is a canvas's size, format and colour space; false when it
// is not one of `g`'s.
canvas_info :: proc(g: Gpu, c: Canvas) -> (size: [2]int, format: Canvas_Format, space: Color_Space, ok: bool) {
	e := canvas_entry(g, c)
	if e == nil do return
	return e.size, e.format, e.space, true
}

@(private)
canvas_entry :: proc(g: Gpu, c: Canvas) -> ^Canvas_Entry {
	h := g.host
	if h == nil || c == 0 || int(c) > len(h.entries) do return nil
	e := &h.entries[c - 1]
	if !e.used || e.lost do return nil
	return e
}

// canvas_entry_lost is the entry behind a handle a GPU reset spent, or nil
// for any other handle. Only canvas_destroy wants one: everything else must
// treat the handle as gone.
@(private)
canvas_entry_lost :: proc(g: Gpu, c: Canvas) -> ^Canvas_Entry {
	h := g.host
	if h == nil || c == 0 || int(c) > len(h.entries) do return nil
	e := &h.entries[c - 1]
	return e if e.used && e.lost else nil
}

@(private)
canvas_rect_ok :: proc "contextless" (e: ^Canvas_Entry, x, y, w, h: int) -> bool {
	return w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= e.size.x && y + h <= e.size.y
}

// canvas_write puts `pixels` (w × h texels of the canvas's format, rows
// tightly packed) at x, y. The bytes are copied now. False for a rectangle
// outside the canvas, too few bytes, or no such canvas.
canvas_write :: proc(g: Gpu, c: Canvas, x, y, w, h: int, pixels: []u8) -> bool {
	e := canvas_entry(g, c)
	if e == nil || !canvas_rect_ok(e, x, y, w, h) do return false
	bpp := gpu.canvas_bpp(e.format)
	if len(pixels) < w * h * bpp do return false
	if g.host.r != nil {
		if !gpu.canvas_write(g.host.r, e.page, u32(x), u32(y), u32(w), u32(h), pixels) do return false
	} else {
		for row in 0 ..< h do copy(e.pixels[((y + row) * e.size.x + x) * bpp:][:w * bpp], pixels[row * w * bpp:][:w * bpp])
	}
	e.version += 1
	return true
}

// canvas_write_begin hands back the bytes to fill for the rectangle at x, y
// — w × h texels of the canvas's format, rows tightly packed — instead of
// copying from the app's own buffer, and canvas_write_end finishes the write.
// Use it where pixels are made a frame at a time (a video frame): it saves
// the copy through the app's own buffer.
//
// ```odin
// if px, ok := baldr.canvas_write_begin(g, c, 0, 0, w, h); ok {
//     decode_into(px)                       // or copy from a helper's memory
//     baldr.canvas_write_end(g, c)
// }
// ```
//
// The memory is the toolkit's and the slice is valid until
// canvas_write_end, after which the GPU owns those bytes and a write
// through it lands in a copy in flight: never free it or keep it across an
// update. The write is queued where it is asked for, so operations keep
// their order; one may be open at a time. Nil and false for a rectangle
// outside the canvas, no such canvas, a write already open, or no memory.
canvas_write_begin :: proc(g: Gpu, c: Canvas, x, y, w, h: int) -> ([]u8, bool) {
	hs := g.host
	e := canvas_entry(g, c)
	if hs == nil || e == nil || hs.writing != 0 || !canvas_rect_ok(e, x, y, w, h) do return nil, false
	need := w * h * gpu.canvas_bpp(e.format)
	px: []u8
	if hs.r != nil {
		bytes, ok := gpu.canvas_write_begin(hs.r, e.page, u32(x), u32(y), u32(w), u32(h))
		if !ok do return nil, false
		px = bytes
	} else {
		resize(&hs.write_buf, need)
		if len(hs.write_buf) < need do return nil, false
		px = hs.write_buf[:need]
	}
	hs.writing, hs.write_rect = c, {x, y, w, h}
	return px, true
}

// canvas_write_end finishes the write canvas_write_begin opened on `c`, and
// the slice it handed over is spent. False when no write was open on that
// canvas.
canvas_write_end :: proc(g: Gpu, c: Canvas) -> bool {
	hs := g.host
	if hs == nil || c == 0 || hs.writing != c do return false
	return canvas_write_commit(hs)
}

// canvas_write_commit is canvas_write_end's work, and what the loop does
// with a write left open (canvases_step). The write stands either way: on
// the GPU it is already queued, so the reference copies its buffer in too,
// and the two hosts agree about what an app's mistake does.
@(private)
canvas_write_commit :: proc(hs: ^Canvas_Host) -> bool {
	c := hs.writing
	hs.writing = 0
	if c == 0 do return false
	if hs.r != nil do gpu.canvas_write_end(hs.r)
	e := canvas_entry(Gpu{host = hs}, c)
	if e == nil do return false // destroyed under the open write: the bytes go nowhere
	if hs.r == nil {
		x, y, w, h := hs.write_rect[0], hs.write_rect[1], hs.write_rect[2], hs.write_rect[3]
		bpp := gpu.canvas_bpp(e.format)
		for row in 0 ..< h do copy(e.pixels[((y + row) * e.size.x + x) * bpp:][:w * bpp], hs.write_buf[row * w * bpp:][:w * bpp])
	}
	e.version += 1
	return true
}

// canvas_fill sets the rectangle's texels to `value`, as stored: 0..1 for
// RGBA8 and RGBA16 (clamped, rounded to the nearest step), any float for
// RGBA32F. False as canvas_write.
canvas_fill :: proc(g: Gpu, c: Canvas, x, y, w, h: int, value: [4]f32) -> bool {
	e := canvas_entry(g, c)
	if e == nil || !canvas_rect_ok(e, x, y, w, h) do return false
	if g.host.r != nil {
		if !gpu.canvas_fill(g.host.r, e.page, u32(x), u32(y), u32(w), u32(h), value) do return false
	} else {
		bpp := gpu.canvas_bpp(e.format)
		texel := canvas_encode(e.format, value)
		for row in 0 ..< h do for col in 0 ..< w do copy(e.pixels[((y + row) * e.size.x + x + col) * bpp:][:bpp], texel[:bpp])
	}
	e.version += 1
	return true
}

// canvas_copy copies w × h texels at x, y of `src` to `to` in `dst`. The
// values keep their meaning across formats (an 8-bit 255 is a 16-bit 65535;
// floats past 0..1 are clamped into an unsigned format); colour spaces are
// not converted. Within one canvas the rectangles must not overlap. False
// for a rectangle outside either canvas, overlapping ones, or no canvas.
canvas_copy :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int) -> bool {
	s, d := canvas_entry(g, src), canvas_entry(g, dst)
	if s == nil || d == nil || !canvas_rect_ok(s, x, y, w, h) || !canvas_rect_ok(d, to.x, to.y, w, h) do return false
	if src == dst && x < to.x + w && to.x < x + w && y < to.y + h && to.y < y + h do return false
	if g.host.r != nil {
		if !gpu.canvas_copy(g.host.r, s.page, u32(x), u32(y), u32(w), u32(h), d.page, u32(to.x), u32(to.y)) do return false
	} else {
		sb, db := gpu.canvas_bpp(s.format), gpu.canvas_bpp(d.format)
		for row in 0 ..< h do for col in 0 ..< w {
			from := s.pixels[((y + row) * s.size.x + x + col) * sb:][:sb]
			into := d.pixels[((to.y + row) * d.size.x + to.x + col) * db:][:db]
			if s.format == d.format {
				copy(into, from)
			} else {
				texel := canvas_encode(d.format, canvas_decode(s.format, from))
				copy(into, texel[:db])
			}
		}
	}
	d.version += 1
	return true
}

// canvas_read reads a rectangle of a canvas back; the handler gets
// Canvas_Read (with `tag`) once the GPU has done the work queued before
// it. For saving, exporting, sampling a colour.
canvas_read :: proc($Msg: typeid, g: Gpu, c: Canvas, x, y, w, h: int, on_done: Handler(Msg, Canvas_Read), tag: u64 = 0) -> Cmd(Msg) {
	return {kind = .Canvas_Read, host = g.host, canvas = c, area = {x, y, w, h}, on_canvas = on_done, tag = tag}
}

// canvas_read_now reads a rectangle straight away, into `allocator`: the
// CPU reference's canvases only (a headless tool, a test). False on the
// GPU, whose reads come back as messages (canvas_read), and for a
// rectangle outside the canvas.
canvas_read_now :: proc(g: Gpu, c: Canvas, x, y, w, h: int, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	e := canvas_entry(g, c)
	if e == nil || g.host.r != nil || !canvas_rect_ok(e, x, y, w, h) do return
	bpp := gpu.canvas_bpp(e.format)
	pixels = make([]u8, w * h * bpp, allocator)
	for row in 0 ..< h do copy(pixels[row * w * bpp:][:w * bpp], e.pixels[((y + row) * e.size.x + x) * bpp:][:w * bpp])
	return pixels, true
}

// canvas_host_read starts a read; its outcome is found in host.done by id
// (at once for the reference; after the batch carrying it, on the GPU).
@(private)
canvas_host_read :: proc(h: ^Canvas_Host, c: Canvas, area: [4]int) -> (id: u32) {
	g := Gpu{host = h}
	out := Canvas_Read{canvas = c, x = area[0], y = area[1], w = area[2], h = area[3]}
	e := canvas_entry(g, c)
	if e != nil do out.format = e.format
	if e == nil || !canvas_rect_ok(e, area[0], area[1], area[2], area[3]) {
		h.next_read += 1
		append(&h.done, Canvas_Done{id = h.next_read, read = out})
		return h.next_read
	}
	if h.r != nil {
		gid, ok := gpu.canvas_read(h.r, e.page, u32(out.x), u32(out.y), u32(out.w), u32(out.h))
		if ok {
			h.reads[gid] = out
			return gid
		}
		h.next_read += 1
		append(&h.done, Canvas_Done{id = h.next_read, read = out})
		return h.next_read
	}
	bpp := gpu.canvas_bpp(e.format)
	out.pixels = make([]u8, out.w * out.h * bpp, h.allocator)
	for row in 0 ..< out.h do copy(out.pixels[row * out.w * bpp:][:out.w * bpp], e.pixels[((out.y + row) * e.size.x + out.x) * bpp:][:out.w * bpp])
	out.ok = true
	h.next_read += 1
	append(&h.done, Canvas_Done{id = h.next_read, read = out})
	return h.next_read
}

// canvas_host_take moves a finished GPU batch's reads into host.done.
@(private)
canvas_host_take :: proc(h: ^Canvas_Host, batch: u64) {
	if h.r == nil do return
	list, _ := gpu.canvas_reads_take(h.r, batch, h.allocator)
	defer delete(list, h.allocator)
	for d in list {
		out := h.reads[d.id]
		delete_key(&h.reads, d.id)
		out.pixels, out.ok = d.pixels, d.ok
		append(&h.done, Canvas_Done{id = d.id, read = out})
	}
}

@(private)
canvas_host_destroy :: proc(h: ^Canvas_Host) {
	for &e in h.entries {
		if !e.used do continue
		if h.r != nil && e.page != 0 do gpu.atlas_destroy(h.r, e.page)
		delete(e.pixels, h.allocator)
		image_destroy(&e.display)
	}
	for d in h.done do delete(d.read.pixels, h.allocator)
	delete(h.entries)
	delete(h.done)
	delete(h.reads)
	delete(h.write_buf)
	delete(h.card_node, h.allocator)
	free(h, h.allocator)
}

// canvas_encode is `v` as one texel of `f`, the way the GPU stores it:
// unsigned formats clamped to 0..1 and rounded to the nearest step,
// little-endian.
@(private)
canvas_encode :: proc(f: Canvas_Format, v: [4]f32) -> (out: [16]u8) {
	switch f {
	case .RGBA8:
		for k in 0 ..< 4 do out[k] = u8(math.round(clamp(v[k], 0, 1) * 255))
	case .RGBA16:
		for k in 0 ..< 4 {
			q := u16(math.round(clamp(v[k], 0, 1) * 65535))
			out[2 * k], out[2 * k + 1] = u8(q), u8(q >> 8)
		}
	case .RGBA32F:
		for k in 0 ..< 4 {
			b := transmute([4]u8)v[k]
			copy(out[4 * k:][:4], b[:])
		}
	case .R8: // coverage: the first channel, and nothing else is kept
		out[0] = u8(math.round(clamp(v.r, 0, 1) * 255))
	case .R16:
		q := u16(math.round(clamp(v.r, 0, 1) * 65535))
		out[0], out[1] = u8(q), u8(q >> 8)
	}
	return
}

// canvas_decode is one texel of `f` as its four values.
@(private)
canvas_decode :: proc(f: Canvas_Format, t: []u8) -> (v: [4]f32) {
	switch f {
	case .RGBA8:
		for k in 0 ..< 4 do v[k] = f32(t[k]) / 255
	case .RGBA16:
		for k in 0 ..< 4 do v[k] = f32(u16(t[2 * k]) | u16(t[2 * k + 1]) << 8) / 65535
	case .RGBA32F:
		for k in 0 ..< 4 do v[k] = transmute(f32)[4]u8{t[4 * k], t[4 * k + 1], t[4 * k + 2], t[4 * k + 3]}
	case .R8:  // one channel read as a texel: coverage in r, opaque
		v = {f32(t[0]) / 255, 0, 0, 1}
	case .R16:
		v = {f32(u16(t[0]) | u16(t[1]) << 8) / 65535, 0, 0, 1}
	}
	return
}

// color_space_to_linear is a colour's values in `space` as linear light
// with sRGB's primaries: the display transform the shader applies to a
// canvas (ui.frag canvas_decode), here for the reference and the tests.
// Colours outside sRGB come out below 0 or above 1.
color_space_to_linear :: proc(rgb: [3]f32, space: Color_Space) -> [3]f32 {
	decode :: proc(c: f32) -> f32 { return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4) }
	switch space {
	case .Linear:
		return rgb
	case .Adobe_RGB:
		l := [3]f32{math.pow(max(rgb.r, 0), 2.19921875), math.pow(max(rgb.g, 0), 2.19921875), math.pow(max(rgb.b, 0), 2.19921875)}
		return {1.3983557 * l.r - 0.3983557 * l.g, l.g, -0.0429290 * l.g + 1.0429290 * l.b}
	case .Display_P3:
		l := [3]f32{decode(rgb.r), decode(rgb.g), decode(rgb.b)}
		return {1.2249402 * l.r - 0.2249402 * l.g, -0.0420570 * l.r + 1.0420570 * l.g, -0.0196376 * l.r - 0.0786360 * l.g + 1.0982736 * l.b}
	case .sRGB:
	}
	return {decode(rgb.r), decode(rgb.g), decode(rgb.b)}
}

// canvas_display brings the reference's picture of a canvas up to date:
// each texel through its colour space to sRGB, 8 bits, straight alpha.
@(private)
canvas_display :: proc(h: ^Canvas_Host, e: ^Canvas_Entry) -> ^Image {
	if e.display.pixels != nil && e.shown == e.version do return &e.display
	if e.display.width != e.size.x || e.display.height != e.size.y {
		image_destroy(&e.display)
		e.display = Image{width = e.size.x, height = e.size.y, pixels = make([]u8, e.size.x * e.size.y * 4, h.allocator), allocator = h.allocator}
	}
	bpp := gpu.canvas_bpp(e.format)
	for i in 0 ..< e.size.x * e.size.y {
		v := canvas_decode(e.format, e.pixels[i * bpp:][:bpp])
		l := color_space_to_linear(v.rgb, e.space)
		out := e.display.pixels[i * 4:][:4]
		for k in 0 ..< 3 do out[k] = u8(math.round(linear_to_srgb(clamp(l[k], 0, 1)) * 255))
		out[3] = u8(math.round(clamp(v.a, 0, 1) * 255))
	}
	e.display.version += 1
	e.shown = e.version
	return &e.display
}

// canvas shows canvas `c` of `g` scaled into `width` × `height`, as `image`
// shows a picture: one side given keeps its aspect, `fit` places it, and
// `source` is the part shown in its texels ({}: all; changing it is a
// repaint, as a zoom or a pan is). Its values are decoded from its colour
// space for the screen. Decorative unless `label` names it (role Image): an
// editor names its document.
//
// Magnified, it goes crisp on its own by default: smooth up to 2 device px
// a texel, hard-edged from 4, crossfaded between. `pixelated = true` forces
// hard texels, `false` the smooth filter. `pixel_grid` draws a 1-pixel line
// between texels, fading in from 8 device px a texel, full from 24. Layout
// sizes it like any node, so one asked for larger than its parent allows is
// squeezed and looks blurry; to show part of a large canvas, pass `source`
// at the node's real size.
canvas :: proc(ui: ^Ui($Msg), g: Gpu, c: Canvas, width: f32 = 0, height: f32 = 0, radius: f32 = 0, label: string = "",
	fit: Image_Fit = .Cover, source: Rect = {}, pixelated: Maybe(bool) = nil, pixel_grid := false, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	w, h := width, height
	px := pixels_of(pixelated)
	e := canvas_entry(g, c)
	if e != nil {
		src, shown := image_source(source, e.size)
		if !shown do src = {}
		aspect := src.w / src.h if src.h > 0 else 1
		switch {
		case w <= 0 && h <= 0: w, h = src.w, src.h
		case w <= 0:           w = h * aspect
		case h <= 0:           h = w / aspect
		}
		now := Canvas_Shown{host = g.host, canvas = c, version = e.version, source = source, pixels = px, pixel_grid = pixel_grid}
		if old, had := t.canvases[n]; !had || old != now do mark_paint_dirty(t, n) // new texels, another part, sampled differently
		t.canvases[n] = now
	} else {
		delete_key(&t.canvases, n)
	}
	if ck, ok := d.kind.(Custom_Kind); !ok || created || ck.size != {w, h} || ck.paint != paint_canvas {
		d.kind = Custom_Kind{size = {w, h}, paint = paint_canvas}
		mark_layout_dirty(t, n)
	}
	if d.style.radius != radius || d.tag != u64(fit) {
		d.style.radius = radius
		d.tag = u64(fit)
		mark_paint_dirty(t, n)
	}
	if label != "" {
		d.access.role = .Image
		set_name(t, n, label)
	} else {
		d.access.role = .None
	}
	return n
}

@(private)
paint_canvas :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	shown, has := t.canvases[n]
	if !has do return
	g := Gpu{host = shown.host}
	e := canvas_entry(g, shown.canvas)
	if e == nil do return // gone: nothing to draw, not a white page
	c := Color{1, 1, 1, t.paint_opacity}
	if disabled_within(t, n) do c.a *= t.theme.state.disabled_alpha
	if shown.host.r == nil { // the reference: drawn as a picture of it
		img := canvas_display(shown.host, e)
		if img.id == 0 do img.id = image_new_id()
		append(&l.cmds, Draw_Image{rect = d.abs, img = img, radius = d.style.radius, square = d.style.square, color = c, fit = Image_Fit(d.tag), id = img.id, version = img.version, size = e.size, source = shown.source, pixels = shown.pixels, pixel_grid = shown.pixel_grid})
		return
	}
	append(&l.cmds, Draw_Canvas{rect = d.abs, page = u32(e.page), size = e.size, radius = d.style.radius, square = d.style.square, color = c, fit = Image_Fit(d.tag), source = shown.source, pixels = shown.pixels, pixel_grid = shown.pixel_grid})
}

// render_canvas draws a canvas's texture as render_image draws a picture's.
@(private)
render_canvas :: proc(v: Draw_Canvas, s: f32, out: ^[dynamic]gpu.Cmd) {
	if v.color.a <= 0 || v.page == 0 do return
	src, shown := image_source(v.source, v.size)
	if !shown do return
	rect := v.rect
	switch v.fit {
	case .Contain: rect = image_contain_rect_f(rect, src.w, src.h)
	case .Cover:   src = image_cover_source(src, rect)
	case .Stretch:
	}
	if rect.w <= 0 || rect.h <= 0 do return
	fw, fh := f32(v.size.x), f32(v.size.y)
	append(out, gpu.Image{
		rect      = snap_rect(rect, s),
		uv        = {src.x / fw, src.y / fh, (src.x + src.w) / fw, (src.y + src.h) / fh},
		page      = gpu.Page(v.page),
		radius    = v.radius * s,
		square    = v.square,
		color     = v.color,
		pixels     = v.pixels,
		pixel_grid = v.pixel_grid,
	})
}

// Runtime

// canvases_step runs once a loop pass, after the messages: it hands out the
// Gpu to those who asked once the device is up, and flushes the canvas work
// the updates queued, a thread waiting on the batch when it carries reads.
@(private)
canvases_step :: proc(rt: ^Runtime($State, $Msg)) {
	if len(rt.gpu_waiting) > 0 {
		h := canvas_host_for(rt)
		if h != nil {
			for w in rt.gpu_waiting do handler_deliver(w, Gpu{host = h}, 0, &rt.msgs)
			clear(&rt.gpu_waiting)
		}
	}
	h := rt.canvas_host
	if h == nil do return
	if h.writing != 0 {
		canvas_write_commit(h)
		if !h.write_said {
			h.write_said = true
			fmt.eprintfln("baldr: canvas_write_begin was not ended in the update that opened it; the write stands, but the slice must not be kept")
		}
	}
	if len(h.done) > 0 do mailbox_post(&rt.mailbox, Mail(Msg){canvas = true}) // the reference's reads: out on the next pass, as any outcome is
	if h.r == nil || !gpu.canvas_pending(h.r) do return
	batch, reads := gpu.canvas_flush(h.r)
	if h.debug {
		st := gpu.canvas_staging_stats(h.r)
		fmt.eprintfln("baldr/canvas: staging made %d, reused %d, let go %d; %d idle (%d KB)",
			st.made, st.reused, st.dropped, st.idle, st.idle_bytes / 1024)
	}
	if batch == 0 || !reads do return
	Waiter :: struct {
		wait:    gpu.Canvas_Wait,
		batch:   u64,
		mailbox: ^Mailbox(Msg),
		count:   ^int,
	}
	w := new(Waiter, runtime.heap_allocator())
	w^ = {gpu.canvas_waiter(h.r, batch), batch, &rt.mailbox, &h.waiters}
	sync.atomic_add(&h.waiters, 1)
	wait :: proc(p: rawptr) {
		w := (^Waiter)(p)
		gpu.canvas_wait(w.wait)
		mailbox_post(w.mailbox, Mail(Msg){canvas_batch = w.batch})
		sync.atomic_sub(w.count, 1) // last: the run may end once this is 0
		free(w, runtime.heap_allocator())
	}
	if thread.create_and_start_with_data(w, wait, self_cleanup = true) == nil do wait(w) // no thread: wait here
}

// canvases_shutdown ends the run's canvases: the threads waiting on
// batches finish (the device is waited for first, so they do at once), then
// every canvas goes, before the renderer.
@(private)
canvases_shutdown :: proc(rt: ^Runtime($State, $Msg)) {
	delete(rt.gpu_waiting)
	h := rt.canvas_host
	if h == nil do return
	if h.r != nil do gpu.canvas_idle(h.r)
	for i := 0; i < 1000 && sync.atomic_load(&h.waiters) > 0; i += 1 do time.sleep(time.Millisecond)
	canvas_host_destroy(h)
	rt.canvas_host = nil
	rt.mailbox.canvas_host = nil
}

// canvas_host_for is the runtime's Gpu host, made the first time: on the
// GPU once its device is up (nil until then), the reference without one.
@(private)
canvas_host_for :: proc(rt: ^Runtime($State, $Msg)) -> ^Canvas_Host {
	if rt.canvas_host != nil do return rt.canvas_host
	if rt.r != nil && gpu.limits(rt.r).max_side == 0 do return nil // the device comes with the first surface
	g := gpu_reference()
	g.host.r = rt.r
	// BALDR_GPU_REFERENCE=1 runs the canvases on the CPU reference even with
	// a device up, to tell a wrong shader from wrong logic
	// (`spikes/stroke_parity` compares the two). Slow; for debugging only.
	if os.get_env("BALDR_GPU_REFERENCE", context.temp_allocator) != "" {
		g.host.r = nil
	}
	// BALDR_DEBUG_CANVAS=1 logs staging buffers made against reused. For a
	// stream written every frame, `made` must stop rising while `reused`
	// climbs, or each frame pays an allocation and a free.
	g.host.debug = os.get_env("BALDR_DEBUG_CANVAS", context.temp_allocator) != ""
	rt.canvas_host = g.host
	rt.mailbox.canvas_host = g.host
	return g.host
}

// canvas_mail delivers the reads that finished: those of a GPU batch
// (`batch`), or the reference's. Their bytes are freed once the messages
// were handled (mailbox_release).
@(private)
canvas_mail :: proc(mb: ^Mailbox($Msg), batch: u64, out: ^[dynamic]Msg) {
	h := mb.canvas_host
	if h == nil do return
	if batch != 0 do canvas_host_take(h, batch)
	for d in h.done {
		if wait, has := mb.canvas_waiting[d.id]; has {
			handler_deliver(wait.on_read, d.read, wait.tag, out)
			delete_key(&mb.canvas_waiting, d.id)
		}
		if d.read.pixels != nil do append(&mb.canvas_bytes, d.read.pixels)
	}
	clear(&h.done)
}

// Canvas_Waiting is a read's handler, until its outcome arrives.
@(private)
Canvas_Waiting :: struct($Msg: typeid) {
	on_read: Handler(Msg, Canvas_Read),
	tag:     u64,
}

