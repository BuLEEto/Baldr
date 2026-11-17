#+build linux
package atspi

// AT-SPI2: what a Linux screen reader reads. A toolkit describes its
// widgets — role, name, state, where they are on screen — and this package
// puts that on the accessibility bus as the object tree assistive
// technologies expect.
//
// The toolkit stays out of D-Bus: it fills in a Provider (what each object
// is, who its children are) and the bridge answers the calls that come in.
// Ids are the toolkit's own and mean nothing here except that 0 is the
// application itself, whose children are its windows.
//
// Interfaces served: Accessible, Component, Application, Text, Value,
// Action, Selection and the Cache, through D-Bus Properties and
// Introspectable; events.odin sends the signals a reader listens for.
//
// The numbers in Role and State are AT-SPI's own (atspi-constants.h); they
// are the wire format, so they are written out rather than derived.

import "core:strings"

// Role is what an object is, in AT-SPI's numbering.
Role :: enum u32 {
	Invalid        = 0,
	Calendar       = 5,
	Canvas         = 6,
	Check_Box      = 7,
	Check_Menu_Item = 8,
	Color_Chooser  = 9,
	Combo_Box      = 11,
	Date_Editor    = 12,
	Dialog         = 16,
	Filler         = 20,
	Frame          = 23,
	Icon           = 26,
	Image          = 27,
	Label          = 29,
	List           = 31,
	List_Item      = 32,
	Menu           = 33,
	Menu_Bar       = 34,
	Menu_Item      = 35,
	Page_Tab       = 37,
	Page_Tab_List  = 38,
	Panel          = 39,
	Password_Text  = 40,
	Progress_Bar   = 42,
	Button         = 43,
	Radio_Button   = 44,
	Radio_Menu_Item = 45,
	Scroll_Bar     = 48,
	Scroll_Pane    = 49,
	Separator      = 50,
	Slider         = 51,
	Spin_Button    = 52,
	Split_Pane     = 53,
	Status_Bar     = 54,
	Table          = 55,
	Table_Cell     = 56,
	Table_Column_Header = 57,
	Terminal       = 60,
	Text           = 61,
	Toggle_Button  = 62,
	Tool_Bar       = 63,
	Tool_Tip       = 64,
	Tree           = 65,
	Viewport       = 68,
	Window         = 69,
	Application    = 75,
	Entry          = 79,
	Heading        = 83,
	Link           = 88,
	Table_Row      = 90,
	Tree_Item      = 91,
	Document_Text  = 94,
	Grouping       = 99,
	Notification   = 101,
	Static         = 116,
}

// State is one of the flags an object can be in, in AT-SPI's numbering.
State :: enum u32 {
	Active        = 1,
	Armed         = 2,
	Busy          = 3,
	Checked       = 4,
	Collapsed     = 5,
	Defunct       = 6,
	Editable      = 7,
	Enabled       = 8,
	Expandable    = 9,
	Expanded      = 10,
	Focusable     = 11,
	Focused       = 12,
	Has_Tooltip   = 13,
	Horizontal    = 14,
	Modal         = 16,
	Multi_Line    = 17,
	Multiselectable = 18,
	Pressed       = 20,
	Resizable     = 21,
	Selectable    = 22,
	Selected      = 23,
	Sensitive     = 24,
	Showing       = 25,
	Single_Line   = 26,
	Vertical      = 29,
	Visible       = 30,
	Indeterminate = 32,
	Required      = 33,
	Invalid_Entry = 36,
	Selectable_Text = 38,
	Is_Default    = 39,
	Checkable     = 41,
	Has_Popup     = 42,
	Read_Only     = 43,
}

States :: bit_set[State; u64]

// ROOT_PATH is where every application's own object lives; the rest hang off
// PATH_PREFIX with the toolkit's id after it.
ROOT_PATH   :: "/org/a11y/atspi/accessible/root"
PATH_PREFIX :: "/org/a11y/atspi/accessible/"
NULL_PATH   :: "/org/a11y/atspi/null"

// Interfaces the bridge answers for.
IFACE_ACCESSIBLE  :: "org.a11y.atspi.Accessible"
IFACE_COMPONENT   :: "org.a11y.atspi.Component"
IFACE_APPLICATION :: "org.a11y.atspi.Application"
IFACE_TEXT        :: "org.a11y.atspi.Text"
IFACE_VALUE       :: "org.a11y.atspi.Value"
IFACE_ACTION      :: "org.a11y.atspi.Action"
IFACE_SELECTION   :: "org.a11y.atspi.Selection"
IFACE_EDIT_TEXT   :: "org.a11y.atspi.EditableText"
IFACE_SOCKET      :: "org.a11y.atspi.Socket"
IFACE_PROPERTIES  :: "org.freedesktop.DBus.Properties"
IFACE_INTROSPECT  :: "org.freedesktop.DBus.Introspectable"
REGISTRY_NAME     :: "org.a11y.atspi.Registry"

// ATSPI_VERSION is the protocol version this bridge reports.
ATSPI_VERSION :: "2.1"

// APP_ID is the id of the application object: never a real node's.
APP_ID :: u64(0)

// ACTION_CLICK is the one action an object has today: the press it would
// have had from a pointer. AT-SPI calls actions by name, and "click" is the
// name readers look for.
ACTION_CLICK :: "click"

