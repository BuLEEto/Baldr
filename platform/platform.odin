// Package platform is the OS backend contract: one struct of proc pointers
// that each backend (wayland, x11, win32, cocoa) fills, and the Event values
// they produce. The toolkit only ever calls through Backend; backends never
// call the toolkit. Everything is in logical pixels except `size_px`.
//
// Backend selection happens above this package (baldr/app.odin) because a
// backend imports this package for the types; importing backends from here
// would be a cycle.
package platform

import "base:runtime"
import "core:math"
import "core:sync"
import vk "vendor:vulkan"

// Surface is a backend-owned window / layer / lock surface. 0 = none.
Surface :: distinct u32

Surface_Kind :: enum u8 {
	Window, // an ordinary toplevel
	Layer,  // desktop-shell surface (panel, dock, wallpaper); Wayland layer-shell
	Lock,   // session-lock surface (one per output)
	Applet, // a surface inside a desktop shell's bar, at a slot the shell reserved (the compositor's rikkiti-applet-v1)
}

Layer_Level :: enum u8 { Background, Bottom, Top, Overlay }
Edge :: enum u8 { Top, Bottom, Left, Right }
Keyboard_Interactivity :: enum u8 { None, Exclusive, On_Demand }

Layer_Desc :: struct {
	level:          Layer_Level,
	anchor:         bit_set[Edge; u8],
	exclusive_zone: i32,
	keyboard:       Keyboard_Interactivity,
	margin:         [4]i32, // top, right, bottom, left
	output:         string, // "" = compositor's choice
	exclusive_edge: bit_set[Edge; u8], // one edge the exclusive zone is on when the anchors leave it open (a corner); empty = the compositor infers it (layer-shell v5)
	keyboard_landing: Keyboard_Landing, // where focus goes when it is given the keyboard with nothing focused
}

// Keyboard_Landing: where focus goes when a panel is handed the keyboard
// with nothing focused and no press to say where. `First_Control` (the
// default) rings the first control, which suits a bar. `Nothing` leaves focus
// alone, for a full-screen overlay whose keys are its own: ringing a button
// there would make Enter press it. Tab still reaches the controls. It is on
// Layer_Desc only: an applet is bar-like and always lands on its first
// control.
Keyboard_Landing :: enum u8 { First_Control, Nothing }

// Applet_Desc: how an applet surface binds to its slot. `token` is the one
// the shell started the applet with ("" = RIKKITI_APPLET_TOKEN); `keyboard`
// says whether a click gives it the keyboard.
Applet_Desc :: struct {
	token:    string,
	keyboard: Applet_Keyboard,
}

// Applet_Keyboard: On_Demand (the default) takes the keyboard when clicked;
// None never does, and hands it back while it has it (Escape in a field).
Applet_Keyboard :: enum u8 { On_Demand, None }

// Locale: how the user's desktop writes dates, times and numbers, and
// what it calls the months and days. Backends read it from the OS (libc
// on Linux, the system locale on Windows and macOS) once at init; the
// toolkit's widgets consult it, and an app may override it. Strings are
// owned by the backend for its lifetime.
Locale :: struct {
	tag:            string,     // "en_GB", "de_DE", "" when unknown
	months:         [12]string, // January …
	months_short:   [12]string, // Jan …
	weekdays:       [7]string,  // Sunday first
	weekdays_short: [7]string,
	first_weekday:  u8,         // 0 = Sunday, 1 = Monday, 6 = Saturday
	date_format:    string,     // strftime-style: %d %e %m %b %B %y %Y and separators ("%d/%m/%Y")
	time_24h:       bool,
	am, pm:         string,
	decimal:        string,     // "." or ","
	thousands:      string,     // "," "." " " or ""
}

