#+build windows
package win32

// Formatted text on the Windows clipboard.
//
// Windows does not take `text/html`. Its form is CF_HTML, registered under
// the name "HTML Format": a short header of byte offsets followed by the
// markup. Word processors and mail clients paste that form and no other, so
// the offsets must be exact: an EndFragment a byte out pastes a truncated
// document, and a wrong StartHTML pastes nothing while the clipboard still
// looks full. They are written by patching a fixed-width field once the
// bytes exist, never by counting the header's length by hand.
//
// The markup goes on as UTF-8. The format names no encoding, but what
// pastes it reads UTF-8, which is what browsers and office suites write.

import "core:strings"
import win "core:sys/windows"

// MIME_HTML is the form the toolkit offers; this file is its Windows end.
MIME_HTML :: "text/html"

// CF_HTML_DIGITS is the width of each offset field. Fixed width is what
// lets a field be patched in place after the fact, and the format asks for
// it anyway: a consumer reads the digits, not a number.
@(private)
CF_HTML_DIGITS :: 10

// The document the fragment is wrapped in. The comments are not decoration:
// a consumer pastes what lies between them, telling the fragment from the
// surrounding document.
@(private) CF_HTML_PRE  :: "<html>\r\n<body>\r\n<!--StartFragment-->"
@(private) CF_HTML_POST :: "<!--EndFragment-->\r\n</body>\r\n</html>"

// html_format is the clipboard's number for CF_HTML, asked of Windows once.
@(private)
html_format :: proc(w: ^Win32) -> win.UINT {
	if w.html_format == 0 {
		w.html_format = win.RegisterClipboardFormatW(win.utf8_to_wstring("HTML Format", context.temp_allocator))
	}
	return w.html_format
}

// cf_html_wrap puts `html` in a CF_HTML document: the header's four
// offsets, then the markup inside the fragment comments the format wants.
// The bytes end with a NUL that is not part of the document — EndHTML
// stops before it — because a Windows program may read the clipboard's
// memory as a C string.
//
// The slice is the caller's to delete.
cf_html_wrap :: proc(html: string, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(0, len(html) + 256, allocator)
	strings.write_string(&b, "Version:0.9\r\n")
	start_html := cf_html_field(&b, "StartHTML")
	end_html   := cf_html_field(&b, "EndHTML")
	start_frag := cf_html_field(&b, "StartFragment")
	end_frag   := cf_html_field(&b, "EndFragment")
	html_at := len(b.buf)
	strings.write_string(&b, CF_HTML_PRE)
	frag_at := len(b.buf)
	strings.write_string(&b, html)
	frag_end := len(b.buf)
	strings.write_string(&b, CF_HTML_POST)
	html_end := len(b.buf)
	strings.write_byte(&b, 0)
	cf_html_put(b.buf[:], start_html, html_at)
	cf_html_put(b.buf[:], end_html,   html_end)
	cf_html_put(b.buf[:], start_frag, frag_at)
	cf_html_put(b.buf[:], end_frag,   frag_end)
	return b.buf[:]
}

// cf_html_field writes one header line with its offset still zero, and
// answers where those digits ended up.
@(private)
cf_html_field :: proc(b: ^strings.Builder, name: string) -> int {
	strings.write_string(b, name)
	strings.write_byte(b, ':')
	at := len(b.buf)
	for _ in 0 ..< CF_HTML_DIGITS do strings.write_byte(b, '0')
	strings.write_string(b, "\r\n")
	return at
}

// cf_html_put writes `value` over the digits at `at`, zero-padded.
@(private)
cf_html_put :: proc(buf: []u8, at: int, value: int) {
	v := value
	for i := CF_HTML_DIGITS - 1; i >= 0; i -= 1 {
		buf[at + i] = '0' + u8(v % 10)
		v /= 10
	}
}
