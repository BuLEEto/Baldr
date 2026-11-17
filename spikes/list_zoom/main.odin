package main

// A document whose pages are a list, zoomed — and the place the reader was
// looking at staying where it was.
//
// The instrument for `height_of` and the hold. A page's height is the app's
// own arithmetic (its size at this zoom), so the list estimates nothing and
// measures nothing, and the app never has to bump a generation into its row
// keys to disown last zoom's measurements.
//
// **A zoom asks with `hold_at`**, which names a spot of the viewport and no
// page at all: the list works out what is there from the offset it is
// actually on. An app's own note of the place, taken during its last build,
// can be behind: a list does not rebuild for a scroll that keeps the same
// pages on screen, so dragging the bar within one tall page moves the view
// without the app hearing.
//
// It still *takes* the note, because the note is the measurement the proof is
// made of — what the spike thought was at the middle, against what the list
// put there. Measuring with the mechanism under test would prove nothing.
//
// **And it holds only the vertical** (`axes = {.Y}`): naming an x of 0 as
// well would put the sideways pan back to the left edge on every zoom.
//
// Opening part-way down (`LIST_ZOOM_START`) is the *other* form, a hold that
// names a page, because there "go to page 40" is the ask rather than "keep
// what is here".
//
// Driven, because the proof is a **sequence of numbers** rather than a
// picture: `LIST_ZOOM_SEQ="1,2,0.5,1"` zooms to each of those scales in
// turn, `LIST_ZOOM_EVERY` seconds apart, and each zoom prints what it is
// holding and then what it found. The two lines must name the same page and
// the same fraction of it — the pixel offset is *expected* to change, since
// the pages have. `LIST_ZOOM_QUIT` ends the run.
//
//	./build.sh spike list_zoom run                     # by hand: Ctrl+= / Ctrl+- / Ctrl+0
//	LIST_ZOOM_SEQ=1,2,0.5,1 LIST_ZOOM_QUIT=9 build/list_zoom
//	LIST_ZOOM_PAN=100 LIST_ZOOM_SEQ=2,3,2.5,2 …        # …and `across` must not move
//
// By hand it is the same proof with a pointer: zoom in and out and watch the
// page number in the bar stay put.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "baldr:baldr"

PAGES    :: 150
PAGE_PAD :: f32(16) // room around a page, which does not scale with it
PORTRAIT :: [2]f32{320, 440}
LANDSCAPE :: [2]f32{440, 320}

State :: struct {
	count: int,
	scale: f32,
	// Noted every build, so a zoom can ask for the place back. A real
	// document viewer has a page table to binary-search; a hundred and fifty
	// pages can be walked.
	at_page: int,
	into:    f32, // px into that page, at the scale it was noted at
	at_view: f32, // px down the viewport the note was taken at (its middle)
	noted:   bool,
	// A hold that names a page, which only the opening jump needs.
	hold:    u64,
	point:   [2]f32,
	hold_at: [2]f32,
	// What the next build *should* find, worked out when the ask is made, so
	// the report can say whether the scroll's clamp got in the way.
	want:    f32,
	report:  bool, // print where the next build finds it
	pan_to:  f32,  // LIST_ZOOM_PAN: scroll this far across, once, before the zooms
	panned:  bool, // …done
	start:   int,  // LIST_ZOOM_START: open on this page, so a zoom is not at the document's edge
	list_n:  baldr.Node,
	// the drive
	seq:     [dynamic]f32,
	step:    int,
	every:   f64,
	quit_at: f64,
	t0:      time.Tick,
}

Msg :: union { Tick, Zoom }

Tick :: struct {}
Zoom :: struct { scale: f32 }

page_size :: proc(i: int) -> [2]f32 {
	return LANDSCAPE if i % 7 == 3 else PORTRAIT
}

// What the list is told, and the whole of what it needs: a row is a page at
// this zoom, with its margin.
page_height :: proc(user: rawptr, i: int) -> f32 {
	s := (^State)(user)
	return page_size(i).y * s.scale + PAGE_PAD
}

page_top :: proc(s: ^State, i: int) -> (top: f32) {
	for j in 0 ..< i do top += page_height(s, j)
	return
}

