#+build linux
// libxcb, loaded at runtime with core:dynlib — nothing is linked at build
// time, as the dependency rule requires.
//
// libxcb rather than our own X protocol code: `VK_KHR_xcb_surface` takes a
// real `xcb_connection_t*` and the driver uses it, so a hand-rolled
// connection could open a window but never show a Vulkan image in it.
//
// Only what the backend uses is bound, grouped by request rather than
// alphabetically. The types are the wire structs: X is a fixed-layout
// protocol, so they do not drift.
package x11

import "core:c"
import "core:c/libc"
import "core:dynlib"

Connection :: distinct rawptr

Window    :: distinct u32
Colormap  :: distinct u32
Visual_Id :: distinct u32
Atom      :: distinct u32
Pixmap    :: distinct u32
Gcontext  :: distinct u32
Font      :: distinct u32
Cursor_Id :: distinct u32
Timestamp :: distinct u32
Keycode   :: distinct u8

ATOM_NONE :: Atom(0)
WINDOW_NONE :: Window(0)
COPY_FROM_PARENT :: 0
WINDOW_CLASS_INPUT_ONLY :: 2
CURRENT_TIME :: Timestamp(0)

// Generic_Event is the head every event shares. `response_type`'s low 7
// bits are the event number; the top bit says it was sent by another client
// with SendEvent, which the backend does not distinguish.
Generic_Event :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	pad:           [7]u32,
	full_sequence: u32,
}

Generic_Error :: struct {
	response_type: u8,
	error_code:    u8,
	sequence:      u16,
	resource_id:   u32,
	minor_code:    u16,
	major_code:    u8,
	pad0:          u8,
	pad:           [5]u32,
	full_sequence: u32,
}

// A cookie is a request's sequence number, handed back to the _reply call.
Void_Cookie       :: struct { sequence: c.uint }
Intern_Atom_Cookie :: struct { sequence: c.uint }

Get_Selection_Owner_Cookie :: struct { sequence: c.uint }
Get_Selection_Owner_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	owner:         Window,
}

Translate_Coordinates_Cookie :: struct { sequence: c.uint }
Translate_Coordinates_Reply :: struct {
	response_type: u8,
	same_screen:   u8,
	sequence:      u16,
	length:        u32,
	child:         Window,
	dst_x, dst_y:  i16,
}

Query_Pointer_Cookie :: struct { sequence: c.uint }
Query_Pointer_Reply :: struct {
	response_type:  u8,
	same_screen:    u8,
	sequence:       u16,
	length:         u32,
	root:           Window,
	child:          Window, // the child the pointer is in, or none: walking these is how a target is found
	root_x, root_y: i16,
	win_x, win_y:   i16,
	mask:           u16,
	pad0:           [2]u8,
}

Grab_Pointer_Cookie :: struct { sequence: c.uint }
Grab_Pointer_Reply :: struct {
	response_type: u8,
	status:        u8, // 0 = success
	sequence:      u16,
	length:        u32,
}

GRAB_MODE_ASYNC :: 1

Query_Extension_Cookie :: struct { sequence: c.uint }
Query_Extension_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	present:       u8,
	major_opcode:  u8,
	first_event:   u8,
	first_error:   u8,
}

Get_Atom_Name_Cookie :: struct { sequence: c.uint }
Get_Atom_Name_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	name_len:      u16,
	pad1:          [22]u8,
}

Get_Property_Cookie :: struct { sequence: c.uint }

Get_Property_Reply :: struct {
	response_type: u8,
	format:        u8, // bits per item: 8, 16 or 32
	sequence:      u16,
	length:        u32,
	type:          Atom,
	bytes_after:   u32, // more than we asked for is waiting
	value_len:     u32, // items, not bytes
	pad0:          [12]u8,
}

Intern_Atom_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	atom:          Atom,
}

Setup :: struct {
	status:                     u8,
	pad0:                       u8,
	protocol_major_version:     u16,
	protocol_minor_version:     u16,
	length:                     u16,
	release_number:             u32,
	resource_id_base:           u32,
	resource_id_mask:           u32,
	motion_buffer_size:         u32,
	vendor_len:                 u16,
	maximum_request_length:     u16,
	roots_len:                  u8,
	pixmap_formats_len:         u8,
	image_byte_order:           u8,
	bitmap_format_bit_order:    u8,
	bitmap_format_scanline_unit: u8,
	bitmap_format_scanline_pad: u8,
	min_keycode:                Keycode,
	max_keycode:                Keycode,
	pad1:                       [4]u8,
}

