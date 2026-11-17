// hit_cost — what does one mouse move cost while dragging a selection?
//
// grapheme_next builds an iterator at the *start of the block* and walks
// forward, so a rich_hit that called it per boundary would cost (graphemes
// on the line) x (how far into the block that line is).
//
// This hits the last line of paragraphs of growing length. Flat is right;
// rising with the paragraph is the bug.
//
//   ./build.sh spike hit_cost run
package main

import "core:fmt"
import "core:strings"
import "core:time"
import "baldr:baldr"

MOVES :: 200

main :: proc() {
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed to load"); return }
	defer baldr.text_engine_destroy(&te)
	t: baldr.Tree
	baldr.tree_init(&t)
	defer baldr.tree_destroy(&t)
	t.text = &te

	base := baldr.Rich_Style{size = 15}
	fmt.println("paragraph   per hit (last line)")
	for reps in ([]int{4, 16, 64, 128}) {
		para := strings.repeat("the quick brown fox jumps over the lazy dog. ", reps)
		defer delete(para)
		lay := baldr.rich_layout(&t, para, nil, base, 520, context.temp_allocator)
		if len(lay.lines) == 0 do continue
		last := len(lay.lines) - 1

		start := time.tick_now()
		for i in 0 ..< MOVES {
			x := f32(20 + (i % 400))
			_ = baldr.rich_hit(&lay, para, last, x)
		}
		d := time.tick_since(start)
		fmt.printfln("%6d bytes  %7.3f ms   (%d lines)",
			len(para), time.duration_milliseconds(d) / MOVES, len(lay.lines))
		free_all(context.temp_allocator)
	}
}