widest :: proc(s: ^State) -> f32 {
	return LANDSCAPE.x * s.scale + PAGE_PAD
}

// Which page is under `y` of the view, and how far into it.
note_place :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	if s.list_n == baldr.NODE_NONE do return
	vp := baldr.scroll_viewport(&ui.tree, s.list_n)
	if vp.y <= 0 do return
	off := baldr.scroll_offset(&ui.tree, s.list_n)
	at := vp.y * 0.5
	y := off.y + at
	i, top := 0, f32(0)
	for i < s.count - 1 {
		h := page_height(s, i)
		if top + h > y do break
		top += h
		i += 1
	}
	if !s.noted { // the drive's clock starts when there is something to look at
		s.t0 = time.tick_now()
		fmt.eprintfln("list_zoom: on screen, viewport %.0fx%.0f", vp.x, vp.y)
	}
	s.at_page, s.into, s.at_view, s.noted = i, y - top, at, true
	if s.report {
		s.report = false
		// What was asked for, before the scroll's own clamp: a hold near
		// either end of a document cannot be granted in full, and that is
		// not the list getting it wrong.
		note := ""
		if abs(off.y - s.want) > 1 {
			note = fmt.tprintf(", asked %.1f and was clamped", s.want)
		}
		fmt.eprintfln("list_zoom:   found page %d, %.3f into it, %.0f px down the view (offset %.1f, across %.1f, %.0f%%%s)",
			i + 1, (y - top) / page_height(s, i), at, off.y, off.x, s.scale * 100, note)
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	secs := time.duration_seconds(time.tick_since(s.t0))
	switch e in m {
	case Tick:
		if len(s.seq) > 0 && s.step < len(s.seq) && secs >= s.every * f64(s.step + 1) {
			zoom_to(s, s.seq[s.step])
			s.step += 1
			// The hold goes with the zoom, in the same breath, so it lands
			// in the build that changed the scale (reveal_cmd.odin).
			return baldr.batch(Msg, hold_middle(s), baldr.delay(Msg, 100, Tick{}))
		}
		if s.quit_at > 0 && secs >= s.quit_at do return baldr.quit(Msg)
		return baldr.delay(Msg, 100, Tick{})
	case Zoom:
		zoom_to(s, e.scale)
		return hold_middle(s)
	}
	return {}
}

// PAGES_LIST is the list's own key, which is how a command names it.
PAGES_LIST :: u64(1)

// What a zoom asks: keep whatever is at the middle of the view where it is,
// vertically. No page named, and nothing of the app's own notes in it.
hold_middle :: proc(s: ^State) -> baldr.Cmd(Msg) {
	return baldr.hold_at(Msg, PAGES_LIST, {0, s.at_view}, axes = {.Y})
}

// …and what opening part-way down asks: a page by name, at the top of the
// view. Pending until there is a viewport to place it in.
hold_page :: proc(s: ^State) -> baldr.Cmd(Msg) {
	return baldr.hold(Msg, PAGES_LIST, s.hold, s.point, s.hold_at)
}

