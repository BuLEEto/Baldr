package baldr

// The clipboard as commands. `copy_text`, `copy_files` and `copy_html` put
// something on it; `paste` reads it and the outcome is a message. Files travel as
// text/uri-list, as the form GNOME's file managers paste (which says
// whether they were cut) and KDE's cut marker, and as the paths in plain
// text, so a file copied or cut here pastes in a file manager and in a
// terminal alike. The text fields and editors use the clipboard on their
// own for Ctrl+C / X / V.
//
// Pictures: `copy_image` offers a picture as image/png, and `paste_image`
// reads the best picture form on offer. Neither makes the UI wait: the PNG
// is encoded on a thread from the moment of the copy, and a program that
// pastes before it is ready is written it when it is; a paste is read and
// decoded on a thread, and arrives as a message.

import "base:runtime"
import "core:image"
import "core:image/bmp"
import "core:image/jpeg"
import "core:image/netpbm"
import "core:image/qoi"
import "core:image/tga"
import "core:strings"
import "core:sync"
import "core:thread"
import "baldr:platform"

// Pasted is what `paste` found: the text form, the local paths when files
// were on the clipboard, and whether they were cut (the paste should move
// them). The strings live only while the message is handled — clone what
// you keep.
Pasted :: struct {
	text:  string,
	files: []string,
	cut:   bool,
}

// copy_text puts `text` on the clipboard; with `primary`, makes it the
// primary selection instead — what was last selected, which a middle click
// pastes (a terminal sets it as a selection is made). A platform without a
// primary selection does nothing with that.
copy_text :: proc($Msg: typeid, text: string, primary := false) -> Cmd(Msg) {
	return {kind = .Copy_Text, text = temp_clone(text), primary = primary}
}

// copy_files puts local `paths` on the clipboard as files, with the paths
// as plain text beside them. `cut` marks them cut: a file manager pasting
// them moves them.
//
//	case Copy: return baldr.copy_files(Msg, selected_paths(s, context.temp_allocator))
//	case Cut:  return baldr.copy_files(Msg, selected_paths(s, context.temp_allocator), cut = true)
copy_files :: proc($Msg: typeid, paths: []string, cut := false) -> Cmd(Msg) {
	out := make([]string, len(paths), context.temp_allocator)
	for p, i in paths do out[i] = temp_clone(p)
	return {kind = .Copy_Files, paths = out, cut = cut}
}

// copy_html puts formatted text on the clipboard: `html` as text/html and
// `text` as the plain text, both at once. The program pasting takes the
// richest form it understands — a word processor takes the HTML, a terminal
// the text — so `text` should be the text as the person wrote it (the
// Markdown behind the formatting, say) rather than a flattening of the HTML.
//
// The text goes on in every form `copy_text` offers. On Windows the HTML
// goes on as CF_HTML, the form word processors there paste. A platform whose
// clipboard Baldr can only put text on offers the text alone.
//
// Both strings are copied: the app may free them straight after. Nothing
// happens when both are empty.
//
//	case Copy_Formatted: return baldr.copy_html(Msg, html_of(s, context.temp_allocator), s.source)
copy_html :: proc($Msg: typeid, html: string, text: string) -> Cmd(Msg) {
	return {kind = .Copy_Html, html = temp_clone(html), text = temp_clone(text)}
}

// paste reads the clipboard; the handler gets Pasted with what was there
// (every field empty when nothing was). With `primary` it reads the
// primary selection instead (a middle click's paste): its text only.
//
//	case Paste: return baldr.paste(Msg, proc(e: baldr.Ev(baldr.Pasted)) -> Msg { return Paste_Files{e.value.files, e.value.cut} })
//	case Middle_Click: return baldr.paste(Msg, proc(e: baldr.Ev(baldr.Pasted)) -> Msg { return Type{e.value.text} }, primary = true)
paste :: proc($Msg: typeid, on_done: Handler(Msg, Pasted), primary := false) -> Cmd(Msg) {
	return {kind = .Paste, on_paste = on_done, primary = primary}
}

