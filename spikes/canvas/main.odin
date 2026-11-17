package main

// Canvases on the GPU. Five canvases, one per format
// and colour space, filled, written and copied across formats; reads come
// back and are logged next to what the CPU reference says they must be;
// the capture's colours show the display transform.
//   A RGBA8   sRGB       a written gradient, a red square copied from it into B
//   B RGBA16  Linear     0.5 grey (shows as sRGB 188), with A's square copied in
//   C RGBA32F Linear     2.0 red (HDR: clipped to 255, 0, 0 on an sRGB screen)
//   D RGBA8   Display P3 0.5 grey (shows as 128: P3 shares sRGB's curve and white)
//   E RGBA8   Adobe RGB  0.5 grey (shows as 129: its curve is a 2.2 power)

import "core:fmt"
import "baldr:baldr"

W :: 160
H :: 100

State :: struct {
	g:       baldr.Gpu,
	c:       [5]baldr.Canvas,
	ready:   bool,
}

Msg :: union { baldr.Gpu, baldr.Canvas_Read }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Gpu:
		s.g = v
		lim := baldr.gpu_limits(v)
		fmt.eprintfln("canvas: gpu on_gpu=%v max_side=%d memory=%d MB formats=%v filtered=%v", lim.on_gpu, lim.max_side, lim.device_memory >> 20, lim.formats, lim.filtered)
		kinds := [5]struct { f: baldr.Canvas_Format, sp: baldr.Color_Space }{{.RGBA8, .sRGB}, {.RGBA16, .Linear}, {.RGBA32F, .Linear}, {.RGBA8, .Display_P3}, {.RGBA8, .Adobe_RGB}}
		for k, i in kinds {
			ok: bool
			s.c[i], ok = baldr.canvas_create(v, {W, H}, k.f, k.sp)
			fmt.eprintfln("canvas: %c %v %v made=%v", 'A' + rune(i), k.f, k.sp, ok)
		}
		px := make([]u8, W * H * 4, context.temp_allocator)
		for y in 0 ..< H do for x in 0 ..< W {
			p := px[(y * W + x) * 4:]
			p[0], p[1], p[2], p[3] = u8(x * 255 / (W - 1)), u8(y * 255 / (H - 1)), 96, 255
		}
		baldr.canvas_write(v, s.c[0], 0, 0, W, H, px)
		baldr.canvas_fill(v, s.c[0], 20, 20, 30, 30, {1, 128.0 / 255, 0, 1})
		baldr.canvas_fill(v, s.c[1], 0, 0, W, H, {0.5, 0.5, 0.5, 1})
		baldr.canvas_copy(v, s.c[0], 20, 20, 30, 30, s.c[1], {100, 50}) // 8 bits into 16
		baldr.canvas_fill(v, s.c[2], 0, 0, W, H, {2, 0, 0, 1})
		baldr.canvas_fill(v, s.c[3], 0, 0, W, H, {0.5, 0.5, 0.5, 1})
		baldr.canvas_fill(v, s.c[4], 0, 0, W, H, {0.5, 0.5, 0.5, 1})
		s.ready = true
		on_read :: proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return e.value }
		return baldr.batch(Msg,
			baldr.canvas_read(Msg, v, s.c[1], 100, 50, 1, 1, on_read, tag = 1),
			baldr.canvas_read(Msg, v, s.c[2], 0, 0, 1, 1, on_read, tag = 2),
			baldr.canvas_read(Msg, v, s.c[0], 159, 99, 1, 1, on_read, tag = 3),
		)
	case baldr.Canvas_Read:
		fmt.eprintfln("canvas: read ok=%v %v %dx%d bytes=%v", v.ok, v.format, v.w, v.h, v.pixels)
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, padding = .md, gap = .md, align = .Start); defer baldr.end(ui)
	if !s.ready do return
	names := [5]string{"A sRGB 8", "B linear 16", "C linear float", "D P3 8", "E Adobe 8"}
	for c, i in s.c {
		baldr.column(ui, gap = .xs, key = u64(i + 1)); defer baldr.end(ui)
		baldr.text(ui, names[i], role = .Caption)
		baldr.canvas(ui, s.g, c, width = W, label = names[i])
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Canvas", app_id = "dev.baldr.canvas", size = {5 * (W + 16) + 32, H + 80},
		init = proc() -> (s: State) { return },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return e.value }) },
		update = update,
		view = view,
	})
}
