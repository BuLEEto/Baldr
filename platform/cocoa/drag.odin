#+build darwin
package cocoa

// Drag and drop: files and pictures leaving a Baldr window, and arriving in
// one. Four Backend procs, wired as a group because the toolkit takes them
// all or none (app.odin), plus the two AppKit protocols they need:
// NSDraggingDestination on the view for what arrives, NSDraggingSource for
// what leaves.
//
// AppKit asks synchronously and the toolkit answers later: `draggingEntered:`
// must return an operation now, while the toolkit answers with `drag_accept`
// only after the event is pumped. So AppKit is told the last answer the
// toolkit gave, one event behind. That costs a wrong pointer shape for a few
// milliseconds, never a misplaced drop: `performDragOperation:` asks the
// toolkit, not this cache.
//
// The dropped data is copied at the drop. The dragging pasteboard is the
// drag's and the toolkit asks for a form after `performDragOperation:` has
// returned, so every understood form is snapshotted and `drag_receive`
// answers from that. A dropped picture costs its size until the drop
// finishes.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strings"
import "baldr:platform"

@(private) @(objc_class = "NSDraggingItem")
Dragging_Item :: struct {using _: NS.Object}

// NSDragOperation, which is a bit set and not an enum.
@(private) DRAG_OP_NONE    :: NS.UInteger(0)
@(private) DRAG_OP_COPY    :: NS.UInteger(1)
@(private) DRAG_OP_MOVE    :: NS.UInteger(16)
@(private) DRAG_OP_GENERIC :: NS.UInteger(4)

// Drag_In is a drag that is over one of our windows.
@(private)
Drag_In :: struct {
	surface: platform.Surface,
	accept:  bool,              // what the toolkit last said, answered to AppKit until it says otherwise
	mimes:   [dynamic]string,   // what it offers, in the toolkit's names
	forms:   map[string][]u8,   // …and their bytes, snapshotted at the drop
	held:    []u8,              // what drag_receive last handed over, freed at the next ask
}

// Drag_Out is a drag that left one of our windows.
@(private)
Drag_Out :: struct {
	live: bool,
}

@(private)
drag_shutdown :: proc(c: ^Cocoa) {
	drag_in_clear(c)
	delete(c.drag_in.mimes)
}

@(private = "file")
drag_in_clear :: proc(c: ^Cocoa) {
	for mime, bytes in c.drag_in.forms {
		delete(mime, c.allocator)
		delete(bytes, c.allocator)
	}
	clear(&c.drag_in.forms)
	for m in c.drag_in.mimes do delete(m, c.allocator)
	clear(&c.drag_in.mimes)
	if c.drag_in.held != nil {
		delete(c.drag_in.held, c.allocator)
		c.drag_in.held = nil
	}
	c.drag_in.accept = false
	c.drag_in.surface = 0
}

// ------------------------------------------------------------ what arrives

// DRAGGED_UTIS is what a Baldr window says it will take. A type that is not
// registered is never offered to the view at all, so this is the ceiling on
// what any app built on the toolkit can receive here.
@(private)
DRAGGED_UTIS := [?]string{UTI_FILE_URL, UTI_TEXT, UTI_PNG, UTI_TIFF, UTI_JPEG, UTI_HTML}

// drag_register says the view takes drops. Called when the view is made.
@(private)
drag_register :: proc(view: ^NS.View) {
	arr := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^NS.MutableArray, NS.MutableArray, "alloc"), "init")
	if arr == nil do return
	defer intrinsics.objc_send(nil, arr, "release")
	for uti in DRAGGED_UTIS {
		s := ns_str(uti)
		if s == nil do continue
		defer s->release()
		intrinsics.objc_send(nil, arr, "addObject:", s)
	}
	intrinsics.objc_send(nil, view, "registerForDraggedTypes:", arr)
}

