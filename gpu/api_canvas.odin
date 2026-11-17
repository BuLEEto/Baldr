// api_canvas.odin — the canvas and shader vocabulary, shared by both backends.
//
// These are types an app names — Canvas_Format, Color_Space, Blend_Mode, Dab,
// Stroke_Seg, Filter, Limits — and the pure helpers over them; nothing here
// touches a device. The Vulkan work is in canvas.odin, with `Canvas_Wait`,
// whose fields are one backend's.
package gpu

// Canvas_Format is how a canvas stores a texel: RGBA8 and RGBA16 are an
// image editor's 8- and 16-bit modes, RGBA32F float for HDR. R8 and R16 hold
// one channel — coverage: a selection, a layer mask, a brush stroke, the
// shape of text — which RGBA would spend four channels on (an 8000 × 6000
// mask is 48 MB of VRAM as R8, 192 MB as RGBA8). They have no colour space:
// coverage is not a colour. Read as a texel they are (r, 0, 0, 1).
Canvas_Format :: enum u8 { RGBA8, RGBA16, RGBA32F, R8, R16 }

// canvas_format_single says whether a format holds coverage rather than
// colour: one channel, no space.
canvas_format_single :: proc "contextless" (f: Canvas_Format) -> bool {
	return f == .R8 || f == .R16
}

// Color_Space is what a canvas's values mean: sRGB, Display P3 or Adobe RGB
// (1998) values, encoded by the space's own curve, or Linear light with
// sRGB's primaries.
Color_Space :: enum u8 { sRGB, Display_P3, Adobe_RGB, Linear }

// KIND_CANVAS marks an Image drawn from a canvas (bit 13); bits 14–15 are its
// Color_Space, which the shader decodes.
KIND_CANVAS :: u32(1) << 13

// Limits is what the device offers canvases: the largest side, the device
// memory, the formats it can make canvases in, which of those it filters
// (the others are drawn with the nearest texel), and which a compute
// shader can write (shader.odin).
Limits :: struct {
	max_side:      u32,
	device_memory: u64,
	formats:       bit_set[Canvas_Format],
	filtered:      bit_set[Canvas_Format],
	storage:       bit_set[Canvas_Format],
}

// Canvas_Read_Done is one finished read: its id (from canvas_read) and the
// texels, rows tightly packed, in the caller's allocator.
Canvas_Read_Done :: struct {
	id:     u32,
	pixels: []u8,
	ok:     bool,
}


@(private)
Canvas_Op_Kind :: enum u8 { Clear, Write, Fill, Copy, Read, Blend, Transform, Filter, Dabs, Strokes, Shader }

@(private)
Canvas_Op :: struct {
	kind:        Canvas_Op_Kind,
	page, src:   Page,
	x, y, w, h:  u32,
	sx, sy:      u32,    // Copy, Blend, Transform: where in `src`
	sw, sh:      u32,    // Transform: how much of `src` (its own rectangle)
	inv:         [9]f32, // Transform: destination texel → source texel, column by column
	kernel:      u32,    // Transform: 0 nearest, 1 bilinear, 2 bicubic, 3 Lanczos3
	value:       [4]f32, // Fill
	staging:     Buffer, // Write; Strokes: the quads, shared across a call's runs
	first:       int,    // Strokes: this run's first segment in that buffer
	own:         bool,   // Strokes: this op is the one that frees the shared buffer
	id:          u32,    // Read
	mask:        Page,   // Blend: 0 for none; its texels line up with the source's
	mode:        Blend_Mode,
	opacity:     f32,
	linear:      bool,
	seed:        u32,
	filter:      Filter, // Filter
	solid:       bool,   // Blend: the source is `value`, a colour (canvas_paint)
	erase:       bool,   // Blend: the source's alpha takes the destination's away
	count:       int,    // Dabs: how many (their quads are in `staging`); Shader: how many inputs
	tip:         Page,   // Dabs: the brush's tip, 0 for round
	shader:      Shader, // Shader (shader.odin)
	inputs:      [SHADER_INPUTS]Page,
	uniforms:    [SHADER_UNIFORMS]u8,
}

