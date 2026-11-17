#+build !darwin
package gpu

// The renderer's pure choices: square corners in the vertex kind, and how a
// transparent target presents.

@(require) import "core:testing"
@(require) import vk "vendor:vulkan"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Every rounded shape carries its square corners above the kind's own byte
// (bit 8 top-left … bit 11 bottom-left), where the fragment shader takes
// radius 0; a shape with none keeps its plain kind.
@(test)
square_corners_ride_in_the_vertex_kind :: proc(t: ^testing.T) {
	verts: [dynamic]Vertex
	defer delete(verts)
	emit_quad(&verts, Quad{rect = {0, 0, 40, 20}, color = {1, 1, 1, 1}, radius = 8, square = {.Bottom_Left, .Bottom_Right}})
	testing.expect_value(t, len(verts), 6)
	for v in verts {
		testing.expect_value(t, v.kind & 0xFF, KIND_QUAD)
		testing.expect_value(t, (v.kind >> 8) & 0xF, u32(0b1100)) // bottom-right (bit 2) and bottom-left (bit 3)
	}
	clear(&verts)
	emit_shadow(&verts, Shadow{rect = {0, 0, 40, 20}, radius = 8, blur = 4, color = {0, 0, 0, 0.3}, square = {.Top_Left}})
	testing.expect(t, verts[0].kind == KIND_SHADOW | 1 << 8, "a shadow's square top-left")
	clear(&verts)
	emit_highlight(&verts, Highlight{rect = {0, 0, 40, 20}, radius = 8, color = {1, 1, 1, 0.2}, width = 1, square = {.Top_Right}})
	testing.expect(t, verts[0].kind == KIND_HIGHLIGHT | 2 << 8, "a highlight's square top-right")
	clear(&verts)
	emit_quad(&verts, Quad{rect = {0, 0, 40, 20}, color = {1, 1, 1, 1}, radius = 8})
	testing.expect_value(t, verts[0].kind, KIND_QUAD) // all four rounded: the kind as it always was
}

// How a magnified picture is sampled rides above the colour-space bits. Auto
// is neither bit: the picture arrives with the plain image kind and the
// shader decides by how magnified the fragment is, so one crossover serves
// every picture. The grid is its own bit, clear of the canvas bits.
@(test)
how_a_picture_is_sampled_rides_in_the_vertex_kind :: proc(t: ^testing.T) {
	kind_of :: proc(px: Pixels, grid: bool) -> u32 {
		r: Renderer
		defer { delete(r.verts); delete(r.batches); delete(r.clips) }
		img := Image{rect = {0, 0, 256, 256}, uv = {0, 0, 1, 1}, color = {1, 1, 1, 1}, pixels = px, pixel_grid = grid}
		cmds := []Cmd{img}
		build_batches(&r, cmds, {600, 600})
		return r.verts[0].kind if len(r.verts) > 0 else 0xFFFF_FFFF
	}
	testing.expect_value(t, kind_of(.Auto, false), KIND_IMAGE)
	testing.expect_value(t, kind_of(.Hard, false), KIND_IMAGE | KIND_PIXELATED)
	testing.expect_value(t, kind_of(.Smooth, false), KIND_IMAGE | KIND_SMOOTH)
	testing.expect_value(t, kind_of(.Auto, true), KIND_IMAGE | KIND_PIXEL_GRID)
	testing.expect_value(t, kind_of(.Hard, true), KIND_IMAGE | KIND_PIXELATED | KIND_PIXEL_GRID)
	// clear of the square corners (8-11) and of the canvas bits (13-15)
	testing.expect_value(t, (KIND_PIXELATED | KIND_SMOOTH | KIND_PIXEL_GRID) & 0x0000_EF00, u32(0))
}

