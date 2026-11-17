package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// rich_hit runs one grapheme iterator per segment, started at the segment,
// rather than calling grapheme_next per boundary (which walks from the start
// of the block, making a drag O(line × offset)). That is safe only because a
// segment starts on a grapheme boundary, and nothing before a boundary
// changes how the text after it divides up. These tests pin the offsets,
// including where a grapheme is several bytes and several code points;
// spikes/hit_cost measures the speed.

@(private = "file")
hit_fx :: proc(t: ^Tree, te: ^Text_Engine) {
	tree_init(t)
	t.text = te
}

// The answer must never fall inside a grapheme: an offset that splits an
// emoji or a combining mark would put the caret in the middle of a
// character the person sees as one.
@(test)
a_hit_lands_on_a_grapheme_boundary :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	tr: Tree
	hit_fx(&tr, &te)
	defer tree_destroy(&tr)

	// combining marks, a family emoji joined with ZWJ, a flag, and a skin
	// tone — every shape where one grapheme is several code points
	text := "café xyz \U0001F468‍\U0001F469‍\U0001F467 ok \U0001F1EC\U0001F1E7 and \U0001F44D\U0001F3FD done, plus a long tail to force wrapping across more than one line so the later lines start well into the block"
	base := Rich_Style{size = 15}
	lay := rich_layout(&tr, text, nil, base, 260, context.temp_allocator)
	if !testing.expect(t, len(lay.lines) > 1, "the text wrapped") do return

	// every boundary rich_hit can return, on every line, is a real one
	for li in 0 ..< len(lay.lines) {
		for x := f32(-20); x < 300; x += 3 {
			got := rich_hit(&lay, text, li, x)
			testing.expectf(t, got >= 0 && got <= len(text), "in range: %d", got)
			if got > 0 && got < len(text) {
				back := grapheme_prev(text, got)
				fwd := grapheme_next(text, back)
				testing.expectf(t, fwd == got,
					"line %d, x %.0f: %d is a grapheme boundary (prev %d, next %d)", li, x, got, back, fwd)
			}
		}
	}
}

// Moving right never moves the answer left. A segment-local iterator that
// lost its place would break this long before anyone noticed it in a drag.
@(test)
a_hit_moves_forward_as_the_pointer_does :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	tr: Tree
	hit_fx(&tr, &te)
	defer tree_destroy(&tr)

	text := strings.repeat("the quick brown fox jumps over the lazy dog. ", 40, context.temp_allocator)
	base := Rich_Style{size = 15}
	lay := rich_layout(&tr, text, nil, base, 300, context.temp_allocator)
	if !testing.expect(t, len(lay.lines) > 4, "several lines") do return

	// a late line is the costliest for a walk from the block's start, so
	// check one and an early one alike
	// named, not inline: an inline slice literal in a `for` is the shape
	// that can cost the compiler minutes (AGENTS.md)
	lines := []int{1, len(lay.lines) - 2}
	for li in lines {
		l := lay.lines[li]
		prev := -1
		for x := l.x - 10; x < l.x + l.width + 10; x += 2 {
			got := rich_hit(&lay, text, li, x)
			testing.expectf(t, got >= prev, "line %d: x %.0f gave %d after %d", li, x, got, prev)
			testing.expectf(t, got >= l.start && got <= l.end, "line %d: %d is inside the line", li, got)
			prev = got
		}
		// …and the far ends are the line's ends. Far right may stop one byte
		// short of `l.end`: the line's trailing space is not in any segment,
		// so there is no boundary out there to land on.
		testing.expect_value(t, rich_hit(&lay, text, li, l.x - 1000), l.start)
		far := rich_hit(&lay, text, li, l.x + l.width + 1000)
		testing.expectf(t, far >= l.end - 1 && far <= l.end, "far right reaches the end of line %d (%d of %d)", li, far, l.end)
	}
}

}
