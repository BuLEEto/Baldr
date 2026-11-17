// wincheck — the parts of the Windows backend that a headless server session
// cannot check (no composition timing, no visible pointer, one unscaled
// screen), answered on a real desktop:
//
//   1. Does DWM give the frame clock **measured** times, or does it fall
//      back to the screen's nominal rate? (A session without composition
//      gets 0x88980090.)
//   2. Does a screen at 125% / 150% report the right `scale`, and does a
//      second screen sit where it should?
//   3. Does the locale come through on a machine set to something else?
//   4. Does a cursor the app drew look right — a soft edge, no dark rim
//      from an alpha that should not have been premultiplied?
//
// Run it, read the panel, and look at the pointer over the dark strip. It
// also writes `wincheck.txt` beside itself, which is the thing to send back.
//
//   ./build.sh spike wincheck run
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "baldr:baldr"

RING  :: 48   // the cursor picture, in screen pixels
FRAMES :: 240 // about two seconds at 120 Hz, four at 60

State :: struct {
	ring:     baldr.Image,
	checks:   baldr.Image, // the strip to hold the pointer over
	ticks:    int,
	first:    f64,
	last:     f64,
	gaps:     [FRAMES]f64,
	measured: bool,
	refresh:  f64,
	done:     bool,
	locale:   baldr.Locale, // read off the tree in the view: that is where it lives
	written:  bool,
	report:   string,
}

Msg :: union { Tick, Stop }
Tick :: struct { ft: baldr.Frame_Time }
Stop :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Baldr on Windows - check", app_id = "baldr.wincheck", size = {980, 680},
		init = proc() -> State { return {ring = ring_image(), checks = checker_image()} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Tick:
				if s.ticks < FRAMES {
					if s.ticks > 0 do s.gaps[s.ticks] = v.ft.now_ms - s.last
					if s.ticks == 0 do s.first = v.ft.now_ms
					s.last = v.ft.now_ms
					s.measured, s.refresh = !v.ft.estimated, v.ft.refresh_ms
					s.ticks += 1
				} else if !s.done {
					s.done = true
					s.report = build_report(s)
					write_report(s.report)
				}
			case Stop:
				// No frames at all in six seconds is itself the answer.
				if !s.done {
					s.done = true
					s.report = build_report(s)
					write_report(s.report)
				}
			}
			return {}
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			if !s.done {
				append(out, baldr.frames(Msg, proc(e: baldr.Ev(baldr.Frame_Time)) -> Msg { return Tick{e.value} }))
				append(out, baldr.every(Msg, 6000, Stop{}))
			}
		},
		view = view,
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	s.locale = ui.locale // an alias into the tree, valid while this build runs
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Baldr on Windows", role = .Headline)
	if !s.done {
		baldr.text(ui, fmt.tprintf("measuring the frame clock... %d / %d", s.ticks, FRAMES), muted = true)
	} else {
		baldr.text(ui, "Saved as wincheck.txt beside this program.", muted = true)
	}

	scroll := baldr.scroll(ui, flex = 1, key = 1); {
		defer baldr.end(ui)
		baldr.text(ui, s.report if s.done else "", role = .Body, mono = true, nowrap = true)
	}
	_ = scroll

	// The cursor to look at, and the same picture drawn four times the size
	// so the two can be compared. A dark strip, because a dark rim from a
	// premultiplied alpha shows against dark as a halo and against light
	// hardly at all.
	baldr.text(ui, "Hold the pointer over the squares. It should be the red ring shown on the right. The squares are there on purpose: an alpha handled wrongly shows as a dark halo on the light squares and a light one on the dark.", muted = true)
	row := baldr.row(ui, gap = .lg, align = .Center, height = 210); {
		defer baldr.end(ui)
		strip := baldr.image(ui, &s.checks, width = 640, height = 200, fit = .Cover, pixelated = true, label = "put the pointer here", key = 2)
		baldr.pointer_area(ui, strip, cursor_image = &s.ring, hotspot = {RING / 2, RING / 2})
		baldr.image(ui, &s.ring, width = RING * 3, height = RING * 3, pixelated = true, label = "the cursor at three times the size", key = 3)
	}
	_ = row
}

