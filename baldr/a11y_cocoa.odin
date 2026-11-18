#+build darwin
package baldr

// Answering NSAccessibility, so VoiceOver can read a Baldr app on macOS.
//
// This is the macOS half of the seam `a11y_model.odin` describes: the model
// decides what every object is, what it is called and what just changed, and
// this file says it in AppKit's words. Nothing here decides anything about a
// widget.
//
// AppKit hands out the application and the window; everything inside a
// view is the view's business, so a custom-drawn toolkit hands AppKit one
// object per control. `BaldrA11yElement`, a class made at runtime, holds
// nothing but the model's 64-bit id and answers every question from the
// live tree. One object per id is kept while the id resolves: VoiceOver
// tracks what it reads by object identity, and a fresh object would make
// its cursor jump.
//
// The view needs no subclass: NSView's accessibility properties are
// settable, so the root elements are hung on the backend's own view, and
// `platform/cocoa` knows nothing of this. `accessibilityFocusedUIElement`
// is added at runtime to `BaldrView` (`ax_hook_view`).
//
// The six text methods and the `AXAnnouncementRequested` path have not yet
// been exercised by a reader; a wrong method encoding in any of them is a
// crash inside AppKit.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"

foreign import AppKit "system:AppKit.framework"

// The role, notification and key names are AppKit's exported strings, not
// the literals behind them: a wrong name is a link error, where a wrong
// literal is a control that silently reads as "unknown".
foreign AppKit {
	NSAccessibilityUnknownRole:           ^NS.String
	NSAccessibilityApplicationRole:       ^NS.String
	NSAccessibilityWindowRole:            ^NS.String
	NSAccessibilityGroupRole:             ^NS.String
	NSAccessibilityStaticTextRole:        ^NS.String
	NSAccessibilityImageRole:             ^NS.String
	NSAccessibilityButtonRole:            ^NS.String
	NSAccessibilityCheckBoxRole:          ^NS.String
	NSAccessibilityRadioButtonRole:       ^NS.String
	NSAccessibilityRadioGroupRole:        ^NS.String
	NSAccessibilitySliderRole:            ^NS.String
	NSAccessibilityIncrementorRole:       ^NS.String
	NSAccessibilityTextFieldRole:         ^NS.String
	NSAccessibilityTextAreaRole:          ^NS.String
	NSAccessibilityComboBoxRole:          ^NS.String
	NSAccessibilityListRole:              ^NS.String
	NSAccessibilityRowRole:               ^NS.String
	NSAccessibilityTableRole:             ^NS.String
	NSAccessibilityCellRole:              ^NS.String
	NSAccessibilityOutlineRole:           ^NS.String
	NSAccessibilityTabGroupRole:          ^NS.String
	NSAccessibilityMenuBarRole:           ^NS.String
	NSAccessibilityMenuRole:              ^NS.String
	NSAccessibilityMenuItemRole:          ^NS.String
	NSAccessibilitySheetRole:             ^NS.String
	NSAccessibilityProgressIndicatorRole: ^NS.String
	NSAccessibilitySplitterRole:          ^NS.String
	NSAccessibilityScrollAreaRole:        ^NS.String
	NSAccessibilityToolbarRole:           ^NS.String
	NSAccessibilityLinkRole:              ^NS.String
	NSAccessibilitySecureTextFieldSubrole: ^NS.String

	NSAccessibilityFocusedUIElementChangedNotification: ^NS.String
	NSAccessibilityValueChangedNotification:            ^NS.String
	NSAccessibilityTitleChangedNotification:            ^NS.String
	NSAccessibilitySelectedTextChangedNotification:     ^NS.String
	NSAccessibilitySelectedChildrenChangedNotification: ^NS.String
	NSAccessibilityLayoutChangedNotification:           ^NS.String
	NSAccessibilityUIElementDestroyedNotification:      ^NS.String
	NSAccessibilityAnnouncementRequestedNotification:   ^NS.String
	NSAccessibilityCreatedNotification:                 ^NS.String

	NSAccessibilityAnnouncementKey: ^NS.String
	NSAccessibilityPriorityKey:     ^NS.String

	NSAccessibilityPostNotification :: proc "c" (element: ObjC.id, notification: ^NS.String) ---
	NSAccessibilityPostNotificationWithUserInfo :: proc "c" (element: ObjC.id, notification: ^NS.String, user_info: ObjC.id) ---
}

// ------------------------------------------------------- sending a message
//
// `intrinsics.objc_send` wants a receiver whose Odin type carries
// `@(objc_class=…)`, and this file works in bare `id`s, so a bare id is
// cast to one of these before a message is sent. They store nothing; they
// only tell the compiler which class a message is going to.

@(private, objc_class = "NSObject")
AX_Obj :: struct { using _: NS.Object }

