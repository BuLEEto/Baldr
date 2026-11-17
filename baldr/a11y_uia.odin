#+build windows
package baldr

// Answering UI Automation, so a screen reader can read a Baldr app on Windows.
//
// This is the Windows half of the seam `a11y_model.odin` describes: the model
// decides what every object is, what it is called and what just changed, and
// this file says it in UIA's words. Nothing here decides anything about a
// widget.
//
// A client's first question arrives as a `WM_GETOBJECT` on the window, and
// the answer is a COM object implementing `IRawElementProviderSimple`: the
// root of a fragment, a tree of providers the application owns. There is one
// provider object per node, holding only the model's 64-bit id and answering
// from the live tree. It is kept for as long as the id resolves, because a
// client holds provider pointers and compares runtime ids.
//
// `core:sys/windows` has no UI Automation, VARIANT, SAFEARRAY or
// `SysAllocString`, so the interfaces, their vtables and the OLE automation
// types are declared here, following `platform/win32/drop.odin`: the object
// starts with its vtable pointers, because that is all a client ever sees.
//
// The window is subclassed rather than the backend changed: only
// `WM_GETOBJECT` is intercepted, so `platform/win32` knows nothing of
// accessibility, the same division the macOS bridge keeps.
//
// Threading: UIA calls a provider from a thread of its own unless told to
// marshal, and the tree may only be read on the thread that builds it. So
// `get_ProviderOptions` asks for `UseComThreading`, which sends every call
// through this thread's apartment, and the bridge initialises that apartment
// itself rather than relying on drag and drop to have done it. A wrong answer
// here is unsafe, not merely wrong.

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import win "core:sys/windows"

// ------------------------------------------------------- the types OLE needs

// VARIANT, as UIA passes property values back. 24 bytes on x64: the four
// words of header, then a union padded to sixteen.
@(private)
VARIANT :: struct {
	vt:        u16,
	reserved1: u16,
	reserved2: u16,
	reserved3: u16,
	val:       struct #raw_union {
		lVal:    i32,
		boolVal: i16,
		dblVal:  f64,
		bstrVal: win.BSTR,
		parray:  rawptr,
		_pad:    [2]u64,
	},
}

@(private) VT_EMPTY :: u16(0)
@(private) VT_I4    :: u16(3)
@(private) VT_R8    :: u16(5)
@(private) VT_BSTR  :: u16(8)
@(private) VT_BOOL  :: u16(11)

@(private) VARIANT_TRUE  :: i16(-1)
@(private) VARIANT_FALSE :: i16(0)

// UiaRect is UIA's rectangle: a position and a size, in screen coordinates,
// in device-independent pixels.
@(private)
UiaRect :: struct { left, top, width, height: f64 }

foreign import oleaut32 "system:oleaut32.lib"

@(default_calling_convention = "system")
foreign oleaut32 {
	SysAllocStringLen    :: proc(s: [^]u16, len: win.UINT) -> win.BSTR ---
	SysFreeString        :: proc(s: win.BSTR) ---
	SafeArrayCreateVector :: proc(vt: u16, lbound: win.LONG, count: win.ULONG) -> rawptr ---
	SafeArrayPutElement  :: proc(arr: rawptr, indices: ^win.LONG, v: rawptr) -> win.HRESULT ---
	SafeArrayDestroy     :: proc(arr: rawptr) -> win.HRESULT ---
}

// ------------------------------------------------------- UI Automation's own
//
// uiautomationcore.dll is loaded rather than linked: it is an OS library, the
// toolkit loads every one of those at runtime, and a Windows install without
// it simply has no accessibility bridge instead of an app that will not
// start.

@(private)
Uia_Lib :: struct {
	UiaReturnRawElementProvider: proc "system" (hwnd: win.HWND, wparam: win.WPARAM, lparam: win.LPARAM, el: rawptr) -> win.LRESULT,
	UiaHostProviderFromHwnd:     proc "system" (hwnd: win.HWND, out: ^rawptr) -> win.HRESULT,
	UiaRaiseAutomationEvent:     proc "system" (provider: rawptr, id: i32) -> win.HRESULT,
	UiaRaiseAutomationPropertyChangedEvent: proc "system" (provider: rawptr, id: i32, old: VARIANT, new: VARIANT) -> win.HRESULT,
	UiaRaiseStructureChangedEvent: proc "system" (provider: rawptr, kind: i32, runtime_id: [^]i32, len: i32) -> win.HRESULT,
	UiaRaiseNotificationEx:      proc "system" (provider: rawptr, kind: i32, processing: i32, display: win.BSTR, activity: win.BSTR) -> win.HRESULT,
	UiaClientsAreListening:      proc "system" () -> win.BOOL,
	UiaDisconnectProvider:       proc "system" (provider: rawptr) -> win.HRESULT,
	_handle:                     dynlib.Library,
}

// Property ids (UIA_*PropertyId). Written out because they are the wire
// format, exactly as the AT-SPI numbers are.
@(private) UIA_PROP_RUNTIME_ID             :: i32(30000)
@(private) UIA_PROP_BOUNDING_RECTANGLE     :: i32(30001)
@(private) UIA_PROP_CONTROL_TYPE           :: i32(30003)
@(private) UIA_PROP_NAME                   :: i32(30005)
@(private) UIA_PROP_HAS_KEYBOARD_FOCUS     :: i32(30008)
@(private) UIA_PROP_IS_KEYBOARD_FOCUSABLE  :: i32(30009)
@(private) UIA_PROP_IS_ENABLED             :: i32(30010)
@(private) UIA_PROP_IS_REQUIRED_FOR_FORM   :: i32(30025)
@(private) UIA_PROP_IS_DATA_VALID_FOR_FORM :: i32(30103)
@(private) UIA_PROP_AUTOMATION_ID          :: i32(30011)
@(private) UIA_PROP_HELP_TEXT              :: i32(30013)
@(private) UIA_PROP_IS_CONTROL_ELEMENT     :: i32(30016)
@(private) UIA_PROP_IS_CONTENT_ELEMENT     :: i32(30017)
@(private) UIA_PROP_IS_PASSWORD            :: i32(30019)
@(private) UIA_PROP_IS_OFFSCREEN           :: i32(30022)
@(private) UIA_PROP_VALUE_VALUE            :: i32(30045)

