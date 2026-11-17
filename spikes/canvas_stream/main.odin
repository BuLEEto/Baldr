package main

// A whole frame written to a canvas every frame, which is what
// a video player does while the frames come back through the processor.
//
// Two ways, chosen with CANVAS_STREAM=copy|direct:
//   copy    baldr.canvas_write of the app's own buffer — one copy into the
//           app's memory (standing in for a decoder's output) and another
//           into the GPU's.
//   direct  baldr.canvas_write_begin / _end — the app fills the GPU's bytes
//           where they are, so the frame is copied once.
//
// Both report the milliseconds the write itself took, best and mean, and
// BALDR_DEBUG_CANVAS=1 says whether the staging buffers were reused: the
// first frame should create one the size of the frame and the rest reuse it.
//
//   BALDR_FAST=1 ./build.sh spike canvas_stream run        # 1080p, copying
//   CANVAS_STREAM=direct BALDR_DEBUG_CANVAS=1 BALDR_FAST=1 ./build.sh spike canvas_stream run
//   CANVAS_STREAM_SIDE=4k ./build.sh spike canvas_stream run   # 3840 × 2160

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import "baldr:baldr"

FRAMES :: 120 // enough to settle, few enough to watch

State :: struct {
	g:        baldr.Gpu,
	c:        baldr.Canvas,
	size:     [2]int,
	own:      []u8, // the app's own frame, as a decoder would hand it over
	direct:   bool,
	frame:    int,
	ms:       [FRAMES]f64,
	ready:    bool,
	said:     bool,
}

Msg :: union { baldr.Gpu, Tick }

Tick :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Gpu:
		s.g = v
		lim := baldr.gpu_limits(v)
		ok: bool
		s.c, ok = baldr.canvas_create(v, s.size)
		fmt.eprintfln("canvas_stream: %dx%d on_gpu=%v canvas=%v  %s", s.size.x, s.size.y, lim.on_gpu, ok,
			"write_begin/_end" if s.direct else "canvas_write")
		if !ok do return baldr.quit(Msg)
		s.own = make([]u8, s.size.x * s.size.y * 4)
		s.ready = true
		return baldr.delay(Msg, 0, Tick{})
	case Tick:
		if !s.ready do return {}
		if s.frame >= FRAMES {
			if !s.said {
				s.said = true
				ms := s.ms[:]
				slice.sort(ms)
				total: f64
				for v in ms do total += v
				fmt.eprintfln("canvas_stream: %d frames of %d x %d: write best %.2f ms, median %.2f, mean %.2f, worst %.2f",
					FRAMES, s.size.x, s.size.y, ms[0], ms[FRAMES / 2], total / FRAMES, ms[FRAMES - 1])
			}
			return baldr.quit(Msg)
		}
		shade := u8(s.frame * 2)
		t0 := time.tick_now()
		if s.direct {
			// The frame is made where the GPU will read it: one pass over the
			// bytes, no buffer of the app's own at all.
			if px, open := baldr.canvas_write_begin(s.g, s.c, 0, 0, s.size.x, s.size.y); open {
				stream_fill(px, s.size, shade)
				baldr.canvas_write_end(s.g, s.c)
			}
		} else {
			stream_fill(s.own, s.size, shade)
			baldr.canvas_write(s.g, s.c, 0, 0, s.size.x, s.size.y, s.own)
		}
		s.ms[s.frame] = time.duration_milliseconds(time.tick_since(t0))
		s.frame += 1
		return baldr.delay(Msg, 0, Tick{})
	}
	return {}
}

// stream_fill is the decode: a moving gradient, so every texel of every
// frame is written and the work cannot be optimised away.
stream_fill :: proc(px: []u8, size: [2]int, shade: u8) {
	for y in 0 ..< size.y {
		row := px[y * size.x * 4:]
		for x in 0 ..< size.x {
			p := row[x * 4:]
			p[0], p[1], p[2], p[3] = u8(x & 0xFF), u8(y & 0xFF), shade, 255
		}
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .md, gap = .sm); defer baldr.end(ui)
	baldr.text(ui, fmt.tprintf("frame %d of %d", s.frame, FRAMES), role = .Caption)
	if s.ready do baldr.canvas(ui, s.g, s.c, width = 480, label = "the stream")
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Canvas stream", app_id = "dev.baldr.canvas_stream", size = {520, 400},
		init = proc() -> (s: State) {
			s.size = {1920, 1080}
			if os.get_env("CANVAS_STREAM_SIDE", context.temp_allocator) == "4k" do s.size = {3840, 2160}
			s.direct = os.get_env("CANVAS_STREAM", context.temp_allocator) == "direct"
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return e.value }) },
		update = update,
		view = view,
	})
}