@(private, objc_class = "NSView")
AX_View :: struct { using _: NS.Object }

@(private, objc_class = "NSWindow")
AX_Win :: struct { using _: NS.Object }

@(private, objc_class = "NSWorkspace")
AX_Workspace :: struct { using _: NS.Object }

@(private) ax_as_obj  :: proc "contextless" (x: ObjC.id) -> ^AX_Obj  { return (^AX_Obj)(x) }
@(private) ax_as_view :: proc "contextless" (x: ObjC.id) -> ^AX_View { return (^AX_View)(x) }
@(private) ax_as_win  :: proc "contextless" (x: ObjC.id) -> ^AX_Win  { return (^AX_Win)(x) }

// ax_sel is a selector by name. Not intrinsics.objc_find_selector, which
// needs a literal known at compile time and so cannot be used from a helper.
@(private)
ax_sel :: proc "contextless" (name: cstring) -> ObjC.SEL {
	return ObjC.sel_registerName(name)
}

// ax_array is an NSArray of objects, autoreleased, which is what every
// accessibility getter returning children hands back.
@(private)
ax_array :: proc(objs: []ObjC.id) -> ObjC.id {
	arr := intrinsics.objc_send(^NS.Array, NS.Array, "arrayWithObjects:count:",
		([^]^NS.Object)(raw_data(objs)), NS.UInteger(len(objs)))
	return ObjC.id(arr)
}

// NSAccessibilityPriorityLevel. Plain numbers rather than symbols, because
// that is what the enumeration is.
@(private) AX_PRIORITY_MEDIUM :: 50
@(private) AX_PRIORITY_HIGH   :: 90

@(private, thread_local)
ax: struct {
	cls:      ObjC.Class,
	ctx:      runtime.Context, // every callback arrives from AppKit with none
	elements: map[u64]ObjC.id,   // one object per id: VoiceOver tracks by identity
	hung:     map[int][dynamic]u64, // the root ids last hung on each window's view
	view_hooked: bool, // the content view's class has been given accessibilityFocusedUIElement
	started:  bool, // ax_bridge_start ran: there is an AppKit to answer to
	debug:    bool,
}

// ------------------------------------------------------------------ the seam

@(private)
ax_bridge_start :: proc() -> (ok: bool, why: string) {
	ax.ctx = context
	ax.debug = os.get_env("BALDR_A11Y_DEBUG", context.temp_allocator) == "1"
	if ax_class() == nil do return false, "could not register the accessibility element class"
	ax.elements = make(map[u64]ObjC.id)
	ax.hung = make(map[int][dynamic]u64)
	ax.started = true
	// Always attached: AppKit asks a view whenever anything wants to know,
	// with nothing to connect to. Whether anyone is listening
	// (ax_bridge_listening) decides only whether changes are reported.
	return true, ""
}

@(private)
ax_bridge_stop :: proc() {
	for _, obj in ax.elements do ax_release(obj)
	delete(ax.elements)
	for _, &ids in ax.hung do delete(ids)
	delete(ax.hung)
	ax = {}
}

// ax_bridge_listening is whether an assistive technology is reading us.
// VoiceOver says so about itself; anything else that walks the tree without
// announcing itself still gets every answer, because the tree is served off
// `attached` rather than this.
@(private)
ax_bridge_listening :: proc() -> bool {
	ws := intrinsics.objc_send(^AX_Workspace, AX_Workspace, "sharedWorkspace")
	if ws == nil do return false
	return bool(intrinsics.objc_send(NS.BOOL, ws, "isVoiceOverEnabled"))
}

@(private)
ax_bridge_debug :: proc(format: string, args: ..any) {
	if !ax.debug do return
	fmt.eprintf("baldr/a11y: ")
	fmt.eprintfln(format, ..args)
}