// copy_image puts a picture on the clipboard, as image/png: pasted into an
// image editor, a browser or a chat, it is the picture. Its pixels are
// copied at once, so the app may change or free `img` straight after; the
// PNG is made on a thread, and a paste that comes before it is ready waits
// for it without the app waiting. Nothing happens for an empty picture.
//
//	case Copy_Merged: return baldr.copy_image(Msg, &s.flattened)
copy_image :: proc($Msg: typeid, img: ^Image) -> Cmd(Msg) {
	return {kind = .Copy_Image, picture = clip_picture_make(img)}
}

// Pasted_Image is what `paste_image` found. `image` is the picture as RGBA8
// and is yours: image_destroy it. `mime` is the form it came in, and `data`
// its bytes as they came (a 16-bit PNG, say, for an app that keeps the
// depth, or a form Baldr cannot decode, for an app that can). Both live
// only while the message is handled: clone what you keep. `ok` is false when
// there was no picture, or one that could not be read or decoded; then
// `image` is empty and `mime` and `data` say what there was, if anything.
Pasted_Image :: struct {
	image: Image,
	mime:  string,
	data:  []u8,
	ok:    bool,
}

// paste_image reads the picture on the clipboard, in its best form: PNG,
// then the other lossless ones Odin decodes (BMP, QOI, TGA, the netpbm
// kinds), then JPEG, then SVG (drawn at its own size). The form is read and
// decoded on a thread, and the handler gets Pasted_Image. Use a handler
// proc: a plain message would drop the picture (it is freed).
//
//	case Paste: return baldr.paste_image(Msg, proc(e: baldr.Ev(baldr.Pasted_Image)) -> Msg { return Pasted_Layer{e.value} })
paste_image :: proc($Msg: typeid, on_done: Handler(Msg, Pasted_Image)) -> Cmd(Msg) {
	return {kind = .Paste_Image, on_image = on_done}
}

MIME_PNG          :: "image/png"
MIME_URI_LIST     :: "text/uri-list"
MIME_GNOME_FILES  :: "x-special/gnome-copied-files" // what GTK file managers paste from: "copy" or "cut", then the URIs
MIME_KDE_CUT      :: "application/x-kde-cutselection" // "1" when KDE's file manager's files were cut
MIME_TEXT_UTF8    :: "text/plain;charset=utf-8"
MIME_TEXT         :: "text/plain"
MIME_HTML         :: "text/html"

// CLIP_TEXT_MIMES is every form plain text goes on the clipboard as: the
// MIME spellings and the three older X ones, which plenty of programs still
// ask for. A copy carrying text beside something richer offers all five
// too, so a plain paste is the same whichever copy made it.
@(private)
CLIP_TEXT_MIMES := [?]string{MIME_TEXT_UTF8, "UTF8_STRING", MIME_TEXT, "TEXT", "STRING"}

// clip_files_items is the set of forms `copy_files` offers.
@(private)
clip_files_items :: proc(paths: []string, cut := false, allocator := context.temp_allocator) -> []Clip_Item {
	uris := uri_list_encode(paths, allocator)
	lf, _ := strings.replace_all(uris, "\r\n", "\n", allocator)
	gnome := strings.concatenate({"cut\n" if cut else "copy\n", strings.trim_right(lf, "\n")}, allocator)
	plain := strings.join(paths, "\n", allocator)
	items := make([dynamic]Clip_Item, 0, 5, allocator)
	append(&items, Clip_Item{mime = MIME_URI_LIST, data = transmute([]u8)uris})
	append(&items, Clip_Item{mime = MIME_GNOME_FILES, data = transmute([]u8)gnome})
	if cut do append(&items, Clip_Item{mime = MIME_KDE_CUT, data = transmute([]u8)string("1")})
	append(&items, Clip_Item{mime = MIME_TEXT_UTF8, data = transmute([]u8)plain})
	append(&items, Clip_Item{mime = MIME_TEXT, data = transmute([]u8)plain})
	return items[:]
}

// clip_html_items is the set of forms `copy_html` offers. The HTML comes
// first because a source's forms are offered in order and a program taking
// the richest one it understands reads them that way; an empty string is
// left out rather than offered as a form that yields nothing.
@(private)
clip_html_items :: proc(html, text: string, allocator := context.temp_allocator) -> []Clip_Item {
	items := make([dynamic]Clip_Item, 0, len(CLIP_TEXT_MIMES) + 1, allocator)
	if len(html) > 0 do append(&items, Clip_Item{mime = MIME_HTML, data = transmute([]u8)html})
	if len(text) > 0 {
		for m in CLIP_TEXT_MIMES do append(&items, Clip_Item{mime = m, data = transmute([]u8)text})
	}
	return items[:]
}

