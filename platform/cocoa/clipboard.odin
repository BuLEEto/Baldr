#+build darwin
package cocoa

// The clipboard, through NSPasteboard.
//
// The four selectors an app needs are sent through the objc runtime
// directly: `generalPasteboard`, `clearContents`, `stringForType:` and
// `setString:forType:`.
//
// No primary selection: `primary_get` / `primary_set` stay nil, since macOS
// has no middle-click selection, and the toolkit then never offers it.
//
// The typed clipboard (`clipboard_types`, `clipboard_get_data`,
// `clipboard_set_data`) is in `clipboard_typed.odin` beside this: pictures,
// files and formatted text, in uniform type identifiers rather than MIME
// names.

import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "core:strings"
import "baldr:platform"

// UTI_TEXT is NSPasteboardTypeString, which is a uniform type identifier
// rather than a MIME type. Spelled out because the constant lives in a
// framework symbol the bindings do not export.
@(private)
UTI_TEXT :: "public.utf8-plain-text"

// `generalPasteboard` is a class method, so the type is the receiver:
// NS.Pasteboard carries `objc_class="NSPasteboard"`. objc_send will not take
// the `^objc_class` that objc_find_class returns.
@(private)
general_pasteboard :: proc "contextless" () -> ^NS.Pasteboard {
	return intrinsics.objc_send(^NS.Pasteboard, NS.Pasteboard, "generalPasteboard")
}

// ns_str makes an NSString the caller releases. Not NS.AT: that is CFSTR,
// which mangles anything but ASCII.
@(private)
ns_str :: proc(s: string) -> ^NS.String {
	return NS.String.alloc()->initWithOdinString(s)
}

@(private)
b_clipboard_get :: proc(b: ^platform.Backend, allocator := context.allocator) -> (string, bool) {
	pb := general_pasteboard()
	if pb == nil do return "", false
	ty := ns_str(UTI_TEXT)
	defer ty->release()
	got := intrinsics.objc_send(^NS.String, pb, "stringForType:", ty)
	// Nil for an empty clipboard, and for one holding only something else
	// (a picture, a file) — not an error, just nothing to paste as text.
	if got == nil do return "", false
	out, err := strings.clone(string(got->odinString()), allocator)
	if err != nil do return "", false
	return out, true
}

@(private)
b_clipboard_set :: proc(b: ^platform.Backend, text: string) -> bool {
	pb := general_pasteboard()
	if pb == nil do return false
	// clearContents first: setString: on an uncleared board is refused, and
	// clearing takes ownership from whoever owned it last.
	intrinsics.objc_send(NS.Integer, pb, "clearContents")
	str := ns_str(text)
	defer str->release()
	ty := ns_str(UTI_TEXT)
	defer ty->release()
	return bool(intrinsics.objc_send(NS.BOOL, pb, "setString:forType:", str, ty))
}
