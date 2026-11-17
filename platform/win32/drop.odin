#+build windows
package win32

// Files dropped on a window from Explorer: a PDF or a screenshot
// dragged into a composer. Windows offers this through OLE — a window
// registers an IDropTarget and hears enter, over, leave and drop — which is
// what the toolkit's drag events want: the hover highlight needs the moves,
// not just the drop, so WM_DROPFILES (a drop and nothing else) is not
// enough.
//
// core:sys/windows has no IDropTarget or IDataObject, so their vtables are
// declared here. Only what a target needs is filled in: the rest of
// IDataObject is declared so the table's shape is right, and never called.
//
// One target serves every surface: it remembers which window each callback
// came from. The paths are read once at the drop and kept until
// drag_finish, so the toolkit can ask for them (drag_receive) after the
// event has been handled, exactly as on Wayland.

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

// core:sys/windows has the clipboard and the shell, but not OLE's drag and
// drop, so what a target needs is declared here.
foreign import ole32 "system:ole32.lib"

@(default_calling_convention = "system")
foreign ole32 {
	OleInitialize    :: proc(reserved: rawptr) -> win.HRESULT ---
	OleUninitialize  :: proc() ---
	RegisterDragDrop :: proc(hwnd: win.HWND, target: ^IDropTarget) -> win.HRESULT ---
	RevokeDragDrop   :: proc(hwnd: win.HWND) -> win.HRESULT ---
	ReleaseStgMedium :: proc(med: ^STGMEDIUM) ---
}

// POINTL is OLE's point, in screen coordinates.
@(private)
POINTL :: struct { x, y: win.LONG }

@(private) DROPEFFECT_NONE :: win.DWORD(0)
@(private) DROPEFFECT_COPY :: win.DWORD(1)
@(private) DROPEFFECT_MOVE :: win.DWORD(2)

@(private) TYMED_HGLOBAL :: win.DWORD(1)
@(private) DVASPECT_CONTENT :: win.DWORD(1)

// FORMATETC and STGMEDIUM as OLE passes them; only the HGLOBAL case is read.
@(private)
FORMATETC :: struct {
	cfFormat: win.WORD,
	ptd:      rawptr,
	dwAspect: win.DWORD,
	lindex:   win.LONG,
	tymed:    win.DWORD,
}

@(private)
STGMEDIUM :: struct {
	tymed:         win.DWORD,
	using _:       struct #raw_union { hGlobal: win.HGLOBAL, other: rawptr },
	pUnkForRelease: rawptr,
}

@(private)
IDataObject :: struct { using vtbl: ^IDataObject_Vtbl }

@(private)
IDataObject_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IDataObject, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IDataObject) -> win.ULONG,
	Release:        proc "system" (this: ^IDataObject) -> win.ULONG,
	GetData:        proc "system" (this: ^IDataObject, fmt: ^FORMATETC, med: ^STGMEDIUM) -> win.HRESULT,
	GetDataHere:    rawptr,
	QueryGetData:   proc "system" (this: ^IDataObject, fmt: ^FORMATETC) -> win.HRESULT,
	GetCanonicalFormatEtc: rawptr,
	SetData:        rawptr,
	EnumFormatEtc:  rawptr,
	DAdvise:        rawptr,
	DUnadvise:      rawptr,
	EnumDAdvise:    rawptr,
}

@(private)
IDropTarget :: struct { using vtbl: ^IDropTarget_Vtbl }

@(private)
IDropTarget_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IDropTarget, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IDropTarget) -> win.ULONG,
	Release:        proc "system" (this: ^IDropTarget) -> win.ULONG,
	DragEnter:      proc "system" (this: ^IDropTarget, data: ^IDataObject, keys: win.DWORD, pt: POINTL, effect: ^win.DWORD) -> win.HRESULT,
	DragOver:       proc "system" (this: ^IDropTarget, keys: win.DWORD, pt: POINTL, effect: ^win.DWORD) -> win.HRESULT,
	DragLeave:      proc "system" (this: ^IDropTarget) -> win.HRESULT,
	Drop:           proc "system" (this: ^IDropTarget, data: ^IDataObject, keys: win.DWORD, pt: POINTL, effect: ^win.DWORD) -> win.HRESULT,
}

// Drop_Target is the object Windows holds: our vtable first (OLE only ever
// sees that pointer), then what we need to answer with.
@(private)
Drop_Target :: struct {
	using base: IDropTarget,
	refs:       win.ULONG,
	w:          ^Win32,
	surface:    platform.Surface,
	hwnd:       win.HWND,
	files:      []u8, // the dropped paths as text/uri-list, until drag_finish
	over:       bool,
}