// Control types (UIA_*ControlTypeId).
@(private) UIA_CT_BUTTON       :: i32(50000)
@(private) UIA_CT_CHECK_BOX    :: i32(50002)
@(private) UIA_CT_COMBO_BOX    :: i32(50003)
@(private) UIA_CT_EDIT         :: i32(50004)
@(private) UIA_CT_HYPERLINK    :: i32(50005)
@(private) UIA_CT_IMAGE        :: i32(50006)
@(private) UIA_CT_LIST_ITEM    :: i32(50007)
@(private) UIA_CT_LIST         :: i32(50008)
@(private) UIA_CT_MENU         :: i32(50009)
@(private) UIA_CT_MENU_BAR     :: i32(50010)
@(private) UIA_CT_MENU_ITEM    :: i32(50011)
@(private) UIA_CT_PROGRESS_BAR :: i32(50012)
@(private) UIA_CT_RADIO_BUTTON :: i32(50013)
@(private) UIA_CT_SLIDER       :: i32(50015)
@(private) UIA_CT_SPINNER      :: i32(50016)
@(private) UIA_CT_STATUS_BAR   :: i32(50017)
@(private) UIA_CT_TAB          :: i32(50018)
@(private) UIA_CT_TAB_ITEM     :: i32(50019)
@(private) UIA_CT_TEXT         :: i32(50020)
@(private) UIA_CT_TOOL_BAR     :: i32(50021)
@(private) UIA_CT_TOOL_TIP     :: i32(50022)
@(private) UIA_CT_TREE         :: i32(50023)
@(private) UIA_CT_TREE_ITEM    :: i32(50024)
@(private) UIA_CT_GROUP        :: i32(50026)
@(private) UIA_CT_DATA_ITEM    :: i32(50029)
@(private) UIA_CT_DOCUMENT     :: i32(50030)
@(private) UIA_CT_WINDOW       :: i32(50032)
@(private) UIA_CT_PANE         :: i32(50033)
@(private) UIA_CT_HEADER_ITEM  :: i32(50035)
@(private) UIA_CT_TABLE        :: i32(50036)
@(private) UIA_CT_SEPARATOR    :: i32(50038)

// Pattern ids, and the events.
@(private) UIA_PATTERN_INVOKE         :: i32(10000)
@(private) UIA_PATTERN_VALUE          :: i32(10002)
@(private) UIA_PATTERN_RANGE_VALUE    :: i32(10003)
@(private) UIA_PATTERN_SELECTION_ITEM :: i32(10010)
@(private) UIA_PATTERN_TOGGLE         :: i32(10015)

@(private) UIA_EVENT_FOCUS_CHANGED    :: i32(20005)
@(private) UIA_EVENT_INVOKED          :: i32(20009)
@(private) UIA_EVENT_NOTIFICATION     :: i32(20023)

// StructureChangeType
@(private) UIA_STRUCTURE_CHILD_ADDED           :: i32(0)
@(private) UIA_STRUCTURE_CHILD_REMOVED         :: i32(1)
@(private) UIA_STRUCTURE_CHILDREN_INVALIDATED  :: i32(2)

// NotificationKind / NotificationProcessing, for an announcement.
@(private) UIA_NOTIFY_KIND_OTHER            :: i32(4)
@(private) UIA_NOTIFY_PROCESS_IMPORTANT_ALL :: i32(0) // interrupts
@(private) UIA_NOTIFY_PROCESS_ALL           :: i32(2) // waits its turn

// ProviderOptions
@(private) PROVIDER_SERVER_SIDE      :: i32(1)
@(private) PROVIDER_USE_COM_THREADING :: i32(0x20)

// NavigateDirection
@(private) NAV_PARENT      :: i32(0)
@(private) NAV_NEXT        :: i32(1)
@(private) NAV_PREVIOUS    :: i32(2)
@(private) NAV_FIRST_CHILD :: i32(3)
@(private) NAV_LAST_CHILD  :: i32(4)

// HRESULT is signed, and the E_* constants in core:sys/windows are untyped
// 32-bit values above its maximum, so each is written here as the negative it
// transmutes to (platform/win32/drop.odin does the same cast inline).
@(private) HR_INVALIDARG  :: win.HRESULT(-2147024809) // 0x80070057 E_INVALIDARG
@(private) HR_NOINTERFACE :: win.HRESULT(-2147467262) // 0x80004002 E_NOINTERFACE
@(private) HR_FAIL        :: win.HRESULT(-2147467259) // 0x80004005 E_FAIL
@(private) HR_OUTOFMEMORY :: win.HRESULT(-2147024882) // 0x8007000E E_OUTOFMEMORY

@(private) WM_GETOBJECT      :: win.UINT(0x003D)
@(private) UIA_ROOT_OBJECT_ID :: win.LPARAM(-25)

// UiaAppendRuntimeId is the marker a fragment's runtime id begins with, so a
// client can tell our ids apart from another provider's.
@(private) UIA_APPEND_RUNTIME_ID :: i32(3)

// ------------------------------------------------------------- the interfaces

@(private)
IRawElementProviderSimple :: struct { using vtbl: ^IRawElementProviderSimple_Vtbl }

@(private)
IRawElementProviderSimple_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	get_ProviderOptions:         proc "system" (this: rawptr, out: ^i32) -> win.HRESULT,
	GetPatternProvider:          proc "system" (this: rawptr, pattern: i32, out: ^rawptr) -> win.HRESULT,
	GetPropertyValue:            proc "system" (this: rawptr, prop: i32, out: ^VARIANT) -> win.HRESULT,
	get_HostRawElementProvider:  proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT,
}

@(private)
IRawElementProviderFragment_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	Navigate:                  proc "system" (this: rawptr, dir: i32, out: ^rawptr) -> win.HRESULT,
	GetRuntimeId:              proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT,
	get_BoundingRectangle:     proc "system" (this: rawptr, out: ^UiaRect) -> win.HRESULT,
	GetEmbeddedFragmentRoots:  proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT,
	SetFocus:                  proc "system" (this: rawptr) -> win.HRESULT,
	get_FragmentRoot:          proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT,
}

@(private)
IRawElementProviderFragmentRoot_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	ElementProviderFromPoint: proc "system" (this: rawptr, x, y: f64, out: ^rawptr) -> win.HRESULT,
	GetFocus:                 proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT,
}

@(private)
IToggleProvider_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	Toggle:            proc "system" (this: rawptr) -> win.HRESULT,
	get_ToggleState:   proc "system" (this: rawptr, out: ^i32) -> win.HRESULT,
}

@(private)
IValueProvider_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	SetValue:        proc "system" (this: rawptr, v: win.BSTR) -> win.HRESULT,
	get_Value:       proc "system" (this: rawptr, out: ^win.BSTR) -> win.HRESULT,
	get_IsReadOnly:  proc "system" (this: rawptr, out: ^win.BOOL) -> win.HRESULT,
}

@(private)
IRangeValueProvider_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	SetValue:        proc "system" (this: rawptr, v: f64) -> win.HRESULT,
	get_Value:       proc "system" (this: rawptr, out: ^f64) -> win.HRESULT,
	get_IsReadOnly:  proc "system" (this: rawptr, out: ^win.BOOL) -> win.HRESULT,
	get_Maximum:     proc "system" (this: rawptr, out: ^f64) -> win.HRESULT,
	get_Minimum:     proc "system" (this: rawptr, out: ^f64) -> win.HRESULT,
	get_LargeChange: proc "system" (this: rawptr, out: ^f64) -> win.HRESULT,
	get_SmallChange: proc "system" (this: rawptr, out: ^f64) -> win.HRESULT,
}

@(private)
ISelectionItemProvider_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	Select:                 proc "system" (this: rawptr) -> win.HRESULT,
	AddToSelection:         proc "system" (this: rawptr) -> win.HRESULT,
	RemoveFromSelection:    proc "system" (this: rawptr) -> win.HRESULT,
	get_IsSelected:         proc "system" (this: rawptr, out: ^win.BOOL) -> win.HRESULT,
	get_SelectionContainer: proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT,
}

@(private)
IInvokeProvider_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> win.ULONG,
	Release:        proc "system" (this: rawptr) -> win.ULONG,
	Invoke:         proc "system" (this: rawptr) -> win.HRESULT,
}