Screen :: struct {
	root:                  Window,
	default_colormap:      Colormap,
	white_pixel:           u32,
	black_pixel:           u32,
	current_input_masks:   u32,
	width_in_pixels:       u16,
	height_in_pixels:      u16,
	width_in_millimeters:  u16,
	height_in_millimeters: u16,
	min_installed_maps:    u16,
	max_installed_maps:    u16,
	root_visual:           Visual_Id,
	backing_stores:        u8,
	save_unders:           u8,
	root_depth:            u8,
	allowed_depths_len:    u8,
}

Screen_Iterator :: struct {
	data:  ^Screen,
	rem:   c.int,
	index: c.int,
}

// ------------------------------------------------------------ the events

// The event numbers the backend acts on. X numbers them from 2; anything
// not here is dropped.
KEY_PRESS        :: 2
KEY_RELEASE      :: 3
BUTTON_PRESS     :: 4
BUTTON_RELEASE   :: 5
MOTION_NOTIFY    :: 6
ENTER_NOTIFY     :: 7
LEAVE_NOTIFY     :: 8
FOCUS_IN         :: 9
FOCUS_OUT        :: 10
EXPOSE           :: 12
SELECTION_CLEAR   :: 29
SELECTION_REQUEST :: 30
SELECTION_NOTIFY  :: 31
DESTROY_NOTIFY   :: 17
UNMAP_NOTIFY     :: 18
MAP_NOTIFY       :: 19
CONFIGURE_NOTIFY :: 22
PROPERTY_NOTIFY  :: 28
CLIENT_MESSAGE   :: 33

// Input_Event is the shape KeyPress, KeyRelease, ButtonPress,
// ButtonRelease and MotionNotify all share. `detail` is the keycode or the
// button; `state` is the modifiers *before* this event, which is why a
// press of Shift itself does not show Shift set.
Input_Event :: struct {
	response_type: u8,
	detail:        u8,
	sequence:      u16,
	time:          Timestamp,
	root:          Window,
	event:         Window,
	child:         Window,
	root_x, root_y:   i16,
	event_x, event_y: i16,
	state:         u16,
	same_screen:   u8,
	pad0:          u8,
}

// Crossing_Event is EnterNotify and LeaveNotify. `mode` tells a real
// crossing from one a grab caused, which must not read as the pointer
// leaving.
Crossing_Event :: struct {
	response_type: u8,
	detail:        u8,
	sequence:      u16,
	time:          Timestamp,
	root:          Window,
	event:         Window,
	child:         Window,
	root_x, root_y:   i16,
	event_x, event_y: i16,
	state:         u16,
	mode:          u8,
	same_screen_focus: u8,
}

Focus_Event :: struct {
	response_type: u8,
	detail:        u8,
	sequence:      u16,
	event:         Window,
	mode:          u8,
	pad0:          [3]u8,
}

// NOTIFY_MODE_NORMAL is a crossing or focus change that really happened;
// the others are a grab taking the pointer or keyboard and giving it back.
NOTIFY_MODE_NORMAL :: 0
NOTIFY_MODE_GRAB   :: 1
NOTIFY_MODE_UNGRAB :: 2

// The modifier bits in an input event's `state` (KeyButMask).
MOD_SHIFT   :: 1 << 0
MOD_LOCK    :: 1 << 1 // Caps Lock
MOD_CONTROL :: 1 << 2
MOD_1       :: 1 << 3 // Alt, by convention
MOD_2       :: 1 << 4 // Num Lock, by convention
MOD_4       :: 1 << 6 // Super, by convention

// X has no scroll axis: the wheel is buttons 4 to 7.
BUTTON_WHEEL_UP    :: 4
BUTTON_WHEEL_DOWN  :: 5
BUTTON_WHEEL_LEFT  :: 6
BUTTON_WHEEL_RIGHT :: 7
BUTTON_BACK        :: 8
BUTTON_FORWARD     :: 9

Expose_Event :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	window:        Window,
	x, y, width, height: u16,
	count:         u16,
	pad1:          [2]u8,
}