// What a zoom asks of the list: the new heights, and the place the reader was
// looking at back where it was.
zoom_to :: proc(s: ^State, want: f32) {
	if want <= 0.05 || want > 8 do return
	if !s.noted { // nothing on screen yet: just take the scale
		s.scale = want
		return
	}
	// The fraction is the spike's **own** measurement, kept for the report:
	// the *place in the page* is what the reader means, and the margin does
	// not scale, so it is not simply `into` times the factor. `hold_at` is
	// told none of this — it is told the spot, and works the rest out itself.
	old_h := page_height(s, s.at_page)
	frac := s.into / max(old_h, 1)
	fmt.eprintfln("list_zoom: %.0f%% -> %.0f%%: holding page %d at %.3f into it, %.0f px down the view",
		s.scale * 100, want * 100, s.at_page + 1, frac, s.at_view)
	s.scale = want
	s.want = page_top(s, s.at_page) + frac * page_height(s, s.at_page) - s.at_view
	s.report = true
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1); defer baldr.end(ui)
	baldr.shortcut(ui, "Ctrl+=", Zoom{s.scale * 1.25})
	baldr.shortcut(ui, "Ctrl+-", Zoom{s.scale * 0.8})
	baldr.shortcut(ui, "Ctrl+0", Zoom{1})
	{
		baldr.row(ui, padding = .md, gap = .md, align = .Center); defer baldr.end(ui)
		baldr.text(ui, fmt.tprintf("%.0f%%", s.scale * 100), role = .Title)
		baldr.text(ui, fmt.tprintf("page %d of %d, %.2f into it", s.at_page + 1, s.count,
			s.into / page_height(s, s.at_page)), role = .Caption)
	}
	first, last := baldr.list(ui, s.count, height_of = page_height, key_user = s,
		content_width = widest(s), flex = 1, label = "Pages", key = PAGES_LIST)
	defer baldr.end(ui)
	s.list_n = baldr.list_node(ui)
	note_place(s, ui)
	// LIST_ZOOM_PAN: the reader scrolled across a page wider than the view,
	// once, before any zoom. `axes = {.Y}` is what leaves it alone.
	// Only once there is something to scroll across: at 100% a page is 456 px
	// against a 760 px viewport, so the offset is clamped to 0 and the pan
	// would look as if the hold had thrown it away. Zoom past about 1.7 first
	// (`LIST_ZOOM_SEQ=2,3,2.5,2`).
	if s.pan_to > 0 && !s.panned && s.noted {
		vp := baldr.scroll_viewport(&ui.tree, s.list_n)
		if widest(s) > vp.x + 1 {
			off := baldr.scroll_offset(&ui.tree, s.list_n)
			baldr.scroll_to(&ui.tree, s.list_n, {s.pan_to, off.y})
			s.panned = true
			fmt.eprintfln("list_zoom: panned across to %.0f (page %.0f wide, view %.0f)",
				s.pan_to, widest(s), vp.x)
		}
	}
	for i in first ..< last {
		sz := page_size(i)
		sz *= s.scale
		baldr.row(ui, justify = .Center, align = .Center, height = page_height(s, i), key = u64(i + 1))
		defer baldr.end(ui)
		baldr.card(ui, width = sz.x, height = sz.y, padding = .md, align = .Center)
		defer baldr.end(ui)
		baldr.text(ui, fmt.tprintf("%d", i + 1), role = .Title)
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "List zoom", app_id = "dev.baldr.list_zoom", size = {760, 620},
		init = proc() -> (s: State) {
			s.t0 = time.tick_now()
			s.count, s.scale = PAGES, 1
			s.every, _ = strconv.parse_f64(os.get_env("LIST_ZOOM_EVERY", context.temp_allocator))
			if s.every <= 0 do s.every = 1.5
			s.quit_at, _ = strconv.parse_f64(os.get_env("LIST_ZOOM_QUIT", context.temp_allocator))
			if v, ok := strconv.parse_f64(os.get_env("LIST_ZOOM_PAN", context.temp_allocator)); ok && v > 0 {
				s.pan_to = f32(v)
			}
			// Open part-way down, so the zooms that follow are nowhere near
			// an end of the document and nothing can be masked by the clamp.
			// It goes through the same hold, pending until there is a
			// viewport to place it in.
			if n, ok := strconv.parse_int(os.get_env("LIST_ZOOM_START", context.temp_allocator)); ok && n > 1 {
				s.start = min(n, PAGES)
				s.hold, s.point, s.hold_at = u64(s.start), {}, {}
				s.want = page_top(&s, s.start - 1)
			}
			for field in strings.split(os.get_env("LIST_ZOOM_SEQ", context.temp_allocator), ",",
				context.temp_allocator) {
				if v, ok := strconv.parse_f64(strings.trim_space(field)); ok && v > 0 {
					append(&s.seq, f32(v))
				}
			}
			fmt.eprintfln("list_zoom: %d pages from page %d, zooms %v every %.1f s",
				s.count, max(s.start, 1), s.seq, s.every)
			return
		},
		// Opening part-way down goes through the same hold, asked once at
		// the start rather than carried in the view.
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			tick := baldr.delay(Msg, 100, Tick{})
			if s.hold == 0 do return tick
			return baldr.batch(Msg, hold_page(s), tick)
		},
		update = update, view = view,
	})
	if baldr.run_failed(err) {
		fmt.eprintln("list_zoom: exit:", err)
		os.exit(1)
	}
}