// ax_bridge_deliver turns one of the toolkit's decisions into the
// notification AppKit spells it with.
//
// AppKit's vocabulary is coarser than AT-SPI's, so several decisions land
// on the nearest notification VoiceOver acts on. Where nothing fits,
// nothing is posted: a reader re-reads the element when its cursor next
// reaches it, as with AppKit's own controls.
@(private)
ax_bridge_deliver :: proc(said: A11y_Said) {
	switch s in said {
	case Said_Focus:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilityFocusedUIElementChangedNotification)
		}
	case Said_Flag:
		// Only two of these have a notification of their own on macOS.
		#partial switch s.flag {
		case .Selected:
			if e := ax_element(s.id); e != nil {
				NSAccessibilityPostNotification(e, NSAccessibilitySelectedChildrenChangedNotification)
			}
		case .Checked, .Pressed, .Expanded, .Collapsed, .Indeterminate, .Busy:
			if e := ax_element(s.id); e != nil {
				NSAccessibilityPostNotification(e, NSAccessibilityValueChangedNotification)
			}
		case .Defunct:
			if e, held := ax.elements[s.id]; held {
				NSAccessibilityPostNotification(e, NSAccessibilityUIElementDestroyedNotification)
				ax_release(e)
				delete_key(&ax.elements, s.id)
			}
		}
	case Said_Window:
		// The window itself is AppKit's object, not ours, and it posts its
		// own activation. Our roots are re-hung on the next frame.
	case Said_Name:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilityTitleChangedNotification)
		}
	case Said_Describe:
		// No notification for a description on macOS: it is read when the
		// cursor arrives.
	case Said_Value:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilityValueChangedNotification)
		}
	case Said_Caret:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilitySelectedTextChangedNotification)
		}
	case Said_Text_Edit:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilityValueChangedNotification)
		}
	case Said_Text_Selection:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilitySelectedTextChangedNotification)
		}
	case Said_Active_Item:
		// The row a view's cursor moved to is what VoiceOver should be on,
		// and on macOS that is said of the row itself rather than of the
		// view holding the keyboard.
		if e := ax_element(s.child); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilityFocusedUIElementChangedNotification)
		}
	case Said_Selection:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilitySelectedChildrenChangedNotification)
		}
	case Said_Children:
		if e := ax_element(s.id); e != nil {
			NSAccessibilityPostNotification(e, NSAccessibilityLayoutChangedNotification)
		}
	case Said_Announce:
		ax_announce(s)
	}
}

// ax_announce says something out loud although nothing took focus. macOS
// carries it as a notification on the window with the text in its user info,
// and the priority is what decides whether it interrupts.
@(private)
ax_announce :: proc(s: Said_Announce) {
	window, _, ok := a11y_unpack(s.id)
	if !ok do return
	view := ax_view(window)
	if view == nil do return
	win := intrinsics.objc_send(ObjC.id, ax_as_view(view), "window")
	if win == nil do return

	text := ax_str(s.text)
	if text == nil do return
	defer ax_release(ObjC.id(text))
	prio := intrinsics.objc_send(^NS.Number, NS.Number, "numberWithInt:",
		i32(AX_PRIORITY_HIGH if s.assertive else AX_PRIORITY_MEDIUM))

	keys := [2]^NS.Object{(^NS.Object)(NSAccessibilityAnnouncementKey), (^NS.Object)(NSAccessibilityPriorityKey)}
	vals := [2]^NS.Object{(^NS.Object)(text), (^NS.Object)(prio)}
	info := intrinsics.objc_send(^NS.Dictionary, NS.Dictionary, "dictionaryWithObjects:forKeys:count:",
		raw_data(vals[:]), raw_data(keys[:]), NS.UInteger(2))
	if info == nil do return
	NSAccessibilityPostNotificationWithUserInfo(win, NSAccessibilityAnnouncementRequestedNotification, ObjC.id(info))
}

// ------------------------------------------------- hanging the tree on a view
//
// Called once a frame from the run loop's accessibility pass. It is cheap
// when nothing changed, which is the ordinary case: the root ids are compared
// and the NSArray is only rebuilt when the set differs.

// ax_bridge_attach gives each window's view the toolkit's root elements. The
// window and the application are AppKit's own objects and are left alone, so
// what a reader walks is: application → window → our roots → the tree.
@(private)
ax_bridge_attach :: proc() {
	for _, wi in a11y.windows {
		view := ax_view(wi)
		if view == nil do continue
		win_id, named := a11y_id(wi, NODE_NONE)
		if !named do continue

		roots := make([dynamic]u64, context.temp_allocator)
		obj, have := a11y_obj(win_id)
		if have {
			for i in 0 ..< obj.child_count {
				if kid, ok := a11y_obj_child(win_id, i); ok do append(&roots, kid)
			}
		}
		was := ax.hung[wi]
		if a11y_same_kids(roots[:], was[:]) do continue

		objs := make([dynamic]ObjC.id, 0, len(roots), context.temp_allocator)
		for id in roots do if e := ax_element(id); e != nil do append(&objs, e)
		v := ax_as_view(view)
		ax_hook_view(v)
		intrinsics.objc_send(nil, v, "setAccessibilityRole:", NSAccessibilityGroupRole)
		intrinsics.objc_send(nil, v, "setAccessibilityElement:", NS.BOOL(true))
		intrinsics.objc_send(nil, v, "setAccessibilityChildren:", ax_array(objs[:]))

		kept, held := &ax.hung[wi]
		if !held {
			ax.hung[wi] = make([dynamic]u64)
			kept = &ax.hung[wi]
		}
		clear(kept)
		append(kept, ..roots[:])
		ax_bridge_debug("hung %d root elements on window %d", len(objs), wi)
	}
}

