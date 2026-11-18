package baldr

// text_area is a multiline editor over an app-owned Document (document.odin):
// paragraphs wrap to the width, the area grows with its content between
// `min_lines` and `max_lines` (0 = unbounded) or scrolls when given a
// height, and everything a text field does works across lines: typing,
// Enter, Backspace/Delete by grapheme or word (joining blocks), arrows
// (Up/Down keep a goal x across wrapped lines and blocks), Home/End of the
// line and Ctrl+Home/End of the document, Page Up/Down, Shift selection,
// Ctrl+A/C/X/V, Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z undo and redo (typing groups
// into one entry until a pause), click / drag / double-click (word) /
// triple-click (paragraph). Accessibility: role Text_Input, name = `label`
// (else the placeholder), the contents as the value, fully keyboard-operable
// with the standard focus ring. Tab moves focus (a text area is not a code
// editor). `on_change` fires with the document version after every edit;
// Ctrl+Enter sends `on_submit`, or Enter itself where the app says so
// (`editor_options(submit = .Enter)`: a chat composer, where Shift+Enter
// breaks the line instead). `on_context` (every editor has it) is sent
// on a right-click or the Menu key with an Editor_Context: where in the
// Document, and where to open the menu; editor_action does what the
// menu's Cut, Copy, Paste, Select All, Undo and Redo ask. `max_length` caps the characters (typing and
// pasting stop at the limit), `readonly` allows navigation, selection and
// copy but no edits, `invalid` / `required` colour the border and set the
// accessibility states, `wrap = false` keeps each paragraph on one line and
// scrolls sideways (code), and `marks` are ranges to decorate: Error and
// Warning squiggles, an Info underline, a Highlight behind the text — the
// hooks a spell checker, a search or a linter needs.
//
// The code editor (widget_code.odin) is the same engine in mono with
// `Code_State` switched on: it adds a gutter, tab stops, syntax colour,
// indentation keys, bracket matching, find and go-to-line — nothing here
// is duplicated there. Painting is virtual: only the blocks in view are
// shaped and drawn, from a cache of block tops kept per document version.

import "core:fmt"
import "core:math"
import "core:slice"
import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import runa "baldr:third_party/runa"

// Mark decorates a document range: what a spell checker, a search or a
// linter wants to show. Marks are copied per build (pass the current list).
// A `message` shows in a tooltip when the pointer rests on the mark (a
// diagnostic's text, a suggestion); the string must outlive the build.
// A mark is display only: never in the document, copied or exported. A new
// list every build is cheap, which is what lets a fade follow the caret.
Mark :: struct {
	from, to: Pos,
	kind:     Mark_Kind,
	message:  string,
	color:    Color, // .Tint's colour; ignored by the others
}

// Mark_Kind is how a mark shows. The first four draw around the text (a
// wave, a rule, a wash); the last three change how the text itself is drawn:
//
//   - Dim: the theme's muted text colour (sentence focus: may cover most of
//     a document and move with every caret press).
//   - Tint: the mark's own `color` (parts of speech); where marks overlap,
//     the last one wins.
//   - Strike: a line through the words in the warning colour (a style
//     check's "consider cutting this").
Mark_Kind :: enum u8 { Error, Warning, Info, Highlight, Dim, Tint, Strike }

// mark_recolours says whether a kind changes the colour of the text rather
// than drawing something around it.
@(private)
mark_recolours :: proc "contextless" (k: Mark_Kind) -> bool {
	return k == .Dim || k == .Tint
}

// Submit_Key is which Enter sends a text area's `on_submit`: Ctrl+Enter
// (the default, for a notes field, where Enter breaks the line), or Enter
// itself, with Shift+Enter for the line break — what every chat composer
// does. An input method's Enter always commits its composition instead.
Submit_Key :: enum u8 { Ctrl_Enter, Enter }

Text_Area_State :: struct {
	doc:         ^Document,
	doc_id:      u64, // the document's own name: a new one at the same address is not the one we cached
	submit:      Submit_Key, // which Enter sends
	submit_said: bool,       // …and the description saying so is ours to take back
	paste_other: bool,       // the app takes a paste that brought a picture or files
	paste_prefer: Paste_Prefer, // …and which wins when the clipboard offers both
	max_length:  int,  // 0 = unlimited (characters)
	readonly:    bool,
	wrap:        bool,
	focus_asked: bool, // the builder's `focus` last build: focus is taken when it turns true
	mono:        bool, // the code face, with tab stops
	tab:         u8,   // cells per tab stop (mono)
	marks:       [dynamic]Mark,
	// The marks indexed by block (area_marks_for): `mark_order` holds the
	// ones that stay inside a block or two, packed as first block << 32 |
	// index and sorted, and `mark_long` the few that cover more.
	mark_order:  [dynamic]u64,
	mark_long:   [dynamic]i32,
	mark_scratch: [dynamic]i32,
	marks_rev:   u64, // bumped whenever the list changes
	mark_index_rev: u64,
	marks_recolour: bool, // any Dim or Tint mark at all (area_mark_tints)
	marks_sorted: bool,   // the list is already in document order, so it is its own index
	caret:       Pos,
	anchor:      Pos,
	// The app's view is built again when the caret moves (editor_options
	// follow_caret): for a view that draws something depending on where it
	// is — sentence focus's fade, a status line's line and column. Off, a
	// caret move only repaints, which is what every other editor wants.
	follow_caret: bool,
	caret_built, anchor_built: Pos, // where they were when the view last ran
	goal_x:      f32,  // x kept while moving up/down (-1 = take the caret's)
	size:        f32,
	wrap_w:      f32,  // inner width the lines were measured for
	line_h:      f32,
	placeholder: string, // owned, tree allocator
	ink:         Color,  // what it writes in (zero: the theme's on_surface) — a coloured page needs its own (editor_options)
	min_lines:   int,
	max_lines:   int,
	blink_start: f64,
	was_focused: bool,
	// an input method's composition, shown at the caret and never in the
	// Document (ime.odin): the text, where it sits, the method's cursor
	// inside it, and the caret's block as it is drawn with it in
	pre:         string, // owned, tree allocator
	pre_block:   int,
	pre_off:     int, // source byte of the block it sits at
	pre_lo:      int, // the method's cursor inside `pre`; both -1: hidden
	pre_hi:      int,
	pre_line:    string, // owned; the block's display text with `pre` in it
	pre_runs:    []Run,  // owned; its runs, shifted around `pre`
	// how the document is shown, not what is in it: an installed family, a
	// body size, and a multiplier on the line height
	font:        string, // as the app asked for it (owned, tree allocator)
	family:      Family_Id,
	size_set:    f32, // 0: the theme's body size
	spacing:     f32, // 0 or 1: the face's own line height
	no_frame:    bool, // the editor is the page: no border, no focus colour, square corners
	dragging:    bool,
	clicks:      int,
	last_click_ms:  f64,
	last_click_pos: [2]f32,
	group:       u64, // undo group of the current typing run
	last_edit_ms: f64,
	value_cache: string, // accessible value (owned, tree allocator)
	value_version: u64,
	// block tops (content y of each block, plus the total at the end): O(1)
	// block_top, binary search for hit-testing, and painting only what is
	// in view. It is the running sum of `heights` below, rebuilt whenever
	// one of them changes.
	tops:         [dynamic]f32,
	tops_dirty:   bool,
	tops_valid:   bool, // false = throw the height map away and estimate everything again
	// The height map (see "the height map" below): one height a block,
	// either measured — the block was shaped, because it came into view —
	// or estimated from its length. `hstamps` is the block stamp each
	// height was taken at, which is how an edit keeps the heights of the
	// blocks it did not touch.
	heights:      [dynamic]f32,
	hstamps:      [dynamic]u64,
	hmeasured:    [dynamic]bool,
	himage:       [dynamic]bool, // …and which of them are picture blocks
	image_count:  int,           // how many: zero means area_images_height has nothing to do
	heights_key:  Heights_Key,
	heights_version: u64,
	// one block's byte-to-x table (area_cum), for a painter walking a line
	cum:          [dynamic]f32,
	cum_block:    int,
	cum_stamp:    u64,
	cum_len:      int,
	cum_key:      Heights_Key,
	cum_valid:    bool,
	// whether one block holds right-to-left text, by its stamp: a painter asks per token
	rtl_block:    int,
	rtl_stamp:    u64,
	rtl_known:    bool,
	rtl_has:      bool,
	widest:       f32, // how wide the widest line draws, unwrapped (area_widest)
	widest_version: u64,
	widest_key:   Heights_Key,
	widest_valid: bool,
	adv_cache:    f32, // the average character advance at adv_size (0 = none yet)
	adv_size:     f32,
	adv_family:   Family_Id,
	adv_mono:     bool,
	typed_since_frame: bool, // a typed character already did its reveal this frame; the rest of the run coalesces
	code:         Code_State, // the code editor's extras (widget_code.odin); `on` = this is one
	complete:     Complete_State, // its completion list, if it has been given a source (editor_complete.odin)
	rich:         bool,       // rich text: block kinds and runs shape the layout (widget_rich.odin)
	rich_cache:   map[int]Rich_Cached, // per-block rich layouts, valid for (version, wrap_w)
	rich_state:   Rich_State, // the rich editor's extras
	live:         bool,       // live preview: the blocks are markdown source lines, rendered unless the caret is in them (widget_markdown.odin)
	live_cache:   map[int]Live_Cached,
	line_limit:   int,                    // the most of a line laid out and drawn: 0 the default (AREA_LINE_LIMIT), below 0 none (editor_options)
	capped:       map[int]Capped_Line,    // the lines over it, as shown: their first part and the marker (area_cap)
	live_fence:   [dynamic]bool, // per block: inside a code fence at its start
	fence_stamps: [dynamic]u64,  // …the stamp each was read at, so an edit re-reads only what follows it
	live_fence_version: u64,
	live_lo, live_hi: int,    // the blocks shown raw (the selection's) the layout was made for
	image_blocks: [dynamic]int, // the image blocks, per version: their resolved heights are checked against the tops
	image_blocks_version: u64,
	image_blocks_valid: bool, // …and whether that list has been worked out at all (an empty one is still nil)
	tops_images: f32,         // the image heights the tops were built with
	pressed_pos: [2]f32,      // where the last press landed
	travelled: bool,          // the pointer moved past the click tolerance since the press
	table_cache: map[int]Table_Cached, // column starts per table (keyed by its first block)
	reveal:    Reveal_Request,  // a position an app asked to show (editor_reveal, editor_select), applied once layout has settled
}

// REVEAL_PASSES is how many times a reveal may scroll, measure what it
// landed on and look again before settling for where it is. Two is the
// ordinary case; a jump to the end of a long file takes three.
REVEAL_PASSES :: 4

// Reveal_At is where editor_reveal puts a position in view: with as little
// scrolling as shows it, in the middle, or on the top line (a view put back
// where editor_view said it was).
Reveal_At :: enum u8 {
	Nearest,
	Center,
	Top,
}

@(private)
Reveal_Request :: struct {
	pos:     Pos,
	at:      Reveal_At,
	pending: bool,
}

// Table_Cached: one table's column starts (tree allocator).
Table_Cached :: struct {
	cols:    []f32,
	version: u64,
	wrap_w:  f32,
	size:    f32,
	raw_key: int, // which blocks were raw when measured (live: the pipes' widths differ)
}

// area_table_group is the run of table blocks around `b` (rows and, in the
// live view, the separator line).
@(private)
area_table_group :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> (first, last: int) {
	is_table :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> bool {
		k := area_meta(t, s, b).kind
		return k == .Table || k == .Table_Sep
	}
	first, last = b, b
	for first > 0 && is_table(t, s, first - 1) do first -= 1
	for last + 1 < len(s.doc.blocks) && is_table(t, s, last + 1) do last += 1
	return
}

// area_table_align is how each of the table around `b` has its columns
// set — the same answer the markdown view gives, so a table reads the same
// in a view and in an editor. A live editor keeps the "|---|:--:|" line as
// a block (drawn as the header's underline) and the declaration is read off
// it. A body column that is all figures is set right when the table asked
// for nothing. The frame's memory.
@(private)
area_table_align :: proc(t: ^Tree, s: ^Text_Area_State, b: int, allocator := context.temp_allocator) -> []Table_Align {
	first, last := area_table_group(t, s, b)
	out: []Table_Align
	sep := -1
	for r in first ..= last {
		meta := area_meta(t, s, r)
		// The live view keeps the separator as a source line; a Document
		// keeps what it said on the header row instead (Block.align).
		if meta.kind == .Table_Sep {
			sep = r
			said := table_sep_align(area_text(t, s, r), allocator)
			if len(said) > 0 do out = said
			break
		}
		if meta.kind == .Table && meta.level == 1 && meta.align != 0 {
			n := len(table_cells(area_text(t, s, r)))
			packed := make([]Table_Align, n, allocator)
			for i in 0 ..< n do packed[i] = table_align_get(meta.align, i)
			out = packed
			break
		}
	}
	if out == nil { // no declaration: as many columns as the first row has
		n := 0
		for r in first ..= last {
			if area_meta(t, s, r).kind != .Table do continue
			n = len(table_cells(area_text(t, s, r)))
			break
		}
		if n == 0 do return nil
		out = make([]Table_Align, n, allocator)
	}
	// The body is every row after the first. By position, not `level`: a
	// live editor parses each source line alone, and a Document keeps no
	// separator block, so a header row may not come back marked as one.
	head := -1
	for r in first ..= last do if area_meta(t, s, r).kind == .Table { head = r; break }
	if head < 0 do return nil
	body := max(head + 1, sep + 1)

	for ci in 0 ..< len(out) {
		if out[ci] != .Default do continue
		all_numbers, seen := true, false
		for r in body ..= last {
			if area_meta(t, s, r).kind != .Table do continue
			text := area_text(t, s, r)
			cells := table_cells(text)
			if ci >= len(cells) do continue
			if strings.trim_space(text[cells[ci][0]:cells[ci][1]]) == "" do continue
			seen = true
			one := [1][2]int{cells[ci]}
			if !table_cells_numeric(text, one[:]) {
				all_numbers = false
				break
			}
		}
		if seen && all_numbers do out[ci] = .Right
	}
	return out
}

// area_table_cols measures the table around `b`: each column as wide as
// its widest cell (padded), scaled down to the width when there is one.
@(private)
area_table_cols :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> []f32 {
	if s.table_cache == nil do s.table_cache = make(map[int]Table_Cached, t.allocator)
	first, last := area_table_group(t, s, b)
	c, ok := &s.table_cache[first]
	if ok && c.version == s.doc.version && c.wrap_w == s.wrap_w && c.size == s.size do return c.cols
	widths := make([dynamic]f32, context.temp_allocator)
	mins := make([dynamic]f32, context.temp_allocator)
	for r in first ..= last {
		if area_meta(t, s, r).kind != .Table do continue
		text := area_text(t, s, r)
		base, _, _, _ := area_block_style(t, s, r)
		lay := rich_layout(t, text, area_runs(t, s, r), base, 0, context.temp_allocator)
		for cell, ci in table_cells(text) {
			w := lay.cum[cell[1]] - lay.cum[cell[0]] + TABLE_CELL_PAD * 2
			m := table_cell_min(&lay, text, cell) + TABLE_CELL_PAD * 2
			if ci >= len(widths) {
				append(&widths, w)
				append(&mins, m)
			} else {
				widths[ci] = max(widths[ci], w)
				mins[ci] = max(mins[ci], m)
			}
		}
	}
	for &w in widths do w = max(w, TABLE_CELL_PAD * 2 + s.size)
	for &m, i in mins do m = clamp(m, TABLE_CELL_PAD * 2 + s.size, widths[i])
	// Whole pixels, so a column is never a hair under its own cell:
	// `table_row_layout` recovers a cell's room as `cols[ci+1] - cols[ci] -
	// TABLE_CELL_PAD * 2`, and that f32 round trip can come out a few ULPs
	// under the natural width, wrapping the widest cell. Only the widths:
	// rounding `mins` up would inflate table_fit_cols' floor and tip it into
	// proportional scaling that starves a narrow column.
	for &w in widths do w = math.ceil(w)
	table_fit_cols(widths[:], mins[:], s.wrap_w)
	cols := make([]f32, len(widths) + 1, t.allocator)
	x: f32
	for w, i in widths {
		cols[i] = x
		x += w
	}
	cols[len(widths)] = x
	if ok do delete(c.cols, t.allocator)
	s.table_cache[first] = {cols = cols, version = s.doc.version, wrap_w = s.wrap_w, size = s.size}
	fresh, _ := &s.table_cache[first]
	return fresh.cols
}

// area_raw: whether block `b` shows its source in the live editor (the
// selection touches it).
@(private)
area_raw :: proc(s: ^Text_Area_State, b: int) -> bool {
	if !s.live do return false
	lo, hi := pos_order(s.caret, s.anchor)
	return b >= lo.block && b <= hi.block
}

// Live_Cached is one source line rendered for display (tree allocator).
Live_Cached :: struct {
	line:    Live_Line,
	stamp:   u64, // the block's own stamp, for the reason Rich_Cached gives
	raw:     bool,
}

// Rich_Cached is one block's rich layout, kept until the document or the
// width changes.
Rich_Cached :: struct {
	lay:     Rich_Layout,
	// The block's own stamp, not the document's version: one letter typed
	// bumps the whole document's version, and keying on it would re-lay
	// every block on every keystroke.
	stamp:   u64,
	wrap_w:  f32,
	size:    f32,
	text_len: int, // a live block's display text changes with the caret, not the version
	raw:      bool,
	family:   Family_Id, // the family it was laid out in
}

