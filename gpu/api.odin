// Package gpu is Baldr's renderer. It consumes device-pixel draw commands
// (quads with rounded corners and borders, glyphs from atlas pages, clip
// rects) and presents them to one or more surfaces through Vulkan. Nothing
// above this package knows Vulkan; nothing here knows widgets.
//
// Contract implemented in renderer.odin (signatures are the API):
//
//   init          :: proc(r: ^Renderer, instance_exts: []cstring, app_name: cstring) -> (ok: bool, why: string)
//                    dlopen the Vulkan loader (libvulkan.so.1 / vulkan-1.dll / libvulkan.dylib),
//                    create the instance (+ validation layer and debug utils when present),
//                    load global + instance procs into vendor:vulkan.
//   destroy       :: proc(r: ^Renderer)
//   instance      :: proc(r: ^Renderer) -> vk.Instance
//   target_add    :: proc(r: ^Renderer, surface: vk.SurfaceKHR, size_px: [2]u32, transparent: bool) -> (Target, bool)
//                    the first target picks the device (graphics+present on that surface),
//                    creates queue, pipelines, atlas sampler; every target owns a swapchain.
//   target_resize :: proc(r: ^Renderer, t: Target, size_px: [2]u32)
//   target_remove :: proc(r: ^Renderer, t: Target)
//   render        :: proc(r: ^Renderer, t: Target, cmds: []Cmd, clear: [4]f32, damage: [][4]f32) -> Render_Result
//                    records, submits, presents one frame. `damage` (px) may be empty = whole surface;
//                    used for VK_KHR_incremental_present when available.
//   atlas_create  :: proc(r: ^Renderer, format: Page_Format, size: [2]u32) -> Page
//   picture_create :: proc(r: ^Renderer, size: [2]u32) -> Page
//                    one picture's RGBA8 page with a mip chain, rebuilt on the GPU after each upload
//                    and sampled trilinearly (0 when the device can't make it)
//   atlas_upload  :: proc(r: ^Renderer, page: Page, x, y, w, h: u32, pixels: []u8)   // staged; lands before the next render
//   atlas_destroy :: proc(r: ^Renderer, page: Page)
//   canvas_create / canvas_write / canvas_fill / canvas_copy / canvas_read,
//   canvas_flush, canvas_waiter / canvas_wait / canvas_reads_take, limits
//                    canvases an app draws into and shows (canvas.odin): an Image
//                    whose page is a canvas is drawn through its colour space
//
// Coordinates: device pixels, origin top-left, y down. Colors: linear RGBA,
// straight alpha, blended in linear light into sRGB storage (an opaque
// target's swapchain; a transparent target's scene, which the present pass
// converts to the premultiplied sRGB a compositor reads).
//
// Implementation notes (see the doc comment on each proc for details):
//   - Files: renderer.odin (init/destroy/instance), device.odin (device pick,
//     pipeline), target.odin (swapchains), atlas.odin (pages), render.odin.
//   - The device is created by the first target_add, so atlas_create needs a
//     target first (returns 0 before that). target_add takes ownership of the
//     VkSurfaceKHR only when it succeeds; target_remove / destroy destroy it,
//     and a drawable it refused stays the caller's — to try again with, or to
//     let go of through drawable_release.
//   - Page 1 (WHITE_PAGE) is a built-in 1×1 white Alpha8 page. A Glyph whose
//     page is 0 or otherwise invalid is drawn with it (a tinted solid quad),
//     never a crash.
//   - render clears with `clear` exactly as given (alpha included): a
//     transparent target (composite alpha PRE_MULTIPLIED / INHERIT) shows the
//     desktop through clear + draw alpha; pass {0,0,0,0} for see-through.
//   - `damage` is only a compositor hint (VK_KHR_incremental_present); every
//     frame redraws the whole surface.
//   - Renderer.validation_errors counts ERROR messages from the validation
//     layer when it is installed; Renderer.last_error holds the last failure.
package gpu

// Cmd is one draw command in device pixels. Order is z-order.
Cmd :: union {
	Quad,
	Line,
	Glyph,
	Image,
	Shadow,
	Backdrop,
	Glow,
	Highlight,
	Clip_Push,
	Clip_Pop,
}

