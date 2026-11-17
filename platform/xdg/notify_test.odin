#+build linux
package xdg

@(require) import "core:testing"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A notification's body is often someone else's words (a chat message, a
// mail's subject). Where the server reads markup, it is shown as text: a
// link in it is not made clickable, and nothing in it is drawn as a picture.
@(test)
a_notification_body_is_shown_as_text :: proc(t: ^testing.T) {
	testing.expect_value(t, notify_escape(`<a href="file:///etc">Invoice</a> & <img src=x>`),
		`&lt;a href=&quot;file:///etc&quot;&gt;Invoice&lt;/a&gt; &amp; &lt;img src=x&gt;`)
	testing.expect_value(t, notify_escape("it's"), "it&apos;s")
	plain := "Nothing to escape here, été"
	testing.expect_value(t, notify_escape(plain), plain)
	free_all(context.temp_allocator)
}

} // when ODIN_TEST
