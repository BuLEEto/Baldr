#+build darwin
package cocoa

// The typed clipboard on macOS: pictures, files and formatted text, not
// just the plain string clipboard.odin handles.
//
// macOS names the forms on a pasteboard with uniform type identifiers
// rather than MIME types, so this maps between the two:
//
//   image/png                  public.png
//   image/png (from a TIFF)    public.tiff, transcoded through
//                              NSBitmapImageRep — see below
//   image/jpeg                 public.jpeg
//   text/uri-list              public.file-url, one per pasteboard
//                              item, as the Finder copies several files
//   text/plain;charset=utf-8   public.utf8-plain-text
//   text/html                  public.html
//
// TIFF is the form a Mac usually puts on the board (screenshots, Preview,
// many native apps offer only `public.tiff`), and `core:image` has no TIFF
// decoder, so NSBitmapImageRep re-encodes it as PNG. The backend reshapes
// bytes; the toolkit keeps the decoders.
//
// A form that takes time to make is waited for here, as on Windows:
// `Clip_Item.later` is made on a worker and `wait` is called while the copy
// is set up. NSPasteboard could serve it lazily (declareTypes:owner:), which
// would keep a big picture off this thread at the cost of ownership
// bookkeeping.

import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "core:mem"
import "core:strings"
import "baldr:platform"

@(private) UTI_PNG      :: "public.png"
@(private) UTI_TIFF     :: "public.tiff"
@(private) UTI_JPEG     :: "public.jpeg"
@(private) UTI_HTML     :: "public.html"
@(private) UTI_FILE_URL :: "public.file-url"

@(private) MIME_TEXT_UTF8 :: "text/plain;charset=utf-8"
@(private) MIME_TEXT      :: "text/plain"
@(private) MIME_PNG       :: "image/png"
@(private) MIME_JPEG      :: "image/jpeg"
@(private) MIME_HTML      :: "text/html"
@(private) MIME_URI_LIST  :: "text/uri-list"

@(private) @(objc_class = "NSPasteboardItem")
Pasteboard_Item :: struct {using _: NS.Object}

// PNG_FILE_TYPE is NSBitmapImageFileTypePNG. The enum is a plain integer
// in the framework and the bindings do not carry it.
@(private) PNG_FILE_TYPE :: NS.UInteger(4)

// uti_for_mime is the form macOS would call this. Files are not here:
// they are not a type on an item, they are one item each (set_data).
@(private)
uti_for_mime :: proc(mime: string) -> (string, bool) {
	switch {
	case strings.equal_fold(mime, MIME_TEXT_UTF8), strings.equal_fold(mime, MIME_TEXT): return UTI_TEXT, true
	case strings.equal_fold(mime, MIME_PNG):  return UTI_PNG, true
	case strings.equal_fold(mime, MIME_JPEG): return UTI_JPEG, true
	case strings.equal_fold(mime, MIME_HTML): return UTI_HTML, true
	}
	return "", false
}

// b_clipboard_types is what is on the pasteboard now, in the toolkit's
// MIME terms (mimes_of_uti).
@(private)
b_clipboard_types :: proc(b: ^platform.Backend, allocator := context.allocator) -> []string {
	pb := general_pasteboard()
	if pb == nil do return nil
	types := intrinsics.objc_send(^NS.Array, pb, "types")
	if types == nil do return nil
	out := make([dynamic]string, 0, 6, allocator)
	n := types->count()
	for i in 0 ..< n {
		s := intrinsics.objc_send(^NS.String, types->object(i), "self")
		if s == nil do continue
		mimes_of_uti(&out, string(s->odinString()), allocator)
	}
	return out[:]
}