// The interface ids. A wrong one is not a crash but a silence (a client asks,
// is told no, and walks away), so `uia_query_for` logs every id it does not
// know under BALDR_A11Y_DEBUG.
@(private) IID_IUnknown := win.GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private) IID_SIMPLE   := win.GUID{0xD6DD68D1, 0x86FD, 0x4332, {0x86, 0x66, 0x9A, 0xBE, 0xDE, 0xA2, 0xD2, 0x4C}}
@(private) IID_FRAGMENT := win.GUID{0xF7063DA8, 0x8359, 0x439C, {0x92, 0x97, 0xBB, 0xC5, 0x29, 0x9A, 0x7D, 0x87}}
@(private) IID_FRAG_ROOT := win.GUID{0x620CE2A5, 0xAB8F, 0x40A9, {0x86, 0xCB, 0xDE, 0x3C, 0x75, 0x59, 0x9B, 0x58}}
@(private) IID_INVOKE   := win.GUID{0x54FCB24B, 0xE18E, 0x47A2, {0xB4, 0xD3, 0xEC, 0xCB, 0xE7, 0x75, 0x99, 0xA2}}
@(private) IID_TOGGLE   := win.GUID{0x56D00BD0, 0xC4F4, 0x433C, {0xA8, 0x36, 0x1A, 0x52, 0xA5, 0x7E, 0x08, 0x92}}
@(private) IID_VALUE    := win.GUID{0xC7935180, 0x6FB3, 0x4201, {0xB1, 0x74, 0x7D, 0xF7, 0x3A, 0xDB, 0xF6, 0x4A}}
@(private) IID_RANGE    := win.GUID{0x36DC7AEF, 0x33E6, 0x4691, {0xAF, 0xE1, 0x2B, 0xE7, 0x27, 0x4B, 0x3D, 0x33}}
@(private) IID_SEL_ITEM := win.GUID{0x2ACAD808, 0xB2D4, 0x452D, {0xA6, 0x23, 0x8D, 0x1C, 0x3C, 0x54, 0xD4, 0x5B}}

@(private)
guid_eq :: proc "contextless" (a, b: ^win.GUID) -> bool {
	if a == nil || b == nil do return false
	if a.Data1 != b.Data1 || a.Data2 != b.Data2 || a.Data3 != b.Data3 do return false
	for i in 0 ..< 8 do if a.Data4[i] != b.Data4[i] do return false
	return true
}

// ------------------------------------------------------------- the provider
//
// One object per node. Its four vtable pointers come first and at fixed
// offsets, because a client is handed the address of one of *those* fields
// and never of the object: a call arriving on the fragment interface is
// `&elem.fragment`, so the object is recovered by subtracting that field's
// offset. That is what the C macro CONTAINING_RECORD does, written out.

@(private)
Uia_Element :: struct {
	simple:   ^IRawElementProviderSimple_Vtbl,
	fragment: ^IRawElementProviderFragment_Vtbl,
	root:     ^IRawElementProviderFragmentRoot_Vtbl,
	invoke:   ^IInvokeProvider_Vtbl,
	toggle:   ^IToggleProvider_Vtbl,
	value:    ^IValueProvider_Vtbl,
	range:    ^IRangeValueProvider_Vtbl,
	sel_item: ^ISelectionItemProvider_Vtbl,
	refs:     win.ULONG,
	id:       u64,
}

@(private, thread_local)
uia: struct {
	lib:      Uia_Lib,
	loaded:   bool,
	ctx:      runtime.Context, // every COM call arrives with none
	elements: map[u64]^Uia_Element,
	subclassed: map[win.HWND]win.WNDPROC, // the window procedure we chained onto
	said_iid: map[win.GUID]bool,          // interface ids already reported once
	started:  bool, // uia_bridge_start ran: there is a UIA client stack to answer to
	simple_vtbl:   IRawElementProviderSimple_Vtbl,
	fragment_vtbl: IRawElementProviderFragment_Vtbl,
	root_vtbl:     IRawElementProviderFragmentRoot_Vtbl,
	invoke_vtbl:   IInvokeProvider_Vtbl,
	toggle_vtbl:   IToggleProvider_Vtbl,
	value_vtbl:    IValueProvider_Vtbl,
	range_vtbl:    IRangeValueProvider_Vtbl,
	sel_item_vtbl: ISelectionItemProvider_Vtbl,
	debug:    bool,
}

// uia_of recovers the object from a pointer to one of its vtable fields.
@(private) uia_of_simple   :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, simple)) }
@(private) uia_of_fragment :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, fragment)) }
@(private) uia_of_root     :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, root)) }
@(private) uia_of_invoke   :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, invoke)) }
@(private) uia_of_toggle   :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, toggle)) }
@(private) uia_of_value    :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, value)) }
@(private) uia_of_range    :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, range)) }
@(private) uia_of_sel_item :: proc "contextless" (p: rawptr) -> ^Uia_Element { return (^Uia_Element)(uintptr(p) - offset_of(Uia_Element, sel_item)) }

// ------------------------------------------------------------------ the seam

@(private)
uia_bridge_start :: proc() -> (ok: bool, why: string) {
	uia.ctx = context
	uia.debug = os.get_env("BALDR_A11Y_DEBUG", context.temp_allocator) == "1"
	if !uia_load() do return false, "uiautomationcore.dll would not load"

	// The apartment every provider call will be marshalled into. S_FALSE
	// means this thread was already an STA, which is the ordinary case —
	// OLE drag and drop gets there first when a window takes drops — and is
	// not a failure.
	win.CoInitializeEx(nil, win.COINIT.APARTMENTTHREADED)

	uia.simple_vtbl = {
		QueryInterface = uia_simple_query, AddRef = uia_simple_add_ref, Release = uia_simple_release,
		get_ProviderOptions        = uia_provider_options,
		GetPatternProvider         = uia_get_pattern,
		GetPropertyValue           = uia_get_property,
		get_HostRawElementProvider = uia_get_host,
	}
	uia.fragment_vtbl = {
		QueryInterface = uia_fragment_query, AddRef = uia_fragment_add_ref, Release = uia_fragment_release,
		Navigate                 = uia_navigate,
		GetRuntimeId             = uia_runtime_id,
		get_BoundingRectangle    = uia_bounds,
		GetEmbeddedFragmentRoots = uia_embedded_roots,
		SetFocus                 = uia_set_focus,
		get_FragmentRoot         = uia_fragment_root,
	}
	uia.root_vtbl = {
		QueryInterface = uia_root_query, AddRef = uia_root_add_ref, Release = uia_root_release,
		ElementProviderFromPoint = uia_from_point,
		GetFocus                 = uia_get_focus,
	}
	uia.invoke_vtbl = {
		QueryInterface = uia_invoke_query, AddRef = uia_invoke_add_ref, Release = uia_invoke_release,
		Invoke = uia_invoke,
	}
	uia.toggle_vtbl = {
		QueryInterface = uia_toggle_query, AddRef = uia_toggle_add_ref, Release = uia_toggle_release,
		Toggle = uia_toggle, get_ToggleState = uia_toggle_state,
	}
	uia.value_vtbl = {
		QueryInterface = uia_value_query, AddRef = uia_value_add_ref, Release = uia_value_release,
		SetValue = uia_value_set, get_Value = uia_value_get, get_IsReadOnly = uia_value_readonly,
	}
	uia.range_vtbl = {
		QueryInterface = uia_range_query, AddRef = uia_range_add_ref, Release = uia_range_release,
		SetValue = uia_range_set, get_Value = uia_range_get, get_IsReadOnly = uia_range_readonly,
		get_Maximum = uia_range_max, get_Minimum = uia_range_min,
		get_LargeChange = uia_range_large, get_SmallChange = uia_range_small,
	}
	uia.sel_item_vtbl = {
		QueryInterface = uia_sel_query, AddRef = uia_sel_add_ref, Release = uia_sel_release,
		Select = uia_sel_select, AddToSelection = uia_sel_add, RemoveFromSelection = uia_sel_remove,
		get_IsSelected = uia_sel_is_selected, get_SelectionContainer = uia_sel_container,
	}
	uia.elements = make(map[u64]^Uia_Element)
	uia.subclassed = make(map[win.HWND]win.WNDPROC)
	uia.started = true
	// Always attached: a client's question arrives as a window message, with
	// nothing to connect to and nothing to register. Whether anyone is
	// listening is UiaClientsAreListening, which is what decides whether
	// changes are worth reporting.
	return true, ""
}

