package baldr

// Document is the editable text model shared by the text area, the code
// editor and the rich text / markdown editors: a sequence of
// blocks of UTF-8 text, edited in place by the widget the way `Text` is by
// a text input, with an undo journal. Positions are (block, byte offset)
// on grapheme boundaries.
//
// Rich text lives in the same blocks: every block has a kind (paragraph,
// heading, list item, quote, code, rule) with its level / depth / checked
// state, and `runs` — attribute runs (bold, italic, underline, strike,
// code, link) covering the text in order. A block with no runs is plain.
// Text edits keep the runs consistent (typing continues the style at the
// caret, deleting removes what it covers, splitting and joining blocks
// split and join the runs), and every change — text, attributes, block
// kinds — is one journal entry, so undo restores formatting too.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

// Document is the editable text model behind `text_area`, `code_editor` and
// the rich-text and markdown editors: a sequence of `Block`s of UTF-8 text
// with a grouped undo journal. Positions are `(block, byte offset)` on
// grapheme boundaries. Make one with `document_make` and free it with
// `document_destroy`; the app owns it and it outlives any one view.
// `version` bumps on every change, which is a cheap "did it change" for a
// view to compare against.
Document :: struct {
	blocks:    [dynamic]Block,
	undo:      [dynamic]Edit,
	redo:      [dynamic]Edit,
	version:   u64, // bumps on every change; a cheap "did it change" for views
	stamper:   u64, // the last per-block stamp handed out (block_stamp)
	id:        u64, // unique per document: tells a new one from one it replaced at the same address, which `version` cannot
	allocator: runtime.Allocator,
}

// Table: one row of a table, its cells written "| a | b |" in the text
// (consecutive Table blocks form one table; level 1 = a header row).
// Table_Sep is a markdown "|---|---|" line as the live view sees it.
Block_Kind :: enum u8 { Paragraph, Heading, Bullet, Numbered, Task, Quote, Code, Rule, Image, Table, Table_Sep }

// table_cells splits a row's text into its cells' byte ranges (the text
// between the pipes, outer pipes optional, cell text trimmed of spaces).
// The ranges are in temp memory by default: copy what you keep.
table_cells :: proc(row: string, allocator := context.temp_allocator) -> [][2]int {
	out := make([dynamic][2]int, allocator)
	lo, hi := 0, len(row)
	for lo < hi && row[lo] == ' ' do lo += 1
	for hi > lo && row[hi - 1] == ' ' do hi -= 1
	if lo < hi && row[lo] == '|' do lo += 1
	if hi > lo && row[hi - 1] == '|' do hi -= 1
	start := lo
	for i := lo; i <= hi; i += 1 {
		if i == hi || row[i] == '|' {
			a, z := start, i
			for a < z && row[a] == ' ' do a += 1
			for z > a && row[z - 1] == ' ' do z -= 1
			append(&out, [2]int{a, z})
			start = i + 1
		}
	}
	return out[:]
}

// table_sep_line reports a "|---|:--:|" separator line.
table_sep_line :: proc(line: string) -> bool {
	t := strings.trim_space(line)
	if len(t) < 3 || strings.index_byte(t, '-') < 0 || strings.index_byte(t, '|') < 0 do return false // "---" alone is a rule
	for c in transmute([]u8)t do if c != '|' && c != '-' && c != ':' && c != ' ' do return false
	return true
}

// Table_Align is how a table's column is set. `Default` is what a table
// that says nothing gets, and lets the renderer decide — which is not the
// same as `Left`, because a column of numbers reads better right-aligned
// and a table that has not asked for anything should get that.
Table_Align :: enum u8 { Default, Left, Center, Right }

// table_sep_align reads the alignment a "|---|:--:|---:|" line declares,
// one entry per column: `:---` left, `---:` right, `:---:` centred, and a
// bare `---` Default. Empty when `line` is not a separator.
//
// The caller's memory.
table_sep_align :: proc(line: string, allocator := context.temp_allocator) -> []Table_Align {
	if !table_sep_line(line) do return nil
	cells := table_cells(strings.trim_space(line))
	if len(cells) == 0 do return nil
	t := strings.trim_space(line)
	out := make([]Table_Align, len(cells), allocator)
	for cell, i in cells {
		part := strings.trim_space(t[cell[0]:cell[1]])
		if len(part) == 0 do continue
		left  := part[0] == ':'
		right := part[len(part) - 1] == ':'
		switch {
		case left && right: out[i] = .Center
		case right:         out[i] = .Right
		case left:          out[i] = .Left
		}
	}
	return out
}

// table_cells_numeric says whether every non-empty cell of `cells` in
// `text` reads as a number: digits, with grouping and decimal marks, a
// currency symbol or a percent sign, and a leading minus. Empty cells are
// skipped, but a column with nothing in it is not numeric. It lets a table
// that declares no alignment still right-align its figures, and is strict
// on purpose: "P001" has letters, so a column of part numbers stays put.
table_cells_numeric :: proc(text: string, cells: [][2]int) -> bool {
	any_seen := false
	for cell in cells {
		s := strings.trim_space(text[cell[0]:cell[1]])
		if len(s) == 0 do continue
		digits, first := false, true
		for r in s { // by rune: a currency symbol is not one byte
			switch {
			case r >= '0' && r <= '9': digits = true
			case r == '-' || r == '+' || r == '(' || r == ')':
				if !first && r != ')' do return false // a sign leads; brackets are the accounting minus
			case r == ',' || r == '.' || r == ' ' || r == '_':
			case r == '%' || r == '$' || r == '#':
			case r == '£' || r == '€' || r == '¥' || r == '₹' || r == '¢':
			case: return false // anything else, including any other letter or script
			}
			first = false
		}
		if !digits do return false
		any_seen = true
	}
	return any_seen
}