// Line_Span is one wrapped line of a block: [start, end) bytes and its width.
Line_Span :: struct {
	start, end: int,
	width:      f32,
}

TEXT_AREA_DEFAULT_WIDTH :: f32(320)
TEXT_AREA_GROUP_MS      :: 1000.0

@(private)
text_area_state_destroy :: proc(t: ^Tree, s: ^Text_Area_State) {
	complete_state_destroy(t, &s.complete)
	if len(s.font) > 0 do delete(s.font, t.allocator)
	if len(s.pre) > 0 do delete(s.pre, t.allocator)
	if len(s.pre_line) > 0 do delete(s.pre_line, t.allocator)
	if s.pre_runs != nil do delete(s.pre_runs, t.allocator)
	if len(s.placeholder) > 0 do delete(s.placeholder, t.allocator)
	if len(s.value_cache) > 0 do delete(s.value_cache, t.allocator)
	delete(s.marks)
	delete(s.mark_order)
	delete(s.mark_long)
	delete(s.mark_scratch)
	delete(s.tops)
	delete(s.heights)
	delete(s.hstamps)
	delete(s.hmeasured)
	delete(s.himage)
	delete(s.cum)
	code_state_destroy(t, &s.code)
	for _, &c in s.rich_cache do rich_free(&c.lay, t.allocator)
	delete(s.rich_cache)
	for _, &c in s.live_cache do live_free(&c.line, t.allocator)
	delete(s.live_cache)
	for _, c in s.capped {
		delete(c.text, t.allocator)
		delete(c.runs, t.allocator)
	}
	delete(s.capped)
	for _, &c in s.table_cache do delete(c.cols, t.allocator)
	delete(s.table_cache)
	delete(s.live_fence)
	delete(s.fence_stamps)
	delete(s.image_blocks)
	rich_state_destroy(t, &s.rich_state)
	s^ = {}
}

// ------------------------------------------------------------ live preview sources

@(private)
live_free :: proc(line: ^Live_Line, allocator: runtime.Allocator) {
	for r in line.runs do if len(r.href) > 0 do delete(r.href, allocator)
	delete(line.runs, allocator)
	delete(line.text, allocator)
	delete(line.src, allocator)
	line^ = {}
}

// area_live_fences tracks which blocks sit inside a code fence.
@(private)
area_live_fences :: proc(s: ^Text_Area_State) -> []bool {
	n := len(s.doc.blocks)
	if s.live_fence_version == s.doc.version && len(s.live_fence) == n do return s.live_fence[:]
	// Incremental, like the code editor's tokenizer states: keyed on the
	// document's version it would read every block per keystroke. It starts
	// at the first changed block and stops where the fence state entering a
	// block matches what it was read with — for typing, the next block.
	from := 0
	if len(s.live_fence) == len(s.fence_stamps) && len(s.live_fence) > 0 {
		old := len(s.fence_stamps)
		p, q := stamp_span(s.doc, s.fence_stamps[:], n)
		block_realign(&s.live_fence, old, n, q)
		block_realign(&s.fence_stamps, old, n, q)
		if p >= n {
			s.live_fence_version = s.doc.version
			return s.live_fence[:]
		}
		from = p
	} else {
		resize(&s.live_fence, n)
		resize(&s.fence_stamps, n)
	}
	inside := s.live_fence[from] if from < len(s.live_fence) else false
	for b in from ..< n {
		if b > from && s.fence_stamps[b] == block_stamp(s.doc, b) && s.live_fence[b] == inside do break // the rest reads as it did
		s.live_fence[b] = inside
		s.fence_stamps[b] = block_stamp(s.doc, b)
		if markdown_line(block_str(s.doc, b)).fence do inside = !inside
	}
	s.live_fence_version = s.doc.version
	return s.live_fence[:]
}

// area_live is block `b` as the live editor shows it: raw (marks kept and
// dimmed) while the selection touches it, rendered otherwise.
@(private)
area_live :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> ^Live_Line {
	if s.live_cache == nil do s.live_cache = make(map[int]Live_Cached, t.allocator)
	raw := area_raw(s, b)
	c, ok := &s.live_cache[b]
	if ok && c.stamp == block_stamp(s.doc, b) && c.raw == raw do return &c.line
	fences := area_live_fences(s)
	line := markdown_render_line(block_str(s.doc, b), fences[b], raw, t.allocator)
	if ok do live_free(&c.line, t.allocator)
	s.live_cache[b] = {line = line, stamp = block_stamp(s.doc, b), raw = raw}
	fresh, _ := &s.live_cache[b]
	return &fresh.line
}

// AREA_LINE_LIMIT is how much of one line an editor lays out and draws, in
// bytes, unless the app says otherwise (`editor_options(line_limit = …)`).
// Laying a line out costs about 650 bytes a character, so a line of
// millions (a minified script, an inlined base64 picture) would cost
// gigabytes. Past the limit a marker says how much more there is; the
// document keeps the whole line, so copy, save and find see all of it.
AREA_LINE_LIMIT :: 10_000

// Capped_Line is a line over the limit as it is shown: its first `cut`
// bytes and the marker after them, kept until the line changes (the draw
// list holds the string past the frame).
@(private)
Capped_Line :: struct {
	stamp: u64,
	limit: int,
	cut:   int,
	text:  string, // owned
	runs:  []Run,  // a rich editor's runs for it: the block's own up to the cut, then the marker dimmed (owned slice; the hrefs are the document's)
}

// area_line_limit is the limit in force: the app's, or the default.
@(private)
area_line_limit :: proc "contextless" (s: ^Text_Area_State) -> int {
	if s.line_limit < 0 do return 0
	return s.line_limit if s.line_limit > 0 else AREA_LINE_LIMIT
}

// area_cap is block `b` as shown when it runs past the limit: the text up
// to a character boundary at the limit, then the marker; `cut` is where
// the marker starts. `capped` is false for a line within it.
//
// Every kind of editor is capped. A live-markdown editor shows a capped
// block as source, since rendering it would lay all of it out; a rich
// editor keeps the block's styles up to the cut. The marker is dimmed as a
// markdown mark is.
@(private)
area_cap :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> (shown: string, cut: int, capped: bool) {
	if s.doc == nil || b < 0 || b >= len(s.doc.blocks) do return
	limit := area_line_limit(s)
	src := block_str(s.doc, b)
	if limit <= 0 || len(src) <= limit do return
	stamp := block_stamp(s.doc, b)
	if s.capped == nil do s.capped = make(map[int]Capped_Line, t.allocator)
	if c, has := s.capped[b]; has && c.stamp == stamp && c.limit == limit do return c.text, c.cut, true
	cut = limit
	for cut > 0 && src[cut] & 0xC0 == 0x80 do cut -= 1 // not inside a character
	more := strings.rune_count(src[cut:])
	digits := fmt.tprintf("%d", more)
	if sep := t.locale.thousands; sep != "" && len(digits) > 3 { // the desktop's own grouping: 11,869,609
		b := strings.builder_make(context.temp_allocator)
		for ch, i in digits {
			if i > 0 && (len(digits) - i) % 3 == 0 do strings.write_string(&b, sep)
			strings.write_rune(&b, ch)
		}
		digits = strings.to_string(b)
	}
	text := strings.concatenate({src[:cut], "  … ", digits, " more characters not shown"}, t.allocator)
	runs: []Run
	if s.rich { // the block's styles up to the cut (none for markdown source), then the marker, dimmed
		out := make([dynamic]Run, 0, len(s.doc.blocks[b].runs) + 2, t.allocator)
		if !s.live do for r in s.doc.blocks[b].runs {
			if r.end >= cut {
				rr := r
				rr.end = cut
				append(&out, rr)
				break
			}
			append(&out, r)
		}
		if len(out) == 0 || out[len(out) - 1].end < cut do append(&out, Run{end = cut})
		append(&out, Run{end = len(text), attrs = {.Mark, .Italic}})
		runs = out[:]
	}
	if old, has := s.capped[b]; has {
		delete(old.text, t.allocator)
		delete(old.runs, t.allocator)
	}
	s.capped[b] = {stamp = stamp, limit = limit, cut = cut, text = text, runs = runs}
	return text, cut, true
}

// area_text is what block `b` shows: its text, or its rendered line, with
// an input method's composition in it where the caret is.
@(private)
area_text :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> string {
	if len(s.pre) > 0 && b == s.pre_block do return s.pre_line
	return area_shown(t, s, b)
}

// area_shown is the block's text as it is without any composition.
@(private)
area_shown :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> string {
	if shown, _, capped := area_cap(t, s, b); capped do return shown // a line past the limit: its first part and the marker, never rendered
	if s.live && s.doc != nil do return area_live(t, s, b).text
	return block_str(s.doc, b)
}

// area_pre_disp is the display byte a composition sits at, in its block.
@(private)
area_pre_disp :: proc(t: ^Tree, s: ^Text_Area_State) -> int {
	return to_disp_plain(t, s, s.pre_block, s.pre_off)
}

// area_preedit_sync rebuilds the caret block's drawn line and runs when the
// composition, the caret or the text moved. Called from the builder and
// whenever the preedit changes.
@(private)
area_preedit_sync :: proc(t: ^Tree, n: Node, s: ^Text_Area_State) {
	changed := ime_keep(t, n, &s.pre, &s.pre_lo, &s.pre_hi)
	if len(s.pre) == 0 {
		if len(s.pre_line) > 0 {
			delete(s.pre_line, t.allocator)
			s.pre_line = ""
		}
		if s.pre_runs != nil {
			delete(s.pre_runs, t.allocator)
			s.pre_runs = nil
		}
		if changed {
			s.tops_valid = false
			mark_layout_dirty(t, n)
		}
		return
	}
	if s.pre_block != s.caret.block || s.pre_off != s.caret.off do changed = true
	s.pre_block, s.pre_off = s.caret.block, s.caret.off
	shown := area_shown(t, s, s.pre_block)
	at := clamp(to_disp_plain(t, s, s.pre_block, s.pre_off), 0, len(shown))
	line := strings.concatenate({shown[:at], s.pre, shown[at:]}, context.temp_allocator)
	if line != s.pre_line {
		if len(s.pre_line) > 0 do delete(s.pre_line, t.allocator)
		s.pre_line = strings.clone(line, t.allocator)
		changed = true
	}
	if s.pre_runs != nil {
		delete(s.pre_runs, t.allocator)
		s.pre_runs = nil
	}
	if runs := area_runs_plain(t, s, s.pre_block); len(runs) > 0 {
		out := make([dynamic]Run, 0, len(runs) + 2, t.allocator)
		start := 0
		for r in runs {
			if r.end <= at {
				append(&out, r)
			} else if start >= at {
				rr := r
				rr.end += len(s.pre)
				append(&out, rr)
			} else { // the run the composition falls inside: split it around
				head := r
				head.end = at
				append(&out, head)
				tail := r
				tail.end = r.end + len(s.pre)
				append(&out, tail)
			}
			start = r.end
		}
		s.pre_runs = out[:]
	}
	if changed {
		s.tops_valid = false
		mark_layout_dirty(t, n)
		mark_paint_dirty(t, n)
	}
}

// area_meta is block `b`'s kind as shown.
@(private)
area_meta :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> Block_Meta {
	if _, _, capped := area_cap(t, s, b); capped && s.live do return {} // shown as source: a plain paragraph, not a heading or a picture
	if s.live && s.doc != nil do return area_live(t, s, b).meta
	return block_meta(s.doc, b)
}

// area_runs is block `b`'s runs as shown, the composition's block included.
@(private)
area_runs :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> []Run {
	if len(s.pre) > 0 && b == s.pre_block && s.pre_runs != nil do return s.pre_runs
	return area_runs_plain(t, s, b)
}

@(private)
area_runs_plain :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> []Run {
	if _, _, capped := area_cap(t, s, b); capped do return s.capped[b].runs // nil outside a rich editor
	if s.live && s.doc != nil do return area_live(t, s, b).runs
	if s.doc == nil || b < 0 || b >= len(s.doc.blocks) do return nil
	return s.doc.blocks[b].runs[:]
}

// to_disp maps a source byte of block `b` to its display byte (the same,
// unless the block is rendered without its marks).
@(private)
to_disp :: proc(t: ^Tree, s: ^Text_Area_State, b: int, off: int) -> int {
	disp := to_disp_plain(t, s, b, off)
	if len(s.pre) > 0 && b == s.pre_block && off > s.pre_off do disp += len(s.pre)
	return disp
}

@(private)
to_disp_plain :: proc(t: ^Tree, s: ^Text_Area_State, b: int, off: int) -> int {
	// past a line's limit nothing is shown: a place there is after the marker
	if shown, cut, capped := area_cap(t, s, b); capped do return off if off <= cut else len(shown)
	if !s.live || s.doc == nil do return off
	l := area_live(t, s, b)
	// the first display byte whose source is at or past `off`
	lo, hi := 0, len(l.src) - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if l.src[mid] < off { lo = mid + 1 } else { hi = mid }
	}
	return lo
}

// to_src maps a display byte back to the source byte.
@(private)
to_src :: proc(t: ^Tree, s: ^Text_Area_State, b: int, disp: int) -> int {
	disp := disp
	if len(s.pre) > 0 && b == s.pre_block { // inside the composition: the caret's own offset
		at := area_pre_disp(t, s)
		if disp > at && disp < at + len(s.pre) do return s.pre_off
		if disp >= at + len(s.pre) do disp -= len(s.pre)
	}
	return to_src_plain(t, s, b, disp)
}

@(private)
to_src_plain :: proc(t: ^Tree, s: ^Text_Area_State, b: int, disp: int) -> int {
	// on the marker or after it: the end of the line, which is what it stands for
	if _, cut, capped := area_cap(t, s, b); capped do return disp if disp <= cut else len(block_str(s.doc, b))
	if !s.live || s.doc == nil do return disp
	l := area_live(t, s, b)
	if len(l.src) == 0 do return disp
	return l.src[clamp(disp, 0, len(l.src) - 1)]
}

text_area :: proc(ui: ^Ui($Msg), doc: ^Document, placeholder: string = "", on_change: Handler(Msg, int) = nil,
	on_submit: Handler(Msg, int) = nil, on_context: Handler(Msg, Editor_Context) = nil, label: string = "", width: f32 = 0,
	height: f32 = 0, flex: f32 = 0, disabled := false, focus := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	return area_build(ui, doc, placeholder, on_change, on_submit, on_context, label, width, height, flex, disabled, tag, key, loc,
		mono = false, def_wrap = true, def_min_lines = 3, focus = focus)
}

