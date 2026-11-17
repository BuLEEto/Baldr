// 09_jobs — background work: three "downloads", each on its own thread,
// reporting progress as messages while the window stays live. The job
// command starts the worker; the worker posts; cancel stops it; the done
// handler reports. Swap `transfer` for a real socket read and the app
// does not change.
//
// A download that finishes notifies the desktop, so the news
// arrives even with the window closed or behind something else; the
// notification's button comes back as a message like any other, and a
// desktop with no notifications says so rather than going quiet.
//
//   ./build.sh example 09_jobs run
package main

import "core:fmt"
import "core:time"
import "baldr:baldr"

CHUNK :: 96 * 1024 // bytes per step, one step every 20 ms: about 5 MB/s

State :: struct {
	files:  [3]Download,
	clicks: int,
	said:   string, // what the desktop told us about the last notification
}
Download :: struct {
	name:      string,
	size:      int,
	got:       int,
	running:   bool,
	cancelled: bool,
	started:   time.Tick,
	took:      time.Duration,
}

Msg :: union {
	Start,
	Start_All,
	Stop,
	Progress,
	Finished,
	Bump,
	Notified,
}
Start     :: struct { id: int }
Start_All :: struct {}
Stop      :: struct { id: int }
Progress  :: struct { id, got: int }
Finished  :: struct { id: int, cancelled: bool }
Bump      :: struct {}
Notified  :: struct { n: baldr.Notification } // what became of a notification

Req :: struct { id, size: int } // what the worker owns

// transfer runs on the job's thread: a step per chunk, progress posted
// after each, and a look at `cancelled` before the next.
transfer :: proc(j: ^baldr.Job(Msg)) {
	req := (^Req)(j.data)
	defer free(req)
	got := 0
	for got < req.size && !baldr.cancelled(j) {
		time.sleep(20 * time.Millisecond) // stands in for a socket read
		got = min(got + CHUNK, req.size)
		baldr.post(j, Progress{req.id, got})
	}
}

start :: proc(s: ^State, id: int) -> baldr.Cmd(Msg) {
	d := &s.files[id]
	if d.running do return {}
	d^ = {name = d.name, size = d.size, running = true, started = time.tick_now()}
	return baldr.job(Msg, transfer, new_clone(Req{id, d.size}),
		on_done = proc(e: baldr.Ev(baldr.Job_Done)) -> Msg { return Finished{int(e.tag), e.value.cancelled} }, tag = u64(id))
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Start:     return start(s, v.id)
	case Start_All: return baldr.batch(Msg, start(s, 0), start(s, 1), start(s, 2))
	case Stop:      return baldr.cancel(Msg, u64(v.id))
	case Progress:  s.files[v.id].got = v.got
	case Finished:
		d := &s.files[v.id]
		d.running = false
		d.cancelled = v.cancelled
		d.took = time.tick_since(d.started)
		if v.cancelled do return {} // nobody wants telling about what they stopped
		// The tag is the download's, so three finishing at once are three
		// notifications and not one replacing the others.
		return baldr.notify(Msg, "Download finished", d.name,
			actions = []baldr.Notify_Action{{"open", "Open the folder"}},
			tag = u64(v.id + 1),
			on_event = proc(e: baldr.Ev(baldr.Notification)) -> Msg { return Notified{e.value} })
	case Notified:
		n := v.n
		switch n.event {
		case .Shown:     s.said = "the desktop showed it"
		case .Failed:    s.said = fmt.aprintf("no notification: %s", n.error) // …so the app says it here instead
		case .Activated: s.said = "you chose it" if n.action == "" else fmt.aprintf("you chose %q", n.action)
		case .Closed:    s.said = "it has gone"
		}
	case Bump: s.clicks += 1
	}
	return {}
}

status :: proc(d: Download) -> string {
	mb := f64(d.size) / 1e6
	switch {
	case d.running:
		secs := time.duration_seconds(time.tick_since(d.started))
		rate := f64(d.got) / 1e6 / max(secs, 0.001)
		return fmt.tprintf("%.1f of %.1f MB · %.1f MB/s", f64(d.got) / 1e6, mb, rate)
	case d.cancelled: return fmt.tprintf("Cancelled at %.1f of %.1f MB", f64(d.got) / 1e6, mb)
	case d.got == d.size && d.size > 0: return fmt.tprintf("Done in %.1f s", time.duration_seconds(d.took))
	}
	return fmt.tprintf("%.1f MB", mb)
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .xl, gap = .lg); defer baldr.end(ui)
	baldr.text(ui, "Downloads", role = .Headline)
	baldr.text(ui, "Each transfer runs on its own thread and posts progress as messages; the view never waits.", muted = true)
	for d, i in s.files {
		baldr.card(ui, gap = .sm, key = u64(i + 1)); {
			defer baldr.end(ui)
			baldr.row(ui, align = .Center, gap = .md); {
				defer baldr.end(ui)
				baldr.text(ui, d.name, role = .Title)
				baldr.spacer(ui)
				baldr.text(ui, status(d), role = .Label, muted = true)
				if d.running {
					baldr.button(ui, "Cancel", Stop{i}, variant = .Outline)
				} else {
					baldr.button(ui, "Download" if d.got == 0 else "Again", Start{i}, variant = .Secondary)
				}
			}
			baldr.progress(ui, f32(d.got) / f32(d.size), label = d.name)
		}
	}
	baldr.row(ui, align = .Center, gap = .md); {
		defer baldr.end(ui)
		baldr.button(ui, "Download all", Start_All{})
		baldr.button(ui, fmt.tprintf("Clicked %d times: still responsive", s.clicks), Bump{}, variant = .Outline)
		// A desktop that cannot show notifications says so, and the app has
		// somewhere to put what it would have said.
		if s.said != "" do baldr.text(ui, s.said, role = .Label, muted = true)
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title  = "Baldr — jobs",
		app_id = "dev.baldr.jobs",
		size   = {560, 460},
		init   = proc() -> State {
			return {files = {
				{name = "odin-nightly.tar.gz", size = 24_000_000},
				{name = "fonts.zip", size = 9_500_000},
				{name = "changelog.md", size = 400_000},
			}}
		},
		update = update,
		view   = view,
	})
}