Configure_Notify_Event :: struct {
	response_type:     u8,
	pad0:              u8,
	sequence:          u16,
	event:             Window,
	window:            Window,
	above_sibling:     Window,
	x, y:              i16,
	width, height:     u16,
	border_width:      u16,
	override_redirect: u8,
	pad1:              u8,
}

Map_Notify_Event :: struct {
	response_type:     u8,
	pad0:              u8,
	sequence:          u16,
	event:             Window,
	window:            Window,
	override_redirect: u8,
	pad1:              [3]u8,
}

// The three selection events. A selection is an owner window, not a buffer
// the server holds; every paste is a conversation between two clients.
Selection_Clear_Event :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	time:          Timestamp,
	owner:         Window,
	selection:     Atom,
}

Selection_Request_Event :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	time:          Timestamp,
	owner:         Window,
	requestor:     Window,
	selection:     Atom,
	target:        Atom,
	property:      Atom, // ATOM_NONE from an ancient client: reply into `target`
}

Selection_Notify_Event :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	time:          Timestamp,
	requestor:     Window,
	selection:     Atom,
	target:        Atom,
	property:      Atom, // ATOM_NONE means the owner refused
}

Property_Notify_Event :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	window:        Window,
	atom:          Atom,
	time:          Timestamp,
	state:         u8, // 0 = new value, 1 = deleted
	pad1:          [3]u8,
}

// Client_Message_Event carries WM_DELETE_WINDOW, among others. The union is
// the protocol's: 20 bytes read as bytes, shorts or longs by `format`.
Client_Message_Event :: struct {
	response_type: u8,
	format:        u8,
	sequence:      u16,
	window:        Window,
	type:          Atom,
	data:          struct #raw_union {
		data8:  [20]u8,
		data16: [10]u16,
		data32: [5]u32,
	},
}

// ---------------------------------------------------------- request flags

// Window classes for create_window.
WINDOW_CLASS_INPUT_OUTPUT :: 1

// A window with no background at all: the server paints nothing, which is
// what a window whose pixels all come from the GPU wants.
BACK_PIXMAP_NONE :: 0

// Bit gravity: where the old contents go when the window is resized.
// Forget, the default, throws them away and paints the background over
// everything; NorthWest keeps them anchored to the top-left corner.
GRAVITY_NORTH_WEST :: 1

// The CW_* value-mask bits, in the order create_window expects its list.
CW_BACK_PIXMAP      :: 0x00000001
CW_BACK_PIXEL       :: 0x00000002
CW_BIT_GRAVITY      :: 0x00000010
CW_BORDER_PIXEL     :: 0x00000008
CW_OVERRIDE_REDIRECT :: 0x00000200
CW_EVENT_MASK       :: 0x00000800
CW_CURSOR           :: 0x00004000
CW_COLORMAP         :: 0x00002000

// The event mask: what the server should send us.
EVENT_MASK_KEY_PRESS       :: 0x00000001
EVENT_MASK_KEY_RELEASE     :: 0x00000002
EVENT_MASK_BUTTON_PRESS    :: 0x00000004
EVENT_MASK_BUTTON_RELEASE  :: 0x00000008
EVENT_MASK_ENTER_WINDOW    :: 0x00000010
EVENT_MASK_LEAVE_WINDOW    :: 0x00000020
EVENT_MASK_POINTER_MOTION  :: 0x00000040
EVENT_MASK_EXPOSURE        :: 0x00008000
EVENT_MASK_STRUCTURE_NOTIFY :: 0x00020000
EVENT_MASK_FOCUS_CHANGE    :: 0x00200000
EVENT_MASK_PROPERTY_CHANGE :: 0x00400000
// A message to the root window asking the window manager for something
// (EWMH) goes with these two set.
EVENT_MASK_SUBSTRUCTURE_NOTIFY   :: 0x00080000
EVENT_MASK_SUBSTRUCTURE_REDIRECT :: 0x00100000

// _NET_WM_STATE actions.
NET_WM_STATE_REMOVE :: 0
NET_WM_STATE_ADD    :: 1
NET_WM_STATE_TOGGLE :: 2

// CONFIG_WINDOW_* for configure_window, again in list order.
CONFIG_WINDOW_X      :: 0x0001
CONFIG_WINDOW_Y      :: 0x0002
CONFIG_WINDOW_WIDTH  :: 0x0004
CONFIG_WINDOW_HEIGHT :: 0x0008