// Clip_Forms is what a paste read, form by form (a missing form is nil).
@(private)
Clip_Forms :: struct {
	text:     string,
	uri_list: []u8,
	gnome:    []u8,
	kde_cut:  []u8,
}

// paste_outcome builds a paste's outcome from the forms the clipboard
// offered: the paths from text/uri-list, else from the GNOME form; cut
// when the GNOME form says so or KDE's marker is "1".
@(private)
paste_outcome :: proc(forms: Clip_Forms, allocator := context.temp_allocator) -> Pasted {
	out := Pasted{text = forms.text}
	if forms.uri_list != nil do out.files = uri_list_decode(string(forms.uri_list), allocator)
	if forms.gnome != nil {
		g := string(forms.gnome)
		verb, rest := g, ""
		if nl := strings.index_byte(g, '\n'); nl >= 0 do verb, rest = g[:nl], g[nl + 1:]
		verb = strings.trim_space(verb)
		out.cut = verb == "cut"
		if len(out.files) == 0 && (verb == "cut" || verb == "copy") do out.files = uri_list_decode(rest, allocator)
	}
	if strings.trim_space(string(forms.kde_cut)) == "1" do out.cut = true
	return out
}

// Pictures

// PICTURE_FORMS are the picture forms paste_image reads, best first.
@(private)
PICTURE_FORMS := [?]string{
	"image/png",
	"image/webp",
	"image/gif",
	"image/bmp", "image/x-bmp", "image/x-ms-bmp",
	"image/qoi", "image/x-qoi",
	"image/tga", "image/x-tga", "image/x-targa",
	"image/x-portable-anymap", "image/x-portable-pixmap", "image/x-portable-graymap", "image/x-portable-bitmap",
	"image/jpeg", "image/jpg", "image/pjpeg",
	"image/svg+xml",
	"image/vnd.microsoft.icon", "image/x-icon",
}

// picture_form is the picture form to read from what the clipboard offers:
// the best one Baldr decodes, else the first image/* it does not, else "".
@(private)
picture_form :: proc(offered: []string) -> string {
	for want in PICTURE_FORMS do for have in offered do if strings.equal_fold(have, want) do return have
	for have in offered do if len(have) > 6 && strings.equal_fold(have[:6], "image/") do return have
	return ""
}

// Paste_Prefer is what an editor takes when the clipboard offers both a
// picture and text. `.Text`, the default, is what a text editor should do.
// `.Picture` is for a composer that attaches pictures: copying an image in a
// browser puts the picture and its URL on the clipboard, so `.Text` pastes
// the address and loses the image. With `.Picture` the picture wins, the app hears `on_paste_other` and nothing is inserted.
// Text alone still pastes as text, and a picture alone always reaches
// `on_paste_other`.
Paste_Prefer :: enum u8 { Text, Picture }

// Paste_Other is what a paste found when the clipboard held no text to
// insert: the forms it does hold, so the app can decide what to do with
// them. `picture` says a picture form is there — answer with `paste_image`.
// `files` says file paths are — answer with `paste` and read its `files`.
// Both can be true (a file manager offering a thumbnail as well as paths):
// the app chooses. `mimes` is every form the clipboard offers, in its own
// order, for an app that reads a form Baldr does not; it and its strings
// live only while the message is handled, so clone what you keep.
//
// It reaches the app through `on_paste_other` on `editor_options` (an
// editor) or on `text_input` (a field). A paste that brought text is
// untouched: the text is inserted and no message is sent.
Paste_Other :: struct {
	picture: bool,
	files:   bool,
	mimes:   []string,
}

