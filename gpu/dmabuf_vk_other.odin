#+build windows
// dmabuf_vk_other.odin — the hooks render.odin and device.odin call, for a
// Vulkan platform that is not Linux. Importing a GPU buffer from another
// process is a Linux mechanism (dmabuf descriptors, DRM format modifiers,
// sync_files); the public calls refuse in dmabuf_other.odin, and these are
// the internal ones the frame path reaches for either way.
//
// The build tag is a platform list rather than "not Linux" because the Metal
// backend has no Frame or Vulkan types for these to mention. A new Vulkan
// platform will fail to compile here, which is the right way to find out.
package gpu

import vk "vendor:vulkan"

@(private)
dmabuf_extensions :: proc(r: ^Renderer, exts: ^[dynamic]cstring) {}

@(private)
dmabuf_node :: proc(r: ^Renderer) {}

@(private)
dmabuf_frame_begin :: proc(r: ^Renderer, cb: vk.CommandBuffer, t: Target, slot: u32, serial: u64) {}

@(private)
dmabuf_frame_end :: proc(r: ^Renderer, cb: vk.CommandBuffer, t: Target, slot: u32, serial: u64) {}

@(private)
dmabuf_waits :: proc(r: ^Renderer, frame: ^Frame) -> []vk.Semaphore { return nil }

@(private)
dmabuf_frame_done :: proc(r: ^Renderer, frame: ^Frame) {}
