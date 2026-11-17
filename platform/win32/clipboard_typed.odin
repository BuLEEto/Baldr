#+build windows
package win32

// The typed clipboard on Windows: pictures and files, not just
// text — a screenshot pasted into a composer, files copied in Explorer.
//
// Windows names its forms with numbers, not MIME types, so this maps
// between the two:
//
//   image/png                     the registered "PNG" format, which
//                                 browsers, Paint and screenshot tools put
//   image/bmp                     CF_DIBV5 / CF_DIB, the form Windows apps
//                                 have always used; a BMP file header is
//                                 put in front so it is a .bmp a decoder
//                                 can read (and taken off again when we
//                                 offer one)
//   text/uri-list                 CF_HDROP, what Explorer copies
//   text/plain;charset=utf-8      CF_UNICODETEXT
//   text/html                     CF_HTML, the registered "HTML Format",
//                                 with the header of byte offsets that
//                                 form needs (clipboard_html.odin)
//
// Nothing here decodes a picture: it moves bytes between the clipboard and
// the toolkit, which owns the decoders.

import "core:mem"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

MIME_PNG      :: "image/png"
MIME_BMP      :: "image/bmp"
MIME_URI_LIST :: "text/uri-list"
MIME_TEXT_UTF8 :: "text/plain;charset=utf-8"
MIME_TEXT     :: "text/plain"

// BMP_FILE_HEADER is the 14 bytes a .bmp file has in front of the DIB the
// clipboard holds.
@(private)
BMP_FILE_HEADER :: 14

// png_format is the clipboard's number for "PNG", asked of Windows once.
@(private)
png_format :: proc(w: ^Win32) -> win.UINT {
	if w.png_format == 0 {
		w.png_format = win.RegisterClipboardFormatW(win.utf8_to_wstring("PNG", context.temp_allocator))
	}
	return w.png_format
}

// clipboard_types is what is on the clipboard now, in MIME terms and best
// first. The strings are constants; the slice is the caller's.
@(private)
clipboard_types :: proc(b: ^platform.Backend, allocator := context.allocator) -> []string {
	w := (^Win32)(b.data)
	if !open_clipboard() do return nil
	defer win.CloseClipboard()
	out := make([dynamic]string, 0, 5, allocator)
	if png := png_format(w); png != 0 && win.IsClipboardFormatAvailable(png) do append(&out, MIME_PNG)
	if win.IsClipboardFormatAvailable(win.CF_DIBV5) || win.IsClipboardFormatAvailable(win.CF_DIB) do append(&out, MIME_BMP)
	if win.IsClipboardFormatAvailable(win.CF_HDROP) do append(&out, MIME_URI_LIST)
	if win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) {
		append(&out, MIME_TEXT_UTF8)
		append(&out, MIME_TEXT)
	}
	return out[:]
}

// clipboard_get_data reads one form. The bytes are the caller's.
@(private)
clipboard_get_data :: proc(b: ^platform.Backend, mime: string, allocator := context.allocator) -> ([]u8, bool) {
	w := (^Win32)(b.data)
	if !open_clipboard() do return nil, false
	defer win.CloseClipboard()
	switch {
	case strings.equal_fold(mime, MIME_PNG):
		png := png_format(w)
		if png == 0 do return nil, false
		return clipboard_bytes(png, allocator)
	case strings.equal_fold(mime, MIME_BMP), strings.equal_fold(mime, "image/x-bmp"), strings.equal_fold(mime, "image/x-ms-bmp"):
		return clipboard_bmp(allocator)
	case strings.equal_fold(mime, MIME_URI_LIST):
		return clipboard_uri_list(allocator)
	case strings.equal_fold(mime, MIME_TEXT_UTF8), strings.equal_fold(mime, MIME_TEXT):
		h := win.GetClipboardData(win.CF_UNICODETEXT)
		if h == nil do return nil, false
		s, ok := global_text(h, allocator)
		if !ok do return nil, false
		return transmute([]u8)s, true
	}
	return nil, false
}

