package baldr

// canvas_import.odin — a GPU buffer another process made, drawn as a canvas.
//
// For a helper process that decodes video in hardware and draws each frame
// on the same card, into a small ring of buffers it shares as dmabufs. The
// app imports each buffer once; from then on a frame costs a fence and a
// draw rather than two copies of the whole picture.
//
// What an app does, in order:
//
//  1. `gpu_card(g)` — which card Baldr draws on, so the producer uses the
//     same one. A buffer from another card will not import, or is copied
//     across the bus.
//  2. `canvas_import_modifiers(g, fourcc, out)` — what layouts can be
//     imported, before the producer allocates: a buffer in a layout this
//     device cannot import has to be copied.
//  3. `canvas_import_dmabuf(g, buf)` once per buffer, keeping the canvas for
//     as long as the producer keeps the buffer.
//  4. Per frame: `canvas_acquire_fence(g, c, fd)` with the sync_file the
//     producer's drawing signals, then draw the canvas as usual. Before
//     telling the producer it may reuse a buffer, `canvas_import_idle(g, c)`.
//
// An imported canvas is read-only to the app: every operation that writes a
// canvas refuses it, because the memory belongs to whoever made it. It is
// drawn by the `canvas` node like any other, and `canvas_destroy` lets it go.
//
// Linux-only (dmabuf descriptors, DRM format modifiers, sync_files).
// Elsewhere the calls exist and refuse, so an app that imports where it can
// and copies where it cannot is written once.

import "core:fmt"
import "baldr:gpu"

// Dmabuf is one plane of a GPU buffer to import: the file descriptor (the
// caller's — Baldr duplicates it and leaves the original alone), the size in
// texels, the DRM fourcc and modifier the producer allocated with, and where
// the plane starts and how long its rows are.
//
// `offset` and `stride` are the producer's own numbers, not worked out from
// the width: a tiled buffer's rows are not width × 4 bytes.
Dmabuf :: gpu.Dmabuf

// The four formats that can be imported: single-plane, 8 bits a channel.
// The DRM names are byte order, so ABGR8888 holds R, G, B, A in memory. An
// X format has no alpha to read and is drawn as opaque, which is what a
// video frame wants; prefer one of those where the producer can give it.
DRM_FORMAT_XBGR8888 :: gpu.DRM_FORMAT_XBGR8888
DRM_FORMAT_ABGR8888 :: gpu.DRM_FORMAT_ABGR8888
DRM_FORMAT_XRGB8888 :: gpu.DRM_FORMAT_XRGB8888
DRM_FORMAT_ARGB8888 :: gpu.DRM_FORMAT_ARGB8888

// DRM_FORMAT_MOD_LINEAR is a plain row-after-row buffer: every device that
// imports anything imports this one, so a producer can always fall back to it.
DRM_FORMAT_MOD_LINEAR :: gpu.DRM_FORMAT_MOD_LINEAR

// Gpu_Card says which card Baldr is drawing on and whether buffers from
// other processes can be imported at all. `node` is the DRM render node's
// path (`/dev/dri/renderD128`), which is what a producer opens; it is "" when
// the driver does not say which card it is. The string is Baldr's and is good
// for the run.
Gpu_Card :: struct {
	shares: bool, // canvas_import_dmabuf can work on this device
	known:  bool, // …and the numbers and node below are real
	major:  i64,
	minor:  i64,
	node:   string,
}

// gpu_card is which card this Gpu draws on, for a producer that has to use
// the same one, and whether it can take buffers from elsewhere. Everything
// false on the CPU reference and off Linux.
gpu_card :: proc(g: Gpu) -> Gpu_Card {
	h := g.host
	if h == nil || h.r == nil do return {}
	caps := gpu.dmabuf_caps(h.r)
	out := Gpu_Card{shares = caps.import_ok, known = caps.render_node, major = caps.render_major, minor = caps.render_minor}
	if !out.known do return out
	// A DRM render node is named after its minor number. Kept on the host:
	// the string outlives this call.
	if h.card_node == "" do h.card_node = fmt.aprintf("/dev/dri/renderD%d", caps.render_minor, allocator = h.allocator)
	out.node = h.card_node
	return out
}