@(private)
drop_vtbl: IDropTarget_Vtbl

// drop_register gives a window a drop target of its own. OLE is started
// once, for this thread, which is the thread every window lives on.
@(private)
drop_register :: proc(w: ^Win32, s: ^Surface) {
	if !w.ole_started {
		if win.FAILED(OleInitialize(nil)) do return
		w.ole_started = true
		drop_vtbl = {
			QueryInterface = drop_query_interface,
			AddRef         = drop_add_ref,
			Release        = drop_release,
			DragEnter      = drop_drag_enter,
			DragOver       = drop_drag_over,
			DragLeave      = drop_drag_leave,
			Drop           = drop_drop,
		}
	}
	t := new(Drop_Target, w.allocator)
	t.vtbl = &drop_vtbl
	t.refs = 1
	t.w, t.surface, t.hwnd = w, s.id, s.hwnd
	if win.FAILED(RegisterDragDrop(s.hwnd, &t.base)) {
		free(t, w.allocator)
		return
	}
	s.drop = t
}

// drop_revoke takes the target off a window as it closes.
@(private)
drop_revoke :: proc(w: ^Win32, s: ^Surface) {
	if s.drop == nil do return
	RevokeDragDrop(s.hwnd)
	t := (^Drop_Target)(s.drop)
	delete(t.files, w.allocator)
	free(t, w.allocator)
	s.drop = nil
}