// editor_options sets how an editor built as `n` (a text area, code
// editor or rich editor — the node the builder returned) behaves. Each
// setting stays until changed, so pass only what you mean:
//
//	ed := baldr.code_editor(ui, &s.src, &baldr.LANG_ODIN, on_change, flex = 1)
//	baldr.editor_options(ui, ed, wrap = true, whitespace = true, tab_width = 2, spaces = true)
//
// `wrap` soft-wraps lines (a text area's and rich editor's default; a code
// editor scrolls sideways), `readonly` allows navigation and copying but
// no edits, `min_lines` / `max_lines` bound the height when none is
// given (0 = unbounded), `max_length` caps the characters (0 = unlimited),
// `invalid` / `required` colour the border and set the accessibility
// states; for code editors `line_numbers`, `tab_width`, `spaces` (indent
// with spaces), `whitespace` (show it) and `ligatures` (off by default:
// "->" stays two glyphs); for rich editors `toolbar`.
//
// `frame = false` is for an editor that fills a window: no border, no focus
// colour, square corners and no fill, so the page does not look like a form
// field (the caret says where focus is).
//
// `on_paste_other` is for a composer that takes more than text: Ctrl+V (or
// the menu's Paste) with a picture or files and no text on the clipboard
// sends it `Paste_Other`, so a pasted screenshot can become an attachment.
// A paste that brought text is untouched.
//
// `line_limit` is how much of one line is laid out and drawn, in bytes:
// AREA_LINE_LIMIT unless set, 0 for no limit. Past it a muted marker says
// how many more characters there are, and the document keeps them all; a
// live-markdown editor shows such a line as its source.
//
// How the document is shown, rather than what is in it:
// `font` is an installed family (installed_fonts lists them; the
// toolkit's own fonts stay behind it for anything the family lacks, and
// editor_font says whether it was found), `size` the body size in logical
// px that the editor's other sizes scale from, and `line_spacing` a
// multiplier on the line height (1.5 for double-spaced prose). A change
// re-lays the document; the caret, the selection and the view stay where
// they are. "" and 0 go back to the theme's font and size.
editor_options :: proc(ui: ^Ui($Msg), n: Node, wrap: Maybe(bool) = nil, readonly: Maybe(bool) = nil, submit: Maybe(Submit_Key) = nil,
	min_lines: Maybe(int) = nil, max_lines: Maybe(int) = nil, max_length: Maybe(int) = nil,
	line_numbers: Maybe(bool) = nil,
	tab_width: Maybe(int) = nil, spaces: Maybe(bool) = nil, whitespace: Maybe(bool) = nil, ligatures: Maybe(bool) = nil, toolbar: Maybe(bool) = nil,
	font: Maybe(string) = nil, size: Maybe(f32) = nil, line_spacing: Maybe(f32) = nil, frame: Maybe(bool) = nil,
	ink: Maybe(Color) = nil, on_paste_other: Handler(Msg, Paste_Other) = nil,
	paste_prefer: Maybe(Paste_Prefer) = nil,
	follow_caret: Maybe(bool) = nil, line_limit: Maybe(int) = nil) {
	t := &ui.tree
	area := n
	if a, has := t.area_of_frame[n]; has do area = a
	if s := &t.areas[area]; s != nil {
		if v, ok := follow_caret.?; ok do s.follow_caret = v
	}
	s := &t.areas[area]
	d := node_get(t, area)
	if s == nil || d == nil do return
	if handler_live(on_paste_other) { ui.paste_others[area] = on_paste_other } else { delete_key(&ui.paste_others, area) }
	s.paste_other = handler_live(on_paste_other) // so the menu offers Paste for a picture, as Ctrl+V takes one — and offers it only when something will come of it (handler_live)
	if v, ok := paste_prefer.?; ok do s.paste_prefer = v
	changed := false
	if v, ok := wrap.?; ok && s.wrap != v { s.wrap = v; changed = true }
	if v, ok := readonly.?; ok do s.readonly = v
	if v, ok := submit.?; ok && s.submit != v { // and say so, for a reader: the key that sends is not guessable
		s.submit = v
		if v == .Enter {
			set_describe(t, area, "Enter to send, Shift+Enter for a new line")
			s.submit_said = true
		} else if s.submit_said {
			set_describe(t, area, "")
			s.submit_said = false
		}
	}
	if v, ok := min_lines.?; ok && s.min_lines != max(v, 1) { s.min_lines = max(v, 1); changed = true }
	if v, ok := max_lines.?; ok && s.max_lines != v { s.max_lines = v; changed = true }
	if v, ok := max_length.?; ok do s.max_length = v
	if v, ok := line_limit.?; ok {
		want := v if v > 0 else -1 // 0 lifts it
		if s.line_limit != want {
			s.line_limit = want
			s.tops_valid = false
			s.widest_valid = false
			changed = true
		}
	}
	if v, ok := ink.?; ok && s.ink != v { // a note's dark ink on its yellow paper: the caret and selection follow it
		s.ink = v
		mark_paint_dirty(t, area)
	}
	if v, ok := font.?; ok && v != s.font {
		if len(s.font) > 0 do delete(s.font, t.allocator)
		s.font = strings.clone(v, t.allocator)
		area_family_sync(t, area, s)
		changed = true
	}
	if v, ok := size.?; ok && s.size_set != v {
		s.size_set = max(v, 0)
		s.size = s.size_set * tree_text_scale(t) if s.size_set > 0 else t.theme.type.body.size
		s.tops_valid = false
		changed = true
	}
	if v, ok := line_spacing.?; ok && s.spacing != v {
		s.spacing = v
		s.tops_valid = false
		changed = true
	}
	if v, ok := frame.?; ok && s.no_frame != !v {
		s.no_frame = !v
		st := d.style
		st.bg = {} if s.no_frame else t.theme.color.surface_variant
		st.radius = 0 if s.no_frame else t.theme.radius.md
		set_style(t, area, st)
		mark_paint_dirty(t, area)
	}
	if s.code.on {
		c := &s.code
		if v, ok := line_numbers.?; ok && c.gutter != v { c.gutter = v; changed = true }
		if v, ok := tab_width.?; ok && c.tab_width != max(v, 1) { c.tab_width = max(v, 1); s.tab = u8(c.tab_width); s.tops_valid = false; changed = true }
		if v, ok := spaces.?; ok do c.spaces = v
		if v, ok := whitespace.?; ok && c.show_ws != v { c.show_ws = v; mark_paint_dirty(t, area) }
		if v, ok := ligatures.?; ok && c.ligatures != v { c.ligatures = v; s.tops_valid = false; changed = true }
	}
	if s.rich {
		if v, ok := toolbar.?; ok && s.rich_state.toolbar != v { s.rich_state.toolbar = v; ask_rebuild(ui) }
	}
	area_apply_flags(t, area, d, s)
	if changed {
		// The cap reaches layout through the node's max_h, and these settings
		// arrive after the builder's set_layout. `changed` only marks layout
		// dirty, not a rebuild, so the new cap is written into the node here.
		if d != nil do d.layout.max_h = area_max_h(t, s)
		mark_layout_dirty(t, area)
	}
}

// area_spacing is the multiplier on the line height an app set (1 by default).
@(private)
area_spacing :: proc(s: ^Text_Area_State) -> f32 {
	return clamp(s.spacing, 0.5, 4) if s.spacing > 0 else 1
}

// area_family_sync loads the family an app asked for, once, and re-lays the
// editor when what it draws with changes.
@(private)
area_family_sync :: proc(t: ^Tree, n: Node, s: ^Text_Area_State) {
	want := Family_Id(0)
	if len(s.font) > 0 && t.text != nil do want = text_family(t.text, s.font)
	if want == s.family do return
	s.family = want
	s.tops_valid = false
	mark_layout_dirty(t, n)
}

// editor_control counts `n` — a field or button of the app's own — as part
// of the editor built as `editor`, the way an editor's built-in find bar is
// part of it: while focus is in `n`, the editor keeps showing its selection,
// so an app's own find bar can select each match and have it look selected.
// It stays until the node goes; pass NODE_NONE as `editor` to undo it.
editor_control :: proc(ui: ^Ui($Msg), n: Node, editor: Node) {
	t := &ui.tree
	if node_get(t, n) == nil do return
	area, s := editor_area(t, editor)
	if s == nil {
		delete_key(&t.editor_owned, n)
		return
	}
	if t.editor_owned[n] == area do return
	t.editor_owned[n] = area
	mark_paint_dirty(t, area)
}

// editor_font is the family an editor built as `n` draws its document in:
// the name as this machine has it, and whether the family the app asked for
// was found; the name aliases the text engine's own storage. An app that
// saved "EB Garamond" with a document can tell the
// reader it is not installed any more instead of quietly drawing something
// else. "" with `installed` false means it draws in the theme's own font.
editor_font :: proc(t: ^Tree, n: Node) -> (family: string, installed: bool) {
	_, s := editor_area(t, n)
	if s == nil || t.text == nil do return
	if len(s.font) == 0 do return "", true // it asked for nothing: the theme's font is what it wanted
	return text_family_name(t.text, s.family), text_family_ok(t.text, s.family)
}

// editor_select sets the selection of a text area, code editor, rich or
// markdown editor built as `n` (its frame or the area), from `anchor` to
// `caret` — just the caret when they are the same: an outline jumping to a
// heading, find selecting its current match, the caret put after text an app
// replaced. Positions are clamped to its Document, the column
// Up and Down keep is reset as a click resets it, and the caret is kept in
// view once the editor is laid out. editor_caret reads it back.
editor_select :: proc(ui: ^Ui($Msg), n: Node, anchor, caret: Pos) {
	t := &ui.tree
	area, s := editor_area(t, n)
	if s == nil do return
	s.anchor = pos_clamp(s.doc, anchor)
	area_move(t, area, s, caret, extend = true)
	editor_reveal_request(t, area, s, s.caret, .Nearest)
}

// editor_reveal scrolls the editor built as `n` so that `pos` is in view:
// with as little movement as that takes (`.Nearest`), in the middle
// (`.Center`: a heading jumped to, a match found), or on the top line
// (`.Top`: where editor_view said the view was, put back when a file is
// reopened). It waits for the editor's layout, so it can be called straight
// after building it or editing its Document; the last call before that
// layout is the one that counts. Positions are clamped to the Document.
editor_reveal :: proc(ui: ^Ui($Msg), n: Node, pos: Pos, at: Reveal_At = .Nearest) {
	t := &ui.tree
	area, s := editor_area(t, n)
	if s == nil do return
	editor_reveal_request(t, area, s, pos_clamp(s.doc, pos), at)
}

// editor_caret reads the caret of the editor built as `n`, and the end it
// was dragged or shifted from (`anchor == caret` when nothing is selected).
// Not ok for a node that is not an editor. It reads what `editor_select`
// writes, in the same order; `editor_selection` gives the range ordered
// instead. Use this one when the direction matters: sentence focus, a
// status bar's line and column. Pair it with
// `editor_options(follow_caret = true)` to be rebuilt when the caret moves,
// since a caret move alone only repaints.
editor_caret :: proc(t: ^Tree, n: Node) -> (caret, anchor: Pos, ok: bool) {
	_, s := editor_area(t, n)
	if s == nil do return
	return s.caret, s.anchor, true
}

// editor_view is where the editor built as `n` is scrolled to: the first
// position on the line at the top of its view, for editor_reveal(…, .Top)
// to put the view back later. Not ok for an editor not laid out yet.
editor_view :: proc(t: ^Tree, n: Node) -> (top: Pos, ok: bool) {
	area, s := editor_area(t, n)
	if s == nil || s.line_h <= 0 do return
	st, has := t.scrolls[area]
	if !has do return
	b := block_at_y(t, s, st.offset.y)
	spans := block_spans(t, s, b)
	line := 0
	if lh := area_line_h(t, s, b); lh > 0 && len(spans) > 0 {
		line = clamp(int((st.offset.y - block_text_top(t, s, b)) / lh + 0.001), 0, len(spans) - 1)
	}
	off := to_src(t, s, b, spans[line].start) if len(spans) > 0 else 0
	return Pos{b, off}, true
}

// Editor_Context is what an editor's `on_context` carries: the
// Document position a right-click landed on (the caret, for the Menu key or
// Shift+F10), whether that is inside the selection, and where to open the
// menu, in window coordinates: under the pointer, or under the caret.
// Ui.context_pos is set to `at` first, so context_menu opens there. A
// right-click outside the selection has already moved the caret to `pos`;
// inside it the selection stays, for Cut and Copy.
Editor_Context :: struct {
	pos:          Pos,
	in_selection: bool,
	at:           [2]f32,
}

// Editor_Action is what an app's menu asks an editor to do: what Ctrl+X,
// Ctrl+C, Ctrl+V, Ctrl+A, Ctrl+Z and Ctrl+Shift+Z (or Ctrl+Y) do.
Editor_Action :: enum u8 {
	Cut, Copy, Paste, Select_All, Undo, Redo,
}

// Editor_Actions is a set of Editor_Action: what editor_actions says an
// editor can do now.
Editor_Actions :: bit_set[Editor_Action; u8]

// editor_action does `action` in the editor built as `n` (its frame or the
// area) exactly as its shortcut does: the same clipboard, the same undo
// steps, the caret and the view following. Focus stays where it is. False
// when there was nothing to do: no selection to cut or copy, no text on the
// clipboard, no step to undo or redo, an empty Document to select, a
// readonly editor asked to cut, paste, undo or redo, a disabled editor.
editor_action :: proc(ui: ^Ui($Msg), n: Node, action: Editor_Action) -> bool {
	area, s := editor_area(&ui.tree, n)
	d := node_get(&ui.tree, area)
	if s == nil || d == nil || .Disabled in d.flags do return false
	return area_action(ui, area, s, action)
}

// editor_actions is what editor_action can do in the editor built as `n`
// now, to grey a menu's items: Cut and Copy need a selection, Paste text on
// the clipboard, Select All some text, Undo and Redo a step to take; Cut,
// Paste, Undo and Redo an editor that is not readonly. Empty for a disabled
// editor or a node that is none.
editor_actions :: proc(t: ^Tree, n: Node) -> (can: Editor_Actions) {
	area, s := editor_area(t, n)
	d := node_get(t, area)
	if s == nil || d == nil || .Disabled in d.flags do return
	lo, hi := pos_order(s.caret, s.anchor)
	if lo != hi && t.clipboard.set != nil do can += s.readonly ? {.Copy} : {.Cut, .Copy}
	if document_end(s.doc) != (Pos{}) do can += {.Select_All}
	if s.readonly do return
	if clipboard_has_text(t) do can += {.Paste}
	else if s.paste_other { if _, any := clip_other(t); any do can += {.Paste} } // a picture or files the app takes
	if len(s.doc.undo) > 0 do can += {.Undo}
	if len(s.doc.redo) > 0 do can += {.Redo}
	return
}

// clipboard_has_text: whether a paste would find text. A clipboard that
// cannot say what it holds is tried.
@(private)
clipboard_has_text :: proc(t: ^Tree) -> bool {
	c := t.clipboard
	if c.get == nil do return false
	if c.types == nil do return true
	for m in c.types(c.user, context.temp_allocator) {
		if strings.has_prefix(m, MIME_TEXT) || m == "UTF8_STRING" || m == "TEXT" || m == "STRING" do return true
	}
	return false
}

// editor_area is the area of an editor built as `n` (its frame or the area
// itself) and its state, nil when `n` is no editor with a Document.
@(private)
editor_area :: proc(t: ^Tree, n: Node) -> (area: Node, s: ^Text_Area_State) {
	area = n
	if a, has := t.area_of_frame[n]; has do area = a
	s = &t.areas[area]
	if s != nil && s.doc == nil do s = nil
	return
}

@(private)
editor_reveal_request :: proc(t: ^Tree, area: Node, s: ^Text_Area_State, pos: Pos, at: Reveal_At) {
	s.reveal = {pos = pos, at = at, pending = true}
	mark_layout_dirty(t, area)
}

// area_reveal_to scrolls `st` so that `p` is in view, and settles: a
// position's y depends on estimated heights above the view, and measuring
// what the scroll lands on moves the target. It scrolls, measures, and
// looks again until nothing moves — two passes for an ordinary move, three
// for a jump to the end of a long file. One pass from estimates can land
// hundreds of px short.
@(private)
area_reveal_to :: proc(t: ^Tree, s: ^Text_Area_State, st: ^Scroll_State, p: Pos, at: Reveal_At) -> (moved: bool) {
	if s.doc == nil || s.line_h <= 0 || st.viewport.y <= 0 do return false
	was := st.offset
	for _ in 0 ..< REVEAL_PASSES {
		area_measure_block(t, s, p.block) // where it lands is never a guess
		line, _, cx := caret_line(t, s, p)
		lh := area_line_h(t, s, p.block)
		cy := block_text_top(t, s, p.block) + f32(line) * lh
		cx += block_indent(t, s, p.block)
		before := st.offset
		switch at {
		case .Nearest:
			if cy < st.offset.y {
				st.offset.y = cy
			} else if cy + lh > st.offset.y + st.viewport.y {
				st.offset.y = cy + lh - st.viewport.y
			}
		case .Center:
			st.offset.y = cy + lh / 2 - st.viewport.y / 2
		case .Top:
			st.offset.y = cy
		}
		if !s.wrap { // a long line: bring its column in too
			if cx < st.offset.x {
				st.offset.x = max(cx - 24, 0)
			} else if cx + 2 > st.offset.x + st.viewport.x {
				st.offset.x = cx + 24 - st.viewport.x
			}
		}
		st.content.y = content_height(t, s)
		st.offset = scroll_clamp(st^, st.offset)
		// …and what it is now looking at, measured for real
		area_measure_range(t, s, st.offset.y, st.offset.y + st.viewport.y)
		st.content.y = content_height(t, s)
		st.offset = scroll_clamp(st^, st.offset)
		if st.offset == before do break // nothing moved: this is where it goes
	}
	return st.offset != was
}

// area_reveals scrolls each editor an app asked to show a position in, once
// layout has given it its final width and its lines their heights. One not
// laid out yet (hidden, say) keeps its request for the next layout.
@(private)
area_reveals :: proc(t: ^Tree) {
	for area, &s in t.areas {
		s.typed_since_frame = false // a new frame: the next character does its own reveal
		if !s.reveal.pending || s.doc == nil do continue
		st, has := &t.scrolls[area]
		if !has || s.line_h <= 0 || st.viewport.y <= 0 do continue
		s.reveal.pending = false
		if area_reveal_to(t, &s, st, pos_clamp(s.doc, s.reveal.pos), s.reveal.at) do mark_paint_dirty(t, area)
	}
}

// editor_marks decorates ranges of an editor's document for this build:
// squiggles, underlines and highlights from a spell checker, a search or
// a linter (see Mark). Pass the current list every build.
editor_marks :: proc(ui: ^Ui($Msg), n: Node, marks: []Mark, loc := #caller_location) {
	t := &ui.tree
	area := n
	if a, has := t.area_of_frame[n]; has do area = a
	s := &t.areas[area]
	if s == nil do return
	append(&s.marks, ..marks)
	s.marks_rev += 1
	mark_paint_dirty(t, area)
	area_mark_tip(ui, area, s, loc)
}

// area_apply_flags derives the node's flags and accessibility states
// from the area's settings.
@(private)
area_apply_flags :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Area_State) {
	if s.wrap { d.flags -= {.Scroll_H} } else { d.flags += {.Scroll_H} }
	if s.readonly { d.access.states += {.Readonly} } else { d.access.states -= {.Readonly} }
	mark_paint_dirty(t, n)
}