// drag_point is where the drag is, in the view's own logical pixels —
// top-left origin, because the view is flipped (view.odin).
@(private = "file")
drag_point :: proc "c" (self: ObjC.id, sender: ObjC.id) -> [2]f32 {
	p := intrinsics.objc_send(NS.Point, cast(^NS.Object)sender, "draggingLocation")
	local := intrinsics.objc_send(NS.Point, cast(^NS.View)self, "convertPoint:fromView:", p, (^NS.View)(nil))
	return {f32(local.x), f32(local.y)}
}

@(private = "file")
drag_pasteboard :: proc "contextless" (sender: ObjC.id) -> ^NS.Pasteboard {
	return intrinsics.objc_send(^NS.Pasteboard, cast(^NS.Object)sender, "draggingPasteboard")
}

@(private)
v_dragging_entered :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) -> NS.UInteger {
	s := surface_of(self)
	if s == nil do return DRAG_OP_NONE
	c := s.cocoa
	context = c.ctx
	drag_in_clear(c)
	c.drag_in.surface = s.id

	// What it offers, named the way the toolkit names things.
	own := false
	if pb := drag_pasteboard(sender); pb != nil {
		if types := intrinsics.objc_send(^NS.Array, pb, "types"); types != nil {
			n := types->count()
			for i in 0 ..< n {
				str := intrinsics.objc_send(^NS.String, types->object(i), "self")
				if str == nil do continue
				mimes_of_uti(&c.drag_in.mimes, string(str->odinString()), c.allocator)
			}
		}
	}
	// A drag that started in this process: the toolkit answers its own
	// data from memory rather than asking for it back.
	own = c.drag_out.live

	if c.debug_files do fmt.eprintfln("baldr/cocoa: drag entered surface %v offering %v", s.id, c.drag_in.mimes[:])
	append(&c.queue, platform.Ev_Drag_Enter{
		surface = s.id, pos = drag_point(self, sender), mimes = c.drag_in.mimes[:], own = own,
	})
	b_wake(&c.backend)
	return DRAG_OP_NONE // nothing is accepted until the toolkit has seen it
}

@(private)
v_dragging_updated :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) -> NS.UInteger {
	s := surface_of(self)
	if s == nil do return DRAG_OP_NONE
	c := s.cocoa
	context = c.ctx
	append(&c.queue, platform.Ev_Drag_Motion{surface = s.id, pos = drag_point(self, sender)})
	b_wake(&c.backend)
	return DRAG_OP_COPY if c.drag_in.accept else DRAG_OP_NONE
}

@(private)
v_dragging_exited :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	s := surface_of(self)
	if s == nil do return
	c := s.cocoa
	context = c.ctx
	append(&c.queue, platform.Ev_Drag_Leave{surface = s.id})
	drag_in_clear(c)
	b_wake(&c.backend)
}

@(private)
v_prepare_for_drag :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) -> NS.BOOL {
	return true // the toolkit decides in performDragOperation:, where the app can be asked
}

// performDragOperation: is the drop. The data is taken here, while the
// dragging pasteboard is still the drag's, and the toolkit is told; what it
// asks for afterwards comes out of this snapshot.
@(private)
v_perform_drag :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) -> NS.BOOL {
	s := surface_of(self)
	if s == nil do return false
	c := s.cocoa
	context = c.ctx
	pb := drag_pasteboard(sender)
	if pb == nil do return false
	for mime in c.drag_in.mimes {
		if mime in c.drag_in.forms do continue
		data, ok := drag_form(pb, mime, c.allocator)
		if !ok do continue
		key, err := strings.clone(mime, c.allocator)
		if err != nil {
			delete(data, c.allocator)
			continue
		}
		c.drag_in.forms[key] = data
	}
	mask := intrinsics.objc_send(NS.UInteger, cast(^NS.Object)sender, "draggingSourceOperationMask")
	// The modifiers as they are *now*: what a drop does is decided by what
	// is held at the moment it is let go, and NSEvent answers that as a
	// class method rather than from the event.
	mods := mods_from_flags(u64(intrinsics.objc_send(NS.UInteger, NS.Event, "modifierFlags")))
	if c.debug_files do fmt.eprintfln("baldr/cocoa: drag dropped on surface %v, %d form(s) taken, action %v", s.id, len(c.drag_in.forms), drag_action(mask))
	append(&c.queue, platform.Ev_Drag_Drop{
		surface = s.id, pos = drag_point(self, sender), action = drag_action(mask), mods = mods,
	})
	b_wake(&c.backend)
	return true
}

