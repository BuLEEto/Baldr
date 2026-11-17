package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A family's normal width comes first. Name id 16 groups every cut of a
// family on purpose, so Debian's fonts-noto-core files Noto Serif's
// Condensed, SemiCondensed and ExtraCondensed cuts under the one typographic
// family "Noto Serif"; choosing on weight and slant alone can hand plain
// "Noto Serif" a condensed face.

@(private = "file")
face :: proc(weight: int, width: int, italic := false, variable := false) -> Font_Face_File {
	return Font_Face_File{weight = weight, width = width, italic = italic, variable = variable}
}

// The same family, the same weight, the same slant, and only the width to
// tell them apart.
@(test)
a_familys_normal_width_comes_first :: proc(t: ^testing.T) {
	// as the scan finds them, condensed first
	files := []Font_Face_File{
		face(400, 3), // Condensed
		face(400, 4), // SemiCondensed
		face(400, 5), // the one "Noto Serif" means
		face(700, 5),
	}
	got, ok := family_pick(files, 400, false)
	testing.expect(t, ok, "something was picked")
	testing.expect_value(t, got.width, 5)
	testing.expect_value(t, got.weight, 400)
}

// Width is matched before weight, as CSS orders it: a normal-width face
// wins even when a condensed cut is nearer the weight asked for. A reader
// asking for a book face wants the family's own proportions first.
@(test)
normal_width_beats_a_closer_weight :: proc(t: ^testing.T) {
	files := []Font_Face_File{
		face(400, 3), // exactly the weight, but condensed
		face(700, 5), // two steps off in weight, and the right width
	}
	got, ok := family_pick(files, 400, false)
	testing.expect(t, ok, "something was picked")
	testing.expect_value(t, got.width, 5)
}

// A face that does not say its width is taken to be normal, which is what
// an unset usWidthClass almost always means — most fonts never set it.
@(test)
an_unsaid_width_counts_as_normal :: proc(t: ^testing.T) {
	files := []Font_Face_File{face(400, 3), face(400, 0)}
	got, ok := family_pick(files, 400, false)
	testing.expect(t, ok, "something was picked")
	testing.expect_value(t, got.width, 0)
}

// The narrow cuts are still used when a family has nothing else: a
// preference, not a filter.
@(test)
a_condensed_face_is_used_when_it_is_all_there_is :: proc(t: ^testing.T) {
	files := []Font_Face_File{face(400, 3), face(700, 3)}
	got, ok := family_pick(files, 400, false)
	testing.expect(t, ok, "something was picked")
	testing.expect_value(t, got.width, 3)
	testing.expect_value(t, got.weight, 400) // and the nearer weight among them
}

// Scores can be negative, so the first candidate must not be beaten by
// every later one just for existing: with `best := -1` and
// `best < 0 || score > best`, any negative best makes the last face win
// whatever it scored.
@(test)
the_best_face_wins_not_the_last :: proc(t: ^testing.T) {
	files := []Font_Face_File{
		face(400, 3), // condensed, the weight asked for
		face(900, 3), // condensed and far off in weight
	}
	got, ok := family_pick(files, 400, false)
	testing.expect(t, ok, "something was picked")
	testing.expect_value(t, got.weight, 400)
}

// Slant is still a hard filter: an upright face is never handed back for an
// italic ask unless it is variable and can be sloped.
@(test)
width_does_not_override_slant :: proc(t: ^testing.T) {
	files := []Font_Face_File{face(400, 5), face(400, 3, italic = true)}
	got, ok := family_pick(files, 400, true)
	testing.expect(t, ok, "something was picked")
	testing.expect(t, got.italic, "a true italic, even though it is condensed")

	upright := []Font_Face_File{face(400, 5), face(400, 3)}
	got2, ok2 := family_pick(upright, 400, false)
	testing.expect(t, ok2, "something was picked")
	testing.expect(t, !got2.italic && got2.width == 5, "and upright takes the normal width")
}

}