// area_build is the shared builder behind text_area, code_editor and
// rich_text; `def_*` are the settings a fresh one starts with.
@(private)
area_build :: proc(ui: ^Ui($Msg), doc: ^Document, placeholder: string, on_change: Handler(Msg, int),
	on_submit: Handler(Msg, int), on_context: Handler(Msg, Editor_Context), label: string, width, height, flex: f32, disabled: bool, tag, key: u64,
	loc: runtime.Source_Code_Location, mono: bool, def_wrap: bool, def_min_lines: int, focus := false) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	if created {
		d.access.role = .Text_Input
		d.access.states += {.Focusable}
		d.flags += {.Focusable, .Clips, .Scroll_V}
		d.kind = Custom_Kind{paint = paint_text_area, measure = measure_text_area}
		t.areas[n] = {goal_x = -1, wrap = def_wrap, mono = mono, min_lines = max(def_min_lines, 1)}
		t.scrolls[n] = scroll_state_new()
		mark_layout_dirty(t, n)
	}
	s := &t.areas[n]
	if s.marks == nil do s.marks = make([dynamic]Mark, t.allocator)
	clear(&s.marks) // editor_marks appends this build's
	s.marks_rev += 1
	if s.mono != mono {
		s.mono = mono
		mark_layout_dirty(t, n)
	}
	area_apply_flags(t, n, d, s)
	if doc != nil do document_ensure(doc)
	if s.doc != doc || s.doc_id != (doc.id if doc != nil else 0) do area_doc_changed(t, s) // a different document, even at the same address
	s.doc = doc
	s.doc_id = doc.id if doc != nil else 0
	// the theme's body size already has the desktop's text size in it; a size the app set takes it here
	if size_now := s.size_set * tree_text_scale(t) if s.size_set > 0 else th.type.body.size; s.size != size_now {
		s.size = size_now // a theme change, or the desktop's text size: the lines are re-measured
		s.line_h = area_line_height(t, s)
		s.tops_valid = false
		mark_layout_dirty(t, n)
	}
	area_family_sync(t, n, s)
	if s.placeholder != placeholder {
		if len(s.placeholder) > 0 do delete(s.placeholder, t.allocator)
		s.placeholder = strings.clone(placeholder, t.allocator)
	}
	if doc != nil {
		s.caret = pos_clamp(doc, s.caret)
		s.anchor = pos_clamp(doc, s.anchor)
		if s.value_version != doc.version || len(s.value_cache) == 0 {
			if len(s.value_cache) > 0 do delete(s.value_cache, t.allocator)
			s.value_cache = document_text(doc, t.allocator)
			s.value_version = doc.version
			mark_layout_dirty(t, n)
		}
		d.access.value_text = s.value_cache
		d.access.has_value = true
	}
	d.tag = tag
	set_name(t, n, label if label != "" else placeholder)
	set_disabled(t, n, disabled)
	set_layout(t, n, Layout_Props{width = width, height = height, flex = flex, max_h = area_max_h(t, s),
		padding = {th.space[.sm], th.space[.md], th.space[.sm], th.space[.md]}})
	st := d.style
	st.bg = {} if s.no_frame else th.color.surface_variant // the page's own background shows through
	st.radius = 0 if s.no_frame else th.radius.md
	set_style(t, n, st)
	area_preedit_sync(t, n, s) // an input method's composition, in the drawn line only
	ui.on_int[n] = on_change
	ui.on_activate[n] = on_submit
	if handler_live(on_context) { ui.editor_contexts[n] = on_context } else { delete_key(&ui.editor_contexts, n) }
	mark_paint_dirty(t, n) // marks and states may have changed
	if focus && !s.focus_asked && !disabled { // it turned true: a chat opened, Reply was pressed
		// The caret goes to the end with nothing selected, unlike
		// `text_input`: an editor holds a draft being continued, and a
		// selection would let the next keystroke delete it.
		s.caret = document_end(doc)
		s.anchor = s.caret
		ui.pending_focus = n
	}
	s.focus_asked = focus
	s.caret_built, s.anchor_built = s.caret, s.anchor // this build saw these (follow_caret)
	// Its completion list, if one is open (editor_complete.odin). A code
	// editor builds its own inside its frame, under the find bar, so this
	// is for the plain editors.
	if s.complete.open && !s.code.on && !disabled && !s.readonly do complete_build(ui, n, s, loc)
	return n
}

// area_doc_changed drops everything cached about the document the area was
// showing. These caches are keyed by `version`, and a new document can have
// the same version (and even the same address) as the one it replaced, so
// matching versions mean nothing once the document itself changes.
@(private)
area_doc_changed :: proc(t: ^Tree, s: ^Text_Area_State) {
	s.tops_valid = false // the height map goes with it: its stamps name blocks of a document that is gone
	s.heights_version, s.tops_images = 0, 0
	s.value_version = 0
	s.live_fence_version = 0
	s.image_blocks_version, s.image_blocks_valid = 0, false
	// …and the layouts are freed, not just dropped: clearing the maps alone
	// would leak every cached layout of the old document.
	for _, &c in s.rich_cache do rich_free(&c.lay, t.allocator)
	clear(&s.rich_cache)
	for _, &c in s.live_cache do live_free(&c.line, t.allocator)
	clear(&s.live_cache)
	for _, &c in s.table_cache do delete(c.cols, t.allocator)
	clear(&s.table_cache)
	clear(&s.live_fence)
	clear(&s.image_blocks)
	s.live_lo, s.live_hi = 0, 0
}

// area_mark_tip shows the message of the mark the pointer rests on, in a
// tooltip under that line (called once the build's marks are in).
@(private)
area_mark_tip :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil || ui.tip_anchor != n || ui.tip_mark < 0 || ui.tip_mark >= len(s.marks) || len(s.marks[ui.tip_mark].message) == 0 do return
	m := s.marks[ui.tip_mark]
	lo, _ := pos_order(m.from, m.to)
	line, _, x := caret_line(t, s, lo)
	scroll := scroll_offset(t, n)
	inner := input_inner(d)
	lh := area_line_h(t, s, lo.block)
	at := [2]f32{inner.x + area_text_x(s) - scroll.x + block_indent(t, s, lo.block) + x, inner.y - scroll.y + block_text_top(t, s, lo.block) + f32(line + 1) * lh + 2}
	// Flipping above the mark near the window's foot must clear the marked
	// line as well, or the tip covers the word it is about.
	tooltip_show(ui, n, m.message, loc, at = at, fixed = true, at_avoid = lh + 4)
}

// area_mark_at is the index of a mark with a message under `pos` (-1: none).
@(private)
area_mark_at :: proc(t: ^Tree, n: Node, s: ^Text_Area_State, pos: [2]f32) -> int {
	d := node_get(t, n)
	if d == nil || s.doc == nil || !rect_contains(input_inner(d), pos) do return -1
	p := area_hit(t, n, d, s, pos)
	for mi in area_marks_for(s, p.block) {
		m := s.marks[mi]
		if len(m.message) == 0 do continue
		lo, hi := pos_order(m.from, m.to)
		if !pos_less(p, lo) && pos_less(p, hi) do return int(mi)
	}
	return -1
}

// ------------------------------------------------------------ line geometry

@(private)
area_line_height :: proc(t: ^Tree, s: ^Text_Area_State) -> f32 {
	if te := t.text; te != nil && te.ok do return text_line_height(te, s.size, s.mono, s.family) * area_spacing(s)
	return s.size * 1.25 * area_spacing(s)
}

// area_rich is block `b`'s rich layout, rebuilt when the document, the
// width or the size changed.
@(private)
area_rich :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> ^Rich_Layout {
	if s.rich_cache == nil do s.rich_cache = make(map[int]Rich_Cached, t.allocator)
	c, ok := &s.rich_cache[b]
	shown := area_text(t, s, b)
	raw := area_raw(s, b)
	if ok && c.stamp == block_stamp(s.doc, b) && c.wrap_w == s.wrap_w && c.size == s.size && c.text_len == len(shown) && c.raw == raw && c.family == s.family do return &c.lay
	base, _, _, _ := area_block_style(t, s, b)
	lay: Rich_Layout
	if area_meta(t, s, b).kind == .Table {
		// The caret's row is not aligned: aligning it would slide the text
		// sideways as digits are typed, which is worse than a column out of
		// line while the caret is there (as a row shown as source keeps its
		// literal layout, rich.odin).
		align := area_table_align(t, s, b) if b != s.caret.block else nil
		lay = table_row_layout(t, shown, area_runs(t, s, b), base, area_table_cols(t, s, b), area_raw(s, b), t.allocator, align)
	} else {
		lay = rich_layout(t, shown, area_runs(t, s, b), base, max(s.wrap_w - block_indent(t, s, b), 1) if s.wrap_w > 0 else 0, t.allocator)
	}
	if ok do rich_free(&c.lay, t.allocator)
	s.rich_cache[b] = {lay = lay, stamp = block_stamp(s.doc, b), wrap_w = s.wrap_w, size = s.size, text_len = len(shown), raw = raw, family = s.family}
	fresh, _ := &s.rich_cache[b]
	return &fresh.lay
}

// rich_free releases a layout made with `allocator`.
@(private)
rich_free :: proc(lay: ^Rich_Layout, allocator: runtime.Allocator) {
	for l in lay.lines do delete(l.segs, allocator)
	delete(lay.lines, allocator)
	delete(lay.cum, allocator)
	delete(lay.styles, allocator)
	delete(lay.runs, allocator)
	lay^ = {}
}

// area_block_style: how block `b` is set — its base style, indent, and
// the space before and after it. Plain areas and code editors: the body
// style, no indent, no space.
@(private)
area_block_style :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> (base: Rich_Style, indent, before, after: f32) {
	th := &t.theme
	base = Rich_Style{size = s.size, mono = s.mono, family = s.family}
	if !s.rich || s.doc == nil || b < 0 || b >= len(s.doc.blocks) do return
	meta := area_meta(t, s, b)
	blk := &meta
	switch blk.kind {
	case .Paragraph:
		after = th.space[.sm]
	case .Heading:
		base.bold = true
		switch blk.level {
		case 1: base.size = th.type.headline.size
		case 2: base.size = th.type.title.size
		case 3: base.size = s.size * 1.12
		case:   base.size = s.size
		}
		before, after = th.space[.md], th.space[.xs]
		if b == 0 do before = 0
	case .Bullet, .Numbered, .Task:
		indent = RICH_LIST_INDENT + f32(blk.depth) * RICH_LIST_STEP
		after = th.space[.xxs]
	case .Quote:
		indent = RICH_QUOTE_INDENT
		after = th.space[.sm]
	case .Code:
		base.mono = true
		base.size = s.size * 0.94
		indent = th.space[.md]
		before = 0 if code_joins(t, s, b) else th.space[.xs]
		after = 0 if code_joins(t, s, b + 1) else th.space[.sm]
	case .Rule:
		after = th.space[.sm]
	case .Image:
		after = th.space[.sm]
	case .Table, .Table_Sep: // rows touch; the table as a whole gets its space
		first, last := area_table_group(t, s, b)
		if b == first do before = th.space[.xs]
		if b == last do after = th.space[.sm]
	}
	if s.live && blk.kind == .Paragraph && len(area_text(t, s, b)) == 0 do after = 0 // a blank source line is a gap, not a paragraph
	return
}

// code_joins: block `b` carries on the code block above it, as one box
// with no space between. In markdown source a closing fence ends its block,
// so a fence opening straight after it starts a box of its own.
@(private)
code_joins :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> bool {
	if b <= 0 || b >= len(s.doc.blocks) || area_meta(t, s, b).kind != .Code || area_meta(t, s, b - 1).kind != .Code do return false
	if s.live {
		above := area_live(t, s, b - 1)
		if above.in_fence && above.fence do return false
	}
	return true
}

RICH_LIST_INDENT  :: f32(26)
RICH_IMAGE_MAX_H  :: f32(360)
RICH_IMAGE_PLACEHOLDER_H :: f32(72)
RICH_LIST_STEP    :: f32(22)
RICH_QUOTE_INDENT :: f32(18)

// area_ink is what an editor writes in: the colour the app gave it, else
// the theme's text colour. A page of the app's own colour (a sticky note's
// yellow paper) needs its own ink, or a dark theme's near-white text lands
// on near-white paper.
@(private)
area_ink :: proc(t: ^Tree, s: ^Text_Area_State) -> Color {
	return s.ink if s.ink.a > 0 else t.theme.color.on_surface
}

// area_ink_muted is what a placeholder, a quote, a bullet and a list number
// are drawn in: the theme's muted text, or the app's own ink faded. A
// placeholder must be read, so the fade keeps the 3:1 large text needs:
// 0.85 of the ink does on pale paper, where 0.6 falls to about 2:1.
@(private)
area_ink_muted :: proc(t: ^Tree, s: ^Text_Area_State) -> Color {
	if s.ink.a <= 0 do return t.theme.color.on_surface_muted
	faded := s.ink
	faded.a *= 0.85
	return faded
}

// area_selection_pair is the band and the text colour this editor's
// selection draws (selection_paint.odin): the theme's pair on the theme's
// own surfaces, and reverse video against the app's ink on a page the theme
// did not choose — a note's yellow paper, which the editor is never told,
// but which its ink is known to read on.
@(private)
area_selection_pair :: proc(t: ^Tree, s: ^Text_Area_State) -> (band, text: Color) {
	if s.ink.a > 0 do return selection_pair(&t.theme, nil, s.ink)
	return selection_pair(&t.theme)
}

// area_ink_accent is a link's colour on a page the app coloured: the
// theme's accent pulled toward the ink, so it keeps its hue and still reads
// on paper the theme did not choose.
@(private)
area_ink_accent :: proc(t: ^Tree, s: ^Text_Area_State) -> Color {
	if s.ink.a <= 0 do return t.theme.color.accent_text
	return mix(t.theme.color.accent_text, s.ink, 0.45)
}

// area_ink_wash is the tint behind a run of code: the theme's raised
// surface, or a wash of the app's own ink.
@(private)
area_ink_wash :: proc(t: ^Tree, s: ^Text_Area_State) -> Color {
	if s.ink.a <= 0 do return t.theme.color.surface_high
	wash := s.ink
	wash.a *= 0.10
	return wash
}

// area_line_h is the line height of block `b` (a heading's is taller).
@(private)
area_line_h :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> f32 {
	if s.rich && s.doc != nil do return area_rich(t, s, b).line_h * area_spacing(s)
	return s.line_h
}

// block_text_height is how tall block `b`'s text is. It is its wrapped
// lines, except for a table row: that holds one line per *cell* line, and
// they are not one stack — the second line of two different cells sit side
// by side, not above one another — so the layout works its own height out
// and this asks it.
@(private)
block_text_height :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> f32 {
	if s.rich && s.doc != nil {
		lay := area_rich(t, s, b)
		if lay.height > 0 do return lay.height * area_spacing(s)
	}
	return f32(len(block_spans(t, s, b))) * area_line_h(t, s, b)
}

// block_indent is how far block `b`'s text starts from the text column.
@(private)
block_indent :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> f32 {
	if !s.rich do return 0
	_, indent, _, _ := area_block_style(t, s, b)
	return indent
}

// block_spans splits block `b` into wrapped lines the way the renderer
// will draw it: from the rich layout, through the text engine when there
// is one (clusters give the byte ranges; a ligature-shuffled line falls
// back to rune counting), else the headless monospace rule.
@(private)
block_spans :: proc(t: ^Tree, s: ^Text_Area_State, b: int, allocator := context.temp_allocator) -> []Line_Span {
	out := make([dynamic]Line_Span, allocator)
	str := area_text(t, s, b) if s.doc != nil else ""
	if s.rich && s.doc != nil {
		lay := area_rich(t, s, b)
		for l in lay.lines do append(&out, Line_Span{start = l.start, end = l.end, width = l.width})
		if len(out) == 0 do append(&out, Line_Span{})
		return out[:]
	}
	if len(str) == 0 {
		append(&out, Line_Span{})
		return out[:]
	}
	te := t.text
	if te == nil || !te.ok {
		adv := s.size * 0.5
		per := max(int(s.wrap_w / adv), 1) if s.wrap_w > 0 else max(int(1e9), 1)
		start, i, count := 0, 0, 0
		for i < len(str) {
			_, w := utf8.decode_rune_in_string(str[i:])
			if count == per {
				append(&out, Line_Span{start = start, end = i, width = f32(count) * adv})
				start, count = i, 0
			}
			i += w
			count += 1
		}
		append(&out, Line_Span{start = start, end = len(str), width = f32(count) * adv})
		return out[:]
	}
	lines := text_lines(te, str, s.size, s.wrap_w, .Regular, s.mono, s.tab, false, area_no_liga(s), s.family)
	if len(lines) == 0 {
		append(&out, Line_Span{end = len(str)})
		return out[:]
	}
	total := 0
	for l in lines do total += len(l.glyphs)
	clusters_ok := total == utf8.rune_count_in_string(str)
	if clusters_ok {
		prev := -1
		for l in lines do for g in l.glyphs {
			c := int(g.cluster)
			if c < prev || c >= len(str) {
				clusters_ok = false
				break
			}
			prev = c
		}
	}
	start := 0
	runes_before := 0
	for l, i in lines {
		end: int
		if i == len(lines) - 1 {
			end = len(str)
		} else if clusters_ok && len(lines[i + 1].glyphs) > 0 {
			end = int(lines[i + 1].glyphs[0].cluster)
		} else {
			end = grapheme_snap(str, rune_offset(str, runes_before + len(l.glyphs)))
		}
		if end < start do end = start
		append(&out, Line_Span{start = start, end = end, width = l.width})
		start = end
		runes_before += len(l.glyphs)
	}
	return out[:]
}

@(private)
rune_offset :: proc(s: string, n: int) -> int {
	i, count := 0, 0
	for count < n && i < len(s) {
		_, w := utf8.decode_rune_in_string(s[i:])
		i += w
		count += 1
	}
	return i
}

// span_x is the x of source byte `off` within its line (a prefix width);
// spans and span_x_disp work in display bytes (the same unless a live
// block is rendered without its marks).
@(private)
span_x :: proc(t: ^Tree, s: ^Text_Area_State, b: int, sp: Line_Span, off: int) -> f32 {
	return span_x_disp(t, s, b, sp, to_disp(t, s, b, off))
}

// Span_Bidi is what a line holding right-to-left text is positioned by:
// the rich layout's line, or the shaped glyphs of a plain one.
@(private)
Span_Bidi :: struct {
	on:     bool,
	lay:    ^Rich_Layout, // rich: the block's layout and the line in it
	li:     int,
	glyphs: []runa.Paragraph_Glyph, // plain: the line's glyphs, in visual order
}

