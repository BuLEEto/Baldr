// frame_clock — does `frames` run in step with the display?
//
// A video player uploads the frame for the audio clock's time and wants it
// shown at a known moment. `every(ms)` cannot do that: it is not tied to
// the screen. This measures what the subscription actually delivers —
// the interval between frames, and whether the times are measured
// (wp_presentation) or estimated.
//
// In step, the implied rate matches the display's and no frame is off by
// half an interval. On Windows a headless session gets no answer from
// DwmGetCompositionTimingInfo, so the rate there is the nominal mode's. On
// macOS, `BALDR_NO_DISPLAY_LINK=1` falls back from the display link to the
// fixed clamp, for comparison.
//
//   ./build.sh spike frame_clock run
package main

import "core:fmt"
import "baldr:baldr"

N :: 180 // three seconds at 60 Hz

State :: struct {
	ticks:  int,
	first:  f64,
	last:   f64,
	gaps:   [N]f64,
	est:    bool,
	refresh: f64,
	done:   bool,
}

Msg :: union { Tick, Stop }
Tick :: struct { ft: baldr.Frame_Time }
Stop :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "frame clock", app_id = "baldr.frameclock", size = {360, 160},
		init = proc() -> State { return {} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Tick:
				if s.ticks < N {
					if s.ticks > 0 do s.gaps[s.ticks] = v.ft.now_ms - s.last
					if s.ticks == 0 do s.first = v.ft.now_ms
					s.last = v.ft.now_ms
					s.est, s.refresh = v.ft.estimated, v.ft.refresh_ms
					s.ticks += 1
				} else if !s.done {
					s.done = true
					report(s)
					return baldr.quit(Msg)
				}
			case Stop:
				if !s.done { s.done = true; report(s); return baldr.quit(Msg) }
			}
			return {}
		},
		// the line is declared only while it is wanted, which is the point
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			if !s.done {
				append(out, baldr.frames(Msg, proc(e: baldr.Ev(baldr.Frame_Time)) -> Msg { return Tick{e.value} }))
				append(out, baldr.every(Msg, 6000, Stop{})) // a way out if no frames come at all
			}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "frame clock", role = .Headline)
			baldr.text(ui, fmt.tprintf("%d / %d frames", s.ticks, N), muted = true)
		},
	})
}

report :: proc(s: ^State) {
	if s.ticks < 2 { fmt.println("no frames arrived — the compositor sent none"); return }
	lo, hi, sum := max(f64), f64(0), f64(0)
	n := 0
	for i in 1 ..< s.ticks {
		g := s.gaps[i]
		if g <= 0 do continue
		lo, hi, sum = min(lo, g), max(hi, g), sum + g
		n += 1
	}
	if n == 0 { fmt.println("no gaps measured"); return }
	mean := sum / f64(n)
	fmt.printfln("frames        %d over %.0f ms", s.ticks, s.last - s.first)
	fmt.printfln("interval      mean %.2f ms   min %.2f   max %.2f", mean, lo, hi)
	// Who measured it differs by platform: DWM on Windows, wp_presentation
	// on Wayland (which the backend does not use yet, so Linux says
	// estimated). The flag is the contract; the source is the backend's.
	fmt.printfln("refresh_ms    %.3f  (%s)", s.refresh, "estimated from the nominal mode" if s.est else "measured by the compositor")
	fmt.printfln("implied rate  %.1f Hz", 1000 / mean)
	// a frame clock that is in step holds close to one refresh; a timer wanders
	off := 0
	for i in 1 ..< s.ticks do if s.gaps[i] > 0 && abs(s.gaps[i] - s.refresh) > s.refresh * 0.5 do off += 1
	fmt.printfln("off by >half a refresh: %d of %d", off, n)
}