@(private)
uia_bridge_stop :: proc() {
	for hwnd, old in uia.subclassed {
		if old != nil do win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, win.LONG_PTR(uintptr(transmute(rawptr)old)))
	}
	delete(uia.subclassed)
	for _, e in uia.elements {
		if uia.lib.UiaDisconnectProvider != nil do uia.lib.UiaDisconnectProvider(&e.simple)
		free(e)
	}
	delete(uia.elements)
	uia = {}
}

// uia_bridge_listening is whether any assistive technology has asked. UIA
// answers it exactly and cheaply.
@(private)
uia_bridge_listening :: proc() -> bool {
	if uia.lib.UiaClientsAreListening == nil do return false
	return bool(uia.lib.UiaClientsAreListening())
}

@(private)
uia_bridge_debug :: proc(format: string, args: ..any) {
	if !uia.debug do return
	fmt.eprintf("baldr/a11y: ")
	fmt.eprintfln(format, ..args)
}

@(private)
uia_load :: proc() -> bool {
	if uia.loaded do return true
	count, ok := dynlib.initialize_symbols(&uia.lib, "uiautomationcore.dll", "", "_handle")
	uia.loaded = ok && count > 0 && uia.lib.UiaReturnRawElementProvider != nil
	uia_bridge_debug("uiautomationcore.dll: %d symbols, ok=%v", count, uia.loaded)
	return uia.loaded
}

// uia_bridge_attach subclasses each window so a client's WM_GETOBJECT reaches
// the toolkit. Called once a frame from the accessibility pass; it does
// nothing for a window already carrying our procedure.
@(private)
uia_bridge_attach :: proc() {
	for w in a11y.windows {
		hwnd := win.HWND(w.native)
		if hwnd == nil do continue
		if _, had := uia.subclassed[hwnd]; had do continue
		prev := win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC,
			win.LONG_PTR(uintptr(rawptr(uia_wnd_proc))))
		uia.subclassed[hwnd] = transmute(win.WNDPROC)rawptr(uintptr(prev))
		uia_bridge_debug("subclassed window %v for WM_GETOBJECT", hwnd)
	}
}

// uia_wnd_proc answers the one message this bridge wants and passes every
// other straight on to the backend's own procedure.
@(private)
uia_wnd_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = uia.ctx
	old := uia.subclassed[hwnd]
	if msg == WM_GETOBJECT && lparam == UIA_ROOT_OBJECT_ID {
		if root := uia_root_for(hwnd); root != nil && uia.lib.UiaReturnRawElementProvider != nil {
			uia_bridge_debug("WM_GETOBJECT: handing out the fragment root of window %v", hwnd)
			return uia.lib.UiaReturnRawElementProvider(hwnd, wparam, lparam, &root.simple)
		}
	}
	if old != nil do return win.CallWindowProcW(old, hwnd, msg, wparam, lparam)
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// uia_root_for is the provider for a window's own object, which is the root
// of the fragment the toolkit owns.
@(private)
uia_root_for :: proc(hwnd: win.HWND) -> ^Uia_Element {
	for w, i in a11y.windows {
		if win.HWND(w.native) != hwnd do continue
		if id, named := a11y_id(i, NODE_NONE); named do return uia_element(id)
	}
	return nil
}

@(private)
uia_element :: proc(id: u64) -> ^Uia_Element {
	// Id 0 is the application object, which on Windows is UIA's own: our
	// fragment starts at the window. No id the bridge hands out is ever 0.
	if id == A11Y_APP_ID do return nil
	// Nothing without a bridge: a headless test reaches the say path
	// directly, with no client stack to hand a provider to, and an Odin map
	// allocates on its first insert, so `uia.elements` would be left with no
	// `uia_bridge_stop` to free it. `ax_element` does the same on macOS.
	if !uia.started do return nil
	if e, held := uia.elements[id]; held do return e
	e := new(Uia_Element)
	e.simple, e.fragment = &uia.simple_vtbl, &uia.fragment_vtbl
	e.root, e.invoke = &uia.root_vtbl, &uia.invoke_vtbl
	e.toggle, e.value = &uia.toggle_vtbl, &uia.value_vtbl
	e.range, e.sel_item = &uia.range_vtbl, &uia.sel_item_vtbl
	e.refs, e.id = 1, id
	uia.elements[id] = e
	return e
}

// ---------------------------------------------------------- IUnknown, ×4
//
// Every interface of one object shares its reference count, which is what COM
// requires: a client that holds any of them holds the object.

@(private)
uia_query_for :: proc "system" (e: ^Uia_Element, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	switch {
	case guid_eq(riid, &IID_IUnknown), guid_eq(riid, &IID_SIMPLE):
		out^ = &e.simple
	case guid_eq(riid, &IID_FRAGMENT):
		out^ = &e.fragment
	case guid_eq(riid, &IID_FRAG_ROOT):
		// Only a window's own object is a fragment root; a node inside one
		// is not, and saying otherwise would make a client treat every
		// control as the top of its own tree.
		_, n, ok := a11y_unpack(e.id)
		if !ok || n != NODE_NONE do return HR_NOINTERFACE
		out^ = &e.root
	case guid_eq(riid, &IID_INVOKE):
		obj, have := a11y_obj(e.id)
		if !have || !obj.has_action do return HR_NOINTERFACE
		out^ = &e.invoke
	case guid_eq(riid, &IID_TOGGLE):
		if !uia_has_toggle(e.id) do return HR_NOINTERFACE
		out^ = &e.toggle
	case guid_eq(riid, &IID_VALUE):
		if !uia_has_value_text(e.id) do return HR_NOINTERFACE
		out^ = &e.value
	case guid_eq(riid, &IID_RANGE):
		if !uia_has_range(e.id) do return HR_NOINTERFACE
		out^ = &e.range
	case guid_eq(riid, &IID_SEL_ITEM):
		if !uia_has_sel_item(e.id) do return HR_NOINTERFACE
		out^ = &e.sel_item
	case:
		// Mostly UIA probing for optional interfaces, where E_NOINTERFACE is
		// right, but a wrong id above would fail as quietly, so each is named
		// once. (`{{` and `}}`: a brace is a placeholder to Odin's fmt.)
		if !uia.said_iid[riid^] {
			uia.said_iid[riid^] = true
			uia_bridge_debug("QueryInterface for an id we do not implement (normal for UIA's optional ones): {{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}}",
				riid.Data1, riid.Data2, riid.Data3,
				riid.Data4[0], riid.Data4[1], riid.Data4[2], riid.Data4[3],
				riid.Data4[4], riid.Data4[5], riid.Data4[6], riid.Data4[7])
		}
		return HR_NOINTERFACE
	}
	e.refs += 1
	return win.S_OK
}

