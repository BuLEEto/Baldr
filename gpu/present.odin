#+build !darwin
package gpu

// Transparent targets. A compositor takes a surface's pixels as sRGB values
// premultiplied by alpha, while Baldr draws and blends in linear light.
// Premultiplied in linear light and encoded after, a light translucent pixel
// keeps more colour than alpha (0.98 at alpha 0.62 is stored as 0.80) and
// clamps to white over a bright desktop. So a transparent target draws its
// scene into an sRGB image of its own, and the present pass writes each pixel
// as the compositor reads it: encoded, then multiplied by alpha (present.frag).

import vk "vendor:vulkan"

// SCENE_FORMAT is a transparent target's scene: linear light stored as sRGB,
// like an opaque target's swapchain.
@(private) SCENE_FORMAT :: vk.Format.R8G8B8A8_SRGB

// Present_Mode is how the compositor reads the swapchain's pixels, from its
// composite alpha; the values are present.frag's.
@(private)
Present_Mode :: enum u32 {
	Premultiplied, // PRE_MULTIPLIED, or INHERIT (Wayland's buffers are premultiplied)
	Straight,      // POST_MULTIPLIED
	Opaque,        // alpha ignored: the scene as an opaque target shows it
}

@(private)
Present_Push :: struct {
	mode:        Present_Mode,
	srgb_target: u32, // the swapchain encodes on write: present.frag decodes first
}

@(private)
present_mode_for :: proc "contextless" (composite: vk.CompositeAlphaFlagsKHR) -> Present_Mode {
	if .PRE_MULTIPLIED in composite || .INHERIT in composite { return .Premultiplied }
	if .POST_MULTIPLIED in composite { return .Straight }
	return .Opaque
}

@(private)
format_is_srgb :: proc "contextless" (f: vk.Format) -> bool {
	#partial switch f {
	case .B8G8R8A8_SRGB, .R8G8B8A8_SRGB, .A8B8G8R8_SRGB_PACK32, .B8G8R8_SRGB, .R8G8B8_SRGB:
		return true
	}
	return false
}

// render_image and render_view are what a frame draws into: a transparent
// target's scene, else the swapchain image.
@(private)
render_image :: proc(ts: ^Target_State, img: u32) -> vk.Image {
	return ts.scene.image if ts.transparent else ts.images[img]
}

@(private)
render_view :: proc(ts: ^Target_State, img: u32) -> vk.ImageView {
	return ts.scene.view if ts.transparent else ts.views[img]
}

// scene_ensure builds a transparent target's scene for its extent, or
// rebuilds it after a resize (waiting for the frames using the old one).
@(private)
scene_ensure :: proc(r: ^Renderer, ts: ^Target_State) -> bool {
	if ts.scene.image != 0 && ts.scene.size == ts.extent { return true }
	if ts.scene.image != 0 {
		vk.DeviceWaitIdle(r.device)
		sampled_image_destroy(r, &ts.scene)
	}
	if !sampled_image_create(r, &ts.scene, ts.extent, SCENE_FORMAT, {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC}) {
		sampled_image_destroy(r, &ts.scene)
		return false
	}
	return true
}

// present_pipeline_for is the present pass's pipeline for a swapchain
// format, made on first use.
@(private)
present_pipeline_for :: proc(r: ^Renderer, format: vk.Format) -> (vk.Pipeline, bool) {
	for e in r.present_pipelines {
		if e.format == format { return e.pipeline, true }
	}
	if r.present_layout == 0 {
		layout, ok := push_layout_create(r, size_of(Present_Push))
		if !ok { return 0, false }
		r.present_layout = layout
	}
	p, ok := fullscreen_pipeline_create(r, PRESENT_FRAG_SPV, r.present_layout, format)
	if !ok { return 0, false }
	append(&r.present_pipelines, Pipeline_Entry{format, p})
	return p, true
}

// present_pass writes a transparent target's scene to swapchain image `img`
// as the compositor reads it. Rendering on the scene has ended; the
// swapchain image is left a colour attachment, ready to present.
@(private)
present_pass :: proc(r: ^Renderer, ts: ^Target_State, cb: vk.CommandBuffer, img: u32) {
	image_barrier(cb, ts.scene.image,
		.COLOR_ATTACHMENT_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}, {.SHADER_READ})
	image_barrier(cb, ts.images[img], // at the stage the acquire gates, not before it (render.odin)
		.UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_OUTPUT}, {}, {.COLOR_ATTACHMENT_WRITE})
	attach := vk.RenderingAttachmentInfo{
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = ts.views[img],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .DONT_CARE,
		storeOp     = .STORE,
	}
	ri := vk.RenderingInfo{
		sType                = .RENDERING_INFO,
		renderArea           = {extent = ts.extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &attach,
	}
	begin_rendering(r, cb, &ri)
	vp := vk.Viewport{width = f32(ts.extent.width), height = f32(ts.extent.height), minDepth = 0, maxDepth = 1}
	sc := vk.Rect2D{extent = ts.extent}
	vk.CmdSetViewport(cb, 0, 1, &vp)
	vk.CmdSetScissor(cb, 0, 1, &sc)
	vk.CmdBindPipeline(cb, .GRAPHICS, ts.present_pipeline)
	set := ts.scene.set
	vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.present_layout, 0, 1, &set, 0, nil)
	pc := Present_Push{mode = ts.present, srgb_target = 1 if format_is_srgb(ts.format.format) else 0}
	vk.CmdPushConstants(cb, r.present_layout, {.FRAGMENT}, 0, size_of(pc), &pc)
	vk.CmdDraw(cb, 3, 1, 0, 0)
	end_rendering(r, cb)
}