// ax_view is the NSView of one of the model's windows, which the run loop
// put there for exactly this.
@(private)
ax_view :: proc(window: int) -> ObjC.id {
	if window < 0 || window >= len(a11y.windows) do return nil
	return ObjC.id(a11y.windows[window].native)
}

// ---------------------------------------------------------------- the element

// ax_element is the object AppKit holds for one id, made the first time it
// is asked for and kept until the id stops resolving.
@(private)
ax_element :: proc(id: u64) -> ObjC.id {
	if id == 0 do return nil
	// Nothing without a bridge: a headless test reaches the say path with no
	// AppKit, and inserting would allocate `ax.elements` with no
	// `ax_bridge_stop` to free it.
	if !ax.started do return nil
	if e, held := ax.elements[id]; held do return e
	cls := ax_class()
	if cls == nil do return nil
	obj := ObjC.class_createInstance(cls, size_of(u64))
	if obj == nil do return nil
	if slot := (^u64)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = id
	ax.elements[id] = obj
	return obj
}

@(private)
ax_id_of :: proc "contextless" (self: ObjC.id) -> u64 {
	slot := (^u64)(ObjC.object_getIndexedIvars(self))
	return slot^ if slot != nil else 0
}

@(private)
ax_release :: proc(obj: ObjC.id) {
	if obj != nil do intrinsics.objc_send(nil, ax_as_obj(obj), "release")
}

// ax_str is an NSString the caller releases. Not NS.AT, which is CFSTR and
// mangles anything above \177 — the same trap `platform/cocoa` documents.
@(private)
ax_str :: proc(s: string) -> ^NS.String {
	return NS.String.alloc()->initWithOdinString(s)
}

// ax_autorelease_str is an NSString handed straight back to AppKit, which
// expects not to own it.
@(private)
ax_autorelease_str :: proc(s: string) -> ^NS.String {
	str := ax_str(s)
	if str == nil do return nil
	intrinsics.objc_send(nil, ax_as_obj(ObjC.id(str)), "autorelease")
	return str
}

// ax_obj_of is the model's answer about the element a callback arrived on.
@(private)
ax_obj_of :: proc(self: ObjC.id) -> (A11y_Obj, bool) {
	return a11y_obj(ax_id_of(self))
}

// --------------------------------------------------------------- the callbacks
//
// Every one of these arrives from AppKit with no Odin context, inside its own
// event loop, so each sets the context the bridge was started with before
// touching the toolkit. They read the live tree: an element stores nothing
// but its id, so an answer is never stale.

@(private)
axm_is_element :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	context = ax.ctx
	_, have := ax_obj_of(self)
	return NS.BOOL(have)
}

@(private)
axm_role :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ^NS.String {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have do return NSAccessibilityUnknownRole
	return ax_role(obj.role)
}

@(private)
axm_subrole :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ^NS.String {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if have && obj.role == .Password do return NSAccessibilitySecureTextFieldSubrole
	return nil
}

@(private)
axm_label :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ^NS.String {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have do return nil
	// Three ways a name can be carried, and macOS wants the right one:
	//
	//   value  text that is read (AXStaticText): VoiceOver speaks the value
	//          and ignores the label.
	//   title  a control whose name is written on it ("Save"). VoiceOver
	//          asks for it first; one answering only the label reads as
	//          "(null)".
	//   label  a control named by something other than its own text.
	//
	// Setting more than one would have a control read its name twice.
	if ax_names_itself(obj.role) do return nil
	#partial switch obj.role {
	case .Static, .Label, .Heading: return nil
	}
	return ax_autorelease_str(obj.name)
}

// axm_title is the name of a control that has its name written on it. See
// axm_label for why the two are not the same thing.
@(private)
axm_title :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ^NS.String {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have || !ax_names_itself(obj.role) do return nil
	return ax_autorelease_str(obj.name)
}

// ax_names_itself: the control's name is the text drawn on it, so macOS
// wants it as the title rather than as a label.
@(private)
ax_names_itself :: proc(r: A11y_Role) -> bool {
	#partial switch r {
	case .Button, .Toggle_Button, .Check_Box, .Radio_Button, .Link,
	     .Menu_Item, .Check_Menu_Item, .Radio_Menu_Item, .Tab, .List_Item, .Tree_Item, .Row, .Cell, .Column_Header:
		return true
	}
	return false
}

@(private)
axm_help :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ^NS.String {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have || len(obj.describe) == 0 do return nil
	return ax_autorelease_str(obj.describe)
}