// Block is one paragraph, heading, list item or code block of a `Document`:
// its UTF-8 text, which kind it is, how deep it sits in a list, and the
// attribute runs over its bytes.
Block :: struct {
	text:    [dynamic]u8,
	kind:    Block_Kind,
	level:   u8,   // heading: 1..6
	depth:   u8,   // list nesting: 0..
	checked: bool, // task item
	lang:    string, // code block language name (owned; "" = none)
	src:     string, // image source (a path or URL; owned); the text is the alt text
	// A table header row's declared column alignment, two bits a column and
	// up to 32 of them (table_align_get / table_align_set), so a markdown
	// `|---:|` survives a save. A plain number rather than a slice: it copies
	// with the block, so undo, redo and duplication keep it without owning
	// anything.
	align:   u64,
	runs:    [dynamic]Run, // attribute runs in order, covering [0, len(text)); empty = all plain
	// What this block's content is, as a number: `block_stamp` gives an
	// unstamped block the next one, and every change to its text, runs or
	// meta clears it, so the same stamp means the block is as it was.
	// 0 = unstamped. It lets a view keep per-block work across an edit,
	// where `doc.version` changes for the whole document on every keystroke.
	stamp:   u64,
}

// block_stamp names block `i`'s content. The same number on two reads
// means the block has not changed in between; a block that has been
// edited, or is new, takes the next number, and a number is never used
// twice in one document — so a cache keyed by it can also survive blocks
// being inserted and removed above.
//
//	if h, ok := cache[block_stamp(doc, b)]; ok do return h   // still true
block_stamp :: proc(doc: ^Document, i: int) -> u64 {
	if i < 0 || i >= len(doc.blocks) do return 0
	b := &doc.blocks[i]
	if b.stamp == 0 {
		doc.stamper += 1
		b.stamp = doc.stamper
	}
	return b.stamp
}

// block_touch says block `b`'s content changed: it drops its stamp, so
// the next `block_stamp` hands out a fresh one and every view's cached
// work for it falls away. Call it from anything that writes a block's
// text, runs or meta — over-calling costs a re-measure, missing a call
// leaves a view drawing the old shape.
@(private)
block_touch :: proc "contextless" (b: ^Block) {
	b.stamp = 0
}

// table_align_get is column `i`'s alignment out of a header block's packed
// `align`. Columns past the 32 it holds read as Default.
table_align_get :: proc "contextless" (packed: u64, i: int) -> Table_Align {
	if i < 0 || i >= 32 do return .Default
	return Table_Align((packed >> uint(i * 2)) & 3)
}

// table_align_set puts column `i`'s alignment into a packed value.
table_align_set :: proc "contextless" (packed: u64, i: int, a: Table_Align) -> u64 {
	if i < 0 || i >= 32 do return packed
	return (packed &~ (u64(3) << uint(i * 2))) | (u64(a) << uint(i * 2))
}

// table_align_pack is a whole row's alignment as one value.
table_align_pack :: proc(cols: []Table_Align) -> (packed: u64) {
	for a, i in cols do packed = table_align_set(packed, i, a)
	return
}

// Block_Meta is everything about a block but its text and runs.
Block_Meta :: struct {
	kind:    Block_Kind,
	level:   u8,
	depth:   u8,
	checked: bool,
	lang:    string,
	src:     string, // image source
	align:   u64,    // a table header row's declared column alignment (see Block.align)
}

// Attr is one character attribute over a document's text — the formatting a
// rich or markdown editor applies. `Attrs` is a set of them, and `Run`
// carries one set over a stretch of bytes.
Attr :: enum u8 { Bold, Italic, Underline, Strike, Code, Link, Highlight, Mark } // Highlight: text washed as with a highlighter pen (markdown `==text==`); Mark: a markdown mark shown dimmed (display only, never in a document)
Attrs :: bit_set[Attr; u8]

// Run is one attribute run: it covers the bytes from the previous run's
// `end` (or 0) up to `end`.
Run :: struct {
	end:   int,
	attrs: Attrs,
	href:  string, // owned; only with .Link
}

// Pos is a caret position: block index and byte offset inside it.
Pos :: struct {
	block, off: int,
}

// Edit_Kind is what one entry in a document's undo journal did.
Edit_Kind :: enum u8 { Insert, Delete, Runs, Meta }

// Edit is one journal entry. Insert / Delete carry the text and its runs
// (offsets relative to the text; the text may span blocks) and the metas
// of the blocks the text creates / removed; Runs and Meta carry the old
// and new state of one block. Entries sharing a `group` undo and redo
// together (a typed word, a paste, a toolbar action over many blocks).
Edit :: struct {
	kind:       Edit_Kind,
	at:         Pos,
	text:       string,   // owned by the document's allocator
	group:      u64,
	runs:       []Run,    // Insert / Delete: the text's runs; Runs: the block's runs before
	runs_after: []Run,    // Runs: the block's runs after
	metas:      []Block_Meta, // Insert / Delete: the metas of the blocks after the first (one per newline)
	meta, meta_after: Block_Meta, // Meta: before / after
}

// doc_ids names documents so a widget can tell a new one from the one it
// cached. A pointer cannot: a freed document's address is often handed
// straight to the next, and a document set once has the same `version` as
// the one it replaced. The same pattern as `image_ids`.
@(private)
doc_ids: u64

