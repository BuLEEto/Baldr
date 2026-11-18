package baldr

// The text caret's blink, shared by fields, editors and terminals: how fast
// it blinks, when it stops, and the wakes that drive it. A blink repaints
// only the caret (mark_blink_dirty), and a caret left alone stops blinking,
// shown, so an idle window wakes nothing.

// CARET_BLINK_MS is the caret's half-period when the desktop does not set
// one: shown this long, then hidden this long.
CARET_BLINK_MS :: 530.0

// CARET_BLINK_TIMEOUT_MS is how long a caret goes on blinking after the last
// key, click or move when the desktop does not say, as GTK's default; then
// it stays shown until the next one.
CARET_BLINK_TIMEOUT_MS :: 10_000.0

// caret_timing is how the caret blinks here: its half-period and how long it
// goes on, from the preferences in force, and whether it blinks at all. A
// steady caret is asked for by the desktop's own setting, and by reduced
// motion.
@(private)
caret_timing :: proc(t: ^Tree) -> (half, timeout: f64, blinks: bool) {
	p := t.a11y_prefs
	blinks = !p.steady_caret && !t.theme.motion.reduce
	half = CARET_BLINK_MS
	if p.caret_blink_ms > 0 do half = clamp(f64(p.caret_blink_ms), 100, 5_000) // a stray setting cannot spin a window or freeze the caret
	timeout = CARET_BLINK_TIMEOUT_MS
	if p.caret_blink_timeout_ms > 0 do timeout = max(f64(p.caret_blink_timeout_ms), 2 * half)
	return
}

// caret_shown says whether a caret whose blink began at `from` is drawn now,
// and asks for the wake that next changes that, if one will. A `from` in the
// future (the clock went back) starts the blink again from now.
@(private)
caret_shown :: proc(t: ^Tree, n: Node, from: ^f64) -> bool {
	half, timeout, blinks := caret_timing(t)
	if !blinks do return true
	elapsed := t.now_ms - from^
	if elapsed < 0 {
		from^ = t.now_ms
		elapsed = 0
	}
	if elapsed + 1 >= timeout do return true // +1 ms: a wake that lands a hair early still counts
	phase := int((elapsed + 1) / half)
	wake_at(t, min(from^ + f64(phase + 1) * half, from^ + timeout), n, blink = true)
	return phase % 2 == 0
}

// caret_painted tells a blink-only repaint where the caret is, drawn or not,
// so the frame presents that and not the whole widget. Logical px, where
// paint is drawing; it is grown by a pixel for the edge a fractional scale
// rounds into.
@(private)
caret_painted :: proc(t: ^Tree, r: Rect) {
	grown := Rect{r.x - 1, r.y - 1, r.w + 2, r.h + 2}
	t.blink_rect = rect_union(t.blink_rect, grown) if t.blink_said else grown
	t.blink_said = true
}