// drag_action is what the source says it would allow, as the toolkit's
// word for it. A source offering both (the usual) leaves the choice to the
// target, which is what Default means.
@(private = "file")
drag_action :: proc "contextless" (mask: NS.UInteger) -> platform.Drag_Action {
	copy_ok := mask & DRAG_OP_COPY != 0 || mask & DRAG_OP_GENERIC != 0
	move_ok := mask & DRAG_OP_MOVE != 0
	switch {
	case copy_ok && move_ok: return .Default
	case move_ok:            return .Move
	case copy_ok:            return .Copy
	}
	return .Default
}

// drag_form reads one form off a dragging pasteboard, by the same names and
// the same transcode the clipboard uses (clipboard_typed.odin).
@(private = "file")
drag_form :: proc(pb: ^NS.Pasteboard, mime: string, allocator: mem.Allocator) -> ([]u8, bool) {
	switch {
	case strings.equal_fold(mime, MIME_URI_LIST):
		return pb_uri_list(pb, allocator)
	case strings.equal_fold(mime, MIME_PNG):
		if data, ok := pb_bytes(pb, UTI_PNG, allocator); ok do return data, true
		tiff, got := pb_bytes(pb, UTI_TIFF, context.temp_allocator)
		if !got do return nil, false
		return tiff_as_png(tiff, allocator)
	}
	uti, ok := uti_for_mime(mime)
	if !ok do return nil, false
	return pb_bytes(pb, uti, allocator)
}

// ------------------------------------------------------------ the Backend procs

@(private)
b_drag_accept :: proc(b: ^platform.Backend, accept: bool) {
	self(b).drag_in.accept = accept
}

@(private)
b_drag_receive :: proc(b: ^platform.Backend, mime: string) -> bool {
	c := self(b)
	data, has := c.drag_in.forms[mime]
	if !has {
		append(&c.queue, platform.Ev_Drag_Data{ok = false})
		return false
	}
	// The bytes belong to the backend until the next pump, which is what
	// platform.odin promises, so the copy handed over is freed at the next
	// ask rather than here.
	if c.drag_in.held != nil do delete(c.drag_in.held, c.allocator)
	held, err := mem.make_aligned([]u8, len(data), 1, c.allocator)
	if err != nil {
		append(&c.queue, platform.Ev_Drag_Data{ok = false})
		return false
	}
	mem.copy(raw_data(held), raw_data(data), len(data))
	c.drag_in.held = held
	append(&c.queue, platform.Ev_Drag_Data{data = held, ok = true})
	return true
}

@(private)
b_drag_finish :: proc(b: ^platform.Backend, accepted: bool) {
	drag_in_clear(self(b))
}