build_report :: proc(s: ^State) -> string {
	b := strings.builder_make()

	fmt.sbprintln(&b, "== frame clock ==")
	if s.ticks < 2 {
		fmt.sbprintln(&b, "no frames arrived at all - frames() is not working here")
	} else {
		lo, hi, sum := max(f64), f64(0), f64(0)
		n, off := 0, 0
		for i in 1 ..< s.ticks {
			g := s.gaps[i]
			if g <= 0 do continue
			lo, hi, sum = min(lo, g), max(hi, g), sum + g
			n += 1
			if s.refresh > 0 && abs(g - s.refresh) > s.refresh / 2 do off += 1
		}
		mean := sum / f64(max(n, 1))
		fmt.sbprintfln(&b, "frames        %d over %.0f ms", s.ticks, s.last - s.first)
		fmt.sbprintfln(&b, "interval      mean %.2f ms   min %.2f   max %.2f", mean, lo, hi)
		fmt.sbprintfln(&b, "refresh_ms    %.3f  (%s)", s.refresh,
			"MEASURED by the compositor - this is what the build box could not do" if s.measured else "estimated from the nominal mode")
		fmt.sbprintfln(&b, "implied rate  %.1f Hz", 1000.0 / mean if mean > 0 else 0)
		fmt.sbprintfln(&b, "off by more than half a refresh: %d of %d", off, n)
	}

	fmt.sbprintln(&b, "\n== screens ==")
	for o in baldr.outputs() {
		fmt.sbprintfln(&b, "%-16s pos %d,%d  size %dx%d  mode %dx%d  scale %.2f  %d mHz  %v%s",
			o.name, o.pos.x, o.pos.y, o.size.x, o.size.y, o.mode_px.x, o.mode_px.y,
			o.scale, o.refresh, o.transform, "  *primary" if o.primary else "")
		if o.description != "" do fmt.sbprintfln(&b, "%-16s %s", "", o.description)
	}
	if len(baldr.outputs()) == 0 do fmt.sbprintln(&b, "(none reported - that is a bug)")

	l := s.locale
	fmt.sbprintln(&b, "\n== locale ==")
	fmt.sbprintfln(&b, "tag %s   dates %s   %s   decimal %q   thousands %q   first day %d",
		l.tag, l.date_format, "24h" if l.time_24h else "12h", l.decimal, l.thousands, l.first_weekday)
	fmt.sbprintfln(&b, "months   %s ... %s", l.months[0], l.months[11])
	fmt.sbprintfln(&b, "weekdays %s ... %s   (Sunday first)", l.weekdays[0], l.weekdays[6])
	fmt.sbprintfln(&b, "am %q  pm %q", l.am, l.pm)

	return strings.to_string(b)
}

// write_report puts the text beside the program, which is where someone who
// double-clicked it will look.
write_report :: proc(text: string) {
	name := "wincheck.txt"
	if len(os.args) > 0 {
		dir := filepath.dir(os.args[0])
		defer delete(dir)
		if dir != "" && dir != "." {
			name, _ = filepath.join({dir, "wincheck.txt"}, context.temp_allocator)
		}
	}
	_ = os.write_entire_file(name, transmute([]u8)text)
	fmt.println(text)
}

// checker_image is the surface to hold the pointer over: light and dark
// squares, so an alpha handled wrongly has nowhere to hide.
checker_image :: proc() -> baldr.Image {
	N :: 16 // squares, drawn at one pixel each and scaled up by the view
	px := make([]u8, N * N * 4)
	defer delete(px)
	for y in 0 ..< N {
		for x in 0 ..< N {
			v: u8 = 235 if (x + y) % 2 == 0 else 45
			i := (y * N + x) * 4
			px[i + 0], px[i + 1], px[i + 2], px[i + 3] = v, v, v, 255
		}
	}
	img, _ := baldr.image_from_rgba(N, N, px)
	return img
}

// ring_image is a red ring with a clear middle and a one-pixel soft edge:
// nothing like a stock cursor, and the soft edge is the part that shows an
// alpha handled wrongly.
ring_image :: proc() -> baldr.Image {
	px := make([]u8, RING * RING * 4)
	defer delete(px)
	c := f32(RING) / 2
	for y in 0 ..< RING {
		for x in 0 ..< RING {
			dx, dy := f32(x) + 0.5 - c, f32(y) + 0.5 - c
			d := math.sqrt(dx * dx + dy * dy)
			a := f32(0)
			if d > c - 5 && d < c - 1 do a = 1
			else if d > c - 6 && d <= c - 5 do a = d - (c - 6)
			else if d >= c - 1 && d < c do a = c - d
			i := (y * RING + x) * 4
			px[i + 0], px[i + 1], px[i + 2] = 220, 40, 40
			px[i + 3] = u8(clamp(a, 0, 1) * 255)
		}
	}
	img, _ := baldr.image_from_rgba(RING, RING, px)
	return img
}