// clipboard_bytes copies one clipboard format's memory out as it is.
@(private)
clipboard_bytes :: proc(format: win.UINT, allocator: mem.Allocator) -> ([]u8, bool) {
	h := win.GetClipboardData(format)
	if h == nil do return nil, false
	size := int(win.GlobalSize(win.HGLOBAL(h)))
	if size <= 0 do return nil, false
	p := win.GlobalLock(win.HGLOBAL(h))
	if p == nil do return nil, false
	defer win.GlobalUnlock(win.HGLOBAL(h))
	out := make([]u8, size, allocator)
	mem.copy(raw_data(out), p, size)
	return out, true
}

// clipboard_bmp reads CF_DIBV5 or CF_DIB and puts a BMP file header in
// front, so what comes back is a .bmp file a decoder reads. The pixels
// start after the info header, its colour masks and its palette — a DIB
// says how big each of those is, and a file that lies about them is
// refused rather than read past its end.
@(private)
clipboard_bmp :: proc(allocator: mem.Allocator) -> ([]u8, bool) {
	format := win.UINT(win.CF_DIBV5)
	if !win.IsClipboardFormatAvailable(format) do format = win.CF_DIB
	dib, ok := clipboard_bytes(format, context.temp_allocator)
	if !ok || len(dib) < 40 do return nil, false
	u32_at :: proc(b: []u8, at: int) -> u32 {
		if at + 4 > len(b) do return 0
		return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
	}
	u16_at :: proc(b: []u8, at: int) -> u16 {
		if at + 2 > len(b) do return 0
		return u16(b[at]) | u16(b[at + 1]) << 8
	}
	header := int(u32_at(dib, 0))          // biSize: 40 (BITMAPINFOHEADER), 108 / 124 (V4 / V5)
	bits := int(u16_at(dib, 14))           // biBitCount
	compression := int(u32_at(dib, 16))    // biCompression: 3 = BI_BITFIELDS
	used := int(u32_at(dib, 32))           // biClrUsed
	if header < 40 || header > len(dib) do return nil, false
	masks := 12 if compression == 3 && header == 40 else 0 // V4 and V5 carry their masks inside the header
	colours := used
	if colours == 0 && bits <= 8 do colours = 1 << uint(bits)
	offset := BMP_FILE_HEADER + header + masks + colours * 4
	if offset > BMP_FILE_HEADER + len(dib) do return nil, false
	out := make([]u8, BMP_FILE_HEADER + len(dib), allocator)
	out[0], out[1] = 'B', 'M'
	put32 :: proc(b: []u8, at: int, v: u32) {
		b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
	put32(out, 2, u32(len(out)))
	put32(out, 10, u32(offset))
	copy(out[BMP_FILE_HEADER:], dib)
	return out, true
}

// clipboard_uri_list turns CF_HDROP's paths into the text/uri-list the
// toolkit reads, one file:// URI a line, CRLF as the format says.
@(private)
clipboard_uri_list :: proc(allocator: mem.Allocator) -> ([]u8, bool) {
	h := win.GetClipboardData(win.CF_HDROP)
	if h == nil do return nil, false
	drop := win.HDROP(h)
	n := win.DragQueryFileW(drop, 0xFFFFFFFF, nil, 0)
	if n == 0 do return nil, false
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< n {
		need := win.DragQueryFileW(drop, i, nil, 0)
		if need == 0 do continue
		buf := make([]u16, need + 1, context.temp_allocator)
		if win.DragQueryFileW(drop, i, raw_data(buf), need + 1) == 0 do continue
		path, err := win.wstring_to_utf8(win.wstring(raw_data(buf)), -1, context.temp_allocator)
		if err != nil do continue
		strings.write_string(&b, file_uri(path, context.temp_allocator))
		strings.write_string(&b, "\r\n")
	}
	s := strings.to_string(b)
	if len(s) == 0 do return nil, false
	return transmute([]u8)strings.clone(s, allocator), true
}

// file_uri is a Windows path as a file:// URI: backslashes become slashes,
// a drive letter gets the third slash, and everything a URI reserves is
// escaped (a space, a #, a % — file names have all three).
@(private)
file_uri :: proc(path: string, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file:///" if len(path) > 1 && path[1] == ':' else "file://")
	for c in transmute([]u8)path {
		switch {
		case c == '\\': strings.write_byte(&b, '/')
		case c == '/' || c == ':' || c == '-' || c == '_' || c == '.' || c == '~':
			strings.write_byte(&b, c)
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'):
			strings.write_byte(&b, c)
		case:
			hex := "0123456789ABCDEF"
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 15])
		}
	}
	return strings.to_string(b)
}