// doc_new_id names one document.
@(private)
doc_new_id :: proc() -> u64 {
	return sync.atomic_add(&doc_ids, 1) + 1
}

document_make :: proc(initial := "", allocator := context.allocator) -> Document {
	doc := Document{allocator = allocator, id = doc_new_id()}
	doc.blocks = make([dynamic]Block, allocator)
	doc.undo = make([dynamic]Edit, allocator)
	doc.redo = make([dynamic]Edit, allocator)
	document_set_text(&doc, initial)
	return doc
}

document_destroy :: proc(doc: ^Document) {
	for &b in doc.blocks do block_free(doc, &b)
	delete(doc.blocks)
	edits_clear(doc, &doc.undo)
	edits_clear(doc, &doc.redo)
	delete(doc.undo)
	delete(doc.redo)
	doc^ = {}
}

@(private)
block_free :: proc(doc: ^Document, b: ^Block) {
	delete(b.text)
	runs_free(doc, b.runs[:])
	delete(b.runs)
	if len(b.lang) > 0 do delete(b.lang, doc.allocator)
	if len(b.src) > 0 do delete(b.src, doc.allocator)
	b^ = {}
}

@(private)
runs_free :: proc(doc: ^Document, runs: []Run) {
	for r in runs do if len(r.href) > 0 do delete(r.href, doc.allocator)
}

@(private)
runs_clone :: proc(doc: ^Document, runs: []Run) -> []Run {
	if len(runs) == 0 do return nil
	out := make([]Run, len(runs), doc.allocator)
	for r, i in runs {
		out[i] = r
		if len(r.href) > 0 do out[i].href = strings.clone(r.href, doc.allocator)
	}
	return out
}

@(private)
meta_clone :: proc(doc: ^Document, m: Block_Meta) -> Block_Meta {
	m := m
	if len(m.lang) > 0 do m.lang = strings.clone(m.lang, doc.allocator)
	if len(m.src) > 0 do m.src = strings.clone(m.src, doc.allocator)
	return m
}

@(private)
meta_free :: proc(doc: ^Document, m: Block_Meta) {
	if len(m.lang) > 0 do delete(m.lang, doc.allocator)
	if len(m.src) > 0 do delete(m.src, doc.allocator)
}

@(private)
edit_free :: proc(doc: ^Document, e: Edit) {
	delete(e.text, doc.allocator)
	runs_free(doc, e.runs)
	delete(e.runs, doc.allocator)
	runs_free(doc, e.runs_after)
	delete(e.runs_after, doc.allocator)
	for m in e.metas do meta_free(doc, m)
	delete(e.metas, doc.allocator)
	meta_free(doc, e.meta)
	meta_free(doc, e.meta_after)
}

@(private)
edits_clear :: proc(doc: ^Document, edits: ^[dynamic]Edit) {
	for e in edits do edit_free(doc, e)
	clear(edits)
}

@(private)
document_ensure :: proc(doc: ^Document) {
	if doc.id == 0 do doc.id = doc_new_id() // a zero-valued Document used directly
	if doc.allocator.procedure == nil do doc.allocator = context.allocator
	if doc.blocks == nil do doc.blocks = make([dynamic]Block, doc.allocator)
	if len(doc.blocks) == 0 do append(&doc.blocks, Block{text = make([dynamic]u8, doc.allocator)})
	if doc.undo == nil do doc.undo = make([dynamic]Edit, doc.allocator)
	if doc.redo == nil do doc.redo = make([dynamic]Edit, doc.allocator)
}

// document_set_text replaces everything (no undo entry) with `s`, one
// plain paragraph per line.
document_set_text :: proc(doc: ^Document, s: string) {
	document_ensure(doc)
	for &b in doc.blocks do block_free(doc, &b)
	clear(&doc.blocks)
	rest := s
	for {
		i := strings.index_byte(rest, '\n')
		line := rest if i < 0 else rest[:i]
		b := Block{text = make([dynamic]u8, 0, len(line), doc.allocator)}
		append(&b.text, ..transmute([]u8)line)
		append(&doc.blocks, b)
		if i < 0 do break
		rest = rest[i + 1:]
	}
	edits_clear(doc, &doc.undo)
	edits_clear(doc, &doc.redo)
	doc.version += 1
}

// document_text joins the blocks with '\n'. The string is the caller's to
// free (it is allocated with `allocator`, the context's by default).
document_text :: proc(doc: ^Document, allocator := context.allocator) -> string {
	return document_range_text(doc, document_start(), document_end(doc), allocator)
}