// clip_other asks the clipboard what it is offering, for a paste that found
// no text. False when the backend cannot list forms (then nothing is known,
// so nothing is claimed) or when neither a picture nor files are there.
@(private)
clip_other :: proc(t: ^Tree, allocator := context.temp_allocator) -> (Paste_Other, bool) {
	if t.clipboard.types == nil do return {}, false
	offered := t.clipboard.types(t.clipboard.user, allocator)
	if len(offered) == 0 do return {}, false
	out := Paste_Other{mimes = offered, picture = picture_form(offered) != ""}
	for m in offered {
		if strings.equal_fold(m, MIME_URI_LIST) || strings.equal_fold(m, MIME_GNOME_FILES) do out.files = true
	}
	return out, out.picture || out.files
}

// paste_other_send tells the app about a paste that brought no text but a
// picture or files, so a screenshot pasted with plain Ctrl+V is not lost.
// False when this node's app asked for nothing, or the clipboard holds
// nothing it could take; then the paste does nothing.
@(private)
paste_other_send :: proc(ui: ^Ui($Msg), n: Node, picture_only := false) -> bool {
	h, has := ui.paste_others[n]
	if !has do return false
	other, any := clip_other(&ui.tree)
	if !any do return false
	// `picture_only` is the Paste_Prefer path: it runs before the text is
	// looked at, so it claims the paste only for an actual picture. Files
	// beside text let the text through: a path pasted as a path is usually
	// what was meant.
	if picture_only && !other.picture do return false
	return handler_send(ui, h, other, n)
}

// picture_decode decodes a picture form to RGBA8 in `allocator`. A PNG is
// checked before core's decoder sees it (png_check.odin).
@(private)
picture_decode :: proc(mime: string, data: []u8, allocator: runtime.Allocator, max_pixels := IMAGE_LOAD_MAX_PIXELS) -> (img: Image, ok: bool) {
	if len(data) == 0 do return
	low := strings.to_lower(mime, context.temp_allocator)
	// the size the header claims, refused before a decoder allocates for it
	if w, h, said := image_declared_size(low, data); said {
		if w <= 0 || h <= 0 || w > IMAGE_MAX_SIDE || h > IMAGE_MAX_SIDE || w * h > max_pixels do return
	}
	src: ^image.Image
	err: image.Error
	switch low {
	case "image/png":
		return image_load_png(data, allocator)
	case "image/gif":
		return gif_load(data, allocator, max_pixels)
	case "image/webp":
		return webp_load(data, allocator, max_pixels)
	case "image/vnd.microsoft.icon", "image/x-icon", "image/ico":
		return ico_load(data, allocator, max_pixels)
	case "image/bmp", "image/x-bmp", "image/x-ms-bmp":
		src, err = bmp.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	case "image/qoi", "image/x-qoi":
		src, err = qoi.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	case "image/tga", "image/x-tga", "image/x-targa":
		src, err = tga.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	case "image/x-portable-anymap", "image/x-portable-pixmap", "image/x-portable-graymap", "image/x-portable-bitmap":
		src, err = netpbm.load_from_bytes(data, context.temp_allocator)
	case "image/jpeg", "image/jpg", "image/pjpeg":
		src, err = jpeg.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	case "image/svg+xml":
		size, sized := svg_size(data)
		if !sized do return
		return svg_render(data, max(int(size.x + 0.5), 1), max(int(size.y + 0.5), 1), allocator = allocator)
	case:
		return
	}
	if err != nil || src == nil do return
	defer image.destroy(src, context.temp_allocator)
	if src.depth != 8 && src.depth != 16 do return // a float netpbm (PFM): not a picture Baldr keeps
	img, ok = image_from_decoded(src, allocator)
	if ok && (strings.has_prefix(low, "image/jp") || low == "image/pjpeg") do image_orient(&img, jpeg_orientation(data)) // a phone's portrait photo, turned upright
	return
}

// Clip_Picture is a copied picture on its way to PNG: made on a thread from
// the copy on, shared by counting with the backend offering it and the
// threads writing it into other programs' pipes (platform.Clip_Later).
@(private)
Clip_Picture :: struct {
	using later:   platform.Clip_Later, // first: a ^Clip_Later is its ^Clip_Picture
	width, height: int,
	pixels:        []u8, // the copy, until the PNG is made
	png:           []u8,
	made:          sync.One_Shot_Event,
}