// clipboard_set_data offers several forms at once: text as CF_UNICODETEXT,
// a PNG as the "PNG" format, a BMP as CF_DIB (its file header taken off),
// HTML as CF_HTML (wrapped in the header that form needs). A form Windows
// has no place for is passed over.
@(private)
clipboard_set_data :: proc(b: ^platform.Backend, items: []platform.Clip_Item) -> bool {
	w := (^Win32)(b.data)
	if !open_clipboard() do return false
	defer win.CloseClipboard()
	win.EmptyClipboard()
	any := false
	for it in items {
		data := it.data
		if data == nil && it.later != nil do data = it.later.wait(it.later) // made on a thread (a picture's PNG)
		if len(data) == 0 do continue
		switch {
		case strings.equal_fold(it.mime, MIME_TEXT_UTF8), strings.equal_fold(it.mime, MIME_TEXT):
			if clipboard_put_text(string(data)) do any = true
		case strings.equal_fold(it.mime, MIME_PNG):
			if png := png_format(w); png != 0 && clipboard_put(png, data) do any = true
		case strings.equal_fold(it.mime, MIME_BMP):
			if len(data) > BMP_FILE_HEADER && clipboard_put(win.CF_DIB, data[BMP_FILE_HEADER:]) do any = true
		case strings.equal_fold(it.mime, MIME_HTML):
			if f := html_format(w); f != 0 && clipboard_put(f, cf_html_wrap(string(data), context.temp_allocator)) do any = true
		}
	}
	return any
}

// clipboard_put hands one format's bytes to the clipboard, which takes
// ownership of the memory when it accepts them.
@(private)
clipboard_put :: proc(format: win.UINT, data: []u8) -> bool {
	h := win.GlobalAlloc(win.GMEM_MOVEABLE, win.SIZE_T(len(data)))
	if h == nil do return false
	p := win.GlobalLock(win.HGLOBAL(h))
	if p == nil {
		win.GlobalFree(h)
		return false
	}
	mem.copy(p, raw_data(data), len(data))
	win.GlobalUnlock(win.HGLOBAL(h))
	if win.SetClipboardData(format, win.HANDLE(h)) == nil {
		win.GlobalFree(h) // ownership only moves on success
		return false
	}
	return true
}

@(private)
clipboard_put_text :: proc(text: string) -> bool {
	utf16 := win.utf8_to_utf16(text, context.temp_allocator)
	bytes := (len(utf16) + 1) * size_of(u16)
	h := win.GlobalAlloc(win.GMEM_MOVEABLE, win.SIZE_T(bytes))
	if h == nil do return false
	p := win.GlobalLock(win.HGLOBAL(h))
	if p == nil {
		win.GlobalFree(h)
		return false
	}
	dst := ([^]u16)(p)
	copy(dst[:len(utf16)], utf16)
	dst[len(utf16)] = 0
	win.GlobalUnlock(win.HGLOBAL(h))
	if win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(h)) == nil {
		win.GlobalFree(h)
		return false
	}
	return true
}
