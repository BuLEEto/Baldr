package baldr

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import runa "baldr:third_party/runa"
@(require) import "baldr:third_party/runa/parse"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A charstring's operand stack holds the 513 operands CFF2 allows, not Type
// 2's 48: a variable font's `blend` carries a glyph's coordinates and their
// per-region deltas together, and a glyph needing 49 or more operands would
// otherwise come back with no outline at all.
//
// These tests read a real CFF2 variable font off this machine. Where none is
// installed they say so and pass.


@(private = "file")
CFF2_FONTS :: [?]string{
	"/usr/share/fonts/opentype/cantarell/Cantarell-VF.otf", // a desktop UI font with deep-stack glyphs
	"/usr/share/fonts/opentype/source-sans/SourceSans3VF-Roman.otf",
}

// every letter and digit: the glyphs that need a deep stack, and the rest
@(private = "file")
LETTERS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

@(private = "file")
open_cff2 :: proc() -> (f: runa.Font, data: []u8, ok: bool) {
	for path in CFF2_FONTS {
		bytes, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil do continue
		loaded, ferr := runa.font_load(bytes, context.allocator)
		if ferr != .None {
			delete(bytes)
			continue
		}
		return loaded, bytes, true
	}
	return {}, nil, false
}

@(test)
every_glyph_of_a_cff2_font_has_an_outline :: proc(t: ^testing.T) {
	f, data, have := open_cff2()
	if !have {
		testing.expect(t, true, "no CFF2 font installed here: nothing to read")
		return
	}
	defer {
		runa.font_destroy(&f)
		delete(data)
	}
	empty := strings.builder_make(context.temp_allocator)
	checked := 0
	for r in LETTERS {
		gid := runa.font_lookup_glyph(&f, r)
		if gid == 0 do continue // the font does not have it: not this test's business
		checked += 1
		out: runa.Outline
		defer runa.outline_destroy(&out)
		err := runa.font_glyph_outline(&f, gid, &out)
		if err != .None || len(out.points) == 0 {
			strings.write_rune(&empty, r)
		}
	}
	testing.expect(t, checked > 40, "the font has the letters")
	testing.expectf(t, strings.builder_len(empty) == 0, "every letter draws; these did not: %q", strings.to_string(empty))
}

@(test)
a_charstring_stack_holds_what_cff2_allows :: proc(t: ^testing.T) {
	// CFF2's operand stack is 513, not Type 2's 48: one blend carries a
	// glyph's coordinates and its deltas at once.
	testing.expect_value(t, parse.CS_STACK_MAX, 513)
}

// ------------------------------------------------------------------ flex

// The flex operators (12 34-37) draw two curves standing in for one shallow
// one, which fonts use for the bows on stems; a CFF font that uses them loses
// those curves if they are skipped. assets/test/flex.otf has one glyph per
// flex spelling, and the bounds below are fontTools' reading of the same
// file. CFF outlines are flattened to line segments here, so the points
// trace the curve itself rather than its control polygon, and a unit of
// slack covers the flattening.
// Embedded, not opened: a test that reads a relative path only passes when
// it is run from the top of the tree.
@(private = "file")
FLEX_FONT :: #load("../assets/test/flex.otf")

@(private = "file")
Flex_Case :: struct {
	letter: rune,
	bounds: [4]i32, // x_min, y_min, x_max, y_max of the curve itself, as fontTools reads it
	last:   [2]i32, // where the path ends
}

@(private = "file")
FLEX_SLACK :: i32(2) // the flattening's own error, at 1000 units per em

@(test)
the_flex_operators_draw_their_curves :: proc(t: ^testing.T) {
	bytes := make([]u8, len(FLEX_FONT), context.allocator) // runa takes ownership of what it is given
	copy(bytes, FLEX_FONT)
	defer delete(bytes)
	f, ferr := runa.font_load(bytes, context.allocator)
	testing.expect_value(t, ferr, runa.Error.None)
	if ferr != .None do return
	defer runa.font_destroy(&f)

	cases := [?]Flex_Case{
		{'A', {100, 100, 400, 122}, {400, 100}}, // flex
		{'B', {100, 100, 310, 140}, {310, 100}}, // hflex
		{'C', {100, 100, 400, 150}, {400, 100}}, // hflex1
		{'D', {100, 100, 400, 160}, {400, 100}}, // flex1
	}
	for c in cases {
		gid := runa.font_lookup_glyph(&f, c.letter)
		testing.expectf(t, gid != 0, "%c is in the fixture", c.letter)
		if gid == 0 do continue
		out: runa.Outline
		defer runa.outline_destroy(&out)
		oerr := runa.font_glyph_outline(&f, gid, &out)
		testing.expectf(t, oerr == .None, "%c has an outline (%v)", c.letter, oerr)
		if oerr != .None || len(out.points) == 0 {
			testing.expectf(t, false, "%c drew nothing: its flex curves were skipped", c.letter)
			continue
		}
		lo, hi := [2]i32{out.points[0].x, out.points[0].y}, [2]i32{out.points[0].x, out.points[0].y}
		for p in out.points {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
		near :: proc(got, want: i32) -> bool { return abs(got - want) <= FLEX_SLACK }
		testing.expectf(t, near(lo.x, c.bounds[0]) && near(lo.y, c.bounds[1]) && near(hi.x, c.bounds[2]) && near(hi.y, c.bounds[3]),
			"%c spans %v..%v, expected %v", c.letter, lo, hi, c.bounds)
		last := out.points[len(out.points) - 1]
		testing.expectf(t, near(last.x, c.last.x) && near(last.y, c.last.y), "%c ends at %v,%v, expected %v", c.letter, last.x, last.y, c.last)
		testing.expectf(t, len(out.points) >= 8, "%c traces both curves (%d points)", c.letter, len(out.points))
	}
}

} // when ODIN_TEST