// b_drag_start begins a drag out of this window. AppKit needs the mouse
// event the drag began with — the press, not the motion — which the pump
// keeps for exactly this (`Surface.press`); `serial` has no meaning here
// and is ignored, as it is on Windows.
@(private)
b_drag_start :: proc(b: ^platform.Backend, surface: platform.Surface, items: []platform.Clip_Item, serial: u32, icon: platform.Drag_Icon) -> bool {
	c := self(b)
	s := find(c, surface)
	if s == nil || s.view == nil || s.press == nil {
		if c.debug_files {
			fmt.eprintfln("baldr/cocoa: drag_start refused: surface %v, view %v, a press to begin from %v",
				s != nil, s != nil && s.view != nil, s != nil && s.press != nil)
		}
		return false
	}

	drag_items := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^NS.MutableArray, NS.MutableArray, "alloc"), "init")
	if drag_items == nil do return false
	defer intrinsics.objc_send(nil, drag_items, "release")

	// Where the drag began, in the view's own coordinates: every item's
	// picture is placed against this, because that is the space a dragging
	// frame is in.
	at := intrinsics.objc_send(NS.Point, s.view, "convertPoint:fromView:",
		intrinsics.objc_send(NS.Point, s.press, "locationInWindow"), (^NS.View)(nil))

	// Files are a dragging item each, as URLs, so a drop into the Finder
	// lands as files; everything else rides one item beside them. The same
	// shape the clipboard writes.
	for it in items do if strings.equal_fold(it.mime, MIME_URI_LIST) {
		data := clip_bytes(it)
		if len(data) == 0 do continue
		for uri in drag_uri_lines(string(data)) {
			u := ns_str(uri)
			if u == nil do continue
			defer u->release()
			url := intrinsics.objc_send(^NS.Object, NS.URL, "URLWithString:", u)
			if url == nil do continue
			if di := drag_item_for(c, url, icon, at); di != nil {
				intrinsics.objc_send(nil, drag_items, "addObject:", di)
				intrinsics.objc_send(nil, di, "release")
			}
		}
	}
	pb_item := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^Pasteboard_Item, Pasteboard_Item, "alloc"), "init")
	if pb_item != nil {
		defer intrinsics.objc_send(nil, pb_item, "release")
		typed := false
		for it in items {
			if strings.equal_fold(it.mime, MIME_URI_LIST) do continue
			uti, ok := uti_for_mime(it.mime)
			if !ok do continue
			data := clip_bytes(it)
			if len(data) == 0 do continue
			if item_put(pb_item, uti, data) do typed = true
		}
		if typed {
			if di := drag_item_for(c, pb_item, icon, at); di != nil {
				intrinsics.objc_send(nil, drag_items, "addObject:", di)
				intrinsics.objc_send(nil, di, "release")
			}
		}
	}
	if intrinsics.objc_send(NS.UInteger, drag_items, "count") == 0 do return false

	n := intrinsics.objc_send(NS.UInteger, drag_items, "count")
	session := intrinsics.objc_send(^NS.Object, s.view, "beginDraggingSessionWithItems:event:source:",
		drag_items, s.press, s.view)
	if c.debug_files {
		fmt.eprintfln("baldr/cocoa: drag_start from surface %v: %d item(s), session %v", surface, n, session != nil)
	}
	if session == nil do return false
	c.drag_out.live = true
	return true
}

// drag_item_for wraps one pasteboard writer in an NSDraggingItem and gives
// it a picture. An item built from a pasteboard writer has none and AppKit
// supplies no default: with no dragging frame the drag is invisible. The
// picture is the one the toolkit sent, else the file's own icon, else a
// generic document icon. `at` is where the drag began in the view's
// coordinates, because the dragging frame is in the space of the view that
// started the drag; a frame at the origin lands in the window's corner.
@(private = "file")
drag_item_for :: proc(c: ^Cocoa, writer: ^NS.Object, icon: platform.Drag_Icon, at: NS.Point) -> ^NS.Object {
	di := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^Dragging_Item, Dragging_Item, "alloc"), "initWithPasteboardWriter:", writer)
	if di == nil do return nil

	img := drag_image(icon)
	centred := false
	if img == nil {
		img = drag_stand_in(writer)
		centred = true // nobody said where the pointer should hold it: the middle
	}
	if img == nil {
		if c.debug_files do fmt.eprintln("baldr/cocoa: drag item has no picture, so nothing will be drawn")
		return di
	}
	defer intrinsics.objc_send(nil, img, "release")

	size := intrinsics.objc_send(NS.Size, img, "size")
	origin := NS.Point{
		at.x - (size.width / 2 if centred else NS.Float(f64(icon.offset.x) / f64(max(icon.scale, 1)))),
		at.y - (size.height / 2 if centred else NS.Float(f64(icon.offset.y) / f64(max(icon.scale, 1)))),
	}
	if c.debug_files {
		fmt.eprintfln("baldr/cocoa: drag picture %.0fx%.0f at %.0f,%.0f (%s)",
			f64(size.width), f64(size.height), f64(origin.x), f64(origin.y),
			"the app's own" if !centred else "a stand-in")
	}
	intrinsics.objc_send(nil, di, "setDraggingFrame:contents:", NS.Rect{origin, size}, img)
	return di
}