// document_range_text is the text between two positions, the caller's to
// free as document_text's is.
document_range_text :: proc(doc: ^Document, a, b: Pos, allocator := context.allocator) -> string {
	lo, hi := pos_order(a, b)
	sb := strings.builder_make(allocator)
	for i in lo.block ..= hi.block {
		if i < 0 || i >= len(doc.blocks) do break
		s := block_str(doc, i)
		from := lo.off if i == lo.block else 0
		to := hi.off if i == hi.block else len(s)
		strings.write_string(&sb, s[clamp(from, 0, len(s)):clamp(to, 0, len(s))])
		if i != hi.block do strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// block_str is block `i`'s text as it stands. It aliases the document's own
// storage: the next edit to that block invalidates it, so copy what you keep.
block_str :: proc(doc: ^Document, i: int) -> string {
	if i < 0 || i >= len(doc.blocks) do return ""
	return string(doc.blocks[i].text[:])
}

block_count :: proc(doc: ^Document) -> int {
	return len(doc.blocks)
}

// block_meta is a block's kind and settings (the lang string is borrowed).
block_meta :: proc(doc: ^Document, i: int) -> Block_Meta {
	if i < 0 || i >= len(doc.blocks) do return {}
	b := &doc.blocks[i]
	return {kind = b.kind, level = b.level, depth = b.depth, checked = b.checked, lang = b.lang, src = b.src, align = b.align}
}

document_start :: proc() -> Pos { return {0, 0} }

document_end :: proc(doc: ^Document) -> Pos {
	if len(doc.blocks) == 0 do return {0, 0}
	last := len(doc.blocks) - 1
	return {last, len(doc.blocks[last].text)}
}

// document_rune_count counts characters (block breaks count as one each).
document_rune_count :: proc(doc: ^Document) -> (n: int) {
	for b, i in doc.blocks do n += utf8.rune_count(b.text[:]) + (1 if i > 0 else 0)
	return
}

document_len :: proc(doc: ^Document) -> (n: int) {
	for b, i in doc.blocks do n += len(b.text) + (1 if i > 0 else 0)
	return
}

pos_less :: proc "contextless" (a, b: Pos) -> bool {
	return a.block < b.block || (a.block == b.block && a.off < b.off)
}

// document_flat_off is a position as a byte offset into `document_text` —
// the blocks joined with a newline apiece. The accessibility bridge counts
// this way, and so does a selection that runs across several documents.
document_flat_off :: proc(doc: ^Document, p: Pos) -> int {
	off := 0
	for i in 0 ..< len(doc.blocks) {
		if i == p.block do return off + clamp(p.off, 0, len(block_str(doc, i)))
		off += len(block_str(doc, i)) + 1 // the newline document_text writes
	}
	return max(off - 1, 0)
}

// document_pos_at is the other way: the position a byte offset into
// `document_text` names. Past the end is the end.
document_pos_at :: proc(doc: ^Document, off: int) -> Pos {
	left := max(off, 0)
	for i in 0 ..< len(doc.blocks) {
		n := len(block_str(doc, i))
		if left <= n do return Pos{block = i, off = left}
		left -= n + 1 // the newline document_text writes
	}
	return document_end(doc)
}

pos_order :: proc "contextless" (a, b: Pos) -> (lo, hi: Pos) {
	if pos_less(b, a) do return b, a
	return a, b
}

pos_clamp :: proc(doc: ^Document, p: Pos) -> Pos {
	if len(doc.blocks) == 0 do return {0, 0}
	b := clamp(p.block, 0, len(doc.blocks) - 1)
	s := block_str(doc, b)
	return {b, grapheme_snap(s, clamp(p.off, 0, len(s)))}
}

// ------------------------------------------------------------ movement

pos_next_grapheme :: proc(doc: ^Document, p: Pos) -> Pos {
	s := block_str(doc, p.block)
	if p.off < len(s) do return {p.block, grapheme_next(s, p.off)}
	if p.block + 1 < len(doc.blocks) do return {p.block + 1, 0}
	return p
}

pos_prev_grapheme :: proc(doc: ^Document, p: Pos) -> Pos {
	if p.off > 0 do return {p.block, grapheme_prev(block_str(doc, p.block), p.off)}
	if p.block > 0 do return {p.block - 1, len(doc.blocks[p.block - 1].text)}
	return p
}

pos_next_word :: proc(doc: ^Document, p: Pos) -> Pos {
	s := block_str(doc, p.block)
	if p.off < len(s) do return {p.block, word_next(s, p.off)}
	if p.block + 1 < len(doc.blocks) do return {p.block + 1, 0}
	return p
}

pos_prev_word :: proc(doc: ^Document, p: Pos) -> Pos {
	if p.off > 0 do return {p.block, word_prev(block_str(doc, p.block), p.off)}
	if p.block > 0 do return {p.block - 1, len(doc.blocks[p.block - 1].text)}
	return p
}

// ------------------------------------------------------------ runs

// attrs_at is the style at `p`: of the character before it (what typing
// there continues), else of the one after; plain at an empty block.
attrs_at :: proc(doc: ^Document, p: Pos) -> Attrs {
	if p.block < 0 || p.block >= len(doc.blocks) do return {}
	b := &doc.blocks[p.block]
	if len(b.runs) == 0 do return {}
	off := p.off if p.off > 0 else 1
	return run_at(b, off - 1).attrs
}

// href_at is the link target at `p`, "" when none. It aliases the run's own
// storage: an edit to that block invalidates it.
href_at :: proc(doc: ^Document, p: Pos) -> string {
	if p.block < 0 || p.block >= len(doc.blocks) do return ""
	b := &doc.blocks[p.block]
	if len(b.runs) == 0 do return ""
	off := clamp(p.off, 0, max(len(b.text) - 1, 0))
	r := run_at(b, off)
	return r.href if .Link in r.attrs else ""
}

// run_at is the run covering byte `off` (the last run when past the end).
@(private)
run_at :: proc(b: ^Block, off: int) -> Run {
	start := 0
	for r in b.runs {
		if off < r.end || r.end == len(b.text) do return r
		start = r.end
	}
	_ = start
	if len(b.runs) > 0 do return b.runs[len(b.runs) - 1]
	return {}
}

// runs_normalize keeps a block's runs covering its text exactly: the last
// run ends at len(text), empty runs go, neighbours with the same style
// merge, and an all-plain block keeps no runs at all.
@(private)
runs_normalize :: proc(doc: ^Document, b: ^Block) {
	n := len(b.text)
	// clamp and drop empties
	i := 0
	start := 0
	for i < len(b.runs) {
		r := &b.runs[i]
		if r.end > n do r.end = n
		if r.end <= start {
			if len(r.href) > 0 do delete(r.href, doc.allocator)
			ordered_remove(&b.runs, i)
			continue
		}
		start = r.end
		i += 1
	}
	if len(b.runs) > 0 && b.runs[len(b.runs) - 1].end < n do b.runs[len(b.runs) - 1].end = n
	// merge neighbours
	i = 1
	for i < len(b.runs) {
		a, c := &b.runs[i - 1], &b.runs[i]
		if a.attrs == c.attrs && a.href == c.href {
			a.end = c.end
			if len(c.href) > 0 do delete(c.href, doc.allocator)
			ordered_remove(&b.runs, i)
			continue
		}
		i += 1
	}
	// all plain: no runs
	if len(b.runs) == 1 && b.runs[0].attrs == {} {
		if len(b.runs[0].href) > 0 do delete(b.runs[0].href, doc.allocator)
		clear(&b.runs)
	}
	if len(b.runs) == 0 && n == 0 do return
}

// runs_ensure gives a plain block one explicit run so edits can split it.
@(private)
runs_ensure :: proc(doc: ^Document, b: ^Block) {
	if b.runs == nil do b.runs = make([dynamic]Run, doc.allocator)
	if len(b.runs) == 0 do append(&b.runs, Run{end = len(b.text)})
}
// runs_shift_insert accounts for `n` bytes just inserted at `off`: the run
// around `off` grows (typing continues the style before the caret; a run's
// end counts as inside it), then a given `style` cuts the new bytes into
// their own run.
@(private)
runs_shift_insert :: proc(doc: ^Document, b: ^Block, off, n: int, style: Maybe(Run)) {
	if n == 0 do return
	block_touch(b)
	had := len(b.runs) > 0
	if !had && style == nil do return // plain stays plain
	if had {
		grown := false
		for &r in b.runs {
			if grown {
				r.end += n
			} else if r.end >= off {
				r.end += n
				grown = true
			}
		}
	} else {
		runs_ensure(doc, b) // one run over the whole text, the new bytes included
	}
	if st, has := style.?; has do run_cut(doc, b, off, off + n, st.attrs, st.href)
	runs_normalize(doc, b)
}
// run_cut sets [lo, hi) to `attrs` / `href`, splitting the runs at the edges.
@(private)
run_cut :: proc(doc: ^Document, b: ^Block, lo, hi: int, attrs: Attrs, href: string) {
	if hi <= lo do return
	block_touch(b)
	runs_ensure(doc, b)
	out := make([dynamic]Run, 0, len(b.runs) + 2, doc.allocator)
	start := 0
	for r in b.runs {
		rs, re := start, r.end
		start = r.end
		if re <= lo || rs >= hi { // untouched
			append(&out, r)
			continue
		}
		if rs < lo do append(&out, Run{end = lo, attrs = r.attrs, href = strings.clone(r.href, doc.allocator) if len(r.href) > 0 else ""})
		if re > hi do append(&out, Run{end = re, attrs = r.attrs, href = strings.clone(r.href, doc.allocator) if len(r.href) > 0 else ""})
		if len(r.href) > 0 do delete(r.href, doc.allocator)
	}
	append(&out, Run{end = hi, attrs = attrs, href = strings.clone(href, doc.allocator) if len(href) > 0 else ""})
	for i in 1 ..< len(out) { // back in order (by end)
		j := i
		for j > 0 && out[j - 1].end > out[j].end {
			out[j - 1], out[j] = out[j], out[j - 1]
			j -= 1
		}
	}
	delete(b.runs)
	b.runs = out
	runs_normalize(doc, b)
}
// runs_shift_delete accounts for [lo, hi) removed from the text: every run
// end moves back by the deleted bytes before it.
@(private)
runs_shift_delete :: proc(doc: ^Document, b: ^Block, lo, hi: int) {
	if hi <= lo || len(b.runs) == 0 do return
	block_touch(b)
	for &r in b.runs do r.end -= clamp(r.end, lo, hi) - lo
	runs_normalize(doc, b)
}

// range_runs copies the runs of [lo, hi) with offsets relative to the
// range's text (blocks joined by "\n"), for the journal and the clipboard.
@(private)
range_runs :: proc(doc: ^Document, lo, hi: Pos) -> []Run {
	out := make([dynamic]Run, doc.allocator)
	base := 0
	for bi in lo.block ..= hi.block {
		b := &doc.blocks[bi]
		from := lo.off if bi == lo.block else 0
		to := hi.off if bi == hi.block else len(b.text)
		if len(b.runs) == 0 {
			append(&out, Run{end = base + (to - from)})
		} else {
			start := 0
			for r in b.runs {
				rs, re := start, r.end
				start = r.end
				a, z := max(rs, from), min(re, to)
				if z <= a do continue
				append(&out, Run{end = base + (z - from), attrs = r.attrs, href = strings.clone(r.href, doc.allocator) if len(r.href) > 0 else ""})
			}
		}
		base += to - from
		if bi != hi.block {
			append(&out, Run{end = base + 1}) // the newline, plain
			base += 1
		}
	}
	// merge neighbours with the same style
	i := 1
	for i < len(out) {
		if out[i - 1].attrs == out[i].attrs && out[i - 1].href == out[i].href {
			out[i - 1].end = out[i].end
			if len(out[i].href) > 0 do delete(out[i].href, doc.allocator)
			ordered_remove(&out, i)
			continue
		}
		i += 1
	}
	if len(out) == 1 && out[0].attrs == {} {
		delete(out)
		return nil
	}
	return out[:]
}

// apply_range_runs restores `runs` (relative to `text`) over the text just
// inserted at `at`; no runs means the text was plain, and it is cut plain
// so a neighbouring styled run does not swallow it.
@(private)
apply_range_runs :: proc(doc: ^Document, at: Pos, text: string, runs: []Run) {
	plain := [1]Run{{end = len(text)}}
	runs := runs
	if len(runs) == 0 do runs = plain[:]
	p := at
	start := 0
	for r in runs {
		// walk the run's bytes across block breaks
		seg_start := start
		for seg_start < r.end {
			nl := strings.index_byte(text[seg_start:r.end], '\n')
			seg_end := r.end if nl < 0 else seg_start + nl
			if seg_end > seg_start { // plain runs too: the growth of a neighbouring styled run is undone
				run_cut(doc, &doc.blocks[p.block], p.off, p.off + (seg_end - seg_start), r.attrs, r.href)
			}
			p.off += seg_end - seg_start
			if nl >= 0 {
				p = {p.block + 1, 0}
				seg_end += 1
			}
			seg_start = seg_end
		}
		start = r.end
	}
}

// ------------------------------------------------------------ editing

// document_replace deletes [a, b) and inserts `s` there (newlines split
// blocks; a new block takes the first one's kind, a plain paragraph after
// a heading or a rule). Typed text continues the style at `a` unless
// `style` says otherwise. Both steps share `group` in the journal.
// Returns the position after the insertion.
document_replace :: proc(doc: ^Document, a, b: Pos, s: string, group: u64 = 0, style: Maybe(Run) = nil) -> Pos {
	document_ensure(doc)
	lo, hi := pos_order(pos_clamp(doc, a), pos_clamp(doc, b))
	edits_clear(doc, &doc.redo)
	first_piece := s
	if nl := strings.index_byte(s, '\n'); nl >= 0 do first_piece = s[:nl]
	if len(first_piece) > 0 && doc.blocks[lo.block].kind == .Rule { // text into a rule: it becomes a paragraph first, in the same group (a newline alone splits after it)
		old := meta_clone(doc, block_meta(doc, lo.block))
		append(&doc.undo, Edit{kind = .Meta, at = {lo.block, 0}, group = group, meta = old, meta_after = {kind = .Paragraph}})
		set_meta(doc, lo.block, {kind = .Paragraph})
	}
	if lo != hi {
		removed := document_range_text(doc, lo, hi, doc.allocator)
		e := Edit{kind = .Delete, at = lo, text = removed, group = group, runs = range_runs(doc, lo, hi), metas = joined_metas(doc, lo, hi)}
		delete_range(doc, lo, hi)
		append(&doc.undo, e)
	}
	end := lo
	if len(s) > 0 {
		e := Edit{kind = .Insert, at = lo, text = strings.clone(s, doc.allocator), group = group}
		end = insert_text(doc, lo, s, style)
		e.runs = range_runs(doc, lo, end)
		e.metas = joined_metas(doc, lo, end)
		append(&doc.undo, e)
	}
	doc.version += 1
	return end
}

// joined_metas snapshots the metas of the blocks after the first in [lo, hi].
@(private)
joined_metas :: proc(doc: ^Document, lo, hi: Pos) -> []Block_Meta {
	if hi.block <= lo.block do return nil
	out := make([]Block_Meta, hi.block - lo.block, doc.allocator)
	for bi in lo.block + 1 ..= hi.block do out[bi - lo.block - 1] = meta_clone(doc, block_meta(doc, bi))
	return out
}

@(private)
insert_text :: proc(doc: ^Document, at: Pos, s: string, style: Maybe(Run) = nil, metas: []Block_Meta = nil) -> Pos {
	p := at
	rest := s
	created := 0
	for {
		i := strings.index_byte(rest, '\n')
		piece := rest if i < 0 else rest[:i]
		b := &doc.blocks[p.block]
		block_touch(b)
		inject_at(&b.text, p.off, ..transmute([]u8)piece)
		runs_shift_insert(doc, b, p.off, len(piece), style)
		p.off += len(piece)
		if i < 0 do break
		// split the block after the inserted piece: the tail (text and runs) moves down
		tail := Block{text = make([dynamic]u8, doc.allocator)}
		append(&tail.text, ..b.text[p.off:])
		resize(&b.text, p.off)
		if len(b.runs) > 0 {
			tail.runs = make([dynamic]Run, doc.allocator)
			start := 0
			for r in b.runs {
				rs := start
				start = r.end
				if r.end > p.off do append(&tail.runs, Run{end = r.end - p.off, attrs = r.attrs, href = strings.clone(r.href, doc.allocator) if len(r.href) > 0 else ""})
				_ = rs
			}
			runs_normalize(doc, b)
			runs_normalize(doc, &tail)
		}
		if created < len(metas) {
			m := metas[created]
			tail.kind, tail.level, tail.depth, tail.checked = m.kind, m.level, m.depth, m.checked
			if len(m.lang) > 0 do tail.lang = strings.clone(m.lang, doc.allocator)
			if len(m.src) > 0 do tail.src = strings.clone(m.src, doc.allocator)
		} else {
			tail.kind, tail.level, tail.depth = b.kind, b.level, b.depth // a new list item / quote line; paragraphs after headings and rules
			if b.kind == .Heading || b.kind == .Rule || b.kind == .Image do tail.kind, tail.level = .Paragraph, 0
			if b.kind == .Code && len(b.lang) > 0 do tail.lang = strings.clone(b.lang, doc.allocator)
		}
		created += 1
		inject_at(&doc.blocks, p.block + 1, tail)
		p = {p.block + 1, 0}
		rest = rest[i + 1:]
	}
	return p
}
@(private)
delete_range :: proc(doc: ^Document, lo, hi: Pos) {
	if lo.block == hi.block {
		block_touch(&doc.blocks[lo.block])
		remove_range(&doc.blocks[lo.block].text, lo.off, hi.off)
		runs_shift_delete(doc, &doc.blocks[lo.block], lo.off, hi.off)
		return
	}
	first := &doc.blocks[lo.block]
	last := &doc.blocks[hi.block]
	if first.kind == .Rule { // a rule cannot hold the joined text: the result takes the last block's shape
		set_meta(doc, lo.block, block_meta(doc, hi.block))
	}
	// the first block keeps [0, lo.off) and takes the last block's tail (text and runs)
	block_touch(first)
	old_len := len(first.text)
	remove_range(&first.text, lo.off, old_len)
	runs_shift_delete(doc, first, lo.off, old_len)
	tail_len := len(last.text) - hi.off
	if len(last.runs) > 0 {
		runs_ensure(doc, first)
		for r in last.runs {
			if r.end <= hi.off do continue
			append(&first.runs, Run{end = lo.off + (r.end - hi.off), attrs = r.attrs, href = strings.clone(r.href, doc.allocator) if len(r.href) > 0 else ""})
		}
	} else if len(first.runs) > 0 {
		append(&first.runs, Run{end = lo.off + tail_len})
	}
	append(&first.text, ..last.text[hi.off:])
	runs_normalize(doc, first)
	for i in lo.block + 1 ..= hi.block do block_free(doc, &doc.blocks[i])
	remove_range(&doc.blocks, lo.block + 1, hi.block + 1)
}
// document_set_attrs adds `add` and removes `remove` over [a, b) (a link's
// `href` with .Link in `add`), block by block, as one journal group; the
// other attributes of the text stay.
document_set_attrs :: proc(doc: ^Document, a, b: Pos, add, remove: Attrs, href := "", group: u64 = 0) {
	document_ensure(doc)
	lo, hi := pos_order(pos_clamp(doc, a), pos_clamp(doc, b))
	if lo == hi do return
	edits_clear(doc, &doc.redo)
	Piece :: struct {
		lo, hi: int,
		attrs:  Attrs,
		href:   string,
	}
	for bi in lo.block ..= hi.block {
		blk := &doc.blocks[bi]
		from := lo.off if bi == lo.block else 0
		to := hi.off if bi == hi.block else len(blk.text)
		if to <= from do continue
		before := runs_clone(doc, blk.runs[:])
		pieces := make([dynamic]Piece, context.temp_allocator)
		if len(blk.runs) == 0 {
			append(&pieces, Piece{from, to, add - remove, href if .Link in add else ""})
		} else {
			start := 0
			for r in blk.runs {
				rs, re := start, r.end
				start = r.end
				x, z := max(rs, from), min(re, to)
				if z <= x do continue
				h := r.href
				if .Link in add do h = href
				if .Link in remove do h = ""
				append(&pieces, Piece{x, z, (r.attrs + add) - remove, strings.clone(h, context.temp_allocator) if len(h) > 0 else ""})
			}
		}
		for pc in pieces do run_cut(doc, blk, pc.lo, pc.hi, pc.attrs, pc.href)
		append(&doc.undo, Edit{kind = .Runs, at = {bi, 0}, group = group, runs = before, runs_after = runs_clone(doc, blk.runs[:])})
	}
	doc.version += 1
}

// document_attrs reports the style over [a, b): the attributes every
// character has (`all`) and the ones any has (`any`); at a caret, the
// style typing would continue.
document_attrs :: proc(doc: ^Document, a, b: Pos) -> (all, any: Attrs) {
	lo, hi := pos_order(pos_clamp(doc, a), pos_clamp(doc, b))
	if lo == hi {
		at := attrs_at(doc, lo)
		return at, at
	}
	all = ~Attrs{}
	for bi in lo.block ..= hi.block {
		blk := &doc.blocks[bi]
		from := lo.off if bi == lo.block else 0
		to := hi.off if bi == hi.block else len(blk.text)
		if to <= from do continue
		if len(blk.runs) == 0 {
			all = {}
			continue
		}
		start := 0
		for r in blk.runs {
			rs, re := start, r.end
			start = r.end
			if re <= from || rs >= to do continue
			all &= r.attrs
			any |= r.attrs
		}
	}
	return
}

// document_set_meta changes a block's kind and settings, journaled.
document_set_meta :: proc(doc: ^Document, block: int, meta: Block_Meta, group: u64 = 0) {
	document_ensure(doc)
	if block < 0 || block >= len(doc.blocks) do return
	old := block_meta(doc, block)
	if old == meta do return
	edits_clear(doc, &doc.redo)
	append(&doc.undo, Edit{kind = .Meta, at = {block, 0}, group = group, meta = meta_clone(doc, old), meta_after = meta_clone(doc, meta)})
	set_meta(doc, block, meta)
	doc.version += 1
}

@(private)
set_meta :: proc(doc: ^Document, block: int, m: Block_Meta) {
	b := &doc.blocks[block]
	block_touch(b)
	b.kind, b.level, b.depth, b.checked = m.kind, m.level, m.depth, m.checked
	if b.lang != m.lang {
		if len(b.lang) > 0 do delete(b.lang, doc.allocator)
		b.lang = strings.clone(m.lang, doc.allocator) if len(m.lang) > 0 else ""
	}
	if b.src != m.src {
		if len(b.src) > 0 do delete(b.src, doc.allocator)
		b.src = strings.clone(m.src, doc.allocator) if len(m.src) > 0 else ""
	}
}

// document_undo reverts the latest group. Returns the caret position to
// restore and whether anything was undone.
document_undo :: proc(doc: ^Document) -> (caret: Pos, ok: bool) {
	if len(doc.undo) == 0 do return
	group := doc.undo[len(doc.undo) - 1].group
	for len(doc.undo) > 0 {
		e := doc.undo[len(doc.undo) - 1]
		if e.group != group do break
		pop(&doc.undo)
		caret = edit_revert(doc, e)
		append(&doc.redo, e)
		ok = true
	}
	if ok do doc.version += 1
	return
}

document_redo :: proc(doc: ^Document) -> (caret: Pos, ok: bool) {
	if len(doc.redo) == 0 do return
	group := doc.redo[len(doc.redo) - 1].group
	for len(doc.redo) > 0 {
		e := doc.redo[len(doc.redo) - 1]
		if e.group != group do break
		pop(&doc.redo)
		caret = edit_apply(doc, e)
		append(&doc.undo, e)
		ok = true
	}
	if ok do doc.version += 1
	return
}

// edit_revert undoes one entry; edit_apply redoes it.
@(private)
edit_revert :: proc(doc: ^Document, e: Edit) -> (caret: Pos) {
	switch e.kind {
	case .Insert:
		end := advance(doc, e.at, e.text)
		delete_range(doc, e.at, end)
		return e.at
	case .Delete:
		end := insert_text(doc, e.at, e.text, nil, e.metas)
		apply_range_runs(doc, e.at, e.text, e.runs)
		return end
	case .Runs:
		runs_set(doc, &doc.blocks[e.at.block], e.runs)
		return e.at
	case .Meta:
		set_meta(doc, e.at.block, e.meta)
		return e.at
	}
	return e.at
}

// runs_set replaces a block's runs with a copy of `runs`.
@(private)
runs_set :: proc(doc: ^Document, b: ^Block, runs: []Run) {
	block_touch(b)
	runs_free(doc, b.runs[:])
	clear(&b.runs)
	if b.runs == nil do b.runs = make([dynamic]Run, doc.allocator)
	for r in runs do append(&b.runs, Run{end = r.end, attrs = r.attrs, href = strings.clone(r.href, doc.allocator) if len(r.href) > 0 else ""})
	runs_normalize(doc, b)
}

@(private)
edit_apply :: proc(doc: ^Document, e: Edit) -> (caret: Pos) {
	switch e.kind {
	case .Insert:
		end := insert_text(doc, e.at, e.text, nil, e.metas)
		apply_range_runs(doc, e.at, e.text, e.runs)
		return end
	case .Delete:
		end := advance(doc, e.at, e.text)
		delete_range(doc, e.at, end)
		return e.at
	case .Runs:
		runs_set(doc, &doc.blocks[e.at.block], e.runs_after)
		return e.at
	case .Meta:
		set_meta(doc, e.at.block, e.meta_after)
		return e.at
	}
	return e.at
}

// numbered_index is the number a numbered item shows: its place among the
// numbered items of its depth in the same list (deeper items of any list
// kind between them do not break the count).
numbered_index :: proc(doc: ^Document, b: int) -> int {
	if b < 0 || b >= len(doc.blocks) do return 1
	depth := doc.blocks[b].depth
	num := 1
	for k := b - 1; k >= 0; k -= 1 {
		pb := &doc.blocks[k]
		listy := pb.kind == .Bullet || pb.kind == .Numbered || pb.kind == .Task
		if !listy do break
		if pb.depth > depth do continue // a nested sub-list
		if pb.kind != .Numbered || pb.depth < depth do break
		num += 1
	}
	return num
}

// advance returns the position `text` spans from `at` (counting newlines
// as block breaks).
@(private)
advance :: proc(doc: ^Document, at: Pos, text: string) -> Pos {
	p := at
	for c in transmute([]u8)text {
		if c == '\n' {
			p = {p.block + 1, 0}
		} else {
			p.off += 1
		}
	}
	return p
}

// table_cell_at is the index of the cell holding byte `off` of a row.
table_cell_at :: proc(row: string, off: int) -> int {
	cells := table_cells(row)
	for c, i in cells do if off <= c[1] || i == len(cells) - 1 do return i
	return 0
}

// table_cell_start is where cell `i`'s text starts (a new cell's text goes there).
table_cell_start :: proc(row: string, i: int) -> int {
	cells := table_cells(row)
	if len(cells) == 0 do return 0
	return cells[clamp(i, 0, len(cells) - 1)][0]
}

// table_row_empty reports a row whose cells hold no text.
table_row_empty :: proc(row: string) -> bool {
	for c in table_cells(row) do if c[1] > c[0] do return false
	return true
}

// table_empty_row writes a row of `n` empty cells: "|  |  |", in temp memory
// by default.
table_empty_row :: proc(n: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '|')
	for _ in 0 ..< max(n, 1) do strings.write_string(&sb, "  |")
	return strings.to_string(sb)
}