// Node is one accessible object, as the toolkit sees it. `extents` is
// x, y, width, height in its **window's** coordinates, and `origin` is where
// that window is on screen when the desktop says (Wayland does not tell a
// toplevel, so `origin_known` is often false and screen coordinates are then
// the window's own — the best a client can do).
Node :: struct {
	id:           u64,
	parent:       u64,
	index:        int, // its place among its parent's children (-1 unknown)
	child_count:  int,
	role:         Role,
	name:         string,
	describe:     string,
	states:       States,
	extents:      [4]i32,
	origin:       [2]i32,
	origin_known: bool,
	// what it is worth: a slider, a spin button, a progress bar. A reader
	// says "40 percent" from these.
	has_value:               bool,
	value, value_min, value_max: f64,
	value_step:              f64, // how much one step moves it (0: unknown)
	value_text:              string, // the value as it is read ("3:25", "40 %"); "" says the number is enough
	// whether it holds text a reader can read character by character (an
	// entry, an editor): `Provider.text` is asked for the text itself.
	has_text:                bool,
	// …and whether a reader may type into it. A read-only editor holds text
	// and is not editable, which is exactly the distinction a reader needs.
	editable:                bool,
	// whether pressing it does something — a button, a checkbox, a menu
	// item — so a reader can offer to press it.
	has_action:              bool,
	// whether it holds a selection a reader can read (a list, a tree, a
	// table): the selected children are the ones whose state says so.
	has_selection:           bool,
}

// Text_Info is what an object holding text answers with. Offsets are
// **bytes** into `text`, the way a toolkit keeps them; the bridge converts
// to the character offsets AT-SPI speaks in.
Text_Info :: struct {
	text:     string,
	caret:    int, // byte offset of the caret (-1: it has none just now)
	sel_lo:   int, // the selection, in bytes; equal when nothing is selected
	sel_hi:   int,
	editable: bool,
}

// Clip_Act is one of the clipboard actions AT-SPI's EditableText offers.
Clip_Act :: enum u8 { Cut, Copy, Paste }

// Granularity is what AT-SPI asks for a piece of text by
// (ATSPI_TEXT_GRANULARITY).
Granularity :: enum u32 {
	Char      = 0,
	Word      = 1,
	Sentence  = 2,
	Line      = 3,
	Paragraph = 4,
}

// Boundary is the older spelling of the same question
// (ATSPI_TEXT_BOUNDARY_TYPE), which readers still use.
Boundary :: enum u32 {
	Char           = 0,
	Word_Start     = 1,
	Word_End       = 2,
	Sentence_Start = 3,
	Sentence_End   = 4,
	Line_Start     = 5,
	Line_End       = 6,
}

// Provider is what the toolkit fills in. Every call happens on the thread
// that pumps the bridge, between frames, so it may read the toolkit's state
// directly. Strings may point at the toolkit's own storage: they are copied
// before they leave.
Provider :: struct {
	user: rawptr,
	// node describes one object. False for an id that is gone — the bridge
	// answers such calls with a defunct object rather than an error.
	node: proc(user: rawptr, id: u64) -> (Node, bool),
	// child is the id of the `index`th child of `id`.
	child: proc(user: rawptr, id: u64, index: int) -> (u64, bool),
	// do_action activates an object — the press a button would have had.
	// False when it cannot be acted on, or when the toolkit is not in a
	// position to (a test harness, a window that has gone).
	do_action: proc(user: rawptr, id: u64) -> bool,
	// grab_focus moves the keyboard focus to an object, which is how a
	// reader hands someone what they just picked out of the tree.
	grab_focus: proc(user: rawptr, id: u64) -> bool,
	// edit replaces the text of an object between two **byte** offsets — the
	// same path typing takes, so an editor's undo grouping and any
	// composition in flight stay consistent. False when the object cannot be
	// edited, or when there is no way to act on it.
	edit: proc(user: rawptr, id: u64, from, to: int, text: string) -> bool,
	// clip does one of the clipboard actions on an object holding text,
	// exactly as its own shortcut would.
	clip: proc(user: rawptr, id: u64, act: Clip_Act) -> bool,
	// select_range puts the selection of an object holding text between two
	// **byte** offsets, so an action that works on a selection (cut, copy)
	// works on what the reader asked for.
	select_range: proc(user: rawptr, id: u64, from, to: int) -> bool,
	// set_caret moves the caret of an object holding text, in **bytes**
	// (the bridge converts from the character offsets AT-SPI speaks in).
	set_caret: proc(user: rawptr, id: u64, byte_off: int) -> bool,
	// text describes an object that holds text — its content, caret and
	// selection — and is asked only of a node whose `has_text` is set.
	text: proc(user: rawptr, id: u64) -> (Text_Info, bool),
	// app_name is what the application is called ("Notes"), and toolkit_name
	// what drew it ("Baldr").
	app_name:     proc(user: rawptr) -> string,
	toolkit_name: proc(user: rawptr) -> string,
	version:      proc(user: rawptr) -> string,
}

// path_of is the object path of `id`.
path_of :: proc(id: u64, allocator := context.temp_allocator) -> string {
	if id == APP_ID do return ROOT_PATH
	b := strings.builder_make(allocator)
	strings.write_string(&b, PATH_PREFIX)
	strings.write_u64(&b, id)
	return strings.to_string(b)
}

// id_of reads an object path back. False for a path that is not ours.
id_of :: proc(path: string) -> (u64, bool) {
	if path == ROOT_PATH do return APP_ID, true
	if !strings.has_prefix(path, PATH_PREFIX) do return 0, false
	rest := path[len(PATH_PREFIX):]
	if len(rest) == 0 do return 0, false
	id: u64
	for c in transmute([]u8)rest {
		if c < '0' || c > '9' do return 0, false
		id = id * 10 + u64(c - '0')
	}
	return id, true
}