@(private)
axm_value :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have do return nil
	#partial switch obj.role {
	case .Static, .Label, .Heading:
		return ObjC.id(ax_autorelease_str(obj.name))
	case .Check_Box, .Radio_Button, .Toggle_Button:
		v := i32(0)
		if .Indeterminate in obj.flags { v = 2 } else if .Checked in obj.flags || .Pressed in obj.flags { v = 1 }
		return ax_number_i32(v)
	case .Tab:
		// A tab is an AXRadioButton (`ax_role`, as AppKit's own tabs are),
		// and a reader learns which one is current from its value.
		return ax_number_i32(1 if .Selected in obj.flags else 0)
	}
	if obj.has_text do return ObjC.id(ax_autorelease_str(obj.value_text))
	if obj.has_value {
		// A formatted value is what a reader should say where the widget has
		// one ("3:25" rather than "205"), and the number otherwise.
		if len(obj.value_text) > 0 do return ObjC.id(ax_autorelease_str(obj.value_text))
		return ax_number_f64(obj.value)
	}
	return nil
}

@(private)
axm_min_value :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have || !obj.has_value do return nil
	return ax_number_f64(obj.value_min)
}

@(private)
axm_max_value :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have || !obj.has_value do return nil
	return ax_number_f64(obj.value_max)
}

// axm_selected is `AXSelected`: the model's `.Selected`, as AT-SPI's
// `Selected` state and UIA's `ISelectionItemProvider::get_IsSelected` carry
// it on the other platforms.
@(private)
axm_selected :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	return NS.BOOL(have && .Selected in obj.flags)
}

@(private)
axm_required :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	return NS.BOOL(have && .Required in obj.flags)
}

@(private)
axm_enabled :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	return NS.BOOL(have && .Enabled in obj.flags)
}

@(private)
axm_focused :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	return NS.BOOL(have && .Focused in obj.flags)
}

@(private)
axm_set_focused :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, focused: NS.BOOL) {
	context = ax.ctx
	if bool(focused) do a11y_grab_focus(ax_id_of(self))
}

@(private)
axm_children :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	id := ax_id_of(self)
	obj, have := a11y_obj(id)
	if !have || obj.child_count == 0 do return nil
	objs := make([dynamic]ObjC.id, 0, obj.child_count, context.temp_allocator)
	for i in 0 ..< obj.child_count {
		kid, ok := a11y_obj_child(id, i)
		if !ok do continue
		if e := ax_element(kid); e != nil do append(&objs, e)
	}
	return ax_array(objs[:])
}

@(private)
axm_selected_children :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	id := ax_id_of(self)
	obj, have := a11y_obj(id)
	if !have || !obj.has_selection do return nil
	objs := make([dynamic]ObjC.id, 0, obj.child_count, context.temp_allocator)
	for i in 0 ..< obj.child_count {
		kid, ok := a11y_obj_child(id, i)
		if !ok do continue
		kid_obj, kid_have := a11y_obj(kid)
		if !kid_have || .Selected not_in kid_obj.flags do continue
		if e := ax_element(kid); e != nil do append(&objs, e)
	}
	return ax_array(objs[:])
}

@(private)
axm_parent :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	id := ax_id_of(self)
	obj, have := a11y_obj(id)
	if !have do return nil
	window, _, ok := a11y_unpack(id)
	if !ok do return nil
	// The window's own object is AppKit's, not ours, so a root element's
	// parent is the view the roots were hung on.
	win_id, named := a11y_id(window, NODE_NONE)
	if named && obj.parent == win_id do return ax_view(window)
	return ax_element(obj.parent)
}

@(private)
axm_window :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	window, _, ok := a11y_unpack(ax_id_of(self))
	if !ok do return nil
	view := ax_view(window)
	return intrinsics.objc_send(ObjC.id, ax_as_view(view), "window") if view != nil else nil
}

@(private)
axm_frame :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.Rect {
	context = ax.ctx
	id := ax_id_of(self)
	obj, have := a11y_obj(id)
	if !have do return {}
	window, _, ok := a11y_unpack(id)
	if !ok do return {}
	view := ax_view(window)
	if view == nil do return {}
	win := intrinsics.objc_send(ObjC.id, ax_as_view(view), "window")
	if win == nil do return {}
	// The node's rect is logical pixels in the window, top-left origin,
	// which is the view's own coordinate system — the backend's view is
	// `isFlipped`. AppKit does the flip to the screen's bottom-left origin
	// as part of these two conversions, so neither is done by hand.
	local := NS.Rect{
		{NS.Float(obj.extents[0]), NS.Float(obj.extents[1])},
		{NS.Float(obj.extents[2]), NS.Float(obj.extents[3])},
	}
	in_window := intrinsics.objc_send(NS.Rect, ax_as_view(view), "convertRect:toView:", local, ObjC.id(nil))
	return intrinsics.objc_send(NS.Rect, ax_as_win(win), "convertRectToScreen:", in_window)
}

@(private)
axm_identifier :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ^NS.String {
	context = ax.ctx
	// A stable name for one object, which is what a UI test or an automation
	// script addresses it by.
	return ax_autorelease_str(fmt.tprintf("baldr-%d", ax_id_of(self)))
}