// put_image's format: the pixels are laid out as the drawable is.
IMAGE_FORMAT_Z_PIXMAP :: 2

PROP_MODE_REPLACE :: 0
PROP_MODE_APPEND  :: 2

// A PropertyNotify says which of the two happened.
PROPERTY_NEW_VALUE :: 0
PROPERTY_DELETE    :: 1

// The predefined atoms the backend needs by number (Xatom.h).
ATOM_ATOM     :: Atom(4)
ATOM_RESOURCE_MANAGER :: Atom(23)
ATOM_PRIMARY  :: Atom(1)
ATOM_CARDINAL :: Atom(6)
ATOM_WINDOW   :: Atom(33)
ATOM_WM_TRANSIENT_FOR :: Atom(68)
ATOM_STRING   :: Atom(31)
ATOM_WM_NAME  :: Atom(39)
ATOM_WM_NORMAL_HINTS :: Atom(40)
ATOM_WM_SIZE_HINTS   :: Atom(41)

// ---------------------------------------------------------------- the API

// Api is the subset of libxcb the backend calls. Filled once by `load`;
// a global, as the Wayland binding's is, because a dlopened library's
// symbol table is process-wide and fixed after loading.
Api :: struct {
	connect:             proc "c" (display: cstring, screen: ^c.int) -> Connection,
	disconnect:          proc "c" (conn: Connection),
	connection_has_error: proc "c" (conn: Connection) -> c.int,
	get_setup:           proc "c" (conn: Connection) -> ^Setup,
	setup_roots_iterator: proc "c" (s: ^Setup) -> Screen_Iterator,
	screen_next:         proc "c" (i: ^Screen_Iterator),
	generate_id:         proc "c" (conn: Connection) -> u32,
	get_file_descriptor: proc "c" (conn: Connection) -> c.int,
	flush:               proc "c" (conn: Connection) -> c.int,

	create_window: proc "c" (conn: Connection, depth: u8, wid: Window, parent: Window,
		x, y: i16, width, height, border_width: u16, class: u16, visual: Visual_Id,
		value_mask: u32, value_list: [^]u32) -> Void_Cookie,
	destroy_window: proc "c" (conn: Connection, w: Window) -> Void_Cookie,
	map_window:     proc "c" (conn: Connection, w: Window) -> Void_Cookie,
	unmap_window:   proc "c" (conn: Connection, w: Window) -> Void_Cookie,
	configure_window: proc "c" (conn: Connection, w: Window, value_mask: u16, value_list: [^]u32) -> Void_Cookie,
	change_window_attributes: proc "c" (conn: Connection, w: Window, value_mask: u32, value_list: [^]u32) -> Void_Cookie,

	// An empty 1x1 cursor is how the pointer is hidden: X has no "no
	// cursor" beyond inheriting the parent's.
	create_pixmap: proc "c" (conn: Connection, depth: u8, pid: Pixmap, drawable: Window, width, height: u16) -> Void_Cookie,
	// The core "cursor" font: the shapes X had before themes, and the only
	// ones guaranteed to exist.
	open_font:           proc "c" (conn: Connection, fid: Font, name_len: u16, name: cstring) -> Void_Cookie,
	close_font:          proc "c" (conn: Connection, font: Font) -> Void_Cookie,
	create_glyph_cursor: proc "c" (conn: Connection, cid: Cursor_Id, source_font, mask_font: Font,
		source_char, mask_char: u16,
		fore_red, fore_green, fore_blue, back_red, back_green, back_blue: u16) -> Void_Cookie,

	// A graphics context and put_image are how pixels get into a pixmap.
	create_gc:  proc "c" (conn: Connection, cid: Gcontext, drawable: Pixmap, value_mask: u32, value_list: [^]u32) -> Void_Cookie,
	free_gc:    proc "c" (conn: Connection, gc: Gcontext) -> Void_Cookie,
	put_image:  proc "c" (conn: Connection, format: u8, drawable: Pixmap, gc: Gcontext,
		width, height: u16, dst_x, dst_y: i16, left_pad, depth: u8, data_len: u32, data: [^]u8) -> Void_Cookie,
	free_pixmap:   proc "c" (conn: Connection, pid: Pixmap) -> Void_Cookie,
	free_cursor:   proc "c" (conn: Connection, cursor: Cursor_Id) -> Void_Cookie,
	create_cursor: proc "c" (conn: Connection, cid: Cursor_Id, source, mask: Pixmap,
		fore_red, fore_green, fore_blue, back_red, back_green, back_blue: u16,
		x, y: u16) -> Void_Cookie,

	change_property: proc "c" (conn: Connection, mode: u8, w: Window, property, type: Atom,
		format: u8, data_len: u32, data: rawptr) -> Void_Cookie,
	intern_atom:       proc "c" (conn: Connection, only_if_exists: u8, name_len: u16, name: cstring) -> Intern_Atom_Cookie,
	intern_atom_reply: proc "c" (conn: Connection, cookie: Intern_Atom_Cookie, e: ^^Generic_Error) -> ^Intern_Atom_Reply,

	// In 4-byte units: the ceiling on one property write. Anything bigger
	// goes through INCR.
	get_maximum_request_length: proc "c" (conn: Connection) -> u32,

	set_selection_owner: proc "c" (conn: Connection, owner: Window, selection: Atom, time: Timestamp) -> Void_Cookie,
	get_selection_owner: proc "c" (conn: Connection, selection: Atom) -> Get_Selection_Owner_Cookie,
	get_selection_owner_reply: proc "c" (conn: Connection, ck: Get_Selection_Owner_Cookie, e: ^^Generic_Error) -> ^Get_Selection_Owner_Reply,
	convert_selection:   proc "c" (conn: Connection, requestor: Window, selection, target, property: Atom, time: Timestamp) -> Void_Cookie,
	delete_property:     proc "c" (conn: Connection, window: Window, property: Atom) -> Void_Cookie,

	// Which major opcode an extension was given: it marks that extension's
	// GenericEvents.
	query_extension:       proc "c" (conn: Connection, name_len: u16, name: cstring) -> Query_Extension_Cookie,
	query_extension_reply: proc "c" (conn: Connection, ck: Query_Extension_Cookie, e: ^^Generic_Error) -> ^Query_Extension_Reply,

	// An atom's name is a MIME type on X: a drag offers atoms, and their
	// names are the strings the toolkit deals in.
	get_atom_name:             proc "c" (conn: Connection, atom: Atom) -> Get_Atom_Name_Cookie,
	get_atom_name_reply:       proc "c" (conn: Connection, ck: Get_Atom_Name_Cookie, e: ^^Generic_Error) -> ^Get_Atom_Name_Reply,
	get_atom_name_name:        proc "c" (r: ^Get_Atom_Name_Reply) -> rawptr,
	get_atom_name_name_length: proc "c" (r: ^Get_Atom_Name_Reply) -> c.int,

	// `long_offset` and `long_length` are in 4-byte units, not bytes.
	get_property: proc "c" (conn: Connection, delete: u8, window: Window, property, type: Atom,
		long_offset, long_length: u32) -> Get_Property_Cookie,
	get_property_reply:        proc "c" (conn: Connection, cookie: Get_Property_Cookie, e: ^^Generic_Error) -> ^Get_Property_Reply,
	get_property_value:        proc "c" (r: ^Get_Property_Reply) -> rawptr,
	get_property_value_length: proc "c" (r: ^Get_Property_Reply) -> c.int,

	// A reparented window's ConfigureNotify is relative to its frame, not
	// the root; this gets the real root position.
	translate_coordinates:       proc "c" (conn: Connection, src, dst: Window, src_x, src_y: i16) -> Translate_Coordinates_Cookie,
	translate_coordinates_reply: proc "c" (conn: Connection, ck: Translate_Coordinates_Cookie, e: ^^Generic_Error) -> ^Translate_Coordinates_Reply,

	warp_pointer: proc "c" (conn: Connection, src, dst: Window, src_x, src_y: i16,
		src_w, src_h: u16, dst_x, dst_y: i16) -> Void_Cookie,

	// A drag needs the pointer wherever it goes, and which window it is over.
	query_pointer:       proc "c" (conn: Connection, window: Window) -> Query_Pointer_Cookie,
	query_pointer_reply: proc "c" (conn: Connection, ck: Query_Pointer_Cookie, e: ^^Generic_Error) -> ^Query_Pointer_Reply,
	grab_pointer:        proc "c" (conn: Connection, owner_events: u8, grab_window: Window, event_mask: u16,
		pointer_mode, keyboard_mode: u8, confine_to: Window, cursor: Cursor_Id, time: Timestamp) -> Grab_Pointer_Cookie,
	grab_pointer_reply:  proc "c" (conn: Connection, ck: Grab_Pointer_Cookie, e: ^^Generic_Error) -> ^Grab_Pointer_Reply,
	ungrab_pointer:      proc "c" (conn: Connection, time: Timestamp) -> Void_Cookie,

	// send_event posts an event to a window as if the server had sent it:
	// how WM_DELETE_WINDOW arrives, and how a client asks the window manager
	// for anything in _NET_WM.
	send_event: proc "c" (conn: Connection, propagate: u8, destination: Window, event_mask: u32, event: rawptr) -> Void_Cookie,

	poll_for_event: proc "c" (conn: Connection) -> ^Generic_Event,
	wait_for_event: proc "c" (conn: Connection) -> ^Generic_Event,
}