@(private) uia_simple_query   :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_simple(this), riid, out) }
@(private) uia_fragment_query :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_fragment(this), riid, out) }
@(private) uia_root_query     :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_root(this), riid, out) }
@(private) uia_invoke_query   :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_invoke(this), riid, out) }
@(private) uia_toggle_query   :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_toggle(this), riid, out) }
@(private) uia_value_query    :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_value(this), riid, out) }
@(private) uia_range_query    :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_range(this), riid, out) }
@(private) uia_sel_query      :: proc "system" (this: rawptr, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return uia_query_for(uia_of_sel_item(this), riid, out) }

// The object outlives its references: the bridge owns every element and drops
// it when the id stops resolving, so Release never frees. A client holding a
// stale pointer is what UiaDisconnectProvider is for.
@(private) uia_add_ref_for :: proc "system" (e: ^Uia_Element) -> win.ULONG { e.refs += 1; return e.refs }
@(private) uia_release_for :: proc "system" (e: ^Uia_Element) -> win.ULONG { if e.refs > 0 do e.refs -= 1; return e.refs }

@(private) uia_simple_add_ref   :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_simple(this)) }
@(private) uia_simple_release   :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_simple(this)) }
@(private) uia_fragment_add_ref :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_fragment(this)) }
@(private) uia_fragment_release :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_fragment(this)) }
@(private) uia_root_add_ref     :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_root(this)) }
@(private) uia_root_release     :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_root(this)) }
@(private) uia_invoke_add_ref   :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_invoke(this)) }
@(private) uia_invoke_release   :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_invoke(this)) }
@(private) uia_toggle_add_ref   :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_toggle(this)) }
@(private) uia_toggle_release   :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_toggle(this)) }
@(private) uia_value_add_ref    :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_value(this)) }
@(private) uia_value_release    :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_value(this)) }
@(private) uia_range_add_ref    :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_range(this)) }
@(private) uia_range_release    :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_range(this)) }
@(private) uia_sel_add_ref      :: proc "system" (this: rawptr) -> win.ULONG { return uia_add_ref_for(uia_of_sel_item(this)) }
@(private) uia_sel_release      :: proc "system" (this: rawptr) -> win.ULONG { return uia_release_for(uia_of_sel_item(this)) }

// ------------------------------------------- IRawElementProviderSimple

@(private)
uia_provider_options :: proc "system" (this: rawptr, out: ^i32) -> win.HRESULT {
	if out == nil do return HR_INVALIDARG
	// UseComThreading is not optional: without it UIA calls this provider on
	// a thread of its own, and the toolkit's tree may only be read on the
	// thread that builds it.
	out^ = PROVIDER_SERVER_SIDE | PROVIDER_USE_COM_THREADING
	return win.S_OK
}

@(private)
uia_get_pattern :: proc "system" (this: rawptr, pattern: i32, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_simple(this)
	switch pattern {
	case UIA_PATTERN_INVOKE:
		obj, have := a11y_obj(e.id)
		if have && obj.has_action { out^ = &e.invoke; e.refs += 1 }
	case UIA_PATTERN_TOGGLE:
		if uia_has_toggle(e.id) { out^ = &e.toggle; e.refs += 1 }
	case UIA_PATTERN_VALUE:
		if uia_has_value_text(e.id) { out^ = &e.value; e.refs += 1 }
	case UIA_PATTERN_RANGE_VALUE:
		if uia_has_range(e.id) { out^ = &e.range; e.refs += 1 }
	case UIA_PATTERN_SELECTION_ITEM:
		if uia_has_sel_item(e.id) { out^ = &e.sel_item; e.refs += 1 }
	}
	return win.S_OK
}

@(private)
uia_get_property :: proc "system" (this: rawptr, prop: i32, out: ^VARIANT) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = {}
	e := uia_of_simple(this)
	obj, have := a11y_obj(e.id)
	if !have do return win.S_OK // an empty VARIANT: "nothing to say about that"

	switch prop {
	case UIA_PROP_NAME:
		// A static's words are its name on Windows, where on macOS they are
		// its value: UIA has no separate "value" for read-only text.
		uia_put_bstr(out, obj.name if len(obj.name) > 0 else obj.value_text)
	case UIA_PROP_HELP_TEXT:
		uia_put_bstr(out, obj.describe)
	case UIA_PROP_AUTOMATION_ID:
		uia_put_bstr(out, fmt.tprintf("baldr-%d", e.id))
	case UIA_PROP_CONTROL_TYPE:
		out.vt, out.val.lVal = VT_I4, uia_control_type(obj.role)
	case UIA_PROP_IS_ENABLED:
		uia_put_bool(out, .Enabled in obj.flags)
	case UIA_PROP_IS_REQUIRED_FOR_FORM:
		uia_put_bool(out, .Required in obj.flags)
	case UIA_PROP_IS_DATA_VALID_FOR_FORM:
		uia_put_bool(out, .Invalid_Entry not_in obj.flags)
	case UIA_PROP_HAS_KEYBOARD_FOCUS:
		uia_put_bool(out, .Focused in obj.flags)
	case UIA_PROP_IS_KEYBOARD_FOCUSABLE:
		uia_put_bool(out, .Focusable in obj.flags)
	case UIA_PROP_IS_OFFSCREEN:
		uia_put_bool(out, .Showing not_in obj.flags)
	case UIA_PROP_IS_PASSWORD:
		uia_put_bool(out, obj.role == .Password)
	case UIA_PROP_IS_CONTROL_ELEMENT, UIA_PROP_IS_CONTENT_ELEMENT:
		uia_put_bool(out, true)
	case UIA_PROP_VALUE_VALUE:
		if obj.has_text do uia_put_bstr(out, obj.value_text)
	}
	return win.S_OK
}

// uia_get_host is the window's own provider, which UIA merges with ours so a
// client gets the native window's properties too. Only the root has one: a
// node inside the fragment is ours alone.
@(private)
uia_get_host :: proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_simple(this)
	window, n, ok := a11y_unpack(e.id)
	if !ok || n != NODE_NONE do return win.S_OK
	if uia.lib.UiaHostProviderFromHwnd == nil do return win.S_OK
	hwnd := win.HWND(a11y.windows[window].native)
	if hwnd == nil do return win.S_OK
	return uia.lib.UiaHostProviderFromHwnd(hwnd, out)
}

// ----------------------------------------- IRawElementProviderFragment