// mimes_of_uti appends what the toolkit would call this form. Text is
// added under both spellings because a caller may look for either, a
// picture under `image/png` whether it is a PNG or a TIFF (get_data
// transcodes), and a form the toolkit cannot read is left out rather than
// offered and then refused. Shared with the drag that carries the same
// forms (drag.odin).
@(private)
mimes_of_uti :: proc(out: ^[dynamic]string, uti: string, allocator: mem.Allocator) {
	switch uti {
	case UTI_TEXT:
		types_add(out, MIME_TEXT_UTF8, allocator)
		types_add(out, MIME_TEXT, allocator)
	case UTI_PNG, UTI_TIFF: types_add(out, MIME_PNG, allocator)
	case UTI_JPEG:          types_add(out, MIME_JPEG, allocator)
	case UTI_HTML:          types_add(out, MIME_HTML, allocator)
	case UTI_FILE_URL:      types_add(out, MIME_URI_LIST, allocator)
	}
}

@(private)
types_add :: proc(out: ^[dynamic]string, mime: string, allocator: mem.Allocator) {
	for have in out do if have == mime do return // public.png and public.tiff are both image/png
	s, err := strings.clone(mime, allocator)
	if err == nil do append(out, s)
}

@(private)
b_clipboard_get_data :: proc(b: ^platform.Backend, mime: string, allocator := context.allocator) -> ([]u8, bool) {
	pb := general_pasteboard()
	if pb == nil do return nil, false
	switch {
	case strings.equal_fold(mime, MIME_TEXT_UTF8), strings.equal_fold(mime, MIME_TEXT):
		return pb_bytes(pb, UTI_TEXT, allocator)
	case strings.equal_fold(mime, MIME_HTML):
		return pb_bytes(pb, UTI_HTML, allocator)
	case strings.equal_fold(mime, MIME_JPEG):
		return pb_bytes(pb, UTI_JPEG, allocator)
	case strings.equal_fold(mime, MIME_URI_LIST):
		return pb_uri_list(pb, allocator)
	case strings.equal_fold(mime, MIME_PNG):
		if data, ok := pb_bytes(pb, UTI_PNG, allocator); ok do return data, true
		// A Mac's own copy is usually TIFF, which nothing here decodes.
		tiff, got := pb_bytes(pb, UTI_TIFF, context.temp_allocator)
		if !got do return nil, false
		return tiff_as_png(tiff, allocator)
	}
	return nil, false
}

// b_clipboard_set_data offers several forms at once. Files become one
// pasteboard item each (NSURL), everything else goes on a single item
// beside them, which is the shape the Finder writes and every Mac app
// expects to read.
@(private)
b_clipboard_set_data :: proc(b: ^platform.Backend, items: []platform.Clip_Item) -> bool {
	pb := general_pasteboard()
	if pb == nil do return false

	objects := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^NS.MutableArray, NS.MutableArray, "alloc"), "init")
	if objects == nil do return false
	defer intrinsics.objc_send(nil, objects, "release")

	// One item carries the typed forms…
	item := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^Pasteboard_Item, Pasteboard_Item, "alloc"), "init")
	if item == nil do return false
	defer intrinsics.objc_send(nil, item, "release")
	typed := false
	for it in items {
		if strings.equal_fold(it.mime, MIME_URI_LIST) do continue
		uti, ok := uti_for_mime(it.mime)
		if !ok do continue
		data := clip_bytes(it)
		if len(data) == 0 do continue
		if item_put(item, uti, data) do typed = true
	}
	if typed do intrinsics.objc_send(nil, objects, "addObject:", item)

	// …and the files are an item each, as URLs, so the Finder can paste them.
	for it in items do if strings.equal_fold(it.mime, MIME_URI_LIST) {
		data := clip_bytes(it)
		if len(data) == 0 do continue
		for uri in uri_lines(string(data)) {
			u := ns_str(uri)
			if u == nil do continue
			defer u->release()
			url := intrinsics.objc_send(^NS.Object, NS.URL, "URLWithString:", u)
			if url != nil do intrinsics.objc_send(nil, objects, "addObject:", url)
		}
	}

	if intrinsics.objc_send(NS.UInteger, objects, "count") == 0 do return false
	// clearContents first, or the old contents and their owner stay.
	intrinsics.objc_send(NS.Integer, pb, "clearContents")
	return bool(intrinsics.objc_send(NS.BOOL, pb, "writeObjects:", objects))
}