api: Api
@(private) lib: dynlib.Library
@(private) loaded: bool

// load dlopens libxcb and fills `api`. Safe to call more than once. False
// (with `missing`, temp-allocated) when the library or a symbol is absent —
// i.e. not an X system.
load :: proc() -> (ok: bool, missing: []string) {
	if loaded do return true, nil
	l, lok := dynlib.load_library("libxcb.so.1")
	if !lok {
		m := make([]string, 1, context.temp_allocator)
		m[0] = "libxcb.so.1"
		return false, m
	}
	lib = l
	miss := make([dynamic]string, context.temp_allocator)
	a := &api
	a.connect              = sym("xcb_connect",              type_of(a.connect), &miss)
	a.disconnect           = sym("xcb_disconnect",           type_of(a.disconnect), &miss)
	a.connection_has_error = sym("xcb_connection_has_error", type_of(a.connection_has_error), &miss)
	a.get_setup            = sym("xcb_get_setup",            type_of(a.get_setup), &miss)
	a.setup_roots_iterator = sym("xcb_setup_roots_iterator", type_of(a.setup_roots_iterator), &miss)
	a.screen_next          = sym("xcb_screen_next",          type_of(a.screen_next), &miss)
	a.generate_id          = sym("xcb_generate_id",          type_of(a.generate_id), &miss)
	a.get_file_descriptor  = sym("xcb_get_file_descriptor",  type_of(a.get_file_descriptor), &miss)
	a.flush                = sym("xcb_flush",                type_of(a.flush), &miss)
	a.create_window        = sym("xcb_create_window",        type_of(a.create_window), &miss)
	a.destroy_window       = sym("xcb_destroy_window",       type_of(a.destroy_window), &miss)
	a.map_window           = sym("xcb_map_window",           type_of(a.map_window), &miss)
	a.unmap_window         = sym("xcb_unmap_window",         type_of(a.unmap_window), &miss)
	a.configure_window     = sym("xcb_configure_window",     type_of(a.configure_window), &miss)
	a.change_window_attributes = sym("xcb_change_window_attributes", type_of(a.change_window_attributes), &miss)
	a.create_pixmap        = sym("xcb_create_pixmap",        type_of(a.create_pixmap), &miss)
	a.open_font            = sym("xcb_open_font",            type_of(a.open_font), &miss)
	a.close_font           = sym("xcb_close_font",           type_of(a.close_font), &miss)
	a.create_glyph_cursor  = sym("xcb_create_glyph_cursor",  type_of(a.create_glyph_cursor), &miss)
	a.create_gc            = sym("xcb_create_gc",            type_of(a.create_gc), &miss)
	a.free_gc              = sym("xcb_free_gc",              type_of(a.free_gc), &miss)
	a.put_image            = sym("xcb_put_image",            type_of(a.put_image), &miss)
	a.free_pixmap          = sym("xcb_free_pixmap",          type_of(a.free_pixmap), &miss)
	a.free_cursor          = sym("xcb_free_cursor",          type_of(a.free_cursor), &miss)
	a.create_cursor        = sym("xcb_create_cursor",        type_of(a.create_cursor), &miss)
	a.change_property      = sym("xcb_change_property",      type_of(a.change_property), &miss)
	a.intern_atom          = sym("xcb_intern_atom",          type_of(a.intern_atom), &miss)
	a.intern_atom_reply    = sym("xcb_intern_atom_reply",    type_of(a.intern_atom_reply), &miss)
	a.get_maximum_request_length = sym("xcb_get_maximum_request_length", type_of(a.get_maximum_request_length), &miss)
	a.set_selection_owner  = sym("xcb_set_selection_owner",  type_of(a.set_selection_owner), &miss)
	a.get_selection_owner  = sym("xcb_get_selection_owner",  type_of(a.get_selection_owner), &miss)
	a.get_selection_owner_reply = sym("xcb_get_selection_owner_reply", type_of(a.get_selection_owner_reply), &miss)
	a.convert_selection    = sym("xcb_convert_selection",    type_of(a.convert_selection), &miss)
	a.delete_property      = sym("xcb_delete_property",      type_of(a.delete_property), &miss)
	a.query_extension       = sym("xcb_query_extension",       type_of(a.query_extension), &miss)
	a.query_extension_reply = sym("xcb_query_extension_reply", type_of(a.query_extension_reply), &miss)
	a.get_atom_name             = sym("xcb_get_atom_name",             type_of(a.get_atom_name), &miss)
	a.get_atom_name_reply       = sym("xcb_get_atom_name_reply",       type_of(a.get_atom_name_reply), &miss)
	a.get_atom_name_name        = sym("xcb_get_atom_name_name",        type_of(a.get_atom_name_name), &miss)
	a.get_atom_name_name_length = sym("xcb_get_atom_name_name_length", type_of(a.get_atom_name_name_length), &miss)
	a.get_property         = sym("xcb_get_property",         type_of(a.get_property), &miss)
	a.get_property_reply   = sym("xcb_get_property_reply",   type_of(a.get_property_reply), &miss)
	a.get_property_value   = sym("xcb_get_property_value",   type_of(a.get_property_value), &miss)
	a.get_property_value_length = sym("xcb_get_property_value_length", type_of(a.get_property_value_length), &miss)
	a.translate_coordinates       = sym("xcb_translate_coordinates",       type_of(a.translate_coordinates), &miss)
	a.translate_coordinates_reply = sym("xcb_translate_coordinates_reply", type_of(a.translate_coordinates_reply), &miss)
	a.warp_pointer         = sym("xcb_warp_pointer",         type_of(a.warp_pointer), &miss)
	a.query_pointer        = sym("xcb_query_pointer",        type_of(a.query_pointer), &miss)
	a.query_pointer_reply  = sym("xcb_query_pointer_reply",  type_of(a.query_pointer_reply), &miss)
	a.grab_pointer         = sym("xcb_grab_pointer",         type_of(a.grab_pointer), &miss)
	a.grab_pointer_reply   = sym("xcb_grab_pointer_reply",   type_of(a.grab_pointer_reply), &miss)
	a.ungrab_pointer       = sym("xcb_ungrab_pointer",       type_of(a.ungrab_pointer), &miss)
	a.send_event           = sym("xcb_send_event",           type_of(a.send_event), &miss)
	a.poll_for_event       = sym("xcb_poll_for_event",       type_of(a.poll_for_event), &miss)
	a.wait_for_event       = sym("xcb_wait_for_event",       type_of(a.wait_for_event), &miss)
	if len(miss) > 0 {
		dynlib.unload_library(lib)
		lib = nil
		return false, miss[:]
	}
	loaded = true
	return true, nil
}

// unload drops the library. Only for a backend that failed to start: the
// connection must be gone first.
unload :: proc() {
	if lib == nil do return
	dynlib.unload_library(lib)
	lib = nil
	loaded = false
	api = {}
}

// free_reply gives a reply or an event back to the allocator libxcb took it
// from, which is libc's, not Odin's.
//
// Every `*_reply` and every event from poll_for_event / wait_for_event is
// `malloc`ed inside libxcb and is the caller's to free. Odin's `free` would
// hand it to the context allocator, corrupting the heap with a crash far
// from the cause.
free_reply :: proc "contextless" (p: rawptr) {
	if p != nil do libc.free(p)
}

@(private)
sym :: proc($name: string, $T: typeid, miss: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(lib, name)
	if !ok {
		append(miss, name)
		return nil
	}
	return (T)(p)
}