// Dab is one stamp of a brush: its centre in texels, its radius, how hard
// its edge is (1 hard, 0 soft all the way from the centre), its strength
// (flow × pressure) and, for a tip texture, its turn in radians.
Dab :: struct {
	centre:   [2]f32,
	radius:   f32,
	hardness: f32,
	strength: f32,
	angle:    f32,
}

// Dab_Vertex is one corner of a dab's quad (dab.vert's input).
@(private)
Dab_Vertex :: struct {
	pos, centre: [2]f32,
	dab:         [4]f32, // radius, hardness, strength, angle
}

@(private)
Dab_Push :: struct {
	size: [2]f32,
	tip:  u32,
	_:    u32,
}

DAB_VERT_SPV := #load("shaders/dab.vert.spv", []u32)
DAB_FRAG_SPV := #load("shaders/dab.frag.spv", []u32)

// Stroke_Seg is one segment of a variable-width stroke: where it runs, and
// its radius at each end, in texels. A stroke is a run of these.
Stroke_Seg :: struct {
	a, b:   [2]f32,
	ra, rb: f32,
}

@(private)
Stroke_Vertex :: struct {
	pos:   [2]f32, // this corner of the segment's quad
	seg:   [4]f32, // a.xy, b.xy
	radii: [2]f32,
}

@(private)
Stroke_Push :: struct {
	size: [2]f32,
}

STROKE_VERT_SPV := #load("shaders/stroke.vert.spv", []u32)
STROKE_FRAG_SPV := #load("shaders/stroke.frag.spv", []u32)

// Filter_Kind is what canvas_filter does: a colour matrix, per-channel
// curves, a conversion between colour spaces, an app's 3D LUT, a Gaussian
// blur, or an unsharp mask.
Filter_Kind :: enum u8 { Matrix, Curves, Convert, Lut, Blur, Sharpen }

// Filter is one filter and its settings. `colors` (Matrix): each output
// channel as a row over the input's r, g, b, a and 1. `table` (Curves, Lut):
// a canvas holding the curve (n × 1 texels, n ≥ 2, each channel's output at
// n even steps of its input) or the LUT (n² × n texels: red across a slice,
// green down it, blue from slice to slice; RGBA32F for precision). `sigma`
// (Blur, Sharpen): the Gaussian's in texels. `amount`, `threshold`
// (Sharpen): how far the original is pushed from its blur, and the least
// difference that is. `linear`: in light rather than on stored values.
Filter :: struct {
	kind:      Filter_Kind,
	colors:    [4][5]f32,
	table:     Page,
	sigma:     f32,
	amount:    f32,
	threshold: f32,
	linear:    bool,
}

// Filter_Push is filter.frag's push constant.
@(private)
Filter_Push :: struct {
	in_off, in_max, aux_off: [2]i32,
	kind, flags:             u32,
	a, b, c:                 f32,
	_:                       u32,
	m:                       [4][4]f32,
	moff:                    [4]f32,
}
#assert(size_of(Filter_Push) == 128)

FILTER_FRAG_SPV := #load("shaders/filter.frag.spv", []u32)

// Blend_Mode is how a source's colour meets what it is laid over: the 27
// modes of Photoshop's layer menu, in its order. Their formulas are in
// shaders/blend.frag, and in baldr's CPU reference.
Blend_Mode :: enum u8 {
	Normal, Dissolve,
	Darken, Multiply, Color_Burn, Linear_Burn, Darker_Color,
	Lighten, Screen, Color_Dodge, Linear_Dodge, Lighter_Color,
	Overlay, Soft_Light, Hard_Light, Vivid_Light, Linear_Light, Pin_Light, Hard_Mix,
	Difference, Exclusion, Subtract, Divide,
	Hue, Saturation, Color, Luminosity,
}

// --- an app's own shader. The Vulkan implementation is in shader.odin, the
// Metal one in metal_shader.odin.

// Shader names an app's shader. 0 is none.
Shader :: distinct u32

// Shader_Stage is which kind of shader: drawn over a rectangle, or
// dispatched over it.
Shader_Stage :: enum u8 { Fragment, Compute }