// span_bidi finds the bidi line behind span `sp` of block `b`; `on` is false
// for a line with nothing right to left, which keeps the plain path.
@(private)
span_bidi :: proc(t: ^Tree, s: ^Text_Area_State, b: int, sp: Line_Span) -> (out: Span_Bidi) {
	if s.doc == nil do return
	if s.rich {
		lay := area_rich(t, s, b)
		for l, i in lay.lines do if l.start == sp.start && l.end == sp.end {
			if l.bidi do out = {on = true, lay = lay, li = i}
			return
		}
		return
	}
	te := t.text
	if te == nil || !te.ok do return
	stamp := block_stamp(s.doc, b)
	str := area_text(t, s, b)
	if !(s.rtl_known && s.rtl_block == b && s.rtl_stamp == stamp) {
		s.rtl_block, s.rtl_stamp, s.rtl_known = b, stamp, true
		s.rtl_has = rich_levels(str) != nil
	}
	if !s.rtl_has do return
	lines := text_lines(te, str, s.size, s.wrap_w, .Regular, s.mono, s.tab, false, area_no_liga(s), s.family)
	for sp2, i in block_spans(t, s, b) do if sp2.start == sp.start && i < len(lines) {
		if line_has_rtl(lines[i].glyphs) do out = {on = true, glyphs = lines[i].glyphs}
		return
	}
	return
}

// span_ranges is where display bytes [a, z) of span `sp` are drawn, as x
// ranges left to right: one on a left-to-right line, one per piece where
// directions mix. In the frame's temp memory.
@(private)
span_ranges :: proc(t: ^Tree, s: ^Text_Area_State, b: int, sp: Line_Span, a, z: int) -> [][2]f32 {
	if bd := span_bidi(t, s, b, sp); bd.on {
		return rich_spans(bd.lay, bd.li, a, z) if bd.lay != nil else line_ranges(bd.glyphs, a, z)
	}
	out := make([][2]f32, 1, context.temp_allocator)
	out[0] = {span_x_disp(t, s, b, sp, a), span_x_disp(t, s, b, sp, z)}
	return out
}

@(private)
span_x_disp :: proc(t: ^Tree, s: ^Text_Area_State, b: int, sp: Line_Span, off: int) -> f32 {
	o := clamp(off, sp.start, sp.end)
	if bd := span_bidi(t, s, b, sp); bd.on {
		return rich_x(bd.lay, bd.li, o) if bd.lay != nil else line_caret_x(bd.glyphs, o)
	}
	if o == sp.start do return 0
	if s.rich && s.doc != nil {
		lay := area_rich(t, s, b)
		return lay.cum[clamp(o, 0, len(lay.cum) - 1)] - lay.cum[clamp(sp.start, 0, len(lay.cum) - 1)]
	}
	str := area_text(t, s, b)
	te := t.text
	if te == nil || !te.ok do return f32(utf8.rune_count_in_string(str[sp.start:o])) * s.size * 0.5
	if o == sp.end do return sp.width
	if cum := area_cum(t, s, b); cum != nil do return cum[o] - cum[sp.start]
	return prefix_width(te, str[sp.start:o], s.size, s.mono, s.tab, no_liga = area_no_liga(s), family = s.family)
}

// area_cum is where each byte of block `b` sits along its own wrapped
// line, taken from the shaped lines the engine has already cached rather
// than by shaping a prefix for each question.
//
// The code painter asks for one x per token, and shaping a prefix for each
// is quadratic in the line. One block's worth is kept, which is all a
// painter walking a line needs. nil = answer it the slow way (a ligature
// shuffled the clusters, or there is no engine).
@(private)
area_cum :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> []f32 {
	te := t.text
	if te == nil || !te.ok || s.doc == nil do return nil
	str := area_text(t, s, b)
	key := area_heights_key(t, s)
	stamp := block_stamp(s.doc, b)
	if s.cum_valid && s.cum_block == b && s.cum_stamp == stamp && s.cum_key == key && s.cum_len == len(str) && len(s.cum) == len(str) + 1 {
		return s.cum[:]
	}
	s.cum_valid = false
	lines := text_lines(te, str, s.size, s.wrap_w, .Regular, s.mono, s.tab, false, area_no_liga(s), s.family)
	if len(lines) == 0 do return nil
	resize(&s.cum, len(str) + 1)
	for i in 0 ..< len(s.cum) do s.cum[i] = -1
	for l in lines {
		x: f32
		for g in l.glyphs {
			c := int(g.cluster)
			if c < 0 || c > len(str) do return nil // the clusters are not byte offsets into this string
			if s.cum[c] < 0 do s.cum[c] = x
			x += g.x_advance
		}
	}
	// a byte inside a cluster takes the x of the next one; the bytes after
	// the last glyph take the last line's width
	run := lines[len(lines) - 1].width
	for i := len(s.cum) - 1; i >= 0; i -= 1 {
		if s.cum[i] < 0 { s.cum[i] = run } else { run = s.cum[i] }
	}
	s.cum_block, s.cum_stamp, s.cum_key, s.cum_len, s.cum_valid = b, stamp, key, len(str), true
	return s.cum[:]
}

// area_no_liga: a code editor keeps "->" as two glyphs unless asked for ligatures.
@(private)
area_no_liga :: proc(s: ^Text_Area_State) -> bool {
	return s.code.on && !s.code.ligatures
}

// span_hit is the source byte of the grapheme boundary nearest to `x`.
@(private)
span_hit :: proc(t: ^Tree, s: ^Text_Area_State, b: int, sp: Line_Span, x: f32) -> int {
	return to_src(t, s, b, span_hit_disp(t, s, b, sp, x))
}

@(private)
span_hit_disp :: proc(t: ^Tree, s: ^Text_Area_State, b: int, sp: Line_Span, x: f32) -> int {
	str := area_text(t, s, b)
	bounds := make([dynamic]int, 0, 16, context.temp_allocator)
	append(&bounds, sp.start)
	// One iterator over this line's own bytes, not `grapheme_next` per step,
	// which iterates from the start of the whole block each call
	// (O(line × block)). A span's ends are cluster boundaries, so the slice
	// can be iterated alone: context rules (regional indicators, ZWJ) only
	// join within a cluster.
	if sp.end > sp.start {
		it := runa.grapheme_iter_make(str[sp.start:sp.end])
		for {
			_, hi, ok := runa.grapheme_iter_next(&it)
			if !ok do break
			append(&bounds, sp.start + hi)
		}
	}
	if bd := span_bidi(t, s, b, sp); bd.on {
		// the caret moves both ways along a line that mixes directions: the nearest boundary, not a search
		best, best_d := bounds[0], max(f32)
		for bo in bounds {
			if d := abs(span_x_disp(t, s, b, sp, bo) - x); d < best_d do best, best_d = bo, d
		}
		return best
	}
	lo, hi := 0, len(bounds) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if span_x_disp(t, s, b, sp, bounds[mid]) <= x { lo = mid } else { hi = mid - 1 }
	}
	if lo + 1 < len(bounds) {
		left := x - span_x_disp(t, s, b, sp, bounds[lo])
		right := span_x_disp(t, s, b, sp, bounds[lo + 1]) - x
		if right < left do lo += 1
	}
	return bounds[lo]
}

// caret_line finds the wrapped line of `p` in its block: index, span, x.
@(private)
caret_line :: proc(t: ^Tree, s: ^Text_Area_State, p: Pos) -> (line: int, sp: Line_Span, x: f32) {
	str := area_text(t, s, p.block)
	spans := block_spans(t, s, p.block)
	off := to_disp(t, s, p.block, p.off)
	if len(s.pre) > 0 && p.block == s.pre_block && p.off == s.pre_off { // in a composition the caret is where the method put it
		off += s.pre_lo if s.pre_lo >= 0 && s.pre_lo <= len(s.pre) else len(s.pre)
	}
	for span, i in spans {
		// an offset at a wrap boundary belongs to the line it ends (except at the very start)
		if off < span.end || i == len(spans) - 1 || (off == span.end && off == len(str)) {
			return i, span, span_x_disp(t, s, p.block, span, off)
		}
	}
	return 0, {}, 0
}

// ------------------------------------------------------- the height map
//
// An editor must know its document's height and where every block starts,
// to scroll and to find what is in view. Shaping every block for that is
// O(document) per edit, resize or scroll bar change, so heights live in an
// array beside the blocks, each one either
//
//   - measured: the block was shaped, because it came into view or the
//     caret went to it; or
//   - estimated: its length over the average character advance, with no
//     shaping at all.
//
// An edit keeps every untouched block's height: blocks are matched by
// `block_stamp`, so the prefix and suffix an edit left alone carry their
// heights across it. And a block is always measured before it is painted,
// so an estimate only places what is off screen, where a few pixels out is
// invisible and corrects itself.

// Heights_Key is everything every block's height depends on. When one of
// these changes there is nothing to carry over, so the whole map goes
// back to estimates and is measured again as it is looked at.
@(private)
Heights_Key :: struct {
	wrap_w, size, spacing: f32,
	family:   Family_Id,
	doc_id:   u64,
	tab:      u8,
	wrap, mono, rich, live, code: bool,
}

@(private)
area_heights_key :: proc(t: ^Tree, s: ^Text_Area_State) -> Heights_Key {
	return {wrap_w = s.wrap_w, size = s.size, spacing = area_spacing(s), family = s.family,
		doc_id = s.doc_id, tab = s.tab, wrap = s.wrap, mono = s.mono, rich = s.rich, live = s.live, code = s.code.on}
}

// area_avg_advance is what one character takes on average in this
// editor's face, from one measured sample: the estimator's only input
// from the font. Headless it is the same half-size advance
// `block_spans` itself uses, so an estimate there *is* the measurement
// and a headless test sees no settling.
@(private)
area_avg_advance :: proc(t: ^Tree, s: ^Text_Area_State) -> f32 {
	te := t.text
	if te == nil || !te.ok do return max(s.size, 1) * 0.5
	if s.adv_cache > 0 && s.adv_size == s.size && s.adv_family == s.family && s.adv_mono == s.mono do return s.adv_cache
	SAMPLE :: "the quick brown fox jumps over a lazy dog, and then some more of it"
	w := prefix_width(te, SAMPLE, s.size, mono = s.mono, family = s.family)
	s.adv_cache = max(w / f32(len(SAMPLE)), 0.5)
	s.adv_size, s.adv_family, s.adv_mono = s.size, s.family, s.mono
	return s.adv_cache
}

// area_est_lines is how many lines `text` is guessed to wrap into at
// width `w`. It counts bytes, not runes: a guess that is high for
// non-Latin text costs a little slack in the scroll bar until the block
// is looked at, and counting runes would walk the whole document on
// every edit, which is the cost this is here to remove.
@(private)
area_est_lines :: proc(t: ^Tree, s: ^Text_Area_State, text: string, w: f32, size: f32) -> int {
	if len(text) == 0 || w <= 0 do return 1
	adv := area_avg_advance(t, s) * (size / max(s.size, 1))
	per := max(int(w / max(adv, 0.5)), 1)
	return max((len(text) + per - 1) / per, 1)
}

// area_line_h_est is a block's line height from its style alone — unlike
// area_line_h, which asks the rich layout and so would shape the block.
@(private)
area_line_h_est :: proc(t: ^Tree, s: ^Text_Area_State, base: Rich_Style) -> f32 {
	if te := t.text; te != nil && te.ok do return text_line_height(te, base.size, base.mono, base.family) * area_spacing(s)
	return base.size * 1.25 * area_spacing(s)
}

// area_estimate is block `b`'s height without shaping it. A picture and a
// table separator are measured outright instead: their height is not a
// count of lines, and there are never many of them.
@(private)
area_estimate :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> (h: f32, measured: bool) {
	if s.rich {
		meta := area_meta(t, s, b)
		// A table row is estimated like text, not measured: a document can
		// hold thousands, and measuring one shapes every cell.
		if meta.kind == .Image || meta.kind == .Table_Sep do return block_height(t, s, b), true
		base, indent, before, after := area_block_style(t, s, b)
		if s.live && meta.kind == .Paragraph && len(area_text(t, s, b)) == 0 && !area_raw(s, b) do return area_line_h_est(t, s, base) * 0.5, false
		w := max(s.wrap_w - indent, 1) if s.wrap_w > 0 else 0
		lines := area_est_lines(t, s, area_text(t, s, b), w, base.size)
		return before + f32(lines) * area_line_h_est(t, s, base) + after, false
	}
	if s.wrap_w > 0 && s.wrap do return f32(area_est_lines(t, s, area_text(t, s, b), s.wrap_w, s.size)) * s.line_h, false
	return s.line_h, true // unwrapped, a block is one line whatever is in it
}

// stamp_span is what an edit left alone: `p` blocks at the front and `q`
// at the back whose stamps are the ones a per-block array was built with.
// Everything between them is what changed — usually one block, two when a
// line was split — however many blocks were inserted or removed.
@(private)
stamp_span :: proc(doc: ^Document, stamps: []u64, n: int) -> (p, q: int) {
	old := len(stamps)
	for p < min(old, n) && stamps[p] == block_stamp(doc, p) do p += 1
	for q < min(old, n) - p && stamps[old - 1 - q] == block_stamp(doc, n - 1 - q) do q += 1
	return
}

// block_realign slides the last `q` entries of a per-block array to where
// their blocks are now, and sizes it to `n`: the front is already right.
// `copy` is a move, so the ranges may overlap.
@(private)
block_realign :: proc(arr: ^[dynamic]$T, old_len, n, q: int) {
	if n > old_len do resize(arr, n)
	if q > 0 && n != old_len do copy(arr[n - q:n], arr[old_len - q:old_len])
	if n < old_len do resize(arr, n)
}

// area_heights is the height map, brought up to date with the document:
// the blocks an edit did not touch keep what they had (measurements
// included), and the ones it did are estimated again.
@(private)
area_heights :: proc(t: ^Tree, s: ^Text_Area_State) -> []f32 {
	n := len(s.doc.blocks)
	key := area_heights_key(t, s)
	if !s.tops_valid || s.heights_key != key || len(s.heights) != len(s.hstamps) {
		resize(&s.heights, n)
		resize(&s.hstamps, n)
		resize(&s.hmeasured, n)
		resize(&s.himage, n)
		for b in 0 ..< n do area_estimate_into(t, s, b)
		area_count_images(s)
		s.heights_key = key
		s.heights_version = s.doc.version
		s.tops_valid = true
		s.tops_dirty = true
		return s.heights[:]
	}
	if s.heights_version == s.doc.version && len(s.heights) == n do return s.heights[:]
	// What the edit did not touch keeps its height: stamps match at the
	// front and back up to the changed blocks, so typing re-estimates one
	// block, and a block inserted above shifts the rest rather than redoing
	// them.
	old := len(s.hstamps)
	p, q := stamp_span(s.doc, s.hstamps[:], n)
	block_realign(&s.heights, old, n, q)
	block_realign(&s.hstamps, old, n, q)
	block_realign(&s.hmeasured, old, n, q)
	block_realign(&s.himage, old, n, q)
	for b in p ..< n - q do area_estimate_into(t, s, b)
	area_count_images(s)
	s.heights_version = s.doc.version
	s.tops_dirty = true
	return s.heights[:]
}

// area_estimate_into puts block `b`'s estimate in the map, with the stamp
// it was taken at.
@(private)
area_estimate_into :: proc(t: ^Tree, s: ^Text_Area_State, b: int) {
	h, measured := area_estimate(t, s, b)
	s.heights[b] = h
	s.hstamps[b] = block_stamp(s.doc, b)
	s.hmeasured[b] = measured
	s.himage[b] = s.rich && area_meta(t, s, b).kind == .Image
}

// area_count_images counts the picture blocks, which tells
// area_images_height whether it has anything to do. Counted afresh rather
// than adjusted, since a drifting count would do the work for ever or miss
// a picture; a pass over a byte a block is cheap even for 80,000 blocks.
@(private)
area_count_images :: proc(s: ^Text_Area_State) {
	s.image_count = 0
	for yes in s.himage do if yes do s.image_count += 1
}

// area_measure_block shapes block `b` and keeps its real height: an
// estimate becomes a measurement, and everything below it moves to suit.
// Anything about to *draw* a block calls this first, so nothing on screen
// is ever placed by a guess.
@(private)
area_measure_block :: proc(t: ^Tree, s: ^Text_Area_State, b: int) {
	if s.doc == nil do return
	area_heights(t, s)
	if b < 0 || b >= len(s.heights) || s.hmeasured[b] do return
	h := block_height(t, s, b)
	s.hmeasured[b] = true
	if h != s.heights[b] {
		s.heights[b] = h
		s.tops_dirty = true
	}
}

// area_measure_range measures the blocks that touch content y in
// [top, bottom) — the ones about to be painted — keeping the block at the
// top of the view where it is, so a corrected estimate does not slide the
// text under the reader. It returns how far the content moved, for the
// caller to add to its scroll offset.
@(private)
area_measure_range :: proc(t: ^Tree, s: ^Text_Area_State, top, bottom: f32) -> (shift: f32) {
	if s.doc == nil do return 0
	tops := area_tops(t, s)
	n := len(tops) - 1
	if n <= 0 do return 0
	first := block_at_y(t, s, top)
	was := tops[first]
	y := was
	for b := first; b < n && y < bottom; b += 1 {
		area_measure_block(t, s, b) // its height may grow or shrink under us…
		y += s.heights[b]           // …so walk on the heights, not the stale tops
	}
	if !s.tops_dirty do return 0
	return area_tops(t, s)[first] - was
}

