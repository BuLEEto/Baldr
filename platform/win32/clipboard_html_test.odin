#+build windows
package win32

// Runs on Windows: `odin test platform/win32`. CF_HTML's header is four byte
// offsets into its own bytes (clipboard_html.odin), and a wrong one is
// invisible from the clipboard's side: a word processor pastes a truncated
// document or nothing. So each offset is read back and used to slice the
// document, which catches one out by a byte or counting runes, not bytes.
@(require) import "core:strconv"
@(require) import "core:strings"
@(require) import "core:testing"

// Behind the `when` like every other test file: the bodies are otherwise
// type-checked by every Windows app that imports the backend (CONTRIBUTING.md).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// cf_html_at reads one header field's offset back out of the document.
@(private = "file")
cf_html_at :: proc(doc: []u8, field: string) -> (int, bool) {
	s := string(doc)
	i := strings.index(s, field)
	if i < 0 do return 0, false
	at := i + len(field)
	if at + CF_HTML_DIGITS > len(s) do return 0, false
	return strconv.parse_int(s[at:at + CF_HTML_DIGITS], 10)
}

@(test)
cf_html_offsets_point_at_the_document_and_the_fragment :: proc(t: ^testing.T) {
	// Not ASCII, and ampersands: the offsets are byte counts, so a header
	// built from rune counts puts the fragment in the wrong place and the
	// slices below come out shifted.
	html := "<h1>Tröst</h1><p>a &amp; b — ok</p>"
	doc := cf_html_wrap(html, context.temp_allocator)

	start_html, ok1 := cf_html_at(doc, "StartHTML:")
	end_html, ok2 := cf_html_at(doc, "EndHTML:")
	start_frag, ok3 := cf_html_at(doc, "StartFragment:")
	end_frag, ok4 := cf_html_at(doc, "EndFragment:")
	testing.expect(t, ok1 && ok2 && ok3 && ok4, "the header names all four offsets, ten digits each")
	if !(ok1 && ok2 && ok3 && ok4) do return

	testing.expect(t, strings.has_prefix(string(doc), "Version:0.9\r\n"), "the version first, as the format says")
	testing.expect(t, 0 < start_html && start_html < start_frag && start_frag <= end_frag && end_frag < end_html, "the four in order")
	if !(0 < start_html && start_html < start_frag && start_frag <= end_frag && end_frag < end_html) do return

	// What a consumer pastes is exactly the markup it was given.
	testing.expect_value(t, string(doc[start_frag:end_frag]), html)
	// …and the document around it is a document.
	body := string(doc[start_html:end_html])
	testing.expect(t, strings.has_prefix(body, "<html>"), "StartHTML is the <html> tag")
	testing.expect(t, strings.has_suffix(body, "</html>"), "EndHTML is just past </html>")
	testing.expect(t, strings.contains(body, "<!--StartFragment-->"), "the fragment comments are in the document")

	// The trailing NUL is for a program that reads the clipboard's memory
	// as a C string; it is not part of the document.
	testing.expect_value(t, len(doc), end_html + 1)
	testing.expect_value(t, doc[len(doc) - 1], 0)
}

@(test)
cf_html_wraps_an_empty_fragment_without_breaking_its_offsets :: proc(t: ^testing.T) {
	doc := cf_html_wrap("", context.temp_allocator)
	start_frag, ok1 := cf_html_at(doc, "StartFragment:")
	end_frag, ok2 := cf_html_at(doc, "EndFragment:")
	end_html, ok3 := cf_html_at(doc, "EndHTML:")
	testing.expect(t, ok1 && ok2 && ok3, "a header all the same")
	testing.expect_value(t, start_frag, end_frag) // an empty fragment, not a negative one
	testing.expect_value(t, len(doc), end_html + 1)
}

@(test)
cf_html_pads_an_offset_to_ten_digits :: proc(t: ^testing.T) {
	// A long fragment pushes EndHTML past four digits; the field is still
	// ten wide, because a consumer reads a fixed width and not a number.
	long := strings.repeat("<p>x</p>", 2000, context.temp_allocator)
	doc := cf_html_wrap(long, context.temp_allocator)
	i := strings.index(string(doc), "EndHTML:") + len("EndHTML:")
	field := string(doc[i:i + CF_HTML_DIGITS])
	testing.expect_value(t, len(field), 10)
	testing.expect(t, strings.has_prefix(field, "00000"), "zero-padded, not space-padded")
	end_html, ok := strconv.parse_int(field, 10)
	testing.expect(t, ok && end_html == len(doc) - 1, "and it is still the end of the document")
	start_frag, _ := cf_html_at(doc, "StartFragment:")
	end_frag, _ := cf_html_at(doc, "EndFragment:")
	testing.expect_value(t, string(doc[start_frag:end_frag]), long)
}

}
