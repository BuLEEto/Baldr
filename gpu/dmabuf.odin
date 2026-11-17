// dmabuf.odin — what a GPU buffer from another process looks like, said once
// for every platform. Importing one is a Linux mechanism and
// lives in dmabuf_linux.odin; the formats, the descriptor shape and what a
// device can do are the same words everywhere, so an app writes one call and
// gets a refusal where there is nothing to import.
package gpu

// DRM_FORMAT_* are the fourccs an imported buffer may be in: the
// single-plane 8-bit-a-channel ones; a format with more than one plane (NV12,
// and AMD's compressed modifiers) is not imported.
DRM_FORMAT_ABGR8888 :: u32('A') | u32('B') << 8 | u32('2') << 16 | u32('4') << 24
DRM_FORMAT_XBGR8888 :: u32('X') | u32('B') << 8 | u32('2') << 16 | u32('4') << 24
DRM_FORMAT_ARGB8888 :: u32('A') | u32('R') << 8 | u32('2') << 16 | u32('4') << 24
DRM_FORMAT_XRGB8888 :: u32('X') | u32('R') << 8 | u32('2') << 16 | u32('4') << 24

// DRM_FORMAT_MOD_LINEAR is the modifier for a plain row-after-row buffer:
// every device that imports anything imports this one.
DRM_FORMAT_MOD_LINEAR :: u64(0)

// DMABUF_FORMATS is what can be asked about, in the order a producer should
// prefer them (an opaque buffer first: a video frame has no transparency to
// keep, and an X format lets the alpha channel be ignored rather than read as
// zero).
DMABUF_FORMATS :: [4]u32{DRM_FORMAT_XBGR8888, DRM_FORMAT_ABGR8888, DRM_FORMAT_XRGB8888, DRM_FORMAT_ARGB8888}

// Dmabuf is one plane of a buffer to import: the file descriptor (the
// caller's, duplicated here and left open), its size in texels, its
// DRM fourcc and modifier, and where the plane starts and how long its rows
// are. offset and stride are the producer's own, not worked out from the
// width: a tiled buffer's rows are not width × 4 bytes.
Dmabuf :: struct {
	fd:       int,
	width:    u32,
	height:   u32,
	fourcc:   u32,
	modifier: u64,
	offset:   u32,
	stride:   u32,
}

// QUEUE_FAMILY_FOREIGN is VK_QUEUE_FAMILY_FOREIGN_EXT: the queue family of
// "some other API entirely", which is what the producer of an imported
// buffer is. Every ownership transfer for such a buffer names it.
//
// Spelled out because `vendor:vulkan` declares `QUEUE_FAMILY_FOREIGN_EXT ::
// 2`, a literal queue family index, where the spec's `(~0U - 2)` is
// 0xFFFFFFFD (its neighbours IGNORED and EXTERNAL are right). With 2 every
// barrier hands ownership to a real family where the device has one, which
// is accepted and draws; where it has none, the validation layer refuses
// the barriers.
QUEUE_FAMILY_FOREIGN :: ~u32(2)

// Dmabuf_Caps is what this device can do with buffers from elsewhere:
// whether importing works at all, and which card it would be drawing on —
// the DRM render node's device numbers, for a producer that must decode on
// the same GPU (a buffer from the other card in a two-card machine either
// will not import or is copied across the bus to get there).
Dmabuf_Caps :: struct {
	import_ok:    bool,
	render_node:  bool, // the numbers below are real
	render_major: i64,
	render_minor: i64,
}