// clip_picture_make copies `img` and starts its PNG; nil for an empty
// picture. It holds one reference for the caller and one for the encoder.
@(private)
clip_picture_make :: proc(img: ^Image) -> ^Clip_Picture {
	if img == nil || img.width <= 0 || img.height <= 0 || len(img.pixels) < img.width * img.height * 4 do return nil
	heap := runtime.heap_allocator()
	p := new(Clip_Picture, heap)
	p.width, p.height = img.width, img.height
	p.pixels = make([]u8, img.width * img.height * 4, heap)
	copy(p.pixels, img.pixels)
	p.refs = 2
	p.wait = proc(l: ^platform.Clip_Later) -> []u8 {
		p := (^Clip_Picture)(l)
		sync.one_shot_event_wait(&p.made)
		return p.png
	}
	p.free = proc(l: ^platform.Clip_Later) {
		p := (^Clip_Picture)(l)
		heap := runtime.heap_allocator()
		delete(p.pixels, heap)
		delete(p.png, heap)
		free(p, heap)
	}
	encode :: proc(data: rawptr) {
		p := (^Clip_Picture)(data)
		heap := runtime.heap_allocator()
		p.png, _ = png_encode(p.width, p.height, p.pixels, heap)
		delete(p.pixels, heap)
		p.pixels = nil
		sync.one_shot_event_signal(&p.made)
		platform.clip_later_release(&p.later)
	}
	if thread.create_and_start_with_data(p, encode, self_cleanup = true) == nil do encode(p) // no thread to be had: here and now
	return p
}

// Picture_Op is a paste of a picture in flight: read and decoded on a job
// thread, its outcome posted to the mailbox, and freed once handled.
@(private)
Picture_Op :: struct($Msg: typeid) {
	reader:    platform.Clip_Reader,
	reading:   bool,
	data:      []u8,   // owned
	mime:      string, // owned
	image:     Image,  // the app's once handed over
	ok:        bool,
	on_image:  Handler(Msg, Pasted_Image),
	mailbox:   ^Mailbox(Msg),
	allocator: runtime.Allocator,
}

// picture_op_free frees what a paste held; its image too unless it was
// handed to the app.
@(private)
picture_op_free :: proc(op: ^Picture_Op($Msg), image_too: bool) {
	if image_too do image_destroy(&op.image)
	delete(op.data, op.allocator)
	delete(op.mime, op.allocator)
	free(op, op.allocator)
}

// paste_image_start chooses the picture form, starts reading it on the UI
// thread (clipboard_read) and hands the rest, reading and decoding, to a
// job; the outcome is posted to the mailbox either way.
@(private)
paste_image_start :: proc(rt: ^Runtime($State, $Msg), on_image: Handler(Msg, Pasted_Image)) {
	op := new(Picture_Op(Msg))
	op.allocator = context.allocator
	op.on_image = on_image
	op.mailbox = &rt.mailbox
	b := rt.backend
	mime := ""
	if b != nil && b.clipboard_types != nil do mime = picture_form(b.clipboard_types(b, context.temp_allocator))
	if mime == "" {
		mailbox_post(&rt.mailbox, Mail(Msg){picture = op}) // no picture: said on the next pass, as any outcome is
		return
	}
	op.mime = strings.clone(mime, op.allocator)
	if b.clipboard_read != nil {
		op.reader, op.reading = b.clipboard_read(b, mime)
	} else if b.clipboard_get_data != nil {
		op.data, _ = b.clipboard_get_data(b, mime, op.allocator)
	}
	work :: proc(j: ^Job(Msg)) {
		picture_op_run((^Picture_Op(Msg))(j.data))
	}
	if j := job_start(&rt.mailbox, work, op, nil, 0); j != nil {
		append(&rt.jobs, j)
		return
	}
	picture_op_run(op) // no thread to be had: here and now
}

// picture_op_run finishes a paste: reads what is still coming, decodes it,
// posts the outcome.
@(private)
picture_op_run :: proc(op: ^Picture_Op($Msg)) {
	if op.reading {
		op.data, _ = op.reader.read(op.reader, op.allocator)
		op.reading = false
	}
	op.image, op.ok = picture_decode(op.mime, op.data, op.allocator)
	mailbox_post(op.mailbox, Mail(Msg){picture = op})
}
