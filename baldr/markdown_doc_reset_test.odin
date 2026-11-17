package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A reply that stops inside an open code fence, then is retried or replaced
// by something shorter: the document starts again from nothing, the open
// fence's position included, so nothing indexes past the new text.
@(test)
a_document_cut_inside_a_fence_starts_again_cleanly :: proc(t: ^testing.T) {
	md: Markdown_Doc
	md_init(&md)
	defer md_destroy(&md)
	long := strings.concatenate({strings.repeat("A paragraph of text.\n", 60, context.temp_allocator), "```odin\nmain :: proc() {"}, context.temp_allocator)
	md_set(&md, long)
	testing.expect_value(t, md.fence_lang, "odin") // streaming, inside the fence
	md_set(&md, "Short.\n")                       // the retry, much shorter
	testing.expect_value(t, md.fence_lang, "")
	testing.expect_value(t, md.fence_at, [2]int{})
	md_append(&md, "More.\n") // and it carries on, re-deriving from the new text
	testing.expect_value(t, md_text(&md), "Short.\nMore.\n")
}

} // when ODIN_TEST