// WIDEST_CANDIDATES is how many of the longest lines are shaped to find
// how wide an unwrapped editor's content is. Byte length ranks them and
// shaping settles it: the longest line in bytes is not always the widest
// drawn (a line of commas against a line of Ws), so a handful are tried
// rather than one.
WIDEST_CANDIDATES :: 8

// WIDEST_INDENT_SCAN is how far into a line the ranking looks for the
// tabs that make it wider than its byte count says. Indentation lives at
// the front, and reading every byte of every line would be the
// whole-document cost this ranking exists to avoid.
WIDEST_INDENT_SCAN :: 64

// area_widest_weight is how wide block `b` is likely to draw, for ranking
// alone: its byte count plus what its leading tabs draw beyond one cell
// each, since a deeply tab-indented line can draw wider than lines with
// more bytes. A tab further in still counts as one byte, a smaller error
// in the same direction.
@(private)
area_widest_weight :: proc(s: ^Text_Area_State, b: int) -> int {
	txt := s.doc.blocks[b].text
	n := len(txt)
	if !s.mono || s.tab <= 1 do return n
	for i in 0 ..< min(len(txt), WIDEST_INDENT_SCAN) {
		if txt[i] != '\t' do break
		n += int(s.tab) - 1
	}
	return n
}

// area_widest is how wide the widest line draws — the horizontal scroll
// bar's range for an editor that does not wrap. It shapes only the
// WIDEST_CANDIDATES longest lines and keeps the answer until the document
// or the face changes.
@(private)
area_widest :: proc(t: ^Tree, s: ^Text_Area_State) -> f32 {
	key := area_heights_key(t, s)
	if s.widest_valid && s.widest_version == s.doc.version && s.widest_key == key do return s.widest
	best: [WIDEST_CANDIDATES]int // the longest blocks by byte length, longest first
	lens: [WIDEST_CANDIDATES]int
	for i in 0 ..< WIDEST_CANDIDATES do best[i] = -1
	for b in 0 ..< len(s.doc.blocks) {
		n := area_widest_weight(s, b)
		if best[WIDEST_CANDIDATES - 1] >= 0 && n <= lens[WIDEST_CANDIDATES - 1] do continue
		at := WIDEST_CANDIDATES - 1
		for at > 0 && (best[at - 1] < 0 || lens[at - 1] < n) {
			best[at], lens[at] = best[at - 1], lens[at - 1]
			at -= 1
		}
		best[at], lens[at] = b, n
	}
	w: f32
	for b in best do if b >= 0 {
		for sp in block_spans(t, s, b) do w = max(w, sp.width + 2)
	}
	s.widest, s.widest_version, s.widest_key, s.widest_valid = w, s.doc.version, key, true
	return w
}

// area_tops is where each block starts, the running sum of the height
// map (and the document's full height at the end).
@(private)
area_tops :: proc(t: ^Tree, s: ^Text_Area_State) -> []f32 {
	if s.doc == nil {
		resize(&s.tops, 2)
		s.tops[0], s.tops[1] = 0, s.line_h
		return s.tops[:]
	}
	hs := area_heights(t, s)
	n := len(hs)
	images := area_images_height(t, s) // 0 without image blocks
	if images != s.tops_images { // a picture arrived: its block is a different height now, and its stamp cannot say so
		for b in s.image_blocks do if b >= 0 && b < n do s.hmeasured[b] = false
		for b in s.image_blocks do area_measure_block(t, s, b)
		s.tops_images = images
		s.tops_dirty = true
	}
	if !s.tops_dirty && len(s.tops) == n + 1 do return s.tops[:]
	resize(&s.tops, n + 1)
	y: f32
	for b in 0 ..< n {
		s.tops[b] = y
		y += hs[b]
	}
	s.tops[n] = y
	s.tops_dirty = false
	return s.tops[:]
}

// area_images_height is the sum of the image blocks' drawn heights: a
// picture that arrives (or a resolver set) after the tops were built
// changes it, and the tops follow. The image blocks are listed per version.
@(private)
area_images_height :: proc(t: ^Tree, s: ^Text_Area_State) -> (total: f32) {
	if !s.rich || s.doc == nil || s.image_count == 0 do return 0 // the height map counted them: no pictures, no work
	// A flag, not `image_blocks == nil`: an empty list is still nil, so nil
	// cannot mean "not worked out yet", and this runs for every block_top.
	if !s.image_blocks_valid || s.image_blocks_version != s.doc.version {
		if s.image_blocks == nil do s.image_blocks = make([dynamic]int, t.allocator)
		clear(&s.image_blocks)
		for b in 0 ..< len(s.doc.blocks) do if area_meta(t, s, b).kind == .Image do append(&s.image_blocks, b)
		s.image_blocks_version = s.doc.version
		s.image_blocks_valid = true
	}
	for b in s.image_blocks do if !area_raw(s, b) do total += rich_image_height(t, s, b)
	return
}

// block_height is block `b`'s full height: space before, lines, space after.
@(private)
block_height :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> f32 {
	if s.rich {
		_, _, before, after := area_block_style(t, s, b)
		meta := area_meta(t, s, b)
		if meta.kind == .Table_Sep && !area_raw(s, b) do return before + after // drawn as the header's underline
		if meta.kind == .Image && !area_raw(s, b) do return before + rich_image_height(t, s, b) + block_text_height(t, s, b) + after
		if s.live && meta.kind == .Paragraph && len(area_text(t, s, b)) == 0 && !area_raw(s, b) do return area_line_h(t, s, b) * 0.5 // a blank line between blocks
		return before + block_text_height(t, s, b) + after
	}
	if s.wrap_w > 0 && s.wrap do return f32(len(block_spans(t, s, b))) * s.line_h
	return s.line_h
}

// block_top is the y (in content coordinates) where block `b` starts.
@(private)
block_top :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> (y: f32) {
	tops := area_tops(t, s)
	return tops[clamp(b, 0, len(tops) - 1)]
}

// block_text_top is where block `b`'s first line starts (after its space before).
@(private)
block_text_top :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> f32 {
	if !s.rich do return block_top(t, s, b)
	_, _, before, _ := area_block_style(t, s, b)
	y := block_top(t, s, b) + before
	if area_meta(t, s, b).kind == .Image && !area_raw(s, b) do y += rich_image_height(t, s, b) // the caption sits under the picture
	return y
}

// block_at_y is the block containing content y (the last when past the end).
@(private)
block_at_y :: proc(t: ^Tree, s: ^Text_Area_State, y: f32) -> int {
	tops := area_tops(t, s)
	n := len(tops) - 1
	if n <= 0 do return 0
	lo, hi := 0, n - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if tops[mid] <= y { lo = mid } else { hi = mid - 1 }
	}
	return lo
}

@(private)
content_height :: proc(t: ^Tree, s: ^Text_Area_State) -> f32 {
	if s.doc == nil do return s.line_h
	tops := area_tops(t, s)
	return tops[len(tops) - 1]
}

// area_text_x is where the text starts inside the area: after the gutter
// in a code editor.
@(private)
area_text_x :: proc(s: ^Text_Area_State) -> f32 {
	return s.code.gutter_w if s.code.on else 0
}

// ------------------------------------------------------------ layout

// area_max_h is the height `max_lines` allows, the frame's own padding
// included; 0 when there is no cap. It goes in `Layout_Props.max_h`
// because a flex child is handed its share as both minimum and maximum, so
// a cap applied only in measure_text_area would be ignored; max_h is
// clamped into the constraints before measuring, flex or not.
@(private)
area_max_h :: proc(t: ^Tree, s: ^Text_Area_State) -> f32 {
	if s == nil || s.max_lines <= 0 do return 0
	return f32(s.max_lines) * s.line_h + t.theme.space[.sm] * 2 // the padding set_layout gives it
}

@(private)
measure_text_area :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	s := &t.areas[n]
	if s == nil do return constrain(cc, {TEXT_AREA_DEFAULT_WIDTH, 60})
	p := d.layout.padding
	w := cc.max.x if is_bounded(cc.max.x) else TEXT_AREA_DEFAULT_WIDTH
	if cc.min.x > w do w = cc.min.x
	s.line_h = area_line_height(t, s)
	if s.code.on do code_measure(t, s)
	inner_w := max(w - p[1] - p[3] - area_text_x(s), 1)
	// Where the reader is, as a block and how far into it, in case the
	// line below changes the wrap width: a narrower window re-estimates
	// every height, and keeping the content *y* would land them somewhere
	// else entirely in a long document. The block they were reading is
	// put back under the top of the view instead.
	was_key := s.heights_key
	anchor, anchor_frac := -1, f32(0)
	if s.doc != nil && len(s.tops) > 1 && len(s.heights) == len(s.tops) - 1 {
		if st, has := t.scrolls[n]; has && st.offset.y > 0 {
			anchor = block_at_y(t, s, st.offset.y)
			anchor_frac = (st.offset.y - s.tops[anchor]) / max(s.heights[anchor], 1)
		}
	}
	s.wrap_w = inner_w if s.wrap else 0
	content := content_height(t, s)
	content_w := inner_w
	if !s.wrap && s.doc != nil do content_w = max(content_w, area_widest(t, s))
	h := content
	h = max(h, f32(s.min_lines) * s.line_h)
	if s.max_lines > 0 do h = min(h, f32(s.max_lines) * s.line_h)
	size := constrain(cc, {w, h + p[0] + p[2]})
	// the area scrolls when its content is taller than it is
	st := &t.scrolls[n]
	if st == nil {
		t.scrolls[n] = scroll_state_new()
		st = &t.scrolls[n]
	}
	st.content = {content_w, content}
	st.viewport = {inner_w, size.y - p[0] - p[2]}
	if anchor >= 0 && anchor < len(s.heights) && s.heights_key != was_key { // only when the heights were all thrown away
		st.offset.y = s.tops[anchor] + anchor_frac * s.heights[anchor]
	}
	st.offset = scroll_clamp(st^, st.offset)
	return size
}

// ------------------------------------------------------------ paint

@(private)
paint_text_area :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	s, ok := &t.areas[n]
	if !ok do return
	th := &t.theme
	focused := .Focused in d.flags
	// the selection stays in view while focus is on the editor's own controls (its toolbar, its bars)
	within := focused
	if ctl_area, is_ctl := t.editor_ctl_of[t.focus]; is_ctl && ctl_area == n do within = true
	if own, is_own := t.editor_owned[t.focus]; is_own && own == n do within = true // a control of the app's own: its find field
	if sel_scope_covers(t, n) do within = true // its part of one selection running across several messages
	disabled := .Disabled in d.flags
	alpha: f32 = th.state.disabled_alpha if disabled else 1
	alpha *= t.paint_opacity // the editor fades with its dialog
	if !s.no_frame { // an editor that is the page draws no frame: the caret says where focus is
		border := th.color.primary if within && !disabled else th.color.outline
		if .Invalid in d.access.states do border = th.color.danger
		border.a *= alpha
		append(&l.cmds, Draw_Rect{rect = d.abs, radius = d.style.radius, border_w = 1, border = border})
	}
	inner := input_inner(d)
	scroll := scroll_offset(t, n)
	off := scroll.y
	// Nothing is drawn from an estimate: every block about to be painted
	// is shaped first, and a screen's worth beyond so that scrolling has
	// its heights before it needs them (the height map, above).
	if s.doc != nil {
		if shift := area_measure_range(t, s, off, off + 2 * inner.h); shift != 0 {
			if st := &t.scrolls[n]; st != nil {
				st.content.y = content_height(t, s)
				st.offset.y = max(st.offset.y + shift, 0)
				st.offset = scroll_clamp(st^, st.offset)
				off = st.offset.y
			}
		}
	}
	append(&l.cmds, Draw_Clip_Push{{inner.x, d.abs.y + 1, inner.w, d.abs.h - 2}})
	gutter_clip := false // …and a second clip for the text column, beside a gutter
	text_x := inner.x + area_text_x(s) - scroll.x // no-wrap: the text slides sideways, the gutter stays
	if s.doc == nil || (len(s.doc.blocks) == 1 && len(s.doc.blocks[0].text) == 0) {
		if len(s.placeholder) > 0 {
			fg := area_ink_muted(t, s)
			fg.a *= alpha
			append(&l.cmds, Draw_Text{pos = {text_x, inner.y - off}, str = s.placeholder, size = s.size, color = fg, wrap_w = s.wrap_w, mono = s.mono, tab = s.tab, family = s.family})
		}
	}
	lo, hi := pos_order(s.caret, s.anchor)
	fg := area_ink(t, s)
	fg.a *= alpha
	if s.doc != nil {
		if s.rich { // list numbers for this draw list: room for every block in view up front, so slices into it stay valid
			clear(&s.rich_state.numbers)
			in_view := 0
			for b := block_at_y(t, s, off); b < len(s.doc.blocks) && block_top(t, s, b) < off + inner.h; b += 1 do in_view += 1
			reserve(&s.rich_state.numbers, (in_view + 1) * 12)
		}
		if s.code.on do code_paint_under(t, n, d, s, l, inner, text_x, off, focused && !disabled)
		// The text column is clipped on its own beside a gutter: unwrapped
		// text scrolled sideways would otherwise show under the line
		// numbers. Everything that slides is inside this clip: lines,
		// selection, marks, bracket match and caret.
		if s.code.on && s.code.gutter && s.code.gutter_w > 0 {
			gutter_clip = true
			gx := inner.x + s.code.gutter_w - CODE_GUTTER_PAD / 2 + 1 // just past the gutter's hairline
			append(&l.cmds, Draw_Clip_Push{{gx, d.abs.y + 1, max(inner.x + inner.w - gx, 0), d.abs.h - 2}})
		}
		// only the blocks in view are shaped and drawn
		first := block_at_y(t, s, off)
		bottom := off + inner.h
		for b := first; b < len(s.doc.blocks); b += 1 {
			top := block_top(t, s, b)
			if top >= bottom do break
			y := inner.y - off + block_text_top(t, s, b)
			bx := text_x + block_indent(t, s, b)
			lh := area_line_h(t, s, b)
			str := area_text(t, s, b)
			spans := block_spans(t, s, b)
			if s.rich do rich_paint_block_under(t, s, l, b, b == first, text_x, inner.y - off + top, inner.w, d.abs.y, d.abs.y + d.abs.h, alpha)
			for mi in area_marks_for(s, b) do if s.marks[mi].kind == .Highlight do paint_mark(t, s, l, s.marks[mi], b, spans, bx, y)
			sel_rects := make([dynamic]Rect, context.temp_allocator)
			if within && lo != hi && b >= lo.block && b <= hi.block {
				for sp, i in spans {
					a := to_disp(t, s, b, lo.off) if b == lo.block else 0
					z := to_disp(t, s, b, hi.off) if b == hi.block else len(str) + 1 // +1: the line break is selected too
					if z <= sp.start || a >= sp.end && !(a == sp.end && b != hi.block && i == len(spans) - 1) do continue
					newline := z > sp.end && b != hi.block && i == len(spans) - 1
					if span_bidi(t, s, b, sp).on {
						for r in span_ranges(t, s, b, sp, max(a, sp.start), min(z, sp.end)) {
							append(&sel_rects, Rect{bx + r[0], y + f32(i) * lh, max(r[1] - r[0], 2), lh})
						}
						if newline { // after the line's last character, wherever that is drawn
							nx := span_x_disp(t, s, b, sp, sp.end)
							append(&sel_rects, Rect{bx + nx, y + f32(i) * lh, s.size * 0.3, lh})
						}
					} else {
						xa := span_x_disp(t, s, b, sp, max(a, sp.start))
						xb := span_x_disp(t, s, b, sp, min(z, sp.end))
						if newline do xb += s.size * 0.3 // the newline
						append(&sel_rects, Rect{bx + xa, y + f32(i) * lh, max(xb - xa, 2), lh})
					}
				}
			}
			from := len(l.cmds) // this block's words, whichever path draws them
			if len(str) > 0 {
				switch {
				case s.rich:
					rich_paint_block(t, s, l, b, bx, y, alpha)
				case s.code.on && s.code.lang != nil:
					code_paint_line(t, s, l, b, str, spans, text_x, y, alpha)
				case:
					// A Dim or Tint mark colours the words themselves, so the
					// block goes down in pieces rather than as one run; without
					// such a mark it is a single command.
					tints := area_mark_tints(t, s, b)
					if _, cut, capped := area_cap(t, s, b); capped && !(len(s.pre) > 0 && b == s.pre_block) {
						// a line past the limit: its marker in the muted ink, after whatever the marks tint
						muted := area_ink_muted(t, s)
						muted.a *= alpha
						all := make([dynamic]Mark_Tint, 0, len(tints) + 1, context.temp_allocator)
						for tn in tints do if tn.from < cut do append(&all, Mark_Tint{tn.from, min(tn.to, cut), tn.color})
						append(&all, Mark_Tint{cut, len(str), muted})
						tints = all[:]
					}
					if len(tints) > 0 {
						paint_tinted_text(t, s, l, b, str, spans, tints, text_x, y, fg)
					} else {
						append(&l.cmds, Draw_Text{pos = {text_x, y}, str = str, size = s.size, color = fg, wrap_w = s.wrap_w, mono = s.mono, tab = s.tab, no_ligatures = area_no_liga(s), family = s.family})
					}
				}
				if s.code.on && s.code.show_ws {
					ws := str
					if _, cut, capped := area_cap(t, s, b); capped && !(len(s.pre) > 0 && b == s.pre_block) do ws = str[:cut] // not the marker's spaces
					code_paint_whitespace(t, s, l, b, ws, spans, text_x, y, alpha)
				}
			}
			// The selection over the words just drawn — rich runs, syntax
			// colours and mark tints alike — and before the marks drawn over
			// text, so a misspelling's squiggle still shows on the band.
			if len(sel_rects) > 0 {
				band, text := area_selection_pair(t, s)
				selection_overpaint(t, l, from, len(l.cmds), sel_rects[:], band, text)
			}
			for mi in area_marks_for(s, b) do if s.marks[mi].kind != .Highlight do paint_mark(t, s, l, s.marks[mi], b, spans, bx, y)
			if len(s.pre) > 0 && b == s.pre_block do paint_preedit(t, s, l, b, spans, bx, y, alpha) // the input method's composition
		}
		if s.code.on do code_paint_over(t, n, d, s, l, inner, text_x, off, focused && !disabled)
	}
	if focused && !disabled && s.doc != nil {
		line, _, cx := caret_line(t, s, s.caret)
		clh := area_line_h(t, s, s.caret.block)
		cy := inner.y - off + block_text_top(t, s, s.caret.block) + f32(line) * clh
		cx += block_indent(t, s, s.caret.block)
		if !s.was_focused do s.blink_start = t.now_ms
		r := Rect{text_x + cx, cy, 1, clh}
		caret := area_ink(t, s)
		caret.a *= t.paint_opacity
		if caret_shown(t, n, &s.blink_start) do append(&l.cmds, Draw_Rect{rect = r, color = caret})
		caret_painted(t, r)
	}
	if gutter_clip do append(&l.cmds, Draw_Clip_Pop{}) // the text column: the caret is inside it too
	s.was_focused = focused && !disabled
	append(&l.cmds, Draw_Clip_Pop{})
}