@(private)
axm_perform_press :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.BOOL {
	context = ax.ctx
	return NS.BOOL(a11y_do_action(ax_id_of(self)))
}

// --- text

@(private)
axm_char_count :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.Integer {
	context = ax.ctx
	info, have := a11y_obj_text(ax_id_of(self))
	if !have do return 0
	return NS.Integer(a11y_char_off(info.text, len(info.text)))
}

@(private)
axm_selected_text :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ^NS.String {
	context = ax.ctx
	info, have := a11y_obj_text(ax_id_of(self))
	if !have do return nil
	lo, hi := clamp(info.sel_lo, 0, len(info.text)), clamp(info.sel_hi, 0, len(info.text))
	if lo >= hi do return ax_autorelease_str("")
	return ax_autorelease_str(info.text[lo:hi])
}

@(private)
axm_selected_range :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.Range {
	context = ax.ctx
	info, have := a11y_obj_text(ax_id_of(self))
	if !have do return {0, 0}
	lo := a11y_char_off(info.text, clamp(info.sel_lo, 0, len(info.text)))
	hi := a11y_char_off(info.text, clamp(info.sel_hi, 0, len(info.text)))
	return {NS.UInteger(lo), NS.UInteger(max(hi - lo, 0))}
}

@(private)
axm_set_selected_range :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, r: NS.Range) {
	context = ax.ctx
	id := ax_id_of(self)
	info, have := a11y_obj_text(id)
	if !have do return
	// AppKit counts characters; the widgets keep bytes.
	from := a11y_byte_off(info.text, int(r.location))
	to := a11y_byte_off(info.text, int(r.location + r.length))
	a11y_select_range(id, from, to)
}

@(private)
axm_string_for_range :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, r: NS.Range) -> ^NS.String {
	context = ax.ctx
	info, have := a11y_obj_text(ax_id_of(self))
	if !have do return nil
	from := a11y_byte_off(info.text, int(r.location))
	to := a11y_byte_off(info.text, int(r.location + r.length))
	from, to = clamp(from, 0, len(info.text)), clamp(to, 0, len(info.text))
	if from >= to do return ax_autorelease_str("")
	return ax_autorelease_str(info.text[from:to])
}

@(private)
axm_visible_range :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.Range {
	context = ax.ctx
	info, have := a11y_obj_text(ax_id_of(self))
	if !have do return {0, 0}
	return {0, NS.UInteger(a11y_char_off(info.text, len(info.text)))}
}

@(private)
axm_insertion_line :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> NS.Integer {
	context = ax.ctx
	info, have := a11y_obj_text(ax_id_of(self))
	if !have || info.caret < 0 do return 0
	line := 0
	for i in 0 ..< clamp(info.caret, 0, len(info.text)) do if info.text[i] == '\n' do line += 1
	return NS.Integer(line)
}

// ------------------------------------------------------------- the class