// clip_bytes is the item's bytes, waiting for a form that is still being
// made (a picture encoded as PNG on a worker).
@(private)
clip_bytes :: proc(it: platform.Clip_Item) -> []u8 {
	if it.data != nil do return it.data
	if it.later != nil do return it.later.wait(it.later)
	return nil
}

@(private)
item_put :: proc(item: ^NS.Object, uti: string, data: []u8) -> bool {
	ty := ns_str(uti)
	if ty == nil do return false
	defer ty->release()
	d := NS.Data.alloc()->initWithBytes(raw_data(data), NS.UInteger(len(data)))
	if d == nil do return false
	defer d->release()
	return bool(intrinsics.objc_send(NS.BOOL, item, "setData:forType:", d, ty))
}

@(private)
pb_bytes :: proc(pb: ^NS.Pasteboard, uti: string, allocator: mem.Allocator) -> ([]u8, bool) {
	ty := ns_str(uti)
	if ty == nil do return nil, false
	defer ty->release()
	d := intrinsics.objc_send(^NS.Data, pb, "dataForType:", ty)
	return data_bytes(d, allocator)
}

@(private)
data_bytes :: proc(d: ^NS.Data, allocator: mem.Allocator) -> ([]u8, bool) {
	if d == nil do return nil, false
	n := int(d->length())
	if n == 0 do return nil, false
	p := intrinsics.objc_send(rawptr, d, "bytes")
	if p == nil do return nil, false
	out, err := mem.make_aligned([]u8, n, 1, allocator)
	if err != nil do return nil, false
	mem.copy(raw_data(out), p, n)
	return out, true
}

// pb_uri_list reads one file URL per pasteboard item and writes them as
// the text/uri-list the toolkit reads: CRLF between, as the format says.
// The strings are already percent-encoded file:// URLs, which is what a
// uri-list holds, so nothing is re-encoded here.
@(private)
pb_uri_list :: proc(pb: ^NS.Pasteboard, allocator: mem.Allocator) -> ([]u8, bool) {
	items := intrinsics.objc_send(^NS.Array, pb, "pasteboardItems")
	if items == nil do return nil, false
	ty := ns_str(UTI_FILE_URL)
	if ty == nil do return nil, false
	defer ty->release()
	b := strings.builder_make(context.temp_allocator)
	n := items->count()
	for i in 0 ..< n {
		it := items->object(i)
		if it == nil do continue
		s := intrinsics.objc_send(^NS.String, it, "stringForType:", ty)
		if s == nil do continue
		uri := string(s->odinString())
		if uri == "" do continue
		strings.write_string(&b, uri)
		strings.write_string(&b, "\r\n")
	}
	out := strings.to_string(b)
	if len(out) == 0 do return nil, false
	clone, err := strings.clone(out, allocator)
	if err != nil do return nil, false
	return transmute([]u8)clone, true
}

// uri_lines splits a text/uri-list, dropping the comment lines the format
// allows and the empty one a trailing CRLF leaves.
@(private = "file")
uri_lines :: proc(list: string) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	rest := list // the iterator walks its own copy; a parameter cannot be addressed
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' do continue
		append(&out, trimmed)
	}
	return out[:]
}

// tiff_as_png asks macOS to re-encode a TIFF as a PNG, because `core:image`
// reads PNG and not TIFF, and TIFF is what a Mac puts on the pasteboard.
@(private)
tiff_as_png :: proc(tiff: []u8, allocator: mem.Allocator) -> ([]u8, bool) {
	d := NS.Data.alloc()->initWithBytes(raw_data(tiff), NS.UInteger(len(tiff)))
	if d == nil do return nil, false
	defer d->release()
	rep := intrinsics.objc_send(^NS.Object, NS.BitmapImageRep, "imageRepWithData:", d)
	if rep == nil do return nil, false
	props := intrinsics.objc_send(^NS.Object, NS.Dictionary, "dictionary")
	png := intrinsics.objc_send(^NS.Data, rep, "representationUsingType:properties:", PNG_FILE_TYPE, props)
	return data_bytes(png, allocator)
}
