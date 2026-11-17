// 12_applet — a clock applet: a small Baldr app a desktop
// shell shows inside one of its bars, through the compositor's rikkiti-applet-v1.
// The shell reserves a slot and starts the app with the slot's token in
// RIKKITI_APPLET_TOKEN; the app declares one `.Applet` surface and draws on
// the bar's glass. In a top or bottom bar it shows the time and date on one
// line; down a side bar, the hour over the minute and a calendar button
// (ui.surface.edge). Its calendar opens as a popup away from the bar, and
// the shell hears how long the clock would like to be. Started by hand,
// with no shell to embed it, it opens as a small window.
//
//   ./build.sh example 12_applet run                # a window of its own
//   RIKKITI_APPLET_TOKEN=<token> build/12_applet    # as a shell starts it
//   BALDR_WAYLAND_DEBUG=1 build/12_applet           # configures, the edge, size hints
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	time:     baldr.Time_Of_Day,
	date:     baldr.Date,
	calendar: bool,
}

Msg :: enum { Tick, Toggle_Calendar, Close_Calendar, Closed }

init :: proc() -> (s: State) {
	read_clock(&s)
	return
}

read_clock :: proc(s: ^State) {
	s.time = baldr.now_local()
	s.date = baldr.today()
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Tick:            read_clock(s)
	case .Toggle_Calendar: s.calendar = !s.calendar
	case .Close_Calendar:  s.calendar = false
	case .Closed:          return baldr.quit(Msg) // the shell removed the slot
	}
	return {}
}

subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	append(out, baldr.every(Msg, 1000, Msg.Tick))
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){tag = 1, kind = .Applet, title = "Clock", size = {220, 44}, on_close = Msg.Closed})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	date := baldr.date_text(&ui.tree, s.date)
	edge, in_bar := ui.surface.edge.?
	anchor: baldr.Node
	if in_bar && (edge == .Left || edge == .Right) {
		// down a side bar: the hour over the minute, and a button for the calendar
		baldr.column(ui, flex = 1, align = .Center, justify = .Center, gap = .xxs); {
			defer baldr.end(ui)
			hour := int(s.time.hour)
			if !ui.tree.locale.time_24h do hour = (hour + 11) % 12 + 1
			baldr.text(ui, fmt.tprintf("%02d", hour), role = .Label)
			baldr.text(ui, fmt.tprintf("%02d", s.time.minute), role = .Label)
			anchor = baldr.button(ui, fmt.tprintf("Calendar, %s", date), Msg.Toggle_Calendar, variant = .Ghost, icon = .Calendar, icon_only = true)
		}
	} else {
		baldr.row(ui, flex = 1, align = .Center, justify = .Center); {
			defer baldr.end(ui)
			anchor = baldr.button(ui, fmt.tprintf("%s  %s", baldr.time_text(&ui.tree, s.time), date), Msg.Toggle_Calendar, variant = .Ghost)
		}
	}
	if baldr.popover(ui, anchor, s.calendar, Msg.Close_Calendar) { // opens away from the bar
		defer baldr.end(ui)
		baldr.date_picker(ui, s.date, label = "Calendar")
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		app_id        = "dev.baldr.clock",
		init          = init,
		update        = update,
		view          = view,
		surfaces      = surfaces,
		subscriptions = subscriptions,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