@(private)
uia_navigate :: proc "system" (this: rawptr, dir: i32, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_fragment(this)
	id := e.id
	obj, have := a11y_obj(id)
	if !have do return win.S_OK

	target: u64
	switch dir {
	case NAV_PARENT:
		// The window's own object is the top of our fragment; above it is
		// the host window, which UIA supplies.
		_, n, ok := a11y_unpack(id)
		if ok && n != NODE_NONE do target = obj.parent
	case NAV_FIRST_CHILD:
		if obj.child_count > 0 {
			if kid, ok := a11y_obj_child(id, 0); ok do target = kid
		}
	case NAV_LAST_CHILD:
		if obj.child_count > 0 {
			if kid, ok := a11y_obj_child(id, obj.child_count - 1); ok do target = kid
		}
	case NAV_NEXT, NAV_PREVIOUS:
		if obj.index < 0 do return win.S_OK
		want := obj.index + 1 if dir == NAV_NEXT else obj.index - 1
		if want < 0 do return win.S_OK
		if sib, ok := a11y_obj_child(obj.parent, want); ok do target = sib
	}
	if target == 0 do return win.S_OK
	if t := uia_element(target); t != nil {
		t.refs += 1
		out^ = &t.simple
	}
	return win.S_OK
}

// uia_runtime_id names this element for as long as it exists. It carries the
// whole of the model's id — window, generation and index — so an id whose
// node has been freed and its slot reused is a *different* runtime id, and a
// client is never handed one object believing it is another.
@(private)
uia_runtime_id :: proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_fragment(this)
	arr := SafeArrayCreateVector(VT_I4, 0, 3)
	if arr == nil do return HR_OUTOFMEMORY
	parts := [3]i32{UIA_APPEND_RUNTIME_ID, i32(u32(e.id & 0xFFFF_FFFF)), i32(u32(e.id >> 32))}
	for i in 0 ..< 3 {
		idx := win.LONG(i)
		if win.FAILED(SafeArrayPutElement(arr, &idx, &parts[i])) {
			SafeArrayDestroy(arr)
			return HR_FAIL
		}
	}
	out^ = arr
	return win.S_OK
}

@(private)
uia_bounds :: proc "system" (this: rawptr, out: ^UiaRect) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = {}
	e := uia_of_fragment(this)
	obj, have := a11y_obj(e.id)
	if !have do return win.S_OK
	window, n, ok := a11y_unpack(e.id)
	if !ok do return win.S_OK
	hwnd := win.HWND(a11y.windows[window].native)
	if hwnd == nil do return win.S_OK
	// The node's rect is in its window's client coordinates; UIA wants the
	// screen's. A window's own object has no rect of its own — the client
	// area is what it covers.
	pt := win.POINT{0, 0}
	win.ClientToScreen(hwnd, &pt)
	if n == NODE_NONE {
		rc: win.RECT
		if !win.GetClientRect(hwnd, &rc) do return win.S_OK
		out^ = {f64(pt.x), f64(pt.y), f64(rc.right - rc.left), f64(rc.bottom - rc.top)}
		return win.S_OK
	}
	out^ = {
		f64(pt.x + i32(obj.extents[0])), f64(pt.y + i32(obj.extents[1])),
		f64(obj.extents[2]), f64(obj.extents[3]),
	}
	return win.S_OK
}

@(private)
uia_embedded_roots :: proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT {
	if out != nil do out^ = nil // nothing in a Baldr window hosts another provider
	return win.S_OK
}

@(private)
uia_set_focus :: proc "system" (this: rawptr) -> win.HRESULT {
	context = uia.ctx
	e := uia_of_fragment(this)
	return win.S_OK if a11y_grab_focus(e.id) else win.S_FALSE
}

@(private)
uia_fragment_root :: proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_fragment(this)
	window, _, ok := a11y_unpack(e.id)
	if !ok do return win.S_OK
	id, named := a11y_id(window, NODE_NONE)
	if !named do return win.S_OK
	if r := uia_element(id); r != nil {
		r.refs += 1
		out^ = &r.simple
	}
	return win.S_OK
}

// ------------------------------------- IRawElementProviderFragmentRoot

// uia_from_point is a client asking what is under a screen point — what a
// reader's mouse mode and a touch exploration gesture both use. The deepest
// shown node whose rect contains the point wins, which is the same rule the
// pointer itself follows.
@(private)
uia_from_point :: proc "system" (this: rawptr, x, y: f64, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_root(this)
	window, _, ok := a11y_unpack(e.id)
	if !ok do return win.S_OK
	hwnd := win.HWND(a11y.windows[window].native)
	if hwnd == nil do return win.S_OK
	pt := win.POINT{0, 0}
	win.ClientToScreen(hwnd, &pt)
	local := [2]f64{x - f64(pt.x), y - f64(pt.y)}

	root_id, named := a11y_id(window, NODE_NONE)
	if !named do return win.S_OK
	found := uia_deepest_at(root_id, local)
	if t := uia_element(found if found != 0 else root_id); t != nil {
		t.refs += 1
		out^ = &t.simple
	}
	return win.S_OK
}

// uia_deepest_at walks down to the innermost object covering a point in
// window coordinates. 0 when nothing does.
@(private)
uia_deepest_at :: proc(id: u64, p: [2]f64) -> u64 {
	obj, have := a11y_obj(id)
	if !have do return 0
	for i in 0 ..< obj.child_count {
		kid, ok := a11y_obj_child(id, i)
		if !ok do continue
		kid_obj, kid_have := a11y_obj(kid)
		if !kid_have || .Showing not_in kid_obj.flags do continue
		x, y := f64(kid_obj.extents[0]), f64(kid_obj.extents[1])
		w, h := f64(kid_obj.extents[2]), f64(kid_obj.extents[3])
		if p.x < x || p.y < y || p.x >= x + w || p.y >= y + h do continue
		if deeper := uia_deepest_at(kid, p); deeper != 0 do return deeper
		return kid
	}
	return 0
}

@(private)
uia_get_focus :: proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_root(this)
	window, _, ok := a11y_unpack(e.id)
	if !ok do return win.S_OK
	t := a11y.windows[window].tree
	if t == nil || t.focus == NODE_NONE do return win.S_OK
	// The row under a focused view's cursor is where the keyboard really is,
	// which is the same answer the model gives a reader on the other two
	// platforms.
	node := t.focus
	if d := node_get(t, t.focus); d != nil && d.access.active != NODE_NONE && a11y_shown(t, d.access.active) {
		node = d.access.active
	}
	if !a11y_reachable(t, node) do return win.S_OK
	id, named := a11y_id(window, node)
	if !named do return win.S_OK
	if f := uia_element(id); f != nil {
		f.refs += 1
		out^ = &f.simple
	}
	return win.S_OK
}

// ----------------------------------------------------------- IInvokeProvider

@(private)
uia_invoke :: proc "system" (this: rawptr) -> win.HRESULT {
	context = uia.ctx
	e := uia_of_invoke(this)
	done := a11y_do_action(e.id)
	// A client treats S_FALSE as success too, so a refusal is invisible
	// unless it is logged here.
	window, n, unpacked := a11y_unpack(e.id)
	uia_bridge_debug("Invoke on %d: done=%v (window %d, node %v, unpacked=%v, can_act=%v)",
		e.id, done, window, n, unpacked, a11y_can_act(window))
	if !done do return win.S_FALSE
	if uia.lib.UiaRaiseAutomationEvent != nil {
		uia.lib.UiaRaiseAutomationEvent(&e.simple, UIA_EVENT_INVOKED)
	}
	return win.S_OK
}