@(private)
drop_query_interface :: proc "system" (this: ^IDropTarget, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT {
	if out == nil do return win.HRESULT(transmute(i32)u32(win.E_INVALIDARG))
	out^ = this // IUnknown and IDropTarget are the only ones asked for, and both are this
	drop_add_ref(this)
	return win.S_OK
}

@(private)
drop_add_ref :: proc "system" (this: ^IDropTarget) -> win.ULONG {
	t := (^Drop_Target)(this)
	t.refs += 1
	return t.refs
}

@(private)
drop_release :: proc "system" (this: ^IDropTarget) -> win.ULONG {
	t := (^Drop_Target)(this)
	if t.refs > 0 do t.refs -= 1
	return t.refs // the surface owns it; drop_revoke frees it
}

@(private)
drop_drag_enter :: proc "system" (this: ^IDropTarget, data: ^IDataObject, keys: win.DWORD, pt: POINTL, effect: ^win.DWORD) -> win.HRESULT {
	t := (^Drop_Target)(this)
	context = t.w.ctx
	has := data_has_files(data)
	t.over = has
	if !has {
		effect^ = DROPEFFECT_NONE
		return win.S_OK
	}
	mimes := make([]string, 1, virtual.arena_allocator(&t.w.text))
	mimes[0] = MIME_URI_LIST
	append(&t.w.queue, platform.Ev_Drag_Enter{surface = t.surface, pos = drop_point(t, pt), mimes = mimes})
	effect^ = drop_effect(keys)
	return win.S_OK
}

@(private)
drop_drag_over :: proc "system" (this: ^IDropTarget, keys: win.DWORD, pt: POINTL, effect: ^win.DWORD) -> win.HRESULT {
	t := (^Drop_Target)(this)
	context = t.w.ctx
	if !t.over {
		effect^ = DROPEFFECT_NONE
		return win.S_OK
	}
	append(&t.w.queue, platform.Ev_Drag_Motion{surface = t.surface, pos = drop_point(t, pt)})
	effect^ = drop_effect(keys)
	return win.S_OK
}

@(private)
drop_drag_leave :: proc "system" (this: ^IDropTarget) -> win.HRESULT {
	t := (^Drop_Target)(this)
	context = t.w.ctx
	if t.over do append(&t.w.queue, platform.Ev_Drag_Leave{surface = t.surface})
	t.over = false
	return win.S_OK
}

@(private)
drop_drop :: proc "system" (this: ^IDropTarget, data: ^IDataObject, keys: win.DWORD, pt: POINTL, effect: ^win.DWORD) -> win.HRESULT {
	t := (^Drop_Target)(this)
	context = t.w.ctx
	t.over = false
	effect^ = DROPEFFECT_NONE
	files, ok := data_files(data, t.w.allocator)
	if !ok {
		append(&t.w.queue, platform.Ev_Drag_Leave{surface = t.surface})
		return win.S_OK
	}
	delete(t.files, t.w.allocator)
	t.files = files // kept for drag_receive, until drag_finish
	t.w.drop_held = t
	action := platform.Drag_Action.Move if keys & win.MK_SHIFT != 0 else .Copy
	mods: platform.Mods
	if keys & win.MK_SHIFT != 0 do mods += {.Shift}
	if keys & win.MK_CONTROL != 0 do mods += {.Ctrl}
	append(&t.w.queue, platform.Ev_Drag_Drop{surface = t.surface, pos = drop_point(t, pt), action = action, mods = mods})
	effect^ = DROPEFFECT_COPY if action == .Copy else DROPEFFECT_MOVE
	return win.S_OK
}

// drop_effect: Shift asks for a move, anything else copies — Windows'
// own convention, and what Explorer shows as the cursor.
@(private)
drop_effect :: proc "contextless" (keys: win.DWORD) -> win.DWORD {
	return DROPEFFECT_MOVE if keys & win.MK_SHIFT != 0 else DROPEFFECT_COPY
}

// drop_point turns OLE's screen point into the surface's logical pixels.
@(private)
drop_point :: proc(t: ^Drop_Target, pt: POINTL) -> [2]f32 {
	p := win.POINT{pt.x, pt.y}
	win.ScreenToClient(t.hwnd, &p)
	for s in t.w.surfaces do if s != nil && s.id == t.surface {
		return [2]f32{f32(p.x), f32(p.y)} / scale_of(s)
	}
	return {f32(p.x), f32(p.y)}
}

// data_has_files: the drag carries CF_HDROP (Explorer's files).
@(private)
data_has_files :: proc(data: ^IDataObject) -> bool {
	if data == nil do return false
	fmt := FORMATETC{cfFormat = win.WORD(win.CF_HDROP), dwAspect = DVASPECT_CONTENT, lindex = -1, tymed = TYMED_HGLOBAL}
	return data.QueryGetData(data, &fmt) == win.S_OK
}

// data_files reads the dropped paths as a text/uri-list, the form the
// toolkit asks for. The bytes are the caller's.
@(private)
data_files :: proc(data: ^IDataObject, allocator: mem.Allocator) -> ([]u8, bool) {
	if data == nil do return nil, false
	fmt := FORMATETC{cfFormat = win.WORD(win.CF_HDROP), dwAspect = DVASPECT_CONTENT, lindex = -1, tymed = TYMED_HGLOBAL}
	med: STGMEDIUM
	if data.GetData(data, &fmt, &med) != win.S_OK do return nil, false
	defer ReleaseStgMedium(&med)
	if med.hGlobal == nil do return nil, false
	drop := win.HDROP(med.hGlobal)
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

// drag_start: dragging out of a Baldr window into another app is not
// implemented here yet (it wants OLE's DoDragDrop and a data object of our
// own). Saying so keeps a drag inside the window, where it works, rather
// than letting one leave and vanish. `icon` would be IDragSourceHelper's
// job on this platform, not a surface of ours.
@(private)
drag_start :: proc(b: ^platform.Backend, surface: platform.Surface, items: []platform.Clip_Item, serial: u32, icon: platform.Drag_Icon) -> bool {
	return false
}

// drag_accept: feedback for our own outgoing drag, which there isn't one of.
@(private)
drag_accept :: proc(b: ^platform.Backend, accept: bool) {}

// drag_receive answers the toolkit's ask for the drop's data
// (Backend.drag_receive): the paths, as text/uri-list.
@(private)
drag_receive :: proc(b: ^platform.Backend, mime: string) -> bool {
	w := (^Win32)(b.data)
	t := (^Drop_Target)(w.drop_held)
	if t == nil || t.files == nil || !strings.equal_fold(mime, MIME_URI_LIST) do return false
	bytes := make([]u8, len(t.files), virtual.arena_allocator(&w.text)) // the toolkit's until the next pump
	copy(bytes, t.files)
	append(&w.queue, platform.Ev_Drag_Data{data = bytes, ok = true})
	return true
}

// drag_finish: the toolkit is done with the drop (Backend.drag_finish).
@(private)
drag_finish :: proc(b: ^platform.Backend, accepted: bool) {
	w := (^Win32)(b.data)
	t := (^Drop_Target)(w.drop_held)
	if t == nil do return
	delete(t.files, w.allocator)
	t.files = nil
	w.drop_held = nil
}
