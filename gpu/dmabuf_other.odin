#+build !linux
// dmabuf_other.odin — importing a GPU buffer another process made is a Linux
// mechanism (dmabuf file descriptors, DRM format modifiers, sync_files).
// These are the same calls, refusing, so an app that imports where it can
// and copies where it cannot is written once rather than behind a `when`.
// The formats and the descriptor itself are in dmabuf.odin, which every
// platform has.
package gpu

@(private)
Dmabuf_State :: struct {}

dmabuf_caps :: proc(r: ^Renderer) -> Dmabuf_Caps { return {} }

dmabuf_modifiers :: proc(r: ^Renderer, fourcc: u32, out: []u64) -> int { return 0 }

canvas_import_dmabuf :: proc(r: ^Renderer, buf: Dmabuf) -> Page { return 0 }

canvas_acquire_fence :: proc(r: ^Renderer, page: Page, sync_fd: int) -> bool { return false }

// dmabuf_drop_fence has nothing to close: there are no sync_files here.
dmabuf_drop_fence :: proc(sync_fd: int) {}

canvas_import_idle :: proc(r: ^Renderer, page: Page) -> bool { return true }

@(private)
dmabuf_shutdown :: proc(r: ^Renderer) {}