// Shader_Code is one shader for each backend: SPIR-V for Vulkan, MSL for
// Metal. An app gives both and the backend in use takes the one it can
// compile; a build-time tool makes the pair from one source, so nothing
// extra ships inside apps. Giving only the one the running backend cannot
// use fails at shader_create, which says so.
//
// `entry` is the MSL entry point's name. MSL reserves `main`, so a shader
// translated by spirv-cross calls its entry `main0`, which is what an empty
// `entry` means. SPIR-V carries its own entry name and ignores this.
Shader_Code :: struct {
	spirv: []u32,
	msl:   string,
	entry: string,
}

// SHADER_UNIFORMS is how many bytes of uniforms an app's shader takes.
SHADER_UNIFORMS :: 112

// SHADER_INPUTS is how many canvases a shader reads.
SHADER_INPUTS :: 6

// canvas_bpp is bytes per texel of a canvas format.
canvas_bpp :: proc "contextless" (f: Canvas_Format) -> int {
	switch f {
	case .RGBA8:   return 4
	case .RGBA16:  return 8
	case .RGBA32F: return 16
	case .R8:      return 1
	case .R16:     return 2
	}
	return 4
}

// space_matrix takes linear light with `from`'s primaries to `to`'s (D65
// throughout; Linear has sRGB's), from the spaces' primaries.
space_matrix :: proc(from, to: Color_Space) -> (m: [3][3]f32) {
	primaries :: proc(s: Color_Space) -> [3][2]f64 {
		switch s {
		case .Display_P3: return {{0.680, 0.320}, {0.265, 0.690}, {0.150, 0.060}}
		case .Adobe_RGB:  return {{0.64, 0.33}, {0.21, 0.71}, {0.15, 0.06}}
		case .sRGB, .Linear:
		}
		return {{0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}}
	}
	to_xyz :: proc(p: [3][2]f64) -> (out: [3][3]f64) {
		white := [3]f64{0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290}
		cols: [3][3]f64
		for i in 0 ..< 3 do cols[i] = {p[i][0] / p[i][1], 1, (1 - p[i][0] - p[i][1]) / p[i][1]}
		prim := [3][3]f64{{cols[0][0], cols[1][0], cols[2][0]}, {cols[0][1], cols[1][1], cols[2][1]}, {cols[0][2], cols[1][2], cols[2][2]}}
		inv := mat3_inverse(prim)
		sc := [3]f64{}
		for i in 0 ..< 3 do sc[i] = inv[i][0] * white[0] + inv[i][1] * white[1] + inv[i][2] * white[2]
		for rr in 0 ..< 3 do for c in 0 ..< 3 do out[rr][c] = prim[rr][c] * sc[c]
		return
	}
	a := to_xyz(primaries(from))
	b := mat3_inverse(to_xyz(primaries(to)))
	for rr in 0 ..< 3 do for c in 0 ..< 3 {
		v: f64
		for k in 0 ..< 3 do v += b[rr][k] * a[k][c]
		m[rr][c] = f32(v)
	}
	return
}

@(private)
mat3_inverse :: proc "contextless" (a: [3][3]f64) -> (out: [3][3]f64) {
	det := a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
	if det == 0 do return
	k := 1 / det
	out[0] = {(a[1][1] * a[2][2] - a[1][2] * a[2][1]) * k, (a[0][2] * a[2][1] - a[0][1] * a[2][2]) * k, (a[0][1] * a[1][2] - a[0][2] * a[1][1]) * k}
	out[1] = {(a[1][2] * a[2][0] - a[1][0] * a[2][2]) * k, (a[0][0] * a[2][2] - a[0][2] * a[2][0]) * k, (a[0][2] * a[1][0] - a[0][0] * a[1][2]) * k}
	out[2] = {(a[1][0] * a[2][1] - a[1][1] * a[2][0]) * k, (a[0][1] * a[2][0] - a[0][0] * a[2][1]) * k, (a[0][0] * a[1][1] - a[0][1] * a[1][0]) * k}
	return
}
