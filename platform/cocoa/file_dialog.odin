#+build darwin
package cocoa

// The open and save dialogs, through NSOpenPanel and NSSavePanel.
//
// Neither panel is in the Odin bindings, so this goes through the objc
// runtime as the clipboard does (clipboard.odin). NSOpenPanel is a subclass
// of NSSavePanel, so one set of selectors covers both and only the
// open-specific switches go to the open panel.
//
// It is modal, like the Windows backend (platform/win32/file_dialog.odin):
// `runModal` runs its own event loop, so the app's pump is not running
// during it, and the Ev_Files is queued for the pump that follows. A sheet
// would need a completion block, which Odin cannot make without building
// one by hand.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:mem/virtual"
import "core:fmt"
import "core:strings"
import "baldr:platform"

@(private) @(objc_class = "NSOpenPanel")
Open_Panel :: struct { using _: NS.Object }

@(private) @(objc_class = "NSSavePanel")
Save_Panel :: struct { using _: NS.Object }

// NSModalResponseOK. The person cancelling is NSModalResponseCancel (0),
// which is not an error: it is "no files", the same as on Windows.
@(private) MODAL_OK :: NS.Integer(1)

@(private)
file_dialog :: proc(b: ^platform.Backend, d: platform.File_Dialog) -> bool {
	c := self(b)
	if c == nil || c.app == nil do return false

	// NSOpenPanel for opening — it is an NSSavePanel underneath, which is why
	// the shared settings below take either.
	panel: ^NS.Object
	if d.save {
		panel = intrinsics.objc_send(^NS.Object, Save_Panel, "savePanel")
	} else {
		panel = intrinsics.objc_send(^NS.Object, Open_Panel, "openPanel")
	}
	if panel == nil do return false

	if d.title != "" {
		s := ns_str(d.title)
		defer s->release()
		intrinsics.objc_send(^NS.Object, panel, "setTitle:", s)
	}
	if d.accept_label != "" { // the OK button's words ("Save a copy", "Choose")
		s := ns_str(d.accept_label)
		defer s->release()
		intrinsics.objc_send(^NS.Object, panel, "setPrompt:", s)
	}
	if d.current_folder != "" {
		p := ns_str(d.current_folder)
		defer p->release()
		if url := NS.URL.alloc()->initFileURLWithPath(p); url != nil {
			defer url->release()
			intrinsics.objc_send(^NS.Object, panel, "setDirectoryURL:", url)
		}
	}
	if d.save && d.current_name != "" {
		s := ns_str(d.current_name)
		defer s->release()
		intrinsics.objc_send(^NS.Object, panel, "setNameFieldStringValue:", s)
	}
	if !d.save { // the three switches that only an open panel has
		intrinsics.objc_send(^NS.Object, panel, "setCanChooseFiles:", NS.BOOL(!d.directory))
		intrinsics.objc_send(^NS.Object, panel, "setCanChooseDirectories:", NS.BOOL(d.directory))
		intrinsics.objc_send(^NS.Object, panel, "setAllowsMultipleSelection:", NS.BOOL(d.multiple))
	}
	// Picking a folder must not be narrowed by a file filter, and a save
	// dialog that hides the extension the app asked for is worse than one
	// that filters nothing.
	if !d.directory {
		if types := allowed_types(d.filters); types != nil {
			defer types->release()
			intrinsics.objc_send(^NS.Object, panel, "setAllowedFileTypes:", types)
		}
	}

	resp := intrinsics.objc_send(NS.Integer, panel, "runModal")
	if resp != MODAL_OK { // cancelled: no files, and not a failure
		append(&c.queue, platform.Ev_Files{token = d.token, ok = false, why = .Cancelled})
		return true
	}

	// The pump's arena, which b_pump does not free while something is
	// queued: a dialog runs between pumps, and freeing at the top of the next
	// one would release these before the app has read them.
	paths := make([dynamic]string, 0, 1, virtual.arena_allocator(&c.text))
	if d.save {
		if url := intrinsics.objc_send(^NS.URL, panel, "URL"); url != nil {
			if p := url_path(url, virtual.arena_allocator(&c.text)); p != "" do append(&paths, p)
		}
	} else if arr := intrinsics.objc_send(^NS.Array, panel, "URLs"); arr != nil {
		n := intrinsics.objc_send(NS.UInteger, arr, "count")
		for i in 0 ..< n {
			url := cast(^NS.URL)intrinsics.objc_send(^NS.Object, arr, "objectAtIndex:", i)
			if url == nil do continue
			if p := url_path(url, virtual.arena_allocator(&c.text)); p != "" do append(&paths, p)
		}
	}
	// Logged, as on Windows: to the app an accepted dialog that gave no path
	// looks the same as one that did nothing.
	if len(paths) == 0 {
		fmt.eprintfln("baldr/cocoa: the file dialog was accepted but gave no path (save=%v, multiple=%v, directory=%v)", d.save, d.multiple, d.directory)
	}
	if c.debug_files {
		fmt.eprintfln("baldr/cocoa: file dialog token %d answered with %d path(s)%s", d.token, len(paths),
			fmt.tprintf(", first %q", paths[0]) if len(paths) > 0 else "")
	}
	append(&c.queue, platform.Ev_Files{token = d.token, paths = paths[:], ok = len(paths) > 0, why = .Chosen if len(paths) > 0 else .Unusable})
	return true
}

// url_path is a file URL's local path. `fileSystemRepresentation` and not
// `path`: it is the bytes the filesystem actually uses, already decomposed
// the way HFS+ and APFS want them, and it is what `open` will take back.
@(private)
url_path :: proc(url: ^NS.URL, allocator := context.allocator) -> string {
	cs := url->fileSystemRepresentation()
	if cs == nil do return ""
	out, err := strings.clone_from_cstring(cs, allocator)
	if err != nil do return ""
	return out
}

// allowed_types turns Baldr's filters into the extensions NSSavePanel takes,
// or nil when there is nothing to filter. Only glob patterns ("*.png")
// convert; a MIME type has no extension to give. "*" and "*.*" mean no
// filter at all. `setAllowedFileTypes:` is deprecated for UTType-based
// `allowedContentTypes`, but still works on every macOS Baldr supports and
// needs no per-pattern UTType lookup. The caller releases the array.
@(private)
allowed_types :: proc(filters: []platform.File_Filter) -> ^NS.Array {
	exts := make([dynamic]^NS.Object, 0, 8, context.temp_allocator)
	for f in filters {
		if f.mime do continue
		for pat in f.patterns {
			if pat == "*" || pat == "*.*" do return nil // anything: no filter at all
			ext := pat
			if i := strings.last_index_byte(ext, '.'); i >= 0 do ext = ext[i + 1:]
			if ext == "" || strings.contains(ext, "*") || strings.contains(ext, "?") do continue
			append(&exts, cast(^NS.Object)ns_str(ext))
		}
	}
	if len(exts) == 0 do return nil
	defer for e in exts do e->release()
	return (^NS.Array)(NS.Array.alloc()->initWithObjects((^ObjC.id)(raw_data(exts)), NS.UInteger(len(exts))))
}
