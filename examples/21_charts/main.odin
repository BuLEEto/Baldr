package main

// Charts: the same numbers as a line, an area, bars and a scatter. Click a
// point or walk them with the arrow keys — the value is read out either way,
// and every series is in the accessibility tree whatever the colours do.

import "core:fmt"
import "core:math"
import "baldr:baldr"

MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

State :: struct {
	kind:   baldr.Chart_Kind,
	picked: string,
	sales:  [12]baldr.Chart_Point,
	costs:  [12]baldr.Chart_Point,
	cloud:  [40]baldr.Chart_Point,
}

Pick :: struct { hit: baldr.Chart_Hit }
Kind :: struct { kind: baldr.Chart_Kind }
Msg :: union { Pick, Kind }

init :: proc() -> State {
	s := State{kind = .Line}
	for i in 0 ..< 12 {
		s.sales[i] = {f64(i), 40 + 30 * math.sin(f64(i) * 0.55) + f64(i) * 2.5}
		s.costs[i] = {f64(i), 28 + 12 * math.cos(f64(i) * 0.8) + f64(i) * 1.2}
	}
	for i in 0 ..< 40 {
		s.cloud[i] = {f64(i % 12), 20 + 55 * math.sin(f64(i) * 1.7) * math.cos(f64(i) * 0.3)}
	}
	return s
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Charts", role = .Title)

	baldr.row(ui, gap = .sm, align = .Center); {
		defer baldr.end(ui)
		for k in ([]baldr.Chart_Kind{.Line, .Area, .Bar, .Scatter}) {
			name := fmt.tprintf("%v", k)
			baldr.button(ui, name, Msg(Kind{k}), variant = .Primary if s.kind == k else .Outline, key = u64(k) + 1)
		}
	}

	series := []baldr.Chart_Series{
		{name = "Sales", points = s.sales[:]},
		{name = "Costs", points = s.costs[:]},
	}
	if s.kind == .Scatter do series = []baldr.Chart_Series{{name = "Orders", points = s.cloud[:]}}

	baldr.card(ui, padding = .md, gap = .sm); {
		defer baldr.end(ui)
		baldr.chart(ui, series, kind = s.kind, label = "Sales and costs by month",
			describe = "Two series over one year", x_labels = MONTHS[:], height = 300,
			on_select = proc(e: baldr.Ev(baldr.Chart_Hit)) -> Msg { return Pick{e.value} })
	}

	baldr.text(ui, s.picked if s.picked != "" else "Click a point, or focus the chart and use the arrow keys.", muted = true)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Kind: s.kind = v.kind
	case Pick: s.picked = fmt.aprintf("%s: %.1f at %s", v.hit.name, v.hit.point.y, MONTHS[int(v.hit.point.x) % 12])
	}
	return {}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Charts", app_id = "baldr.charts", size = {820, 560},
		init = init, view = view, update = update,
	})
}