// ---------------------------------------------------------------- patterns
//
// A pattern is UIA's word for "this control can be used like a …": a
// checkbox toggles, a slider has a range, a row is selectable. They are what
// carry a control's *state*, so without them a reader names a checkbox and
// cannot say whether it is ticked.

@(private)
uia_has_toggle :: proc(id: u64) -> bool {
	obj, have := a11y_obj(id)
	return have && .Checkable in obj.flags
}

@(private)
uia_has_value_text :: proc(id: u64) -> bool {
	obj, have := a11y_obj(id)
	return have && obj.has_text
}

@(private)
uia_has_range :: proc(id: u64) -> bool {
	obj, have := a11y_obj(id)
	return have && obj.has_value
}

@(private)
uia_has_sel_item :: proc(id: u64) -> bool {
	obj, have := a11y_obj(id)
	if !have do return false
	#partial switch obj.role {
	case .List_Item, .Tree_Item, .Tab, .Row, .Cell: return true
	}
	return false
}

// --- IToggleProvider

@(private)
uia_toggle :: proc "system" (this: rawptr) -> win.HRESULT {
	context = uia.ctx
	e := uia_of_toggle(this)
	return win.S_OK if a11y_do_action(e.id) else win.S_FALSE
}

@(private)
uia_toggle_state :: proc "system" (this: rawptr, out: ^i32) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = 0 // ToggleState_Off
	e := uia_of_toggle(this)
	obj, have := a11y_obj(e.id)
	if !have do return win.S_OK
	if .Indeterminate in obj.flags {
		out^ = 2
	} else if .Checked in obj.flags || .Pressed in obj.flags {
		out^ = 1
	}
	return win.S_OK
}

// --- IValueProvider: the text a field holds

@(private)
uia_value_get :: proc "system" (this: rawptr, out: ^win.BSTR) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	e := uia_of_value(this)
	info, have := a11y_obj_text(e.id)
	out^ = uia_bstr(info.text if have else "")
	return win.S_OK
}

@(private)
uia_value_readonly :: proc "system" (this: rawptr, out: ^win.BOOL) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	e := uia_of_value(this)
	obj, have := a11y_obj(e.id)
	out^ = win.BOOL(!(have && obj.editable))
	return win.S_OK
}

// uia_value_set is a reader typing on someone's behalf: the whole of the
// field replaced, through the widget's own editing path, which is what
// a11y_edit guarantees.
@(private)
uia_value_set :: proc "system" (this: rawptr, v: win.BSTR) -> win.HRESULT {
	context = uia.ctx
	e := uia_of_value(this)
	info, have := a11y_obj_text(e.id)
	if !have do return win.S_FALSE
	text := uia_from_bstr(v)
	return win.S_OK if a11y_edit(e.id, 0, len(info.text), text) else win.S_FALSE
}

// --- IRangeValueProvider: what a slider or a progress bar is worth
//
// Read-only, like the Linux bridge's: the model has no act for "set this
// value", so claiming otherwise would offer a reader a control it cannot in
// fact move.

@(private)
uia_range_get :: proc "system" (this: rawptr, out: ^f64) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	obj, have := a11y_obj(uia_of_range(this).id)
	out^ = obj.value if have else 0
	return win.S_OK
}

@(private)
uia_range_min :: proc "system" (this: rawptr, out: ^f64) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	obj, have := a11y_obj(uia_of_range(this).id)
	out^ = obj.value_min if have else 0
	return win.S_OK
}

@(private)
uia_range_max :: proc "system" (this: rawptr, out: ^f64) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	obj, have := a11y_obj(uia_of_range(this).id)
	out^ = obj.value_max if have else 0
	return win.S_OK
}

@(private)
uia_range_small :: proc "system" (this: rawptr, out: ^f64) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	obj, have := a11y_obj(uia_of_range(this).id)
	out^ = obj.value_step if have else 0
	return win.S_OK
}

@(private)
uia_range_large :: proc "system" (this: rawptr, out: ^f64) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	obj, have := a11y_obj(uia_of_range(this).id)
	out^ = obj.value_step * 10 if have else 0 // what Shift and an arrow move, as the widgets do
	return win.S_OK
}

@(private)
uia_range_readonly :: proc "system" (this: rawptr, out: ^win.BOOL) -> win.HRESULT {
	if out != nil do out^ = win.BOOL(true)
	return win.S_OK
}

@(private)
uia_range_set :: proc "system" (this: rawptr, v: f64) -> win.HRESULT {
	return win.S_FALSE // read-only: see above
}

// --- ISelectionItemProvider: a row, a tile, a tab

@(private)
uia_sel_select :: proc "system" (this: rawptr) -> win.HRESULT {
	context = uia.ctx
	e := uia_of_sel_item(this)
	return win.S_OK if a11y_do_action(e.id) else win.S_FALSE
}

@(private)
uia_sel_add :: proc "system" (this: rawptr) -> win.HRESULT {
	return win.S_FALSE // adding to a selection is the view's own gesture, not a press
}

@(private)
uia_sel_remove :: proc "system" (this: rawptr) -> win.HRESULT {
	return win.S_FALSE
}

@(private)
uia_sel_is_selected :: proc "system" (this: rawptr, out: ^win.BOOL) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	obj, have := a11y_obj(uia_of_sel_item(this).id)
	out^ = win.BOOL(have && .Selected in obj.flags)
	return win.S_OK
}

@(private)
uia_sel_container :: proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT {
	context = uia.ctx
	if out == nil do return HR_INVALIDARG
	out^ = nil
	e := uia_of_sel_item(this)
	obj, have := a11y_obj(e.id)
	if !have || obj.parent == 0 do return win.S_OK
	if c := uia_element(obj.parent); c != nil {
		c.refs += 1
		out^ = &c.simple
	}
	return win.S_OK
}

// uia_from_bstr reads a BSTR as the toolkit's own text, for the frame.
@(private)
uia_from_bstr :: proc(b: win.BSTR) -> string {
	if b == nil do return ""
	w := ([^]u16)(b)
	n := 0
	for w[n] != 0 do n += 1
	if n == 0 do return ""
	s, err := win.utf16_to_utf8(w[:n], context.temp_allocator)
	return s if err == nil else ""
}

// --------------------------------------------------------------- what we say

