package baldr

@(require) import "core:testing"

// A chat bubble's styled_text is as wide as its widest line, not its first.
// A chat body is one styled_text holding the newlines the person typed, and
// `layout_paragraph` returns a Line per hard break; reading only `lines[0]`
// leaves every byte after the first newline at x = 0, so each later line
// measures zero-wide, the greedy fill never breaks, and the paragraph
// reports its first line's width while painting the rest past it.
//
// Markdown splits on newlines before laying a block out, and the headless
// measurer walks the bytes itself, so these need the real engine.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Bub_Msg :: union { int }

@(private = "file")
BUB_BODY :: "Hi George,\nMy request on 30 September was for two user accounts, a desk phone for Nev and a headset.\nPlease can I have a quote for what I requested, as that is what I have been asked for.\n\nPlease can i have them promptly as it has now been 2 weeks.\nThanks Richard"

// Every hard line of a multi-line paragraph measures its own width — the
// one `cum` table has to cover all of them.
@(test)
every_hard_line_has_a_width :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Bub_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.text = &te

	lay := rich_layout(&ui.tree, BUB_BODY, nil, Rich_Style{size = 14}, 0, context.temp_allocator)
	defer rich_free(&lay, context.temp_allocator)
	testing.expectf(t, len(lay.lines) == 6, "six hard lines, got %d", len(lay.lines))
	body := BUB_BODY // a constant cannot be sliced with a variable index
	for line, i in lay.lines {
		if line.end - line.start <= 1 do continue // the blank line
		testing.expectf(t, line.width > 1,
			"line %d (%q) measured %v wide", i, body[line.start:line.end], line.width)
	}
}

// …and so the paragraph wraps at the width it is given rather than running
// on past it.
@(test)
a_multi_line_paragraph_wraps :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Bub_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.text = &te

	WRAP :: f32(300)
	lay := rich_layout(&ui.tree, BUB_BODY, nil, Rich_Style{size = 14}, WRAP, context.temp_allocator)
	defer rich_free(&lay, context.temp_allocator)
	testing.expectf(t, len(lay.lines) > 6, "it wraps as well as breaking, got %d lines", len(lay.lines))
	for line, i in lay.lines {
		testing.expectf(t, line.x + line.width <= WRAP + 0.5,
			"line %d is %v wide, past the %v it was wrapped at", i, line.x + line.width, WRAP)
	}
}

// The bubble: a chat's tree, with no width on the text. The box the
// paragraph is drawn in must hold the paragraph, which is what "the bubble
// is as wide as its text, capped by max_width" needs.
@(test)
a_bubble_holds_the_paragraph_drawn_in_it :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Bub_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.text = &te

	W, H :: f32(760), f32(520)
	set_viewport(&ui.tree, {W, H})
	begin_view(&ui)
	column(&ui, flex = 1)
	{
		list(&ui, 1, estimated_height = 72, follow_end = true, gap = .xs, padding = .sm, key = 90)
		{
			row(&ui, gap = .xs, align = .End, key = 1)
			{
				box(&ui, width = 28, height = 28)
				column(&ui, gap = .xxs, align = .Start, max_width = 520)
				{
					column(&ui, gap = .xs, padding = .md)
					{
						styled = styled_text(&ui, BUB_BODY, key = 3)
						end(&ui)
					}
					end(&ui)
				}
				spacer(&ui)
				end(&ui)
			}
			end(&ui)
		}
	}
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {W, H})

	d := node_get(&ui.tree, styled)
	s := &ui.tree.styled[styled]
	testing.expect(t, d != nil && s != nil && s.have, "the paragraph was laid out")
	widest: f32
	for line in s.lay.lines do widest = max(widest, line.x + line.width)
	testing.expectf(t, widest <= d.abs.w + 0.5,
		"the widest line is %v in a box %v wide", widest, d.abs.w)
	testing.expectf(t, d.abs.h + 0.5 >= s.lay.height,
		"the box is %v tall for a paragraph of %v", d.abs.h, s.lay.height)
	testing.expectf(t, d.abs.w > 200, "shrink-to-fit kept the bubble at %v for a long message", d.abs.w)
	testing.expectf(t, d.abs.w <= 520, "max_width held: the box is %v wide", d.abs.w)
}

@(private = "file")
styled: Node

}