@(private)
ax_class :: proc() -> ObjC.Class {
	if ax.cls != nil do return ax.cls
	super := intrinsics.objc_find_class("NSObject")
	if super == nil do return nil
	// extraBytes carries the one thing an element holds: the model's id.
	cls := ObjC.objc_allocateClassPair(super, "BaldrA11yElement", size_of(u64))
	if cls == nil do return nil

	add :: proc(cls: ObjC.Class, sel: cstring, imp: rawptr, types: cstring) {
		ObjC.class_addMethod(cls, ax_sel(sel), auto_cast imp, types)
	}

	// The encodings: `@` an object, `:` a selector, `B` a BOOL, `q` a signed
	// 64-bit integer, `d` a double; a struct is spelled out. A wrong one is a
	// method AppKit calls with the wrong frame, so each is written against
	// the signature above.
	RECT  :: "{CGRect={CGPoint=dd}{CGSize=dd}}"
	RANGE :: "{_NSRange=QQ}"

	add(cls, "isAccessibilityElement",   auto_cast axm_is_element,   "B@:")
	add(cls, "accessibilityRole",        auto_cast axm_role,         "@@:")
	add(cls, "accessibilitySubrole",     auto_cast axm_subrole,      "@@:")
	add(cls, "accessibilityLabel",       auto_cast axm_label,        "@@:")
	add(cls, "accessibilityTitle",       auto_cast axm_title,        "@@:")
	add(cls, "accessibilityHelp",        auto_cast axm_help,         "@@:")
	add(cls, "accessibilityValue",       auto_cast axm_value,        "@@:")
	add(cls, "accessibilityMinValue",    auto_cast axm_min_value,    "@@:")
	add(cls, "accessibilityMaxValue",    auto_cast axm_max_value,    "@@:")
	add(cls, "isAccessibilityEnabled",   auto_cast axm_enabled,      "B@:")
	add(cls, "isAccessibilityRequired",  auto_cast axm_required,     "B@:")
	add(cls, "isAccessibilitySelected",  auto_cast axm_selected,     "B@:")
	add(cls, "isAccessibilityFocused",   auto_cast axm_focused,      "B@:")
	add(cls, "setAccessibilityFocused:", auto_cast axm_set_focused,  "v@:B")
	add(cls, "accessibilityChildren",    auto_cast axm_children,     "@@:")
	add(cls, "accessibilitySelectedChildren", auto_cast axm_selected_children, "@@:")
	add(cls, "accessibilityParent",      auto_cast axm_parent,       "@@:")
	add(cls, "accessibilityWindow",      auto_cast axm_window,       "@@:")
	add(cls, "accessibilityTopLevelUIElement", auto_cast axm_window, "@@:")
	add(cls, "accessibilityFrame",       auto_cast axm_frame,        RECT + "@:")
	add(cls, "accessibilityIdentifier",  auto_cast axm_identifier,   "@@:")
	add(cls, "accessibilityPerformPress", auto_cast axm_perform_press, "B@:")

	add(cls, "accessibilityNumberOfCharacters",  auto_cast axm_char_count,     "q@:")
	add(cls, "accessibilitySelectedText",        auto_cast axm_selected_text,  "@@:")
	add(cls, "accessibilitySelectedTextRange",   auto_cast axm_selected_range, RANGE + "@:")
	add(cls, "setAccessibilitySelectedTextRange:", auto_cast axm_set_selected_range, "v@:" + RANGE)
	add(cls, "accessibilityStringForRange:",     auto_cast axm_string_for_range, "@@:" + RANGE)
	add(cls, "accessibilityVisibleCharacterRange", auto_cast axm_visible_range, RANGE + "@:")
	add(cls, "accessibilityInsertionPointLineNumber", auto_cast axm_insertion_line, "q@:")

	// Last, because it is the answer to "which of the above do you have?".
	add(cls, "isAccessibilitySelectorAllowed:", auto_cast axm_selector_allowed, "B@::")

	ObjC.objc_registerClassPair(cls)
	ax.cls = cls
	return cls
}


// axm_selector_allowed is AppKit asking which of the class's methods this
// element actually has. Without it every element advertises every
// selector, so a radio button offers the text attributes of a text area
// and a reader navigates it by line instead of stepping to the next option.
// Each answer comes from what the object is (`has_text`, `has_value`,
// `has_action`, `has_selection`, `editable`, Focusable), not from a role
// list kept in step by hand.
@(private)
axm_selector_allowed :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sel: ObjC.SEL) -> NS.BOOL {
	context = ax.ctx
	obj, have := ax_obj_of(self)
	if !have do return NS.BOOL(false)
	switch string(ObjC.sel_getName(sel)) {
	// Text, and only for something that holds text: an entry, an editor.
	case "accessibilityNumberOfCharacters", "accessibilitySelectedText",
	     "accessibilitySelectedTextRange", "accessibilityStringForRange:",
	     "accessibilityVisibleCharacterRange", "accessibilityInsertionPointLineNumber":
		return NS.BOOL(obj.has_text)
	// …and typing into it needs it to be editable as well: a read-only
	// editor holds text and must not offer to be written to.
	case "setAccessibilitySelectedTextRange:":
		return NS.BOOL(obj.has_text && obj.editable)
	// A quantity a reader reads as one: a slider, a progress bar.
	case "accessibilityMinValue", "accessibilityMaxValue":
		return NS.BOOL(obj.has_value)
	// What is picked inside a list, a tree, a table.
	case "accessibilitySelectedChildren":
		return NS.BOOL(obj.has_selection)
	// Something pressing does something to.
	case "accessibilityPerformPress":
		return NS.BOOL(obj.has_action)
	// Only where the keyboard can go: otherwise a reader lists the action
	// and nothing happens.
	case "setAccessibilityFocused:":
		return NS.BOOL(.Focusable in obj.flags)
	}
	// Role, name, frame, parent, children, enabled: every element has them.
	return NS.BOOL(true)
}

// ------------------------------------------------------------ AppKit's words

@(private)
ax_number_i32 :: proc(v: i32) -> ObjC.id {
	return ObjC.id(intrinsics.objc_send(^NS.Number, NS.Number, "numberWithInt:", v))
}

@(private)
ax_number_f64 :: proc(v: f64) -> ObjC.id {
	return ObjC.id(intrinsics.objc_send(^NS.Number, NS.Number, "numberWithDouble:", v))
}