// drag_stand_in is what to drag when the app sent no picture: the file's
// own icon for a file, as the Finder drags, and a generic document icon for
// anything else. Sized to 64 points, which is what a Finder drag looks
// like; the icon comes back at whatever size it was stored at otherwise.
@(private = "file")
drag_stand_in :: proc(writer: ^NS.Object) -> ^Cur_Image {
	ws := intrinsics.objc_send(^NS.Object, Workspace, "sharedWorkspace") // declared in open.odin
	if ws == nil do return nil
	img: ^Cur_Image
	// An NSURL answers `path`; a pasteboard item does not, which is how one
	// is told from the other without keeping a flag alongside.
	if path := intrinsics.objc_send(^NS.String, writer, "path"); path != nil {
		img = intrinsics.objc_send(^Cur_Image, ws, "iconForFile:", path)
	}
	if img == nil {
		ty := ns_str("public.data")
		if ty == nil do return nil
		defer ty->release()
		img = intrinsics.objc_send(^Cur_Image, ws, "iconForFileType:", ty)
	}
	if img == nil do return nil
	// Retained because the caller releases: these come from AppKit's own
	// cache and are not ours to take.
	img = intrinsics.objc_send(^Cur_Image, img, "retain")
	intrinsics.objc_send(nil, img, "setSize:", NS.Size{64, 64})
	return img
}

// drag_image is the picture the drag carries, or nil when the toolkit sent
// none (an `icon` with no pixels means there is none to show).
@(private = "file")
drag_image :: proc(icon: platform.Drag_Icon) -> ^Cur_Image {
	if len(icon.pixels) == 0 do return nil
	return ns_image_from_rgba(icon.pixels, icon.size, icon.scale)
}

// drag_uri_lines splits a text/uri-list, dropping the comments the format
// allows. (clipboard_typed.odin has the same split for the clipboard; they
// are three lines each and sharing them would cost more than it saves.)
@(private = "file")
drag_uri_lines :: proc(list: string) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	rest := list
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' do continue
		append(&out, trimmed)
	}
	return out[:]
}

// ------------------------------------------------------------ what leaves

// The view is the dragging source. `sourceOperationMaskForDraggingContext:`
// is what this drag may do; offering both copy and move leaves the choice
// to the target and to what the person is holding, which is the toolkit's
// Default.
@(private)
v_source_mask :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, session: ObjC.id, context_: NS.Integer) -> NS.UInteger {
	return DRAG_OP_COPY | DRAG_OP_MOVE
}

@(private)
v_session_ended :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, session: ObjC.id, at: NS.Point, operation: NS.UInteger) {
	s := surface_of(self)
	if s == nil do return
	c := s.cocoa
	context = c.ctx
	c.drag_out.live = false
	if c.debug_files do fmt.eprintfln("baldr/cocoa: drag ended, operation %v", operation)
	append(&c.queue, platform.Ev_Drag_End{
		dropped = operation != DRAG_OP_NONE,
		action  = drag_action(operation),
	})
	b_wake(&c.backend)
}