// Drawable is the thing a target draws into, as the platform backend handed
// it over: a `VkSurfaceKHR` on Vulkan, a `CAMetalLayer` on macOS. An opaque
// word so `target_add` has one signature on every backend; the backend that
// owns it casts.
Drawable :: distinct uintptr

// Target_Fault says why the last `target_add` gave no target, for a caller
// deciding whether that drawable is worth another try. Only `.Slots` clears
// itself (another window or popup closing frees one); the rest belong to the
// drawable or the device, so a retry fails the same way; that window can
// never be drawn, and the answer is to say so and stop rather than run on
// invisibly.
// `target_fault` reads it; `Renderer.last_error` says it in words.
Target_Fault :: enum u8 {
	None,     // the last target_add succeeded
	Slots,    // MAX_TARGETS are in use
	Drawable, // nothing was handed over, or the renderer has no instance yet
	Device,   // no device could be created for it
	Surface,  // the device cannot present to it, or it is already lost
	Objects,  // its swapchain, pipelines or per-frame objects could not be made
}

// Scissor is a batch's clip in device pixels, in no backend's type, so the
// shared half of the renderer (command list in, vertices and batches out)
// serves Vulkan and Metal alike; each backend converts where it binds.
Scissor :: struct {
	x, y: i32,
	w, h: u32,
}

// Corner names a corner of a rounded shape; Corners are the ones a shape
// keeps square (a bar's corners at the screen edge), its other corners
// taking its radius. The zero value rounds all four.
Corner :: enum u8 { Top_Left, Top_Right, Bottom_Right, Bottom_Left }
Corners :: bit_set[Corner; u8]

// Image: a textured rectangle with rounded corners: the atlas region `uv`
// of `page` (RGBA), tinted by `color` (alpha fades it), corners cut by an
// SDF of `radius` like a Quad.
Image :: struct {
	rect:   [4]f32,
	uv:     [4]f32,
	page:   Page,
	radius: f32,
	square: Corners, // corners left square
	color:  [4]f32,
	pixels:     Pixels, // how it is sampled where it is magnified
	pixel_grid: bool,   // a line between texels, once zoomed far enough in
}

// Pixels is how a magnified picture is sampled.
//
// `Auto` (the zero value) blends from smooth to hard as it is magnified:
// linear up to 2 device pixels a texel, nearest from 4, mixed between. An
// icon or a photograph at its own size stays smooth, and a zoomed-in viewer
// stops going soft without choosing its own crossover. `Smooth` and `Hard`
// force one or the other: a checkerboard behind a transparent picture wants
// Hard whatever the zoom.
Pixels :: enum u8 { Auto, Smooth, Hard }

// Quad: an axis-aligned rectangle with optional rounded corners and border,
// anti-aliased in the shader (signed-distance edge).
Quad :: struct {
	rect:     [4]f32, // x, y, w, h
	color:    [4]f32,
	color2:   [4]f32, // if non-zero: far-edge colour of a gradient (color is the top, or the left when horizontal); may be transparent for a fade
	radius:   f32,
	square:   Corners, // corners left square
	border_w: f32,
	border:   [4]f32,
	horizontal: bool, // gradient runs left → right instead of top → bottom
}

// Shadow: a soft drop shadow of a rounded rect — `rect` is the casting shape
// already offset, `blur` its blur radius in px as CSS box-shadow means it: a
// Gaussian of blur / 2, half strength at the shape's edge, gone 1.5 × blur
// out. Drawn before the shape that casts it.
Shadow :: struct {
	rect:   [4]f32,
	radius: f32,
	square: Corners,
	blur:   f32,
	color:  [4]f32,
	hole:   [4]f32, // a rect it leaves clear, rounded like it: the see-through card it sits under (zero: none)
}