// paint_tinted_text draws a block whose words a Dim or Tint mark recolours:
// one command per line per run of one colour, placed with the same offsets
// the selection uses, so the pieces land exactly where the whole line would
// have. Wrapping is already decided (`spans`), so drawing it in pieces
// cannot move it.
@(private)
paint_tinted_text :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, str: string,
	spans: []Line_Span, tints: []Mark_Tint, x0, y0: f32, base: Color) {
	lh := area_line_h(t, s, b)
	for sp, i in spans {
		y := y0 + f32(i) * lh
		at := sp.start
		for at < sp.end {
			col := mark_tint_at(tints, at, base) // the mark's own alpha stands
			z := at + 1
			for z < sp.end && mark_tint_at(tints, z, base) == col do z += 1
			c := col
			c.a *= t.paint_opacity
			left := span_x_disp(t, s, b, sp, at)
			for r in span_ranges(t, s, b, sp, at, z) do left = min(left, r[0]) // a piece is drawn from its left, whichever way it runs
			append(&l.cmds, Draw_Text{pos = {x0 + left, y}, str = str[at:z],
				size = s.size, color = c, mono = s.mono, tab = s.tab,
				no_ligatures = area_no_liga(s), family = s.family})
			at = z
		}
	}
}

// Mark_Tint is a run of a block's display text that a Dim or Tint mark
// colours, in display offsets.
@(private)
Mark_Tint :: struct {
	from, to: int,
	color:    Color,
}

// area_mark_tints is the runs of block `b` whose colour a mark changes,
// in order and not overlapping: later marks win over earlier ones, which is
// what "the last one wins" means when parts of speech and a focus fade
// cover the same words. Empty when no Dim or Tint mark touches the block,
// which is the usual case and costs one pass over the list.
@(private)
area_mark_tints :: proc(t: ^Tree, s: ^Text_Area_State, b: int, allocator := context.temp_allocator) -> []Mark_Tint {
	area_mark_index(s)
	if !s.marks_recolour do return nil
	str := area_text(t, s, b)
	n := len(str)
	if n == 0 do return nil
	// One colour per byte, last mark wins, then the runs are read off it.
	// A document's marks are few and its blocks short; the fade that covers
	// most of a document is one mark, not one per word.
	cols := make([]Color, n, context.temp_allocator)
	set := make([]bool, n, context.temp_allocator)
	muted := t.theme.color.on_surface_muted
	for mi in area_marks_for(s, b) {
		m := s.marks[mi]
		if !mark_recolours(m.kind) do continue
		lo, hi := pos_order(m.from, m.to)
		if b < lo.block || b > hi.block do continue
		a := to_disp(t, s, b, lo.off) if b == lo.block else 0
		z := to_disp(t, s, b, hi.off) if b == hi.block else n
		c := muted if m.kind == .Dim else m.color
		for i in clamp(a, 0, n) ..< clamp(z, 0, n) {
			cols[i] = c
			set[i] = true
		}
	}
	out := make([dynamic]Mark_Tint, allocator)
	i := 0
	for i < n {
		if !set[i] {
			i += 1
			continue
		}
		j := i + 1
		for j < n && set[j] && cols[j] == cols[i] do j += 1
		append(&out, Mark_Tint{from = i, to = j, color = cols[i]})
		i = j
	}
	return out[:]
}

// mark_tint_at is the colour covering display offset `off`, or `base`.
@(private)
mark_tint_at :: proc(tints: []Mark_Tint, off: int, base: Color) -> Color {
	for m in tints do if off >= m.from && off < m.to do return m.color
	return base
}

// ------------------------------------------------------- marks by block
//
// An editor hands over its marks every build, and a spell checker's are
// one a word: hundreds of thousands in a large file. Walking the list per
// block in view is too slow, so it is indexed when it changes: marks within
// a block or two are sorted by where they start, and the few that cover
// more are kept aside and always looked at. Painting a block then costs
// the marks on it, not the document's.
MARK_SPAN_SHORT :: 1 // blocks a mark may cover and still be found by its first

@(private)
area_mark_index :: proc(s: ^Text_Area_State) {
	if s.mark_index_rev == s.marks_rev do return
	clear(&s.mark_order)
	clear(&s.mark_long)
	s.marks_recolour = false
	s.marks_sorted = true
	prev := -1
	for m, i in s.marks {
		if mark_recolours(m.kind) do s.marks_recolour = true
		lo, hi := pos_order(m.from, m.to)
		if lo.block < prev do s.marks_sorted = false
		prev = lo.block
		if hi.block - lo.block > MARK_SPAN_SHORT do append(&s.mark_long, i32(i))
	}
	// A list already in document order (what a spell checker produces) needs
	// no index: sorting hundreds of thousands of marks every build costs
	// tens of ms.
	if !s.marks_sorted {
		for m, i in s.marks {
			lo, hi := pos_order(m.from, m.to)
			if hi.block - lo.block <= MARK_SPAN_SHORT do append(&s.mark_order, u64(max(lo.block, 0)) << 32 | u64(u32(i)))
		}
		slice.sort(s.mark_order[:]) // the block is the high half, so this is by block
	}
	s.mark_index_rev = s.marks_rev
}

// area_marks_for is the marks that may touch block `b`, as indices into
// `s.marks`. The slice is the state's own scratch: it lasts until the
// next call.
@(private)
area_marks_for :: proc(s: ^Text_Area_State, b: int) -> []i32 {
	area_mark_index(s)
	clear(&s.mark_scratch)
	first := max(b - MARK_SPAN_SHORT, 0)
	if s.marks_sorted { // binary search the marks themselves
		lo, hi := 0, len(s.marks)
		for lo < hi {
			mid := (lo + hi) / 2
			a, _ := pos_order(s.marks[mid].from, s.marks[mid].to)
			if a.block < first { lo = mid + 1 } else { hi = mid }
		}
		for i := lo; i < len(s.marks); i += 1 {
			a, z := pos_order(s.marks[i].from, s.marks[i].to)
			if a.block > b do break
			if z.block - a.block > MARK_SPAN_SHORT do continue // it is in mark_long
			append(&s.mark_scratch, i32(i))
		}
	} else {
		to := u64(b + 1) << 32
		from := u64(first) << 32
		lo, hi := 0, len(s.mark_order)
		for lo < hi {
			mid := (lo + hi) / 2
			if s.mark_order[mid] < from { lo = mid + 1 } else { hi = mid }
		}
		for i := lo; i < len(s.mark_order) && s.mark_order[i] < to; i += 1 {
			append(&s.mark_scratch, i32(s.mark_order[i] & 0xFFFF_FFFF))
		}
	}
	for i in s.mark_long do append(&s.mark_scratch, i)
	return s.mark_scratch[:]
}

// paint_mark draws the part of `m` that lies in block `b`: a squiggle
// (Error, Warning), an underline (Info), a strike (Strike) or a translucent
// block (Highlight) on each wrapped line segment.
@(private)
paint_mark :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, m: Mark, b: int, spans: []Line_Span, x0, y0: f32) {
	lo, hi := pos_order(m.from, m.to)
	if b < lo.block || b > hi.block do return
	str := area_text(t, s, b)
	lh := area_line_h(t, s, b)
	th := &t.theme
	c: Color
	switch m.kind {
	case .Error:     c = th.color.danger
	case .Warning:   c = th.color.warning
	case .Info:      c = th.color.primary
	case .Highlight: c = th.color.warning; c.a = 0.28
	case .Strike:    c = th.color.warning
	case .Dim, .Tint: return // these colour the text itself, not a decoration over it
	}
	c.a *= t.paint_opacity
	a := to_disp(t, s, b, lo.off) if b == lo.block else 0
	z := to_disp(t, s, b, hi.off) if b == hi.block else len(str)
	for sp, i in spans {
		if z <= sp.start || a >= sp.end do continue
		ranges := span_ranges(t, s, b, sp, max(a, sp.start), min(z, sp.end))
		if len(ranges) == 0 do continue
		xa, xb := x0 + ranges[0][0], x0 + ranges[len(ranges) - 1][1] // a mark spans its whole extent on the line
		if xb <= xa do continue
		y := y0 + f32(i) * lh
		switch m.kind {
		case .Highlight:
			append(&l.cmds, Draw_Rect{rect = {xa, y, xb - xa, lh}, color = c, radius = 2})
		case .Info:
			append(&l.cmds, Draw_Rect{rect = {xa, y + lh - 2, xb - xa, 1}, color = c})
		case .Error, .Warning:
			append(&l.cmds, Draw_Wave{pos = {xa, y + lh - WAVE_H}, width = xb - xa, color = c})
		case .Strike:
			// Through the middle of the line, not under it: an underline is
			// a link or a diagnostic, a line through is "cut this".
			append(&l.cmds, Draw_Rect{rect = {xa, y + lh * 0.52, xb - xa, 1}, color = c})
		case .Dim, .Tint: // the text is drawn in another colour instead
		}
	}
}

// paint_preedit underlines the input method's composition where it sits in
// the caret's line, its own cursor range more strongly.
@(private)
paint_preedit :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, spans: []Line_Span, x0, y0: f32, alpha: f32) {
	at := area_pre_disp(t, s)
	col := area_ink(t, s)
	col.a *= alpha
	lh := area_line_h(t, s, b)
	rule :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, spans: []Line_Span, x0, y0, lh: f32, from, to: int, thick: f32, col: Color) {
		for sp, i in spans {
			a := clamp(from, sp.start, sp.end)
			z := clamp(to, sp.start, sp.end)
			if z <= a do continue
			for r in span_ranges(t, s, b, sp, a, z) do append(&l.cmds, Draw_Rect{rect = {x0 + r[0], y0 + f32(i) * lh + lh - 2, r[1] - r[0], thick}, color = col})
		}
	}
	rule(t, s, l, b, spans, x0, y0, lh, at, at + len(s.pre), 1, col)
	if s.pre_lo >= 0 && s.pre_hi > s.pre_lo {
		rule(t, s, l, b, spans, x0, y0, lh, at + clamp(s.pre_lo, 0, len(s.pre)), at + clamp(s.pre_hi, 0, len(s.pre)), 2, col)
	}
}

// ------------------------------------------------------------ editing

@(private)
focused_area :: proc(t: ^Tree) -> (n: Node, d: ^Node_Data, s: ^Text_Area_State, ok: bool) {
	n = t.focus
	d = node_get(t, n)
	if d == nil || .Disabled in d.flags do return
	s = &t.areas[n]
	if s == nil || s.doc == nil do return
	ok = true
	return
}

// area_touch: repaint, restart the blink, keep the caret in view, and tell
// assistive technology where the caret is (code editors).
@(private)
area_touch :: proc(t: ^Tree, n: Node, s: ^Text_Area_State) {
	s.blink_start = t.now_ms
	mark_paint_dirty(t, n)
	if s.live { // the selection's blocks show raw: when that set moves, heights change — before the caret is kept in view
		lo, hi := pos_order(s.caret, s.anchor)
		if lo.block != s.live_lo || hi.block != s.live_hi {
			s.live_lo, s.live_hi = lo.block, hi.block
			s.tops_valid = false
			mark_layout_dirty(t, n)
		}
	}
	// Keeping the caret in view needs caret_line, which shapes the caret's
	// whole paragraph: per typed character that makes streamed text O(n^2),
	// and a long enough stall stops the Wayland socket being read and the
	// compositor drops the window (spikes/typing_cost). So the first typed
	// character of a frame reveals inline and the rest of the run is left
	// to area_reveals. Only typing coalesces: a click, an arrow, a paste or
	// Ctrl+End reveal at once, so code reading the scroll offset after one
	// sees it settled, and a wheel in the same frame cannot fight a reveal
	// still pending.
	if s.typed_since_frame { // a run of typing: one reveal will do (area_replace)
		if _, ok := &t.scrolls[n]; ok && s.line_h > 0 {
			s.reveal = {pos = s.caret, at = .Nearest, pending = true}
		}
		if s.code.on do code_describe_caret(t, n, s)
		return
	}
	if st, ok := &t.scrolls[n]; ok && s.line_h > 0 {
		area_reveal_to(t, s, st, s.caret, .Nearest)
	}
	if s.code.on do code_describe_caret(t, n, s)
}

@(private)
area_move :: proc(t: ^Tree, n: Node, s: ^Text_Area_State, to: Pos, extend: bool, keep_goal := false) {
	s.caret = pos_clamp(s.doc, to)
	if !extend do s.anchor = s.caret
	if !keep_goal do s.goal_x = -1
	area_touch(t, n, s)
}

@(private)
area_replace :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, a, b: Pos, ins: string, typing := false, style: Maybe(Run) = nil) {
	t := &ui.tree
	if s.readonly do return
	ins := ins
	if s.max_length > 0 && len(ins) > 0 {
		lo, hi := pos_order(a, b)
		removed := utf8.rune_count_in_string(document_range_text(s.doc, lo, hi, context.temp_allocator))
		room := s.max_length - (document_rune_count(s.doc) - removed)
		if room <= 0 do return
		if utf8.rune_count_in_string(ins) > room do ins = ins[:grapheme_snap(ins, len(rune_prefix(ins, room)))]
	}
	// typing groups into one undo entry until a pause; other edits stand alone
	if !typing || t.now_ms - s.last_edit_ms > TEXT_AREA_GROUP_MS || s.group == 0 do s.group += 1
	s.last_edit_ms = t.now_ms
	lo, _ := pos_order(a, b)
	keeps_column := s.code.on && s.code.column.doc == s.doc.id && s.code.column.stamp == block_stamp(s.doc, lo.block) && lo.off > s.code.column.at
	s.caret = document_replace(s.doc, a, b, ins, s.group, style)
	// Everything before the edit reads as it did, so the column counted to a
	// place before it still holds — typing at the end of a long line does
	// not count the line again (code_caret_column).
	if keeps_column do s.code.column.stamp = block_stamp(s.doc, lo.block)
	s.anchor = s.caret
	s.goal_x = -1
	mark_layout_dirty(t, n) // the height may change
	area_touch(t, n, s)
	// Only a typed character arms the coalescing, and only until the next
	// area_reveals clears it (why: area_touch).
	if typing do s.typed_since_frame = true
	area_changed(ui, n, s)
}

// area_break_typing makes the next typing start its own undo group (an
// action — formatting, a comment toggle, a line move — stands alone).
@(private)
area_break_typing :: proc(s: ^Text_Area_State) {
	s.last_edit_ms = -TEXT_AREA_GROUP_MS * 2
}

@(private)
area_changed :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State) {
	ask_rebuild(ui) // the accessible value follows the document
	if h, ok := ui.on_int[n]; ok do handler_send(ui, h, int(s.doc.version), n)
}

// area_vertical moves the caret `lines` wrapped lines up (< 0) or down,
// keeping the goal x across lines and blocks.
@(private)
area_vertical :: proc(t: ^Tree, n: Node, s: ^Text_Area_State, lines: int, extend: bool) {
	line, _, x := caret_line(t, s, s.caret)
	if s.goal_x < 0 do s.goal_x = x
	b := s.caret.block
	target := line + lines
	for {
		spans := block_spans(t, s, b)
		if target < 0 {
			if b == 0 {
				area_move(t, n, s, {0, 0}, extend)
				return
			}
			b -= 1
			target += len(block_spans(t, s, b))
			continue
		}
		if target >= len(spans) {
			if b == len(s.doc.blocks) - 1 {
				area_move(t, n, s, document_end(s.doc), extend)
				return
			}
			target -= len(spans)
			b += 1
			continue
		}
		off := span_hit(t, s, b, spans[target], s.goal_x - block_indent(t, s, b) + block_indent(t, s, s.caret.block))
		area_move(t, n, s, {b, off}, extend, keep_goal = true)
		return
	}
}