// ax_role is a role in AppKit's vocabulary. Where macOS has no word, the
// nearest true one is used (better than "unknown") and the comment says
// what was lost.
@(private)
ax_role :: proc(r: A11y_Role) -> ^NS.String {
	switch r {
	case .None:          return NSAccessibilityUnknownRole
	case .Application:   return NSAccessibilityApplicationRole
	case .Window:        return NSAccessibilityWindowRole
	case .Panel:         return NSAccessibilityGroupRole
	case .Group:         return NSAccessibilityGroupRole
	case .Static:        return NSAccessibilityStaticTextRole
	case .Heading:       return NSAccessibilityStaticTextRole // AppKit has no heading: AXHeading is web content's
	case .Label:         return NSAccessibilityStaticTextRole
	case .Image:         return NSAccessibilityImageRole
	case .Button:        return NSAccessibilityButtonRole
	case .Toggle_Button: return NSAccessibilityCheckBoxRole   // a checkbox reads its on/off; a button would not
	case .Link:          return NSAccessibilityLinkRole
	case .Check_Box:     return NSAccessibilityCheckBoxRole
	case .Radio_Button:  return NSAccessibilityRadioButtonRole
	// VoiceOver steps through an AXRadioGroup's members with the arrows; a
	// plain AXGroup's options are unrelated children it will not step between.
	case .Radio_Group:   return NSAccessibilityRadioGroupRole
	case .Slider:        return NSAccessibilitySliderRole
	case .Spin_Button:   return NSAccessibilityIncrementorRole
	case .Entry:         return NSAccessibilityTextFieldRole
	case .Password:      return NSAccessibilityTextFieldRole  // with the secure subrole, which is what hides it
	case .Document:      return NSAccessibilityTextAreaRole
	case .Combo_Box:     return NSAccessibilityComboBoxRole
	case .List:          return NSAccessibilityListRole
	case .List_Item:     return NSAccessibilityRowRole
	case .Table:         return NSAccessibilityTableRole
	case .Row:           return NSAccessibilityRowRole
	case .Cell:          return NSAccessibilityCellRole
	case .Column_Header: return NSAccessibilityCellRole       // AppKit has no header cell of its own
	case .Tree:          return NSAccessibilityOutlineRole
	case .Tree_Item:     return NSAccessibilityRowRole
	case .Tab_List:      return NSAccessibilityTabGroupRole
	case .Tab:           return NSAccessibilityRadioButtonRole // which is what AppKit's own tabs are
	case .Menu_Bar:      return NSAccessibilityMenuBarRole
	case .Menu:          return NSAccessibilityMenuRole
	case .Menu_Item, .Check_Menu_Item, .Radio_Menu_Item: return NSAccessibilityMenuItemRole
	case .Dialog:        return NSAccessibilitySheetRole
	case .Alert:         return NSAccessibilityGroupRole
	case .Status_Bar:    return NSAccessibilityGroupRole
	case .Progress_Bar:  return NSAccessibilityProgressIndicatorRole
	case .Tooltip:       return NSAccessibilityGroupRole      // a macOS help tag is not an element
	case .Separator:     return NSAccessibilitySplitterRole
	case .Scroll_Area:   return NSAccessibilityScrollAreaRole
	case .Tool_Bar:      return NSAccessibilityToolbarRole
	case .Terminal:      return NSAccessibilityTextAreaRole
	}
	return NSAccessibilityGroupRole
}

// ------------------------------------------------- following the keyboard
//
// A reader follows the keyboard by asking, not by being told: VoiceOver
// treats `AXFocusedUIElementChanged` as a hint and then asks what is
// focused, and AppKit answers with the view itself, never one of our
// elements. `accessibilityFocusedUIElement` has no setter, so the method is
// added to our own `BaldrView` class, never to one we did not make, which is
// why the name is checked first.

@(private)
ax_hook_view :: proc(v: ^AX_View) {
	if ax.view_hooked do return
	name := string(ObjC.object_getClassName(ObjC.id(v)))
	if name != "BaldrView" {
		// Someone changed what platform/cocoa makes. Say so rather than
		// patching a class that is not ours.
		ax_bridge_debug("the content view is a %s, not BaldrView: the keyboard will not be followed", name)
		ax.view_hooked = true // once, not every frame
		return
	}
	cls := ObjC.object_getClass(ObjC.id(v))
	if cls == nil do return
	ax.view_hooked = true
	ObjC.class_addMethod(cls, ax_sel("accessibilityFocusedUIElement"), auto_cast axm_view_focused, "@@:")
	ax_bridge_debug("the content view will answer what has the keyboard")
}

// axm_view_focused: what has the keyboard now, as a reader should see it.
//
// The active descendant comes first where there is one: a table, tree,
// icon view or radio group keeps the focus and moves a cursor inside, so
// the row under that cursor is where a reader should stand.
@(private)
axm_view_focused :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) -> ObjC.id {
	context = ax.ctx
	id := a11y.watch.active if a11y.watch.active != 0 else a11y.watch.id
	if id == 0 do return nil
	return ax_element(id)
}
