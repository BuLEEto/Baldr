package main

// A Task Manager's sidebar (each resource a 64 × 28 sparkline beside its
// name and value, the last 60 samples at 4 Hz, one still filling from the
// right) and a big area chart pinned to 0–100 %, whose tick labels must
// draw as text rather than boxes.

import "core:fmt"
import "core:math"
import "baldr:baldr"

SPAN :: 60

Res :: struct {
	name, unit: string,
	hist:       [dynamic]f32,
	pinned:     bool,
	color:      string,
}

State :: struct {
	tick: int,
	res:  [4]Res,
}

Msg :: enum { Tick }

sample :: proc(i, t: int) -> f32 {
	x := f32(t) * 0.15
	switch i {
	case 0: return clamp(35 + 25 * math.sin(x) + 15 * math.sin(x * 3.7), 0, 100)
	case 1: return 58 + 0.3 * math.sin(x * 0.2) // memory: steady
	case 2: return max(0, 30 * math.sin(x * 0.9) * math.sin(x * 2.3))
	case:   return abs(800 * math.sin(x * 0.5)) + 100
	}
	return 0
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	s.tick += 1
	for &r, i in s.res {
		if i == 3 && s.tick < 20 do continue // the network one is still filling
		append(&r.hist, sample(i, s.tick))
		if len(r.hist) > SPAN do ordered_remove(&r.hist, 0)
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, gap = .lg, padding = .lg); defer baldr.end(ui)
	{
		baldr.column(ui, gap = .xs, width = 240); defer baldr.end(ui)
		for &r, i in s.res {
			baldr.row(ui, gap = .md, align = .Center, padding = .sm, key = u64(i + 1)); defer baldr.end(ui)
			c, _ := baldr.color_parse_hex(r.color)
			if r.pinned {
				baldr.sparkline(ui, r.hist[:], color = c, fill = true, y_min = 0, y_max = 100, span = SPAN)
			} else {
				baldr.sparkline(ui, r.hist[:], color = c, fill = true, span = SPAN)
			}
			baldr.column(ui, gap = .none); defer baldr.end(ui)
			baldr.text(ui, r.name, weight = .Medium)
			last := r.hist[len(r.hist) - 1] if len(r.hist) > 0 else 0
			baldr.text(ui, fmt.tprintf("%.0f %s", last, r.unit), muted = true)
		}
	}
	// the memory page, as the Task Manager has it: alone in a scroll, a
	// steady value against a moving window of readings
	pts := make([]baldr.Chart_Point, len(s.res[1].hist), context.temp_allocator)
	first := s.tick - len(s.res[1].hist) + 1
	for v, i in s.res[1].hist do pts[i] = {f64(first + i), f64(v)}
	baldr.scroll(ui, flex = 1, key = 9)
	baldr.chart(ui, []baldr.Chart_Series{{name = "Memory", points = pts, color = baldr.chart_color(&ui.tree.theme, 6)}}, kind = .Area, label = "Memory",
		y_min = 0, y_max = 100, legend = false, height = 280, x_min = f64(s.tick - SPAN), x_max = f64(s.tick), x_grid = 15)
	baldr.end(ui)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Tasks", app_id = "dev.baldr.task_graphs", size = {900, 360},
		init = proc() -> (s: State) {
			s.res = {
				{name = "CPU", unit = "%", pinned = true, color = "#2a78d6"},
				{name = "Memory", unit = "%", pinned = true, color = "#7a4fd6"},
				{name = "Disk", unit = "MB/s", color = "#1baf7a"},
				{name = "Network", unit = "KB/s", color = "#eb6834"},
			}
			for &r in s.res do r.hist = make([dynamic]f32)
			return
		},
		update = update, view = view,
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) { append(out, baldr.every(Msg, 250, Msg.Tick)) },
	})
}