// A transparent target presents through its scene into a UNORM swapchain, so
// the present pass writes the very values the compositor reads; an opaque
// target keeps its sRGB swapchain. Where only sRGB formats are offered a
// transparent target takes one too (the present pass then decodes first).
@(test)
transparent_targets_present_into_unorm :: proc(t: ^testing.T) {
	offered := []vk.SurfaceFormatKHR{
		{format = .B8G8R8A8_SRGB, colorSpace = .SRGB_NONLINEAR},
		{format = .B8G8R8A8_UNORM, colorSpace = .SRGB_NONLINEAR},
	}
	testing.expect_value(t, pick_surface_format(offered, true).format, vk.Format.B8G8R8A8_UNORM)
	testing.expect_value(t, pick_surface_format(offered, false).format, vk.Format.B8G8R8A8_SRGB)
	srgb_only := []vk.SurfaceFormatKHR{{format = .R8G8B8A8_SRGB, colorSpace = .SRGB_NONLINEAR}}
	only := pick_surface_format(srgb_only, true).format
	testing.expect_value(t, only, vk.Format.R8G8B8A8_SRGB)
	testing.expect(t, format_is_srgb(only) && !format_is_srgb(.B8G8R8A8_UNORM), "the present pass knows which encodes on write")
	testing.expect_value(t, SCENE_FORMAT, vk.Format.R8G8B8A8_SRGB) // the scene blends in linear light, as a swapchain does
}

// The present pass writes what the compositor's composite alpha reads:
// premultiplied (Wayland's INHERIT is), straight, or opaque.
@(test)
present_mode_follows_composite_alpha :: proc(t: ^testing.T) {
	testing.expect_value(t, present_mode_for({.PRE_MULTIPLIED}), Present_Mode.Premultiplied)
	testing.expect_value(t, present_mode_for({.INHERIT}), Present_Mode.Premultiplied)
	testing.expect_value(t, present_mode_for({.POST_MULTIPLIED}), Present_Mode.Straight)
	testing.expect_value(t, present_mode_for({.OPAQUE}), Present_Mode.Opaque)
	testing.expect_value(t, present_mode_for(choose_composite_alpha({.OPAQUE, .PRE_MULTIPLIED}, true)), Present_Mode.Premultiplied)
}

// A backdrop carries how far its node's transition has faded it out in its
// vertex (border.z), where the shader fades what it draws; the zero value
// is shown whole.
@(test)
backdrop_fade_rides_in_the_vertex :: proc(t: ^testing.T) {
	verts: [dynamic]Vertex
	defer delete(verts)
	emit_backdrop(&verts, Backdrop{rect = {0, 0, 40, 20}, radius = 8, blur = 20, tint = {1, 1, 1, 0.6}, fade = 0.25}, {100, 100})
	testing.expect_value(t, verts[0].border.z, 0.25)
	clear(&verts)
	emit_backdrop(&verts, Backdrop{rect = {0, 0, 40, 20}, radius = 8, blur = 20, tint = {1, 1, 1, 0.6}}, {100, 100})
	testing.expect_value(t, verts[0].border.z, 0) // shown
}

// A shadow carries the rect it leaves clear (the see-through card over it)
// in its vertex's border, where the shader cuts it out; the zero value
// leaves nothing clear.
@(test)
shadow_hole_rides_in_the_vertex :: proc(t: ^testing.T) {
	verts: [dynamic]Vertex
	defer delete(verts)
	emit_shadow(&verts, Shadow{rect = {10, 26, 300, 200}, radius = 16, blur = 40, color = {0, 0, 0, 0.4}, hole = {10, 10, 300, 200}})
	testing.expect_value(t, verts[0].border, [4]f32{10, 10, 300, 200})
	clear(&verts)
	emit_shadow(&verts, Shadow{rect = {10, 26, 300, 200}, radius = 16, blur = 40, color = {0, 0, 0, 0.4}})
	testing.expect_value(t, verts[0].border, [4]f32{})
}

// A shadow's quad reaches three sigmas of its Gaussian past the casting shape
// (sigma = blur / 2, as CSS box-shadow blurs), where it has faded to nothing.
@(test)
shadow_quad_reaches_as_far_as_its_gaussian :: proc(t: ^testing.T) {
	verts: [dynamic]Vertex
	defer delete(verts)
	emit_shadow(&verts, Shadow{rect = {100, 100, 200, 80}, radius = 16, blur = 40, color = {0, 0, 0, 0.4}})
	lo, hi := verts[0].pos, verts[0].pos
	for v in verts {
		lo = {min(lo.x, v.pos.x), min(lo.y, v.pos.y)}
		hi = {max(hi.x, v.pos.x), max(hi.y, v.pos.y)}
	}
	testing.expect_value(t, lo, [2]f32{100 - 61, 100 - 61})
	testing.expect_value(t, hi, [2]f32{300 + 61, 180 + 61})
}

} // when ODIN_TEST
