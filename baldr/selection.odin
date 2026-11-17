package baldr

// Selection is the app-owned set of selected rows of a table (or list),
// mutated in place by the widget the way `Text` is by a text input: the
// app keeps it in its state, passes a pointer to the builder, reads it
// whenever it likes, and hears about changes through `on_select`.
// `cursor` is the row keyboard navigation and Shift ranges work from;
// `anchor` is where the current Shift range started. The zero value is an
// empty single-select; set `multi` for Ctrl / Shift / Ctrl+A.

Selection :: struct {
	rows:   map[int]struct{},
	cursor: int, // -1 = none
	anchor: int, // -1 = none
	multi:  bool,
	// version counts changes to `rows`, so anything watching the selection
	// (the accessibility bridge, which must say when the set changed) can
	// see a different set rather than only a different size.
	version: u64,
	_init:  bool,
}

selection_make :: proc(multi := false, allocator := context.allocator) -> Selection {
	return {rows = make(map[int]struct{}, allocator), cursor = -1, anchor = -1, multi = multi, _init = true}
}

selection_destroy :: proc(s: ^Selection) {
	delete(s.rows)
	s^ = {}
}

@(private)
selection_ensure :: proc(s: ^Selection) {
	if !s._init {
		s.cursor, s.anchor, s._init = -1, -1, true
	}
}

selection_contains :: proc(s: ^Selection, row: int) -> bool {
	return row in s.rows
}

selection_count :: proc(s: ^Selection) -> int {
	return len(s.rows)
}

selection_clear :: proc(s: ^Selection) {
	clear(&s.rows)
	s.version += 1
}

// selection_set makes `row` the only selected row and the cursor/anchor.
selection_set :: proc(s: ^Selection, row: int) {
	selection_ensure(s)
	clear(&s.rows)
	if row >= 0 do s.rows[row] = {}
	s.cursor, s.anchor = row, row
	s.version += 1
}

// selection_toggle flips one row (multi only; single-select just sets it).
selection_toggle :: proc(s: ^Selection, row: int) {
	selection_ensure(s)
	if !s.multi {
		selection_set(s, row)
		return
	}
	if row in s.rows { delete_key(&s.rows, row) } else { s.rows[row] = {} }
	s.cursor, s.anchor = row, row
	s.version += 1
}

// selection_range selects anchor..row inclusive (replacing the selection),
// keeping the anchor; the cursor moves to `row`.
selection_range :: proc(s: ^Selection, row: int) {
	selection_ensure(s)
	if !s.multi || s.anchor < 0 {
		selection_set(s, row)
		return
	}
	clear(&s.rows)
	lo, hi := min(s.anchor, row), max(s.anchor, row)
	for i in lo ..= hi do s.rows[i] = {}
	s.cursor = row
	s.version += 1
}

selection_all :: proc(s: ^Selection, count: int) {
	selection_ensure(s)
	if !s.multi do return
	clear(&s.rows)
	for i in 0 ..< count do s.rows[i] = {}
	if s.cursor < 0 && count > 0 do s.cursor = 0
	s.version += 1
}