@(private)
uia_bridge_deliver :: proc(said: A11y_Said) {
	l := &uia.lib
	switch s in said {
	case Said_Focus:
		if e := uia_element(s.id); e != nil && l.UiaRaiseAutomationEvent != nil {
			l.UiaRaiseAutomationEvent(&e.simple, UIA_EVENT_FOCUS_CHANGED)
		}
	case Said_Active_Item:
		// The row a view's cursor moved to is where the keyboard is, and on
		// Windows that is said as a focus change on the row itself.
		if e := uia_element(s.child); e != nil && l.UiaRaiseAutomationEvent != nil {
			l.UiaRaiseAutomationEvent(&e.simple, UIA_EVENT_FOCUS_CHANGED)
		}
	case Said_Name:
		uia_property_changed(s.id, UIA_PROP_NAME)
	case Said_Describe:
		uia_property_changed(s.id, UIA_PROP_HELP_TEXT)
	case Said_Value:
		uia_property_changed(s.id, UIA_PROP_VALUE_VALUE)
	case Said_Text_Edit:
		uia_property_changed(s.id, UIA_PROP_VALUE_VALUE)
	case Said_Flag:
		#partial switch s.flag {
		case .Enabled:   uia_property_changed(s.id, UIA_PROP_IS_ENABLED)
		case .Invalid_Entry: uia_property_changed(s.id, UIA_PROP_IS_DATA_VALID_FOR_FORM)
		case .Required:  uia_property_changed(s.id, UIA_PROP_IS_REQUIRED_FOR_FORM)
		case .Showing:   uia_property_changed(s.id, UIA_PROP_IS_OFFSCREEN)
		case .Focused:   if s.on do uia_property_changed(s.id, UIA_PROP_HAS_KEYBOARD_FOCUS)
		case .Defunct:
			if e, held := uia.elements[s.id]; held {
				if l.UiaDisconnectProvider != nil do l.UiaDisconnectProvider(&e.simple)
				delete_key(&uia.elements, s.id)
				free(e)
			}
		}
	case Said_Children:
		uia_structure_changed(s.id)
	case Said_Announce:
		uia_notify(s)
	case Said_Window, Said_Caret, Said_Text_Selection, Said_Selection:
		// Nothing of UIA's own fits these yet: a window's activation is the
		// host provider's, and the caret and selection belong to the Text
		// pattern, which is not implemented. A client re-reads the element
		// when its cursor next reaches it.
	}
}

@(private)
uia_property_changed :: proc(id: u64, prop: i32) {
	if uia.lib.UiaRaiseAutomationPropertyChangedEvent == nil do return
	e := uia_element(id)
	if e == nil do return
	old: VARIANT // UIA accepts an empty "was": a client re-reads rather than diffing
	new: VARIANT
	uia.lib.UiaRaiseAutomationPropertyChangedEvent(&e.simple, prop, old, new)
}

@(private)
uia_structure_changed :: proc(id: u64) {
	if uia.lib.UiaRaiseStructureChangedEvent == nil do return
	e := uia_element(id)
	if e == nil do return
	parts := [3]i32{UIA_APPEND_RUNTIME_ID, i32(u32(id & 0xFFFF_FFFF)), i32(u32(id >> 32))}
	uia.lib.UiaRaiseStructureChangedEvent(&e.simple, UIA_STRUCTURE_CHILDREN_INVALIDATED, raw_data(parts[:]), 3)
}

@(private)
uia_notify :: proc(s: Said_Announce) {
	if uia.lib.UiaRaiseNotificationEx == nil do return
	e := uia_element(s.id)
	if e == nil do return
	text := uia_bstr(s.text)
	if text == nil do return
	defer SysFreeString(text)
	activity := uia_bstr("baldr")
	defer if activity != nil do SysFreeString(activity)
	uia.lib.UiaRaiseNotificationEx(&e.simple, UIA_NOTIFY_KIND_OTHER,
		UIA_NOTIFY_PROCESS_IMPORTANT_ALL if s.assertive else UIA_NOTIFY_PROCESS_ALL,
		text, activity)
}

// ------------------------------------------------------------ small helpers

// uia_bstr is a BSTR the caller frees. UIA takes a copy of anything it keeps.
@(private)
uia_bstr :: proc(s: string) -> win.BSTR {
	if len(s) == 0 {
		empty := [1]u16{0}
		return SysAllocStringLen(raw_data(empty[:]), 0)
	}
	w := win.utf8_to_utf16(s, context.temp_allocator)
	if len(w) == 0 do return nil
	return SysAllocStringLen(raw_data(w), win.UINT(len(w)))
}

@(private)
uia_put_bstr :: proc(out: ^VARIANT, s: string) {
	b := uia_bstr(s)
	if b == nil do return
	out.vt, out.val.bstrVal = VT_BSTR, b // UIA frees what it is handed
}

@(private)
uia_put_bool :: proc "contextless" (out: ^VARIANT, on: bool) {
	out.vt = VT_BOOL
	out.val.boolVal = VARIANT_TRUE if on else VARIANT_FALSE
}

// uia_control_type is a role in UIA's vocabulary. Where UIA has no word for
// something the nearest one is used and the comment says what was lost.
@(private)
uia_control_type :: proc(r: A11y_Role) -> i32 {
	switch r {
	case .None:          return UIA_CT_PANE
	case .Application:   return UIA_CT_WINDOW
	case .Window:        return UIA_CT_WINDOW
	case .Panel:         return UIA_CT_PANE
	case .Group:         return UIA_CT_GROUP
	case .Static:        return UIA_CT_TEXT
	case .Heading:       return UIA_CT_TEXT // UIA has a Heading level, not a heading type
	case .Label:         return UIA_CT_TEXT
	case .Image:         return UIA_CT_IMAGE
	case .Button:        return UIA_CT_BUTTON
	case .Toggle_Button: return UIA_CT_BUTTON // with the Toggle pattern, which is what reads its state
	case .Link:          return UIA_CT_HYPERLINK
	case .Check_Box:     return UIA_CT_CHECK_BOX
	case .Radio_Button:  return UIA_CT_RADIO_BUTTON
	case .Radio_Group:   return UIA_CT_GROUP // UI Automation names no radio group either
	case .Slider:        return UIA_CT_SLIDER
	case .Spin_Button:   return UIA_CT_SPINNER
	case .Entry:         return UIA_CT_EDIT
	case .Password:      return UIA_CT_EDIT // with IsPassword, which is what hides it
	case .Document:      return UIA_CT_DOCUMENT
	case .Combo_Box:     return UIA_CT_COMBO_BOX
	case .List:          return UIA_CT_LIST
	case .List_Item:     return UIA_CT_LIST_ITEM
	case .Table:         return UIA_CT_TABLE
	case .Row:           return UIA_CT_DATA_ITEM
	case .Cell:          return UIA_CT_TEXT // UIA's grid cells are addressed by pattern, not type
	case .Column_Header: return UIA_CT_HEADER_ITEM
	case .Tree:          return UIA_CT_TREE
	case .Tree_Item:     return UIA_CT_TREE_ITEM
	case .Tab_List:      return UIA_CT_TAB
	case .Tab:           return UIA_CT_TAB_ITEM
	case .Menu_Bar:      return UIA_CT_MENU_BAR
	case .Menu:          return UIA_CT_MENU
	case .Menu_Item:     return UIA_CT_MENU_ITEM
	case .Dialog:        return UIA_CT_WINDOW
	case .Alert:         return UIA_CT_GROUP
	case .Status_Bar:    return UIA_CT_STATUS_BAR
	case .Progress_Bar:  return UIA_CT_PROGRESS_BAR
	case .Tooltip:       return UIA_CT_TOOL_TIP
	case .Separator:     return UIA_CT_SEPARATOR
	case .Scroll_Area:   return UIA_CT_PANE
	case .Tool_Bar:      return UIA_CT_TOOL_BAR
	case .Terminal:      return UIA_CT_DOCUMENT
	}
	return UIA_CT_PANE
}