// LOCALE_EN is the fallback: English names, ISO-ish dates, a point.
LOCALE_EN :: Locale{
	tag = "en",
	months = {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"},
	months_short = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"},
	weekdays = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"},
	weekdays_short = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"},
	first_weekday = 1,
	date_format = "%d/%m/%Y",
	time_24h = true,
	am = "AM", pm = "PM",
	decimal = ".", thousands = ",",
}

// File dialogs: the desktop's own open / save dialog, asked for by the
// toolkit's open_files / save_file commands. The backend shows it and
// later emits one Ev_Files carrying the request's `token`.
File_Filter :: struct {
	name:     string,
	patterns: []string, // globs ("*.png") or MIME types when `mime`
	mime:     bool,
}
File_Dialog :: struct {
	token:         u64,
	save:          bool,
	title:         string,
	accept_label:  string,
	current_folder: string, // absolute path to start in ("" = the desktop's choice)
	current_name:  string,  // save: suggested file name
	multiple:      bool,    // open: more than one file
	directory:     bool,    // open: pick folders
	filters:       []File_Filter,
}

// Backdrop: what the compositor does behind a transparent surface, and
// whether it says how bright it is. Blur needs Cap.Backdrop_Blur; the
// toolkit falls back to an opaque theme surface when it is missing, never to
// an unreadable see-through one.
//
// Measure asks for no effect behind the surface, only the brightness reports
// a blurred one gets (Ev_Backdrop, Cap.Backdrop_Luminance), for text drawn
// straight on the desktop. A blurred surface is measured as glass sees it, a
// Measure one as it shows: a blur hides the letter-sized contrast that
// decides whether text reads.
Backdrop :: enum u8 { None, Blur, Measure }

// Cap: what this backend and its compositor can do, filled by init. The
// toolkit degrades: a .Layer without Layer_Shell becomes an undecorated
// window, a Blur backdrop without Backdrop_Blur becomes opaque.
// Backdrop_Luminance: the compositor reports how bright the backdrop behind
// each blurred surface — and each surface that asked with Backdrop.Measure —
// is (Ev_Backdrop), so glass needs no worst-case tint and text on the
// desktop can read what is behind it.
// Applets: a .Applet surface can be shown inside a shell's bar.
// Toplevels / Workspaces: the desktop lists its windows / workspaces and
// takes requests about them (Backend.toplevels, Backend.workspaces).
// Applet_Slots: a .Layer surface can reserve slots for other programs'
// applets (Backend.slot_create).
Cap :: enum u8 { Transparent, Backdrop_Blur, Layer_Shell, Session_Lock, Popups, Backdrop_Luminance, Applets, Toplevels, Workspaces, Applet_Slots }
Caps :: bit_set[Cap; u16]

// Surface_Desc: zero values are the sensible defaults (resizable, decorated,
// opaque, backend-default size).
Surface_Desc :: struct {
	kind:        Surface_Kind,
	title:       string,
	app_id:      string,
	size:        [2]f32, // logical; 0 = backend default
	min_size:    [2]f32,
	max_size:    [2]f32,
	fixed_size:  bool,
	fullscreen:  bool, // opened asking for the whole screen (.Window); the compositor answers in its configure
	maximized:   bool, // opened asking to be maximised (.Window), for a window coming back as it was left; the desktop answers in its configure
	// opened asking to sit here (.Window), in the desktop's own coordinates
	// as `Output.pos` uses them. Honoured at creation only, and a request
	// like `maximized`: nil asks for nothing. Wayland ignores it — a client
	// there has no say in where it goes.
	position:    Maybe([2]i32),
	undecorated: bool, // client draws its own frame (Wayland CSD fallback also lands here)
	transparent: bool, // alpha in the swapchain composites with the desktop
	backdrop:    Backdrop, // ask the compositor to blur what is behind, or only to say how bright it is (transparent only)
	layer:       Layer_Desc,
	applet:      Applet_Desc, // .Applet only
	output:      string,      // .Lock: the screen it covers (Output.name)
	icon:        Window_Icon, // the window's icon where the backend sets one (Windows, X11); empty: the desktop's default
	parent:      Surface,     // .Window: the window this one belongs to (kept above it), 0 none; macOS keeps its windows independent
}

// Window_Icon is a window's icon as straight-alpha ARGB words (0xAARRGGBB),
// rows top to bottom; `argb` is the caller's and only read during the call.
Window_Icon :: struct {
	w, h: int,
	argb: []u32,
}

Mouse_Button :: enum u8 { Left, Right, Middle, Back, Forward }

Mod :: enum u8 { Shift, Ctrl, Alt, Super, Caps_Lock, Num_Lock }
Mods :: bit_set[Mod; u8]

// Key is the portable physical-ish key. `Ev_Key.native` carries the
// platform code (xkb keysym / Win32 VK / macOS keycode) for anything else.
Key :: enum u16 {
	Unknown,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	N0, N1, N2, N3, N4, N5, N6, N7, N8, N9,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24,
	Escape, Enter, Tab, Backspace, Space,
	Left, Right, Up, Down, Home, End, Page_Up, Page_Down, Insert, Delete,
	Shift_L, Shift_R, Ctrl_L, Ctrl_R, Alt_L, Alt_R, Super_L, Super_R,
	Caps_Lock, Num_Lock, Scroll_Lock, Print, Pause, Menu,
	Minus, Equal, Bracket_L, Bracket_R, Backslash, Semicolon, Apostrophe, Grave, Comma, Period, Slash,
	KP_0, KP_1, KP_2, KP_3, KP_4, KP_5, KP_6, KP_7, KP_8, KP_9,
	KP_Decimal, KP_Divide, KP_Multiply, KP_Subtract, KP_Add, KP_Enter, KP_Equal,
	// The keys a laptop has beyond the typewriter: desktops bind these by
	// default, so anything that shows or rebinds a shortcut has to be able
	// to name them.
	Volume_Up, Volume_Down, Volume_Mute, Mic_Mute,
	Media_Play, Media_Pause, Media_Play_Pause, Media_Stop, Media_Prev, Media_Next,
	Media_Rewind, Media_Forward, Media_Record,
	Brightness_Up, Brightness_Down, Kbd_Brightness_Up, Kbd_Brightness_Down,
	Power, Sleep, Wake, Eject,
	Search, Home_Page, Mail, Calculator, Explorer, Favorites, Tools, Refresh,
	Browser_Back, Browser_Forward,
	Display_Switch, Touchpad_Toggle, Wlan, Bluetooth, Rf_Kill,
}

Cursor :: enum u8 {
	Default, Pointer, Text, Crosshair, Move, Not_Allowed, Grab, Grabbing,
	Resize_NS, Resize_EW, Resize_NESW, Resize_NWSE, Wait, Progress, Help, Hidden,
	Picture, // the picture surface_set_cursor_image gave
}

// Events. Strings inside events are owned by the backend and valid until the
// next pump; clone to keep.
Event :: union {
	Ev_Configure,
	Ev_Close,
	Ev_Popup_Configure,
	Ev_Popup_Done,
	Ev_Backdrop,
	Ev_Backdrop_Map,
	Ev_Focus,
	Ev_Redraw,
	Ev_Pointer_Enter,
	Ev_Pointer_Leave,
	Ev_Pointer_Motion,
	Ev_Pointer_Button,
	Ev_Scroll,
	Ev_Touch,
	Ev_Pen,
	Ev_Input_Caps,
	Ev_Caps,
	Ev_Outputs,
	Ev_Surface_Output,
	Ev_Lock,
	Ev_Keyboard,
	Ev_Url,
	Ev_Notify,
	Ev_Tray,
	Ev_Frame,
	Ev_Toplevels,
	Ev_Workspaces,
	Ev_Slot,
	Ev_Key,
	Ev_Text,
	Ev_Ime,
	Ev_Theme,
	Ev_Files,
	Ev_Watch,
	Ev_Drag_Enter,
	Ev_Drag_Motion,
	Ev_Drag_Leave,
	Ev_Drag_Drop,
	Ev_Drag_End,
	Ev_Drag_Data,
	Ev_Quit,
}

// Popup_Placement: the side of its anchor a popup opens on (it flips to the
// other side, and slides along, to stay on the screen); At opens at the
// anchor rect's corner (a context menu at the pointer).
Popup_Placement :: enum u8 { Below, Above, Right, Left, At }

// Popup_Align: where a popup sits along its anchor — its start lined up with
// the anchor's start, its middle over the anchor's middle, or its end with
// the anchor's end (across for Above and Below, down for Left and Right).
Popup_Align :: enum u8 { Start, Center, End }

// Popup_Desc: a popup surface opened from `parent` (a surface, or another
// popup). Its card of `size` logical px goes beside `anchor` (x, y, w, h in
// the parent's card) with `gap` between and `offset` added, inside a surface
// `margin` px larger on every side for its shadow; the card's corners are
// rounded by `radius`, and the input and blur regions follow the card.
// `grab` takes the pointer and keyboard with the latest input event, so a
// press outside dismisses it (a menu); a tooltip takes none. `clear` is room
// kept free around the card on the screen: the compositor keeps the card
// that far from the screen's edges (it lies inside `margin`).
Popup_Desc :: struct {
	parent:    Surface,
	anchor:    [4]f32,
	size:      [2]f32,
	placement: Popup_Placement,
	align:     Popup_Align, // along the anchor: its start, its middle or its end
	gap:       f32,
	offset:    [2]f32,
	margin:    f32,
	clear:     f32,
	radius:    f32,
	grab:      bool,
	backdrop:  Backdrop,
}

// popup_surface_size is the logical size of a popup's surface for a card of
// `card` with `margin` around it for its shadow. The surface never shrinks
// while the popup is open: it keeps the size it has, `current`, where that
// is big enough, and grows with a quarter of the card to spare where not.
// A new size means new buffers, which a compositor has to take in before it
// can show them (a card easing its height between pages would otherwise
// blank on the frames after each); the room past the card is clear, and
// only the card takes input and blur.
popup_surface_size :: proc "contextless" (card: [2]f32, margin: f32, current: [2]f32) -> [2]f32 {
	want := card + 2 * margin
	if current == {} do return want
	size := current
	for i in 0 ..< 2 do if want[i] > current[i] {
		grown := want[i] + card[i] / 4
		size[i] = f32(i32(grown))
		if size[i] < grown do size[i] += 1
	}
	return size
}

// Popup_Positioner is what a backend's positioner gets for a popup: the
// anchor rect in its parent's window geometry (x, y, w, h) and the size of
// its own geometry, which is the card with `clear` around it, so a
// compositor keeping that geometry on the screen keeps the card `clear`
// from its edges.
Popup_Positioner :: struct {
	anchor: [4]i32,
	size:   [2]i32,
}

// popup_positioner_rects works a popup's positioner out from its desc and
// its parent's clearance (0 for a parent that isn't a popup). The anchor
// widens by the gap along the placement's axis, less the clearance the
// geometry already puts there, and by `clear` across it at the side the
// card lines up with (its start, its end, or both for a centred card), so
// the card lines up with the anchor on either side a compositor flips it
// to. At a point, the anchor grows by `clear` all round.
popup_positioner_rects :: proc(desc: Popup_Desc, parent_clear: f32) -> Popup_Positioner {
	a := desc.anchor
	a[0] += parent_clear
	a[1] += parent_clear
	c := max(desc.clear, 0)
	g := desc.gap - c
	// across: the start `clear` earlier (Start: the geometry grows on from
	// there), the end `clear` later (End: it grows back from there), or both
	// (Center: its middle stays the anchor's)
	lead, trail: f32
	switch desc.align {
	case .Start:  lead = c
	case .Center: lead, trail = c, c
	case .End:    trail = c
	}
	switch desc.placement {
	case .Below, .Above:
		a[1] -= g
		a[3] += 2 * g
		a[0] -= lead
		a[2] += lead + trail
	case .Right, .Left:
		a[0] -= g
		a[2] += 2 * g
		a[1] -= lead
		a[3] += lead + trail
	case .At:
		a[0] -= c
		a[1] -= c
		a[2] += 2 * c
		a[3] += 2 * c
	}
	if a[2] < 1 { a[0] += (a[2] - 1) / 2; a[2] = 1 } // a gap smaller than the clearance on a thin anchor: keep its middle
	if a[3] < 1 { a[1] += (a[3] - 1) / 2; a[3] = 1 }
	x, y := i32(math.floor(a[0])), i32(math.floor(a[1]))
	return {
		anchor = {x, y, max(i32(math.ceil(a[0] + a[2])) - x, 1), max(i32(math.ceil(a[1] + a[3])) - y, 1)},
		size   = {max(i32(math.ceil(desc.size.x + 2 * c)), 1), max(i32(math.ceil(desc.size.y + 2 * c)), 1)},
	}
}

// popup_card_of turns a positioner's configure, the geometry's place in its
// parent's geometry and its size, into the card's place in the parent's
// card and the card's size.
popup_card_of :: proc(geometry: [4]i32, clear, parent_clear: f32) -> (pos, size: [2]f32) {
	pos = {f32(geometry[0]) + clear - parent_clear, f32(geometry[1]) + clear - parent_clear}
	size = {f32(geometry[2]) - 2 * clear, f32(geometry[3]) - 2 * clear}
	return
}

// Ev_Popup_Configure: where the compositor put a popup's card, relative to
// its parent's card, and its size. An Ev_Configure for the whole surface
// follows.
Ev_Popup_Configure :: struct { surface: Surface, pos: [2]f32, size: [2]f32 }
// Ev_Popup_Done: the compositor dismissed a popup (a press outside its grab).
Ev_Popup_Done :: struct { surface: Surface }

// Ev_Backdrop: how bright what shows through a blurred surface (or popup)
// is: the darkest part, the average and the brightest part of its blurred
// backdrop, as relative luminance 0..1. Sent soon after the surface maps and
// when the backdrop changes enough to matter, a few times a second at most.
Ev_Backdrop :: struct { surface: Surface, min, avg, max: f32 }

// Ev_Backdrop_Map: the same backdrop, cell by cell, for a surface measured
// as shown, so each piece of text can take the ink that reads over what is
// behind that piece rather than one ink for the whole span.
//
// `cell` is a cell's side in logical px and `origin` the map's top-left in
// surface-local logical px (not {0, 0} when the surface is partly off
// screen: only what is shown is measured). The last column and row may be
// cut short. `cells` is one byte per cell, row-major, `columns` per row: the
// relative luminance as the 8-bit sRGB grey of the same brightness, so decode
// it with the sRGB curve, not /255. It is the backend's until the next pump.
// Sent only where the compositor offers it; otherwise Ev_Backdrop's range
// applies.
Ev_Backdrop_Map :: struct {
	surface: Surface,
	columns: int,
	rows:    int,
	cell:    int,
	origin:  [2]i32,
	cells:   []u8,
}

// Drags across apps. Another app's drag over one of our surfaces arrives
// as Enter (with the forms it offers; owned by the backend until the next
// pump), Motion, then Leave or Drop; after Drop the toolkit asks for the
// data in one form with Backend.drag_receive, which arrives as Ev_Drag_Data
// while events keep flowing, and answers with drag_finish. Our own drag,
// handed to the compositor with drag_start when it leaves our surface,
// ends with Ev_Drag_End; over another of our surfaces its Enter says
// `own`, and its data is answered from memory.
Ev_Drag_Enter  :: struct { surface: Surface, pos: [2]f32, mimes: []string, own: bool }
Ev_Drag_Motion :: struct { surface: Surface, pos: [2]f32 }
Ev_Drag_Leave  :: struct { surface: Surface }
Ev_Drag_Drop   :: struct { surface: Surface, pos: [2]f32, action: Drag_Action, mods: Mods }
Ev_Drag_Data   :: struct { data: []u8, ok: bool } // what drag_receive asked for, owned by the backend until the next pump; ok false when the source gave nothing in time
Ev_Drag_End    :: struct { dropped: bool, action: Drag_Action }

// Drag_Action is what a drop should do with what it carries. Default: the
// user asked for nothing in particular, so the target decides (a file
// manager moves within a disk and copies across).
Drag_Action :: enum u8 { Default, Copy, Move, Ask }

// Clip_Item: one form of what is on the clipboard or carried by a drag.
// `data` is its bytes; a form that takes time to make (a picture as PNG)
// has `later` instead, which makes them off the UI thread, and is waited
// for only when a program asks for it.
Clip_Item :: struct { mime: string, data: []u8, later: ^Clip_Later }

// Drag_Icon is the picture a drag carries while the desktop holds it.
// `pixels` is RGBA8, straight alpha, row-major, `size.x * size.y * 4` bytes
// in device px, the shape surface_set_cursor_image takes; they belong to the
// caller's frame, so a backend copies them before it returns. `offset` is
// the picture's top-left relative to the pointer (device px) and `scale` is
// device px per logical px. Empty `pixels` means no picture.
Drag_Icon :: struct {
	pixels: []u8,
	size:   [2]i32,
	offset: [2]i32,
	scale:  f32,
}

// DROP_WAIT_MS is how long either side of a drop waits for its data. A
// source may still be making the files its paths name (the toolkit's
// Files_Later), and extracting a large file from an archive takes time; the
// minute is a backstop for a source that never answers.
DROP_WAIT_MS :: 60_000

// TRANSFER_MAX_BYTES is the most a paste or a drop reads from another
// program: 256 MB, past any picture or document a person moves this way. A
// source sending more is refused rather than filling the app's memory.
TRANSFER_MAX_BYTES :: 256 * 1024 * 1024

// TRANSFER_DEADLINE_MS bounds a paste as a whole, however steadily the other
// program dribbles: a paste read on the UI thread holds the app no longer.
// A drop, read between events, is bounded by DROP_WAIT_MS in all.
TRANSFER_DEADLINE_MS :: 10_000

// Clip_Later is a clipboard form made on demand, shared by counting: whoever
// keeps it (the app while it makes it, a backend while it offers it, a
// thread writing it into a pipe) holds a reference, taken with
// clip_later_retain and given back with clip_later_release. `wait` blocks,
// on any thread, until the bytes are made, and gives them; they live as
// long as the reference the caller holds. Nil bytes: making them failed.
// A `wait` has an end: whoever makes the bytes gives up at some point and
// answers with none, so a thread that calls it always comes back.
Clip_Later :: struct {
	wait: proc(l: ^Clip_Later) -> []u8,
	free: proc(l: ^Clip_Later), // called when the last reference goes
	refs: int,
}

clip_later_retain :: proc(l: ^Clip_Later) {
	sync.atomic_add(&l.refs, 1)
}

clip_later_release :: proc(l: ^Clip_Later) {
	if sync.atomic_sub(&l.refs, 1) == 1 do l.free(l)
}

// Clip_Reader is one form of the clipboard on its way in, started by the
// backend on the UI thread (clipboard_read). `read` blocks until all of it
// has come, or the program sending it stops for a while, on any thread,
// once; it gives back what the reader held, and the bytes are
// `allocator`'s.
Clip_Reader :: struct {
	read: proc(r: Clip_Reader, allocator: runtime.Allocator) -> ([]u8, bool),
	fd:   int,    // the backend's: a pipe's end, say
	user: rawptr,
}

// Watch_Kind: what happened under a watched path.
Watch_Kind :: enum u8 { Created, Modified, Removed }

// Ev_Watch: something changed under a watched path (Backend.watch).
// `name` is the entry inside a watched directory, "" for the path
// itself; owned by the backend until the next pump.
Ev_Watch :: struct { token: u64, name: string, kind: Watch_Kind }

// Ev_Files: a file dialog closed. `paths` are local paths, owned by the
// backend until the next pump (clone to keep); empty when cancelled. `why`
// says how it ended; `uris` is what the desktop answered when none of it was
// a local file (`.Unusable`).
//
// A dialog runs between pumps, so its paths are queued before the pump that
// delivers them: a pump that frees its string storage at the top would free
// them in the call that hands them over. Free that arena only when the queue
// is empty: a non-empty queue at a pump's start was filled outside a pump.
Ev_Files :: struct { token: u64, ok: bool, paths: []string, why: Files_Why, uris: []string }

// Files_Why is how a file dialog ended, so an app can tell a person's Cancel
// from a dialog that never appeared.
Files_Why :: enum u8 {
	Chosen,    // something was chosen, and `paths` holds it
	Cancelled, // the person closed the dialog without choosing
	Not_Shown, // no dialog was shown, or it failed: no service for one on this desktop, the service refused the call, or it gave up
	Unusable,  // something was chosen and none of it is a file on this computer (an smb:// address, a document in an app); `uris` holds what came back
}

// Ev_Configure: the surface has a (new) size/scale. Sent at least once before
// the first Ev_Redraw. `size_px` is what the swapchain must be.
Ev_Configure :: struct {
	surface:    Surface,
	size:       [2]f32,
	size_px:    [2]u32,
	scale:      f32,
	maximized:  bool,
	fullscreen: bool,
	activated:  bool,
	tiled:      bool, // against a neighbour or a screen edge (any of xdg's tiled states): sized by the desktop, as when maximised
	edge:       Edge, // an applet: the screen edge its bar is on
}
// Ev_Close: a surface is closing. `User`: the user asked, the app decides;
// `Compositor`: the compositor took it away (a layer surface whose screen
// went) and it is already gone.
Close_Reason :: enum u8 { User, Compositor }
Ev_Close :: struct { surface: Surface, reason: Close_Reason }
Ev_Focus :: struct { surface: Surface, focused: bool }
// Ev_Redraw: it is time to render this surface. Only sent after
// surface_request_frame (compositor frame callback / vsync tick).
Ev_Redraw :: struct { surface: Surface }
Ev_Pointer_Enter  :: struct { surface: Surface, pos: [2]f32 }
Ev_Pointer_Leave  :: struct { surface: Surface }
// `time_ms` is the input event's own time, in ms on the compositor's clock:
// only differences between two events mean anything (a stroke's speed).
Ev_Pointer_Motion :: struct { surface: Surface, pos: [2]f32, time_ms: u32, mods: Mods }
Ev_Pointer_Button :: struct { surface: Surface, button: Mouse_Button, pressed: bool, pos: [2]f32, mods: Mods, serial: u32, time_ms: u32 }

// Pen_Tool is what is touching a drawing tablet: a pen, its eraser end, and
// the rarer tools tablets report.
Pen_Tool :: enum u8 { Pen, Eraser, Brush, Pencil, Airbrush, Finger, Mouse, Lens }
// Pen_Phase is what a pen event is: the tool coming near the tablet over a
// surface, moving (tip down or hovering), its tip touching or lifting, a
// barrel button changing, or the tool going away.
Pen_Phase :: enum u8 { Near, Move, Down, Up, Button, Away }
// Ev_Pen is one frame of a tablet tool, in logical px:
// `pressure` 0..1, `tilt` in degrees from upright on x and y, `rotation` in
// degrees, `distance` 0..1 above the tablet (-1: not reported), `contact`
// whether the tip is down, `buttons` the barrel buttons held (bit 0 the
// first), and for .Button which one changed and how. `time_ms` as the
// pointer's; `serial` is the tip's or the button's, for a grab.
Ev_Pen :: struct {
	surface:  Surface,
	phase:    Pen_Phase,
	tool:     Pen_Tool,
	pos:      [2]f32,
	pressure: f32,
	tilt:     [2]f32,
	rotation: f32,
	distance: f32,
	contact:  bool,
	buttons:  u8,
	button:   u8, // .Button: which barrel button (0 the first)
	pressed:  bool, // .Button: pressed or let go
	mods:     Mods,
	time_ms:  u32,
	serial:   u32,
}
// Ev_Scroll: delta in logical pixels, +y = content should move up (wheel
// down). Backends convert discrete wheel steps at 48 px per step.
Ev_Scroll :: struct { surface: Surface, delta: [2]f32, pos: [2]f32, precise: bool, mods: Mods }
// Ev_Touch: one point of a touch sequence, in logical px. Backends send Down,
// then Move events, then Up (or Cancel when the compositor takes the gesture).
Touch_Phase :: enum u8 { Down, Move, Up, Cancel }
Ev_Touch :: struct { surface: Surface, id: i32, phase: Touch_Phase, pos: [2]f32 }
// Ev_Input_Caps: the seat's devices changed. `touch` = a touchscreen is
// present (the toolkit grows interactive targets to 44 px).
Ev_Input_Caps :: struct { touch: bool }
// Ev_Caps: the backend's capabilities changed after init (the compositor
// turned blur off or on); Backend.caps already holds the new set.
Ev_Caps :: struct { caps: Caps }
// Ev_Outputs: a screen was added, removed or changed (mode, scale,
// position, transform); Backend.outputs returns the new set.
Ev_Outputs :: struct {}

// Ev_Surface_Output: a surface is now on this screen (its name, owned by the
// backend until the next pump); one on two screens hears the newest.
Ev_Surface_Output :: struct { surface: Surface, output: string }
// Ev_Lock: what became of the session lock asked for with
// Backend.session_lock. Locked: the session is locked — the compositor has
// hidden every screen and promises no frame of the session shows until it
// is unlocked. Shown: every lock surface has had a frame of its own shown
// since. Finished: the compositor refused the lock (another is live) or,
// after Locked, ended it itself; either way the lock object stays the app's
// to end with session_unlock, and nothing in the backend unlocks.
Lock_Event :: enum u8 { Locked, Shown, Finished }
Ev_Lock :: struct { event: Lock_Event }

// Lock_Key is a key that stays on: Caps Lock, Num Lock.
Lock_Key :: enum u8 { Caps, Num }
Lock_Keys :: bit_set[Lock_Key; u8]

// Ev_Keyboard is what a view may show of the keyboard: the lock keys that
// are on (locked, not only held: Caps Lock may be on before any key comes),
// the active layout's name ("English (UK)"; "" when the keymap has none)
// and how many layouts there are. Sent when a keymap arrives and whenever
// any of it changes; `layout` is the backend's until the next pump.
Ev_Keyboard :: struct {
	locks:   Lock_Keys,
	layout:  string,
	layouts: int,
}

// Ev_Url: what became of an open_url ask, carrying its `token`. `ok` is
// false when the desktop refused it, nothing was there to open it, or the
// person dismissed the chooser — the app then shows the link to copy.
Ev_Url :: struct { token: u64, ok: bool }

// Notify_Urgency is how much the desktop should interrupt for a
// notification. Low is a background fact, Normal the default, Critical
// something that will not go away on its own — a desktop may keep a
// Critical one on screen until it is answered, and may show it while
// notifications are otherwise silenced. Use it sparingly: an app that
// marks everything Critical is one the person turns off entirely.
Notify_Urgency :: enum u8 { Low, Normal, Critical }

// Notify_Action is one button on a notification: `key` is what comes back
// in Ev_Notify, `label` is what the person reads. The key "default" is the
// notification body itself, which most desktops make clickable without
// drawing a button for it.
Notify_Action :: struct { key, label: string }

// Notify_Desc is a notification to show. `tag` is the app's own name for
// it, echoed in every Ev_Notify about it and the handle `notify_close`
// takes; showing a second with the same tag *replaces* the first in place,
// which is how a progress or "now playing" notification updates without
// stacking up.
//
// `icon` is a name from the desktop's icon theme (the app's own icon when
// empty). `timeout_ms` is -1 for the desktop's choice, 0 for "until it is
// dismissed"; a desktop is free to ignore it either way.
Notify_Desc :: struct {
	tag:        u64,
	title:      string,
	body:       string,
	icon:       string,
	actions:    []Notify_Action,
	urgency:    Notify_Urgency,
	timeout_ms: i32,
}

// Notify_Event is what happened to a notification the app sent.
Notify_Event :: enum u8 {
	Shown,     // the desktop took it
	Failed,    // it could not be shown at all, and nothing else follows
	Activated, // the person chose it, or one of its actions (`action`)
	Closed,    // it went away (`reason`)
}

// Notify_Close_Reason is why a notification went away. Dismissed means the
// person waved it off, which is *not* the same as choosing it: an app that
// treats both as "they want this" interrupts them twice.
Notify_Close_Reason :: enum u8 { Expired, Dismissed, By_App, Unknown }

// Ev_Notify: something happened to the notification with this `tag`.
// `action` is the key of the action chosen ("" is the notification itself),
// `error` says why a Failed one failed.
Ev_Notify :: struct {
	tag:    u64,
	event:  Notify_Event,
	action: string,
	reason: Notify_Close_Reason,
	error:  string,
}

// A tray / status item: what an app living in the notification area or the
// menu bar shows while its window is closed. It is not a surface: Baldr
// draws only the icon's pixels, and the menu and its accessibility are the
// desktop's.

// Tray_Pixmap is one size of the item's icon, ARGB32, premultiplied, rows
// top to bottom. Several are offered and each desktop picks: that is SNI's
// own wire format, and Windows and macOS each take the size they want.
Tray_Pixmap :: struct {
	w, h: int,
	argb: []u32, // the frame's, as everything in a Tray_Desc is
}

// Tray_Status is how much the item wants to be noticed. `.Attention` is
// SNI's NeedsAttention; a desktop without one (macOS) shows the attention
// icon instead, which is why an app gives both.
Tray_Status :: enum u8 { Normal, Attention }

// Tray_Item is one line of the menu. `separator` ignores everything else;
// `checked` present means a checkable item, absent means a plain one — the
// desktops draw "a checkbox that is off" and "no checkbox" differently and
// an app that means one must not get the other. `children` is a submenu; a
// backend that cannot do them flattens to the parent and says so.
Tray_Item :: struct {
	id:        u32, // what comes back in Ev_Tray; 0 for a separator
	label:     string,
	icon:      []Tray_Pixmap,
	checked:   Maybe(bool),
	disabled:  bool,
	separator: bool,
	children:  []Tray_Item,
}

// Tray_Desc is a tray item to show. `tag` is the app's own name for it and
// comes back with everything that happens to it; showing a second with the
// same tag **updates** the first in place rather than adding another.
//
// `icon_name` is a name from the desktop's icon theme, which Linux hosts
// theme themselves and prefer; `icon` is the toolkit's own rasterisation,
// used when there is no name and on the desktops that have no theme.
Tray_Desc :: struct {
	tag:       u64,
	title:     string, // what the desktop calls it in its own lists
	tooltip:   string,
	icon_name: string,
	icon:      []Tray_Pixmap,
	status:    Tray_Status,
	menu:      []Tray_Item,
}

// Tray_Event is what happened to a tray item. A desktop may have no tray
// (GNOME without the AppIndicator extension) and a restarting panel takes
// every item with it, so Hosted and Gone tell an app when it can stop
// falling back to its window. Clicked may never arrive (some hosts open the
// menu for any click), so keep everything reachable from the menu too.
Tray_Event :: enum u8 {
	Hosted,  // a tray exists and this item is in it
	Gone,    // …and now it is not
	Clicked, // the primary action
	Chosen,  // a menu item: `id`
}

// Ev_Tray: something happened to the tray item with this `tag`.
Ev_Tray :: struct {
	tag:  u64,
	kind: Tray_Event,
	id:   u32, // .Chosen: the item
}

// Ev_Frame: when the frame the app is about to draw is expected on screen,
// the number a video player aims at (a timer cannot place a 30 fps frame on
// exactly two 60 Hz refreshes). Sent only while Backend.frames_wanted is on,
// because it means drawing at the screen's rate.
// `refresh_ms` is the display's interval. Times are measured where the
// compositor reports presentation (wp_presentation), otherwise estimated from
// the frame callback and refresh rate, and `estimated` says so. `ahead_ms` is
// relative to now, not a time on any clock: the compositor's presentation
// clock is a different timeline, and the runtime converts it to its own.
Ev_Frame :: struct {
	surface:    Surface,
	ahead_ms:   f64,
	refresh_ms: f64,
	estimated:  bool,
}

// Ev_Toplevels: the compositor's list of windows changed (once for each
// batch of its changes); Backend.toplevels returns the new list.
// Ev_Workspaces: the same for its workspaces.
Ev_Toplevels :: struct {}
Ev_Workspaces :: struct {}

// Slot is an applet slot a bar reserved on one of its layer surfaces
// (rikkiti-applet-v1, the host's side). 0 = none.
Slot :: distinct u32

// Ev_Slot: something about a slot. Token: the token to start an applet
// with (`token`, owned by the backend until the next pump), again after an
// applet detaches; Attached: an applet bound it (`pid`, 0 when unknown);
// Detached: it went; Size_Hint: the length along the bar it would like
// (`least`, `preferred`, logical px, 0 = none).
Ev_Slot :: struct {
	slot:      Slot,
	kind:      Slot_Event_Kind,
	token:     string,
	pid:       u32,
	least:     u32,
	preferred: u32,
}
Slot_Event_Kind :: enum u8 { Token, Attached, Detached, Size_Hint }

// Output is one screen as the compositor reports it (wl_output and
// xdg-output). Strings are owned by the backend until the next pump.
Output :: struct {
	name:        string,           // connector, "DP-1"
	description: string,           // make and model
	pos:         [2]i32,           // position in the desktop's own coordinates: logical on Wayland, device px on Windows (which has no logical desktop plane), so a screen's rectangle is pos+size there and pos+mode_px here
	size:        [2]i32,           // logical size, after scale and transform
	mode_px:     [2]i32,           // the current mode, device px
	scale:       f32,              // device px per logical px
	transform:   Output_Transform,
	refresh:     i32,              // mHz
	primary:     bool,             // the screen an app should treat as first; the toolkit decides it, not the backend (baldr: outputs)
}

// Output_Transform: how a screen is rotated (counter-clockwise) or flipped.
Output_Transform :: enum u8 { Normal, Rotate_90, Rotate_180, Rotate_270, Flipped, Flipped_90, Flipped_180, Flipped_270 }

// Toplevel is one open window as the compositor lists it for a taskbar
// (wlr-foreign-toplevel-management). `id` is stable while the window is
// open (not across runs); `activated` is the window focus last went to, so
// a bar taking the keyboard doesn't clear it. Strings and `outputs` (the
// screens it is on, by name) are owned by the backend until the next pump.
Toplevel :: struct {
	id:         u64,
	// handle is the compositor's own name for the window, on this app's
	// connection: on Wayland the protocol object id of the
	// zwlr_foreign_toplevel_handle_v1 we hold for it (0 elsewhere). `id` is
	// ours — a counter, stable while the window is open — and means nothing
	// to anyone else; `handle` is what an app passes to the compositor over
	// another channel to name exactly this window, where an app id and a
	// title cannot (two "Home — Files" windows). It is only meaningful to a
	// compositor looking it up on this process's own Wayland client.
	handle:     u32,
	title:      string,
	app_id:     string,
	outputs:    []string,
	parent:     u64, // the window a dialog belongs to; 0 = none
	activated:  bool,
	maximized:  bool,
	minimized:  bool,
	fullscreen: bool,
}

// Toplevel_Action: what a taskbar can ask of a window.
Toplevel_Action :: enum u8 { Activate, Minimize, Unminimize, Maximize, Unmaximize, Fullscreen, Unfullscreen, Close }

// Window_Act is what a window asks of its own frame (Backend.surface_act).
Window_Act :: enum u8 { Move, Resize, Maximize, Unmaximize, Minimize, Menu }

// Window_Edge names a side or corner a resize drags.
Window_Edge  :: enum u8 { Top, Bottom, Left, Right }
Window_Edges :: bit_set[Window_Edge; u8]

// Workspace is one workspace as the compositor lists it (ext-workspace).
// `id` is stable while it exists; `identifier` is the compositor's own id,
// stable across runs ("" when it gives none); `number` is its first
// coordinate, its place (-1 when it has none); `outputs` are its group's
// screens. `can_activate` / `can_assign` say which requests it takes.
// Strings and slices are owned by the backend until the next pump.
Workspace :: struct {
	id:           u64,
	identifier:   string,
	name:         string,
	number:       int,
	outputs:      []string,
	active:       bool,
	urgent:       bool,
	hidden:       bool,
	can_activate: bool,
	can_assign:   bool,
}

// Workspace_Action: switch to a workspace, or move it to another screen.
Workspace_Action :: enum u8 { Activate, Assign }
Ev_Key  :: struct { surface: Surface, key: Key, native: u32, pressed: bool, repeat: bool, mods: Mods }
Ev_Text :: struct { surface: Surface, text: string } // committed UTF-8 from the keyboard (an input method's text arrives as Ev_Ime)

// Ime_Purpose is what a field is for, so an input method can suit itself to
// it: a numeric keypad for a PIN, no composing and no learning in a password.
Ime_Purpose :: enum u8 { Normal, Alpha, Digits, Number, Phone, Url, Email, Name, Password, Pin, Date, Time, Datetime, Terminal }

// Ime_Hint asks an input method for a behaviour where it has the choice.
Ime_Hint :: enum u8 { Completion, Spellcheck, Auto_Capitalization, Lowercase, Uppercase, Titlecase, Hidden_Text, Sensitive_Data, Latin, Multiline }
Ime_Hints :: bit_set[Ime_Hint; u16]

// Ime_Cause says what moved the text last: the input method itself, or
// anything else (typing, a click, the app).
Ime_Cause :: enum u8 { Input_Method, Other }

// IME_SURROUNDING_MAX is how much text around the caret is sent (the
// protocol's limit is 4000 bytes for the whole message).
IME_SURROUNDING_MAX :: 2000

// Ime_State is what the focused field tells the input method: whether it
// wants one at all, what the field is for, the text around the caret
// (never the preedit, at most IME_SURROUNDING_MAX bytes) with the caret and
// the selection anchor in it, and where the caret is on screen, so the
// candidate window can sit by it.
Ime_State :: struct {
	surface:        Surface,
	on:             bool,
	purpose:        Ime_Purpose,
	hints:          Ime_Hints,
	surrounding:    string,
	cursor, anchor: int,
	cause:          Ime_Cause,
	caret:          [4]f32, // x, y, width, height in surface coordinates
}

// Ev_Ime is one round of input-method changes, to apply in this order: take
// away the preedit shown now, delete `delete_before` bytes before the caret
// and `delete_after` after it, insert `commit` as if typed, then show
// `preedit` at the caret with its cursor between `cursor_begin` and
// `cursor_end` (both -1: no cursor). The strings live until the next pump.
Ev_Ime :: struct {
	surface:                  Surface,
	delete_before, delete_after: u32,
	commit:                   string,
	preedit:                  string,
	cursor_begin, cursor_end: i32,
}
// Ev_Theme is the desktop's look and preferences. icon_theme: its icon theme
// ("" when it doesn't say). button_layout and double_click: the choices for a
// title bar a window draws itself, in GNOME's words (button-layout,
// action-double-click-titlebar), "" when it doesn't say. The strings are the
// backend's until the next pump.
// `accent` is the desktop's accent colour in sRGB, 0..1 per channel, as both
// the Settings portal (`accent-color (ddd)`) and the Windows registry
// (`DWM\AccentColor`) give it. A backend passes it on unconverted; the
// toolkit converts to its linear `Color`.
Ev_Theme :: struct {
	dark: bool, has_accent: bool, accent: [4]f32, reduce_motion: bool, reduce_transparency: bool, high_contrast: bool, text_scale: f32,
	icon_theme:    string,
	button_layout: string,
	double_click:  string,
	// The desktop's UI font and its monospace font, by family name
	// ("Cantarell", "Source Code Pro"), "" when it doesn't say.
	font_family:   string,
	mono_family:   string,
	// font_size is the UI font's size in points as the desktop states it
	// ("Cantarell 11" → 11), 0 when it doesn't. A separate setting from
	// `text_scale`, which multiplies it, as GTK does. Only the portal
	// reports one: Windows' size control *is* its Text size setting, already
	// `text_scale`, and macOS has no font size to set.
	font_size:     f32,
	// The desktop's own colour scheme, when it has a whole one to give: a
	// Windows contrast theme, a KDE colour scheme. `ok` false when it has
	// none, and the toolkit generates its colours from `dark` and `accent`.
	palette:       System_Palette,
}

// System_Palette is a desktop colour scheme in the roles every desktop
// names, sRGB 0..1. `inactive_text` is secondary text (KDE's inactive
// foreground, Windows' grey text); `link` is hyperlink ink.
System_Palette :: struct {
	ok:             bool,
	window:         [4]f32,
	window_text:    [4]f32,
	view:           [4]f32,
	view_text:      [4]f32,
	button:         [4]f32,
	button_text:    [4]f32,
	selection:      [4]f32,
	selection_text: [4]f32,
	link:           [4]f32,
	inactive_text:  [4]f32,
}
// Ev_Quit: the run should end. `lost` means the desktop went away or
// dropped us rather than the app being asked to stop — the app did not
// choose this, and a caller that exits silently on it turns a dropped
// connection into "it just closed".
Ev_Quit :: struct { lost: bool }

SCROLL_STEP_PX :: f32(48)

// Backend is the contract. Every proc is required unless marked optional;
// optional ones may be nil and the toolkit checks before calling.
Backend :: struct {
	name: string,
	data: rawptr,
	caps: Caps, // filled by init


	init:     proc(b: ^Backend) -> (ok: bool, why: string),
	shutdown: proc(b: ^Backend),

	// Vulkan glue. gpu.init loads the loader and instance procs (vendor:vulkan
	// globals are shared package state), so the backend just calls the
	// platform's vkCreate*SurfaceKHR.
	vk_instance_extensions: proc(b: ^Backend) -> []cstring,
	vk_create_surface:      proc(b: ^Backend, s: Surface, instance: vk.Instance) -> (vk.SurfaceKHR, bool),

	// drawable_create is the renderer seam, and the one the toolkit calls.
	// It hands back whatever this backend's renderer draws into — a
	// VkSurfaceKHR on Wayland, X11 and Win32, a CAMetalLayer on macOS — as an
	// opaque word that `gpu.target_add` takes as a `gpu.Drawable`.
	//
	// `renderer` is the renderer's own handle where one is needed to make it
	// (a VkInstance); macOS needs nothing and ignores it. This exists because
	// `vk_create_surface` cannot be spelled on a platform with no Vulkan, and
	// a `when ODIN_OS` in the toolkit's run loop would put the backend's
	// business in the wrong place.
	drawable_create:        proc(b: ^Backend, s: Surface, renderer: rawptr) -> (uintptr, bool),

	surface_create:        proc(b: ^Backend, desc: Surface_Desc) -> (Surface, bool),
	surface_destroy:       proc(b: ^Backend, s: Surface),
	surface_set_title:     proc(b: ^Backend, s: Surface, title: string),
	surface_set_cursor:    proc(b: ^Backend, s: Surface, c: Cursor),
	// surface_set_cursor_image makes `s`'s pointer (and a pen's over it) a
	// picture the app drew, such as a brush's outline: `pixels` RGBA8,
	// straight alpha, sRGB, `size` of them, `hotspot` the pixel that is the
	// pointer's point, `scale` the picture's pixels per logical pixel. It is
	// the cursor until surface_set_cursor gives a shape. Optional.
	surface_set_cursor_image: proc(b: ^Backend, s: Surface, pixels: []u8, size: [2]i32, hotspot: [2]i32, scale: f32),
	// surface_set_dark says whether the theme drawn in window `s` is dark,
	// for the part of it the platform draws — macOS's title bar, Windows'
	// caption, an X window manager's frame — so that a dark app has a dark
	// frame on a light desktop and the other way round. The toolkit calls it
	// when the window's theme turns dark or light, and once when the window
	// first builds; an app that follows the desktop is told the desktop's.
	// Optional: on Wayland the compositor draws a decoration by its own
	// theme, or the app draws its own.
	surface_set_dark: proc(b: ^Backend, s: Surface, dark: bool),
	// frames_wanted says whether this surface wants an Ev_Frame for every
	// frame the display shows, rather than only when something changed. It
	// paints at the screen's rate for as long as it is on, so an app turns
	// it off the moment it stops needing it (a player that has paused).
	// Optional: without it an app hears no Ev_Frame and falls back to a
	// timer.
	frames_wanted: proc(b: ^Backend, s: Surface, on: bool),

	// surface_request_frame asks for one Ev_Redraw when the display is ready
	// for the next frame. Safe to call right after presenting (the backend
	// commits as needed); the first redraw after a configure is synthesised
	// because compositors send no frame callbacks for unmapped surfaces.
	surface_request_frame: proc(b: ^Backend, s: Surface),
	surface_geometry:      proc(b: ^Backend, s: Surface) -> (size: [2]f32, size_px: [2]u32, scale: f32),
	// surface_position is where the window's top-left corner is, in the
	// desktop's own coordinates (`Output.pos`), with the frame the window
	// manager put around it included — so it round-trips with
	// `Surface_Desc.position` and an app can put a window back where it was.
	//
	// `ok = false` where the platform will not say: Wayland by design (a
	// client is never told where it is), and before the first configure.
	// Nil on a backend that has no answer at all.
	surface_position:      proc(b: ^Backend, s: Surface) -> (pos: [2]i32, ok: bool),
	// surface_native is this platform's own object for the surface — an
	// `NSView *` on macOS, an `HWND` on Windows — for the one caller that
	// cannot be written against the portable contract: the accessibility
	// bridge. UI Automation and NSAccessibility are both answered *through*
	// the window (a `WM_GETOBJECT` on one, methods on the view on the other),
	// so the toolkit needs the handle the desktop will name.
	//
	// Nothing else may use it. It is deliberately a bare word with no type:
	// anything that wants to do more with a window belongs in the contract
	// above, where every backend has to answer for it.
	//
	// Optional, and nil on a platform whose accessibility interface is not
	// reached that way — Wayland and X11 answer on a bus of their own, so
	// neither implements it.
	surface_native:        proc(b: ^Backend, s: Surface) -> rawptr,
	// surface_set_backdrop changes the behind-surface effect after creation
	// (the theme's glass was switched off, or back on). Optional.
	surface_set_backdrop:  proc(b: ^Backend, s: Surface, backdrop: Backdrop),
	// outputs returns the screens as the compositor last reported them
	// (Ev_Outputs says when that changes), owned by the backend until the
	// next pump. Optional: the toolkit then knows no screens.
	outputs: proc(b: ^Backend) -> []Output,
	// toplevels returns the open windows as the compositor last listed them
	// (Ev_Toplevels says when that changes), owned by the backend until the
	// next pump; toplevel_request asks something of one (it does nothing for
	// a window that has gone). Optional (Caps .Toplevels): the toolkit then
	// knows no windows.
	toplevels:        proc(b: ^Backend) -> []Toplevel,
	toplevel_request: proc(b: ^Backend, id: u64, action: Toplevel_Action),
	// toplevel_set_rectangle tells the compositor where window `id` is shown
	// on surface `s` — a taskbar button, a dock icon — in that surface's own
	// logical pixels, so a minimise can fly the window into it and back
	// (zwlr_foreign_toplevel_handle_v1.set_rectangle). A zero `rect` clears
	// it. It takes the toolkit's `Toplevel.id`, not the protocol handle, so
	// the lookup stays the backend's. Optional (Caps .Toplevels).
	toplevel_set_rectangle: proc(b: ^Backend, id: u64, s: Surface, rect: [4]f32),
	// workspaces and workspace_request, likewise (Caps .Workspaces); an
	// Assign moves the workspace to the screen named `output`. Optional.
	workspaces:        proc(b: ^Backend) -> []Workspace,
	workspace_request: proc(b: ^Backend, id: u64, action: Workspace_Action, output: string),
	// slot_create reserves a slot for another program's applet on layer
	// surface `host`, at `rect` (logical px in the surface) on the bar's
	// `edge`; an Ev_Slot Token follows. slot_set_geometry moves or resizes
	// it, applied with the host's next commit so the bar and the applet move
	// together; slot_destroy removes it (its applet is closed). A host
	// surface going removes its slots. Optional (Caps .Applet_Slots).
	slot_create:       proc(b: ^Backend, host: Surface, rect: [4]f32, edge: Edge) -> (Slot, bool),
	slot_set_geometry: proc(b: ^Backend, slot: Slot, rect: [4]f32, edge: Edge),
	slot_destroy:      proc(b: ^Backend, slot: Slot),
	// surface_set_layer changes an open layer surface's placement in place:
	// anchors, size (0 = stretch between anchors), exclusive zone and edge,
	// margins, keyboard and level. Not its output. Optional; false when it
	// cannot.
	surface_set_layer: proc(b: ^Backend, s: Surface, layer: Layer_Desc, size: [2]f32) -> bool,
	// surface_set_input_region sets where a surface takes the pointer, in
	// logical px: the union of `rects` (x, y, w, h), nowhere when `rects` is
	// empty, or the whole surface when `all`. Optional.
	surface_set_input_region: proc(b: ^Backend, s: Surface, rects: [][4]f32, all: bool),
	// surface_set_blur_region sets where the compositor blurs behind a surface
	// with a blur backdrop, in logical px: the union of `rects` (x, y, w, h),
	// each with its corners rounded by its `radii` entry; nowhere when `rects`
	// is empty. Optional: without it the whole surface is blurred.
	surface_set_blur_region: proc(b: ^Backend, s: Surface, rects: [][4]f32, radii: []f32),
	// surface_set_applet changes an open applet surface's keyboard setting.
	// Optional; false when it cannot.
	surface_set_applet: proc(b: ^Backend, s: Surface, applet: Applet_Desc) -> bool,
	// surface_set_size_hint tells an applet's shell the length along the bar
	// it can't go below and the one it would like (logical px, 0 = none); the
	// shell answers with a configure. Optional.
	surface_set_size_hint: proc(b: ^Backend, s: Surface, least, preferred: u32),
	// session_lock asks the compositor to lock the session
	// (ext-session-lock-v1); Ev_Lock answers. While the lock is live the
	// app's .Lock surfaces can be created, one per screen. False when it
	// cannot ask: no protocol, or a lock of this app's is still live.
	// Optional (Caps .Session_Lock).
	session_lock:   proc(b: ^Backend) -> bool,
	// session_unlock ends this app's lock, and is the only thing that does.
	// Once the compositor has locked, the session is unlocked
	// (unlock_and_destroy) and the call returns when the compositor has the
	// request, so an app may quit straight after. Asked but not yet locked,
	// the lock is withdrawn: unlocked the moment the compositor locks, or
	// dropped if it refuses. The caller then closes its lock surfaces.
	// Nothing else in a backend unlocks — not shutdown, a lost connection or
	// Finished — and a lock surface's going leaves the session locked.
	session_unlock: proc(b: ^Backend),
	// popup_create opens a popup (Caps .Popups); surface_destroy closes it,
	// after any popup opened from it. Optional.
	popup_create:     proc(b: ^Backend, desc: Popup_Desc) -> (Surface, bool),
	// popup_reposition moves or resizes an open popup (a new anchor or card
	// size); false when it can't, and the popup has to be opened again.
	// Optional.
	popup_reposition: proc(b: ^Backend, s: Surface, desc: Popup_Desc) -> bool,

	// pump blocks until an event arrives, `wake` is called, or `timeout_ms`
	// passes (-1 = forever, 0 = poll), then returns everything queued — which
	// may be empty after a wake. The slice and any strings in it are owned by
	// the backend until the next pump.
	pump: proc(b: ^Backend, timeout_ms: i32) -> []Event,
	// wake interrupts a blocked pump from any thread.
	wake: proc(b: ^Backend),

	// Set by the toolkit, called by the backend ONLY from inside an OS modal
	// loop that swallows the pump (Win32 size/move loop, macOS drawRect) so
	// the surface keeps painting. Optional for backends without modal loops.
	redraw_callback: proc(user: rawptr, s: Surface),
	redraw_user:     rawptr,

	system_theme:  proc(b: ^Backend) -> Ev_Theme,
	// open_url hands `url` to the desktop's own handler — the browser, the
	// mail app — and later emits Ev_Url with `token`. The toolkit allows
	// only http, https and mailto through and checks the URL before this is
	// called (open_url in baldr), so a backend passes it on as it is.
	// False when it cannot ask at all, and no Ev_Url follows. Optional: the
	// toolkit then answers the app that it could not be opened.
	open_url: proc(b: ^Backend, url: string, token: u64) -> bool,

	// notify asks the desktop to show `d` and later emits Ev_Notify about
	// it, keyed by `d.tag`. False when this backend cannot show
	// notifications at all, and no Ev_Notify follows — the app then says it
	// some other way (a toast of its own, a line in its window) rather than
	// staying silent. A tag already showing is replaced in place.
	//
	// The desktop owns what is shown and for how long: a backend passes the
	// description on and does not second-guess it. Whether a notification is
	// shown at all is the person's setting, not the app's, so `Shown` means
	// the desktop took it, not that anyone saw it.
	notify: proc(b: ^Backend, d: Notify_Desc) -> bool,

	// notify_close takes back the notification with `tag` — the job it was
	// about finished, or the window it points at is now in front. A tag that
	// is not showing is not an error. The desktop answers with an Ev_Notify
	// whose reason is By_App, so an app has one place to keep its books.
	notify_close: proc(b: ^Backend, tag: u64),
	// tray_set shows the item described, or updates the one with the same
	// tag in place. False when this desktop has no tray at all, and no
	// Ev_Tray follows — the app is then told (its `on_gone`), so it can
	// keep its window instead of showing nothing.
	//
	// Everything in `t` is the frame's: a backend that keeps any of it
	// copies it.
	tray_set: proc(b: ^Backend, t: Tray_Desc) -> bool,
	// tray_remove takes the item with `tag` away. A tag that is not showing
	// is not an error.
	tray_remove: proc(b: ^Backend, tag: u64),
	// open_path opens a local file the app itself made with the desktop's
	// handler for it, or with `reveal` shows it in the file manager (picked
	// out where the file manager can). It answers with Ev_Url and `token`,
	// as open_url does — the tokens come from one counter, so a backend has
	// one kind of answer to send. The toolkit checks the path before this is
	// called (open_path in baldr): it exists, it is not executable, and it
	// is a file (or, for `reveal`, a file or a folder). False when it cannot
	// ask at all, and no Ev_Url follows.
	open_path: proc(b: ^Backend, path: string, reveal: bool, token: u64) -> bool,
	// file_dialog shows the desktop's open / save dialog for `d` and later
	// emits Ev_Files with d.token. Returns false when no dialog can be shown
	// (no portal / no bus); the toolkit then answers the command with
	// ok = false. Optional.
	file_dialog:   proc(b: ^Backend, d: File_Dialog) -> bool,
	// locale returns the desktop's locale (see Locale). Optional: the
	// toolkit uses LOCALE_EN when absent.
	locale:        proc(b: ^Backend) -> Locale,
	// ime_set tells the input method what the focused field is and where it
	// is, and enables or disables composing (see Ime_State). Optional: a
	// backend without input methods leaves it nil and no Ev_Ime arrives.
	ime_set:       proc(b: ^Backend, st: Ime_State),
	clipboard_get: proc(b: ^Backend, allocator := context.allocator) -> (string, bool), // optional
	clipboard_set: proc(b: ^Backend, text: string) -> bool,                             // optional
	// The primary selection: what was last selected, which a middle click
	// pastes (X11 and Wayland). Text only. Optional: a platform without one
	// leaves both nil.
	primary_get: proc(b: ^Backend, allocator := context.allocator) -> (string, bool),
	primary_set: proc(b: ^Backend, text: string) -> bool,
	// Typed clipboard: what is offered now, one form of it, and offering
	// several forms at once (files as text/uri-list next to plain text).
	// Optional; the toolkit falls back to the text pair.
	clipboard_types:    proc(b: ^Backend, allocator := context.allocator) -> []string,
	clipboard_get_data: proc(b: ^Backend, mime: string, allocator := context.allocator) -> ([]u8, bool),
	clipboard_set_data: proc(b: ^Backend, items: []Clip_Item) -> bool,
	// clipboard_read starts reading one form (a picture, which may be
	// megabytes) for a thread to finish, so the UI never waits on the
	// program that copied it. Optional; without it the toolkit reads with
	// clipboard_get_data.
	clipboard_read:     proc(b: ^Backend, mime: string) -> (Clip_Reader, bool),
	// surface_ack_configure acknowledges the configure the surface is about
	// to answer, and must be called immediately before the frame drawn at
	// that size is presented: acking is a promise that the next commit is at
	// the new size, so acking earlier lets the desktop stretch the last
	// frame over the new geometry until one arrives. A configure that
	// changes no size is acked by the backend as it arrives. Optional.
	surface_ack_configure: proc(b: ^Backend, s: Surface),
	// surface_set_size gives a floating window a size of its own choosing (a
	// window rolled up to its title bar, and back): at once, with an
	// Ev_Configure saying so, and kept through the desktop's configures while
	// the window floats. A maximised, full-screen or tiled one is the
	// desktop's to size, and a configure in one of those states ends it.
	// {0, 0} hands the size back to the desktop, whose next configure with a
	// size sets it, except one still carrying the size chosen before the
	// last (sent before the desktop saw the change). Optional.
	surface_set_size: proc(b: ^Backend, s: Surface, size: [2]f32),
	// surface_set_fullscreen asks the desktop to give this window the whole
	// screen, or to give it back. It is a request: what the compositor did
	// arrives in the next Ev_Configure (`fullscreen`), which is what a view
	// must be built from. Optional; false when the backend cannot ask.
	surface_set_fullscreen: proc(b: ^Backend, s: Surface, on: bool) -> bool,
	// surface_act asks the desktop to do something with this window: begin a
	// move or a resize the desktop itself runs (the pointer is already down;
	// for a window drawing its own title bar), maximise, minimise, or show the
	// window menu at a point in the window. False when the desktop cannot.
	// `edges` is only read for .Resize.
	surface_act: proc(b: ^Backend, s: Surface, act: Window_Act, edges: Window_Edges, at: [2]f32) -> bool,
	// surface_post_close asks for this surface to close as if its frame's
	// close button had been pressed: an Ev_Close with reason .User on the
	// next pump, so a window drawing its own title bar closes down the same
	// path as one the desktop decorates. Optional.
	surface_post_close: proc(b: ^Backend, s: Surface),
	// inhibit_shortcuts asks the desktop to stop acting on its own keyboard
	// shortcuts while `surface` has the keyboard, so chords it would
	// otherwise swallow (Super+Q) reach the app: a shortcut editor
	// listening for one, a remote desktop or a virtual machine passing them
	// to the guest. Optional, and the desktop may say no — a compositor
	// without the protocol simply keeps its shortcuts.
	inhibit_shortcuts: proc(b: ^Backend, surface: Surface, on: bool),
	// keep_awake asks the desktop not to dim, blank or lock the screen while
	// `surface` is on it: a video playing in a window, a slideshow, a recipe
	// left open. The desktop decides, and it may well take the surface being
	// visible as part of the asking (a compositor need not keep the screen on
	// for a window nobody can see), so an app sets it while it is actually
	// showing something and clears it when it stops. Optional — a desktop
	// without the protocol simply dims as usual.
	keep_awake: proc(b: ^Backend, surface: Surface, on: bool),
	// activate asks the desktop to bring `surface`'s window to the front and
	// give it the keyboard (xdg-activation-v1): with `token` when the app was
	// handed one (a D-Bus caller's, a launcher's), else with one the backend
	// asks the desktop for itself, which a desktop may grant only after
	// recent input. A window not shown yet is activated as it first shows.
	// The desktop decides: it may raise the window, or only mark it as
	// wanting attention. Optional.
	activate: proc(b: ^Backend, surface: Surface, token: string),
	// key_name is what the platform calls a key (`Ev_Key.native`): the xkb
	// keysym name here ("q", "comma", "Print", "XF86AudioPlay"), which is
	// what a keyboard configuration file is written in. "" when the
	// platform cannot say. Optional.
	key_name: proc(b: ^Backend, native: u32, allocator := context.allocator) -> string,
	// watch_fd puts `fd` in the backend's poll set (or takes it out), so a
	// connection the toolkit owns — the accessibility bus — wakes the loop
	// when it has something. The backend reads nothing from it; waking is
	// the whole job. Optional: without it such a connection is only served
	// when something else wakes the loop.
	watch_fd: proc(b: ^Backend, fd: i32, on: bool),
	// watch reports changes to `path` (a file, or a directory and its
	// entries) as Ev_Watch carrying `token` until unwatch. Optional: the
	// toolkit's `watch` subscription reports nothing without it.
	watch:   proc(b: ^Backend, path: string, token: u64) -> bool,
	unwatch: proc(b: ^Backend, token: u64),
	// Drags across apps (see Ev_Drag_*). Optional as a group. `serial` is
	// the button press that started the drag. `icon` is the picture the
	// drag carries, to copy and show beside the pointer; a backend with
	// nowhere to put one ignores it.
	drag_start:   proc(b: ^Backend, surface: Surface, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool,
	drag_accept:  proc(b: ^Backend, accept: bool),                                           // over a target that would take it: cursor feedback for the source
	drag_receive: proc(b: ^Backend, mime: string) -> bool, // after Drop: ask for the data in one form, which comes as Ev_Drag_Data (false: not offered)
	drag_finish:  proc(b: ^Backend, accepted: bool),                                         // after Drop: done with it
}