// Glyph: a textured quad sampling an atlas page. Alpha8 pages are tinted by
// `color` (out = color.rgb, color.a * tex.r); RGBA8 pages (colour emoji,
// icons) are modulated by `color.a` only (out = tex.rgb, tex.a * color.a).
// `page` 0 or an unknown page draws with the built-in white page.
Glyph :: struct {
	rect:  [4]f32,
	uv:    [4]f32, // u0, v0, u1, v1 normalised
	page:  Page,
	color: [4]f32,
	angle: f32,    // radians, clockwise on screen, turned about `pivot` (device px): a rotated label; 0 is upright
	pivot: [2]f32,
}

// Backdrop: frosted glass. Blurs everything drawn so far behind `rect`
// (corners rounded by `radius`), adjusts saturation (1 = unchanged), mixes in
// `tint` by its alpha, adds `noise` (0..1) grain, and draws the result;
// commands after it compose on top. `blur` is the radius in px. Requires the
// swapchain to be readable (TRANSFER_SRC); when it is not, the quad shows the
// tint over a neutral base so text stays legible. On a transparent target
// the tint keeps the alpha of what it covers: over nothing it is the tint
// alone, and the compositor's blur of the desktop shows through.
Backdrop :: struct {
	rect:       [4]f32,
	radius:     f32,
	square:     Corners,
	blur:       f32,
	tint:       [4]f32,
	saturation: f32,
	noise:      f32,
	fade:       f32, // how far its node's transition has faded it out, 0..1 (0: shown): what it draws fades alike
}

// Glow: a soft halo behind a glyph (the same `rect`, `uv` and `page`): its
// coverage blurred like a Gaussian of sigma radius / 2, in `color`. Draw
// every glow of a run of text before its glyphs.
Glow :: struct {
	rect:   [4]f32,
	uv:     [4]f32,
	page:   Page,
	color:  [4]f32,
	radius: f32,
	angle:  f32, // turned with its glyph (Glyph.angle)
	pivot:  [2]f32,
}

// Highlight: a `width` px line of `color` along the top edge of a rounded
// rect, thinning out around its corners (glass's bright rim).
Highlight :: struct {
	rect:   [4]f32,
	radius: f32,
	square: Corners,
	color:  [4]f32,
	width:  f32,
}

// Line is a straight segment of `width` px between two points, with round
// ends (so a polyline drawn as segments joins itself without any geometry for
// the joins) or flat ones. It is the only primitive that is not axis-aligned:
// everything else the toolkit draws is a rectangle of some kind, and a chart's
// series is the thing that is not.
Line :: struct {
	a, b:  [2]f32,
	width: f32,
	color: [4]f32,
	flat:  bool, // flat ends instead of round
}

// Clip_Push intersects the current clip with `rect`; Clip_Pop restores.
// Clips become scissor rects rounded outward to whole pixels; commands under
// an empty clip are dropped. Unbalanced pops are ignored; the stack resets
// every render.
Clip_Push :: struct { rect: [4]f32 }
Clip_Pop  :: struct {}

// Page is an atlas texture handle. 0 = none. 1 is always the built-in 1×1
// white Alpha8 page (WHITE_PAGE); atlas_create returns 2 and up.
Page :: distinct u32

// Two page ids every backend reserves, because batch.odin names both:
// WHITE_PAGE is the 1x1 opaque page a quad samples and the fallback for a
// page that has gone, and BLUR_PAGE marks the batch break where the scene so
// far is blurred into the target.
WHITE_PAGE :: Page(1)
BLUR_PAGE  :: Page(0xFFFF_FFFF)

Page_Format :: enum u8 { Alpha8, RGBA8 }

// Target is a presentable surface (window) with its own swapchain. 0 = none.
Target :: distinct u32

Render_Result :: enum u8 {
	OK,
	Skipped,     // zero-size target or nothing to do
	Recreated,   // swapchain was out of date and has been recreated; frame drawn
	Lost,        // surface lost; caller should remove the target
	Error,
}

// MAX_TARGETS is how many surfaces can have a swapchain at once. 64 covers
// a shell's twelve bars on six screens, a popup or two each, plus tooltips,
// a drag's ghost and notifications. An unused slot costs only this struct
// (the per-image arrays are allocated when a target is made), so the ceiling
// is static memory, not video memory.
MAX_TARGETS :: 64