// canvas_import_modifiers fills `out` with the DRM format modifiers this
// device can import `fourcc` in, most preferred first, and returns how many
// there are — which may be more than `out` held, so a caller with a small
// buffer can ask again with a bigger one. 0 for a format that cannot be
// imported here at all.
//
// Ask this before the producer allocates, and let it choose from the answer.
// Each modifier listed has been checked with the driver against a shared
// buffer, so it is what will work rather than what the format table claims.
// Only single-plane layouts are listed.
canvas_import_modifiers :: proc(g: Gpu, fourcc: u32, out: []u64) -> int {
	h := g.host
	if h == nil || h.r == nil do return 0
	return gpu.dmabuf_modifiers(h.r, fourcc, out)
}

// canvas_import_dmabuf imports `buf` as a canvas that can be drawn and
// nothing else: every operation that would write it refuses, because the
// memory belongs to whoever made it. Import each buffer of a producer's ring
// once and keep the canvas; `canvas_destroy` lets it go.
//
// Baldr duplicates the file descriptor, so the caller may close its own
// whenever it likes.
//
// False when this device cannot import, when the format or modifier is not
// one `canvas_import_modifiers` listed, when the size is impossible, or when
// the driver refuses the memory; a line on stderr says which, once a run.
// False on the CPU reference and off Linux. The answer to a refusal is to
// copy the frames in instead (`canvas_write_begin`).
//
// A GPU reset takes an imported canvas with it, as it takes every canvas
// (`App.gpu_reset`): the handle stops being valid, and the app imports the
// producer's buffers again on the new device.
canvas_import_dmabuf :: proc(g: Gpu, buf: Dmabuf) -> (c: Canvas, ok: bool) {
	h := g.host
	if h == nil || h.r == nil do return
	page := gpu.canvas_import_dmabuf(h.r, buf)
	if page == 0 do return
	e := Canvas_Entry{
		used = true, size = {int(buf.width), int(buf.height)},
		format = .RGBA8, space = .sRGB, version = 1, page = page, imported = true,
	}
	for &slot, i in h.entries do if !slot.used {
		slot = e
		return Canvas(i + 1), true
	}
	append(&h.entries, e)
	return Canvas(len(h.entries)), true
}

// canvas_acquire_fence takes the sync_file the producer's drawing signals,
// to be waited on before anything samples the buffer again. The descriptor
// is taken over: Baldr closes it whether it was used or not, because a fence
// belongs to one frame.
//
// Nothing blocks: the fence is handed to the GPU. Call it once per frame,
// with that frame's fence, before the view that draws the canvas.
//
// False for a canvas that was not imported, a descriptor the driver will not
// take, or no importing on this device — in which case the frame is drawn
// without waiting, which can show a half-drawn picture but never breaks.
canvas_acquire_fence :: proc(g: Gpu, c: Canvas, sync_fd: int) -> bool {
	e := canvas_entry(g, c)
	if e == nil || !e.imported || g.host == nil || g.host.r == nil {
		gpu.dmabuf_drop_fence(sync_fd) // taken over however this turns out
		return false
	}
	return gpu.canvas_acquire_fence(g.host.r, e.page, sync_fd)
}

// canvas_import_idle says whether the GPU has finished with an imported
// buffer: true when no frame that drew it is still running, so the producer
// may draw into that buffer again. Ask it before telling the producer a
// buffer of its ring is free.
//
// The other half of explicit sync: rather than handing back a fence, Baldr
// answers whether the frame that drew it has finished. True for a canvas
// nothing has drawn yet, and for one that was never imported.
canvas_import_idle :: proc(g: Gpu, c: Canvas) -> bool {
	e := canvas_entry(g, c)
	if e == nil || !e.imported || g.host.r == nil do return true
	return gpu.canvas_import_idle(g.host.r, e.page)
}

// canvas_imported says whether `c` is a buffer from another process, and so
// cannot be written to. Every operation that writes a canvas checks this
// itself, so an app rarely needs to.
canvas_imported :: proc(g: Gpu, c: Canvas) -> bool {
	e := canvas_entry(g, c)
	return e != nil && e.imported
}