// text_area_text commits typed text into the focused area.
text_area_text :: proc(ui: ^Ui($Msg), text: string) -> bool {
	n, _, s, ok := focused_area(&ui.tree)
	if !ok do return false
	clean := sanitize_input(text)
	if len(clean) == 0 do return true
	style: Maybe(Run)
	if s.rich && !s.live do style = rich_typing_style(s)
	area_replace(ui, n, s, s.anchor, s.caret, clean, typing = true, style = style)
	complete_after_type(ui, n, s, clean)
	if s.rich && !s.live do rich_after_type(ui, n, s, clean)
	return true
}

text_area_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	n, _, s, ok := focused_area(t)
	if !ok do return false
	if shift_chord_bound(ui, key, mods) do return false // the app's own Ctrl+Shift+C / V / A wins
	if complete_key(ui, n, s, key, mods) do return true // an open completion list takes its keys before anything else
	if inline_key(ui, n, key, mods) do return true // …and an editor standing in for a label: Enter commits, Escape reverts
	if s.code.on && code_key(ui, n, s, key, mods) do return true // indentation, comments, find … first
	if s.live && live_key(ui, n, s, key, mods) do return true // markdown source: prefixes, marks, links
	if s.rich && !s.live && rich_key(ui, n, s, key, mods) do return true // formatting, lists, links
	// Alt or Super with an arrow is the window's (Back, Forward), after a code
	// editor's Alt+Up / Down. On macOS Option+arrows cross words, so they stay.
	when ODIN_OS != .Darwin {
		if window_nav(key, mods) do return false
	}
	doc := s.doc
	shift, ctrl := .Shift in mods, .Ctrl in mods
	lo, hi := pos_order(s.caret, s.anchor)
	has_sel := lo != hi
	#partial switch key {
	case .Left:
		to: Pos
		switch {
		case ctrl:              to = pos_prev_word(doc, s.caret)
		case has_sel && !shift: to = lo
		case:                   to = pos_prev_grapheme(doc, s.caret)
		}
		area_move(t, n, s, to, shift)
	case .Right:
		to: Pos
		switch {
		case ctrl:              to = pos_next_word(doc, s.caret)
		case has_sel && !shift: to = hi
		case:                   to = pos_next_grapheme(doc, s.caret)
		}
		area_move(t, n, s, to, shift)
	case .Up:
		area_vertical(t, n, s, -1, shift)
	case .Down:
		area_vertical(t, n, s, 1, shift)
	case .Page_Up, .Page_Down:
		if ctrl do return false // Ctrl+Page Up / Down switch a window's tabs, as in every other editor
		st := t.scrolls[n]
		page := max(int(st.viewport.y / max(s.line_h, 1)) - 1, 1)
		area_vertical(t, n, s, page if key == .Page_Down else -page, shift)
	case .Home:
		if ctrl {
			area_move(t, n, s, {0, 0}, shift)
		} else {
			// a line's span is in display bytes: mapped back to the document,
			// which differs where a line is cut at its limit or rendered
			_, sp, _ := caret_line(t, s, s.caret)
			area_move(t, n, s, {s.caret.block, to_src(t, s, s.caret.block, sp.start)}, shift)
		}
	case .End:
		if ctrl {
			area_move(t, n, s, document_end(doc), shift)
		} else {
			_, sp, _ := caret_line(t, s, s.caret)
			area_move(t, n, s, {s.caret.block, to_src(t, s, s.caret.block, sp.end)}, shift)
		}
	case .Enter:
		// Which Enter sends is the app's to say: Ctrl+Enter by default, plain
		// Enter for a chat composer. An input method's Enter commits the
		// composition and must never send half-typed words.
		sends := ctrl if s.submit == .Ctrl_Enter else (!shift && !ctrl && len(s.pre) == 0)
		if sends {
			if h, has := ui.on_activate[n]; has do handler_send(ui, h, int(doc.version), n)
		} else {
			area_replace(ui, n, s, lo, hi, "\n")
		}
	case .Backspace:
		if has_sel {
			area_replace(ui, n, s, lo, hi, "")
		} else if s.caret != (Pos{0, 0}) {
			from := pos_prev_word(doc, s.caret) if ctrl else pos_prev_grapheme(doc, s.caret)
			area_replace(ui, n, s, from, s.caret, "", typing = !ctrl)
		}
	case .Delete:
		if has_sel {
			area_replace(ui, n, s, lo, hi, "")
		} else if s.caret != document_end(doc) {
			to := pos_next_word(doc, s.caret) if ctrl else pos_next_grapheme(doc, s.caret)
			area_replace(ui, n, s, s.caret, to, "")
		}
	case .A:
		if !ctrl do return false
		area_action(ui, n, s, .Select_All)
	case .C:
		if !ctrl do return false
		area_action(ui, n, s, .Copy)
	case .X:
		if !ctrl do return false
		area_action(ui, n, s, .Cut)
	case .V:
		if !ctrl do return false
		area_action(ui, n, s, .Paste)
	case .Z:
		if !ctrl do return false
		area_action(ui, n, s, .Redo if shift else .Undo)
	case .Y:
		if !ctrl do return false
		area_action(ui, n, s, .Redo)
	case .Escape:
		if !has_sel do return false
		s.anchor = s.caret
		area_touch(t, n, s)
	case .Space:
		// arrives through text_area_text; swallow so nothing else activates
	case .Tab, .Unknown, .Menu, .F10, .F, .G, .H, .Slash, .F3, .B, .I, .U, .E, .K,
		.D, .J, .L, .M, .N, .O, .P, .Q, .R, .S, .T, .W, .N0, .N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9, .F1, .F2, .F4, .F5, .F6, .F7, .F8, .F9, .F11, .F12, .Insert, .Minus, .Equal, .Comma, .Period, .Grave, .Bracket_L, .Bracket_R, .Backslash, .Semicolon, .Apostrophe:
		return false
	}
	return true
}

// area_action is an Editor_Action, from its shortcut or from editor_action.
@(private)
area_action :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, action: Editor_Action) -> bool {
	t := &ui.tree
	lo, hi := pos_order(s.caret, s.anchor)
	switch action {
	case .Cut:
		if s.readonly || !area_copy(t, s) do return false
		area_replace(ui, n, s, lo, hi, "")
	case .Copy:
		return area_copy(t, s)
	case .Paste:
		if s.readonly || t.clipboard.get == nil do return false
		// An editor that prefers pictures takes the picture over the text a
		// browser puts beside it, and inserts nothing.
		if s.paste_prefer == .Picture && paste_other_send(ui, n, picture_only = true) do return true
		pasted, got := t.clipboard.get(t.clipboard.user, context.temp_allocator)
		clean := sanitize_multiline(pasted) if got else ""
		if len(clean) == 0 do return paste_other_send(ui, n) // a screenshot, files: the app's to take
		area_replace(ui, n, s, lo, hi, clean)
	case .Select_All:
		if document_end(s.doc) == (Pos{}) do return false
		s.anchor = {0, 0}
		s.caret = document_end(s.doc)
		s.goal_x = -1
		area_touch(t, n, s)
	case .Undo:
		if s.readonly do return false
		p := document_undo(s.doc) or_return
		area_after_history(ui, n, s, p)
	case .Redo:
		if s.readonly do return false
		p := document_redo(s.doc) or_return
		area_after_history(ui, n, s, p)
	}
	return true
}

@(private)
area_after_history :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, p: Pos) {
	t := &ui.tree
	s.caret, s.anchor = pos_clamp(s.doc, p), pos_clamp(s.doc, p)
	s.goal_x = -1
	s.group += 1
	mark_layout_dirty(t, n)
	area_touch(t, n, s)
	area_changed(ui, n, s)
}

@(private)
area_copy :: proc(t: ^Tree, s: ^Text_Area_State) -> bool {
	lo, hi := pos_order(s.caret, s.anchor)
	if lo == hi || t.clipboard.set == nil do return false
	return t.clipboard.set(t.clipboard.user, document_range_text(s.doc, lo, hi, context.temp_allocator))
}

// area_caret_rect is the caret's rectangle in window coordinates: where an
// input method's candidate window goes, and where the Menu key opens a menu.
@(private)
area_caret_rect :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Area_State) -> Rect {
	inner := input_inner(d)
	scroll := scroll_offset(t, n)
	line, _, x := caret_line(t, s, s.caret)
	b := s.caret.block
	lh := area_line_h(t, s, b)
	rect := Rect{inner.x + area_text_x(s) - scroll.x + block_indent(t, s, b) + x,
		inner.y - scroll.y + block_text_top(t, s, b) + f32(line) * lh, 1, lh}
	rect.x = clamp(rect.x, d.abs.x, d.abs.x + d.abs.w)
	rect.y = clamp(rect.y, d.abs.y, d.abs.y + d.abs.h)
	return rect
}

// text_area_commit puts an input method's text into the editor `n` as
// typing does. False when `n` is no editor.
@(private)
text_area_commit :: proc(ui: ^Ui($Msg), n: Node, text: string) -> bool {
	t := &ui.tree
	d := node_get(t, n)
	s, ok := &t.areas[n]
	if !ok || d == nil || s.doc == nil || s.readonly || .Disabled in d.flags do return false
	clean := sanitize_input(text)
	if len(clean) == 0 do return true
	area_replace(ui, n, s, s.anchor, s.caret, clean, typing = true)
	complete_after_type(ui, n, s, clean)
	if s.rich && !s.live do rich_after_type(ui, n, s, clean)
	return true
}

// text_area_delete_around deletes bytes either side of the editor's
// selection, as an input method asked. False when `n` is no editor.
@(private)
text_area_delete_around :: proc(ui: ^Ui($Msg), n: Node, before, after: int) -> bool {
	t := &ui.tree
	d := node_get(t, n)
	s, ok := &t.areas[n]
	if !ok || d == nil || s.doc == nil || s.readonly || .Disabled in d.flags do return false
	lo, hi := pos_order(s.caret, s.anchor)
	// bytes count within the caret's line, as the surrounding text sent does
	a := Pos{lo.block, ime_byte_before(block_str(s.doc, lo.block), lo.off, before)}
	b := Pos{hi.block, ime_byte_after(block_str(s.doc, hi.block), hi.off, after)}
	if a == lo && b == hi do return true
	kept := strings.clone(document_range_text(s.doc, lo, hi, context.temp_allocator), context.temp_allocator)
	area_replace(ui, n, s, a, b, kept)
	s.anchor = pos_clamp(s.doc, a)
	area_touch(t, n, s)
	return true
}

// sanitize_multiline keeps newlines (and tabs) but drops other controls.
@(private)
sanitize_multiline :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		if r == '\n' || r == '\t' || !is_control(r) do strings.write_rune(&b, r)
		else if r == '\r' do continue
	}
	return strings.to_string(b)
}

// ------------------------------------------------------------ pointer

@(private)
area_at :: proc(ui: ^Ui($Msg), pos: [2]f32) -> (n: Node, d: ^Node_Data, s: ^Text_Area_State, ok: bool) {
	t := &ui.tree
	n = interactive_target(ui, hit_test(t, pos))
	d = node_get(t, n)
	if d == nil || .Disabled in d.flags do return
	s = &t.areas[n]
	if s == nil || s.doc == nil do return
	ok = true
	return
}

// area_hit maps a window position to a document position.
@(private)
area_hit :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Area_State, pos: [2]f32) -> Pos {
	b, sp, x := area_hit_line(t, n, d, s, pos)
	return {b, span_hit(t, s, b, sp, x)}
}

// area_hit_line is the block and wrapped line a window position falls on,
// and its x along that line.
@(private)
area_hit_line :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Area_State, pos: [2]f32) -> (b: int, sp: Line_Span, x: f32) {
	inner := input_inner(d)
	scroll := scroll_offset(t, n)
	y := pos.y - inner.y + scroll.y
	b = block_at_y(t, s, y)
	spans := block_spans(t, s, b)
	top := block_text_top(t, s, b)
	line := clamp(int((y - top) / max(area_line_h(t, s, b), 1)), 0, len(spans) - 1)
	x = pos.x - inner.x - area_text_x(s) + scroll.x - block_indent(t, s, b)
	return b, spans[line], x
}

// area_hit_selection is area_hit, and whether the pointer is over the
// selection: on a selected character (both its halves, though the nearer
// caret stop of one is the selection's edge), or past the end of a line the
// selection carries on from.
@(private)
area_hit_selection :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Area_State, pos: [2]f32) -> (p: Pos, inside: bool) {
	b, sp, x := area_hit_line(t, n, d, s, pos)
	disp := span_hit_disp(t, s, b, sp, x)
	p = {b, to_src(t, s, b, disp)}
	lo, hi := pos_order(s.caret, s.anchor)
	if lo == hi do return
	under := disp // where the character under the pointer starts
	if disp > sp.start && span_x_disp(t, s, b, sp, disp) > x do under = max(grapheme_prev(area_text(t, s, b), disp), sp.start)
	c := Pos{b, to_src(t, s, b, under)}
	return p, !pos_less(c, lo) && pos_less(c, hi)
}

// area_context_press: a right-click in an editor with `on_context` puts the
// caret under the pointer, unless it is on the selection, which stays; then
// asks for the menu there.
@(private)
area_context_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	n, d, s, ok := area_at(ui, pos)
	if !ok do return false
	h, has := ui.editor_contexts[n]
	if !has do return false
	t := &ui.tree
	set_focus(t, n, false)
	complete_close(ui, s)
	s.dragging = false
	p, inside := area_hit_selection(t, n, d, s, pos)
	if inside {
		s.blink_start = t.now_ms // the view stays: the selection's other end may be out of it
		mark_paint_dirty(t, n)
	} else {
		area_move(t, n, s, p, extend = false)
	}
	ui.context_pos = pos
	return handler_send(ui, h, Editor_Context{pos = p, in_selection = inside, at = pos}, n)
}

// area_context_key: the Menu key (or Shift+F10) in an editor with
// `on_context` asks for the menu at the caret, opening under its line.
@(private)
area_context_key :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	h, has := ui.editor_contexts[n]
	if !has do return false
	d := node_get(t, n)
	s := &t.areas[n]
	if d == nil || s == nil || s.doc == nil || .Disabled in d.flags do return false
	complete_close(ui, s)
	area_touch(t, n, s) // the caret in view, so the menu opens by it
	caret := area_caret_rect(t, n, d, s)
	at := [2]f32{caret.x, clamp(caret.y + caret.h, d.abs.y, d.abs.y + d.abs.h)} // under the caret's line
	lo, hi := pos_order(s.caret, s.anchor)
	ui.context_pos = at
	return handler_send(ui, h, Editor_Context{pos = s.caret, in_selection = lo != hi, at = at}, n)
}

text_area_pointer_button :: proc(ui: ^Ui($Msg), pressed: bool, pos: [2]f32) -> bool {
	t := &ui.tree
	if !pressed {
		for _, &s in t.areas {
			if s.dragging {
				s.dragging = false
				return true
			}
		}
		return false
	}
	n, d, s, ok := area_at(ui, pos)
	if !ok do return false
	set_focus(t, n, false)
	complete_close(ui, s) // a press places the caret: the list goes
	if s.rich && !s.live && rich_press(ui, n, d, s, pos) do return true // a task's checkbox, a link
	if s.live && live_press(ui, n, d, s, pos) do return true
	// The click's own time, not the frame clock, so a busy app does not need
	// a faster double-click than an idle one.
	click_ms := ui.pointer.time_ms
	if click_ms >= s.last_click_ms && click_ms - s.last_click_ms <= MULTI_CLICK_MS && abs(pos.x - s.last_click_pos.x) <= MULTI_CLICK_PX && abs(pos.y - s.last_click_pos.y) <= MULTI_CLICK_PX {
		s.clicks += 1
	} else {
		s.clicks = 1
	}
	s.last_click_ms, s.last_click_pos = click_ms, pos
	s.pressed_pos, s.travelled = pos, false
	p := area_hit(t, n, d, s, pos)
	if s.code.on && s.code.gutter && pos.x < input_inner(d).x + s.code.gutter_w { // a click on a line number selects the line
		s.anchor = {p.block, 0}
		s.caret = {p.block + 1, 0} if p.block + 1 < len(s.doc.blocks) else Pos{p.block, len(s.doc.blocks[p.block].text)}
		s.goal_x = -1
		area_touch(t, n, s)
		return true
	}
	switch s.clicks {
	case 1:
		if .Shift in ui.pointer.mods {
			s.caret = p // Shift-click extends from the existing anchor
		} else {
			s.caret, s.anchor = p, p
		}
		s.dragging = true
	case 2:
		str := block_str(s.doc, p.block)
		lo, hi := word_at(str, p.off)
		s.anchor, s.caret = Pos{p.block, lo}, Pos{p.block, hi}
	case:
		s.anchor, s.caret = Pos{p.block, 0}, Pos{p.block, len(s.doc.blocks[p.block].text)}
	}
	s.goal_x = -1
	area_touch(t, n, s)
	primary_mark(t, n, fresh = true)
	return true
}

text_area_pointer_move :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	for n, &s in t.areas {
		if !s.dragging do continue
		d := node_get(t, n)
		if d == nil {
			s.dragging = false
			continue
		}
		if !s.travelled && abs(pos.x - s.pressed_pos.x) <= MULTI_CLICK_PX && abs(pos.y - s.pressed_pos.y) <= MULTI_CLICK_PX do return true // jitter, not a drag: the caret stays where the press put it
		s.travelled = true
		if p := area_hit(t, n, d, &s, pos); p != s.caret {
			s.caret = p
			area_touch(t, n, &s)
			primary_mark(t, n)
		}
		return true
	}
	return false
}
