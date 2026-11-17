#+build linux
package gpu

// Importing a GPU buffer from another process, as far as it can be asked
// without a device: which Vulkan format each DRM fourcc is, and that a
// refusal still takes over the descriptor it was handed. A real import, the
// barriers and the acquire fence need a card; `spikes/dmabuf_import` checks
// those.

@(require) import "core:sys/linux"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// The DRM fourccs are little-endian byte order and Vulkan's names are
// channel order, so the two read backwards from one another: a buffer whose
// bytes are R, G, B, A is called ABGR8888 by DRM and R8G8B8A8 by Vulkan.
// The wrong way round swaps red and blue in every frame, which looks like a
// decoder fault.
@(test)
a_drm_fourcc_names_its_bytes_and_a_vulkan_format_names_its_channels :: proc(t: ^testing.T) {
	testing.expect_value(t, DRM_FORMAT_ABGR8888, u32(0x3432_4241)) // 'A' 'B' '2' '4'
	testing.expect_value(t, DRM_FORMAT_XBGR8888, u32(0x3432_4258))
	testing.expect_value(t, DRM_FORMAT_ARGB8888, u32(0x3432_5241))
	testing.expect_value(t, DRM_FORMAT_XRGB8888, u32(0x3432_5258))

	f, is_opaque, ok := dmabuf_vk_format(DRM_FORMAT_ABGR8888)
	testing.expect(t, ok && f == .R8G8B8A8_UNORM && !is_opaque, "ABGR8888 holds R, G, B, A")
	f, is_opaque, ok = dmabuf_vk_format(DRM_FORMAT_ARGB8888)
	testing.expect(t, ok && f == .B8G8R8A8_UNORM && !is_opaque, "ARGB8888 holds B, G, R, A")

	// An X format has the same bytes and no alpha to read, so it is drawn
	// opaque; otherwise a frame whose fourth byte is zero would be invisible.
	f, is_opaque, ok = dmabuf_vk_format(DRM_FORMAT_XBGR8888)
	testing.expect(t, ok && f == .R8G8B8A8_UNORM && is_opaque, "XBGR8888 is opaque")
	f, is_opaque, ok = dmabuf_vk_format(DRM_FORMAT_XRGB8888)
	testing.expect(t, ok && f == .B8G8R8A8_UNORM && is_opaque, "XRGB8888 is opaque")

	// UNORM, never _SRGB: an imported buffer is drawn as a canvas and its
	// colour space is undone in the shader, as every canvas's is. An sRGB
	// view would decode it a second time.
	for cc in DMABUF_FORMATS {
		vf, _, got := dmabuf_vk_format(cc)
		testing.expect(t, got, "one of the four is known")
		testing.expect(t, vf == .R8G8B8A8_UNORM || vf == .B8G8R8A8_UNORM, "and is unsigned-normalised")
	}

	_, _, nv12 := dmabuf_vk_format(u32('N') | u32('V') << 8 | u32('1') << 16 | u32('2') << 24)
	testing.expect(t, !nv12, "two planes is not one of ours")
	_, _, nothing := dmabuf_vk_format(0)
	testing.expect(t, !nothing, "nor is nothing")
}

// dma_readers_gone says whether the read end of a pipe has been closed, by
// asking the pipe rather than the descriptor number: tests run on several
// threads, so another test may be handed the closed number at once, and "is
// this fd valid" would answer about its file. POLLERR on the write end means
// the pipe has no readers left.
@(private = "file")
dma_readers_gone :: proc(write_end: linux.Fd) -> bool {
	fds := []linux.Poll_Fd{{fd = write_end, events = {.OUT}}}
	linux.poll(fds, 0)
	return .ERR in fds[0].revents
}

// A fence handed over is taken over, however the call turns out. The caller
// writes no close of its own, so a refusal that kept the descriptor would
// leak one a frame: at sixty a second, out of descriptors in minutes.
@(test)
a_refused_acquire_fence_still_takes_the_descriptor :: proc(t: ^testing.T) {
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {}) != .NONE do testing.fail_now(t, "no pipe to make a descriptor from")
	defer linux.close(fds[1])

	r: Renderer // no device: the refusal every call makes before anything else
	testing.expect(t, !dma_readers_gone(fds[1]), "the pipe has a reader to begin with")
	testing.expect(t, !canvas_acquire_fence(&r, 1, int(fds[0])), "refused")
	testing.expect(t, dma_readers_gone(fds[1]), "closed means closed")

	// …and nothing is attempted with a descriptor that was never one.
	testing.expect(t, !canvas_acquire_fence(&r, 1, -1), "nothing to take over")
}

// Everything refuses without a device rather than reaching for one.
@(test)
importing_refuses_quietly_where_there_is_no_device :: proc(t: ^testing.T) {
	r: Renderer
	testing.expect_value(t, canvas_import_dmabuf(&r, Dmabuf{fd = 3, width = 8, height = 8, fourcc = DRM_FORMAT_XBGR8888}), Page(0))
	testing.expect_value(t, dmabuf_modifiers(&r, DRM_FORMAT_XBGR8888, nil), 0)
	testing.expect(t, canvas_import_idle(&r, 1), "nothing is holding a buffer that was never imported")
	caps := dmabuf_caps(&r)
	testing.expect(t, !caps.import_ok && !caps.render_node, "and the device says it can do neither")
}

}
