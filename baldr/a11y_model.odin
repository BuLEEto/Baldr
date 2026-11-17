package baldr

// What to tell an assistive technology about this application — decided once,
// for every platform.
//
// Each desktop has its own interface (AT-SPI2 on the Linux desktops, UI
// Automation on Windows, NSAccessibility on macOS) and they differ in how
// they ask and how they are told, but they agree almost entirely on *what*
// they want to know: what each object is, what it is called, what state it
// is in, what it is worth, who its children are, and what just changed.
// This file is that answer. A platform file turns it into its own protocol
// and nothing more.
//
// The answer is the hard part: which nodes a reader is shown and which are
// walked through, when an object is "showing" rather than merely visible,
// what a focused list says about the row under its cursor. Deciding it once
// keeps the bridges from disagreeing, and the headless tests over this file
// run on all three platforms, so a bridge only has to be right about
// delivery.
//
// The tree a reader walks is the one `access_dump` prints: a node with role
// None is transparent, its children standing in its place, and hidden or
// inert subtrees are not there at all. The application's children are the
// app's windows, in the order they opened.
//
// An id names a node in a particular window and nothing else: the window
// index + 1 on top, then the node handle's generation, then its index. The
// generation is carried whole, so an id whose node has been freed and its
// slot reused resolves to nothing rather than to whatever took its place —
// the reader is told the object is defunct, which is what it expects of
// something taken away under it. Id 0 is the application; a window's own
// object has a zero generation, which no live node has.

import "core:strings"

// ------------------------------------------------------------- the vocabulary

// A11y_Role is what an object is, as a platform is told. It is the node's
// own Role with the widget taken into account — a password field and a
// document editor are both `Text_Input` to a view and are not the same thing
// to a reader — so it is a vocabulary of its own rather than an alias.
@(private)
A11y_Role :: enum u8 {
	None,
	Application,
	Window,
	Panel,         // a box with no meaning of its own
	Group,         // …and one with a name, so a reader announces it
	Static,        // text that is read, not typed into
	Heading,
	Label,
	Image,
	Button,
	Toggle_Button,
	Link,
	Check_Box,
	Radio_Button,
	Radio_Group,   // the set one Radio_Button is picked from — macOS navigates it as a unit
	Slider,
	Spin_Button,
	Entry,         // a single-line field
	Password,      // …whose contents must never be read out
	Document,      // a body of text, read line by line
	Combo_Box,
	List,
	List_Item,
	Table,
	Row,
	Cell,
	Column_Header,
	Tree,
	Tree_Item,
	Tab_List,
	Tab,
	Menu_Bar,
	Menu,
	Menu_Item,
	Dialog,
	Alert,
	Status_Bar,
	Progress_Bar,
	Tooltip,
	Separator,
	Scroll_Area,
	Tool_Bar,
	Terminal,
}

// A11y_Flag is one thing a platform is told about an object's state.
//
// This is **not** `A11y_State`, which is what a *widget* declares about
// itself. This is what a platform hears, which is the widget's declaration
// plus everything derived from the tree it sits in: whether it can be seen
// right now, whether it can take the keyboard, whether it holds one line or
// many. `a11y_flags` is the one place that derivation happens.
@(private)
A11y_Flag :: enum u8 {
	Active,        // the window a reader is in
	Busy,
	Checkable,
	Checked,
	Collapsed,
	Defunct,       // taken away under the reader
	Editable,
	Enabled,
	Expandable,
	Expanded,
	Focusable,
	Focused,
	Indeterminate, // a checkbox that is neither
	Invalid_Entry,
	Is_Default,    // the button Enter presses in its dialog
	Modal,
	Multi_Line,
	Has_Popup,
	Pressed,
	Read_Only,
	Required,
	Resizable,
	Selectable_Text,
	Selected,
	Sensitive,     // it can be interacted with (a dimmed control cannot)
	Showing,       // it is on screen now — see a11y_showing
	Single_Line,
	Visible,       // it would be on screen if nothing were in the way
}

@(private)
A11y_Flags :: bit_set[A11y_Flag; u64]

// A11Y_APP_ID is the id of the application object: never a real node's.
@(private)
A11Y_APP_ID :: u64(0)

// A11y_Obj is one accessible object, as the toolkit sees it. `extents` is
// x, y, width, height in its **window's** coordinates, and `origin` is where
// that window is on screen when the desktop says (Wayland does not tell a
// toplevel, so `origin_known` is often false and screen coordinates are then
// the window's own — the best a client can do).
@(private)
A11y_Obj :: struct {
	id:           u64,
	parent:       u64,
	index:        int, // its place among its parent's children (-1 unknown)
	child_count:  int,
	role:         A11y_Role,
	name:         string,
	describe:     string,
	flags:        A11y_Flags,
	extents:      [4]i32,
	origin:       [2]i32,
	origin_known: bool,
	// what it is worth: a slider, a spin button, a progress bar. A reader
	// says "40 percent" from these.
	has_value:               bool,
	value, value_min, value_max: f64,
	value_step:              f64,    // how much one step moves it (0: unknown)
	value_text:              string, // the value as it is read ("3:25", "40 %"); "" says the number is enough
	// whether it holds text a reader can read character by character (an
	// entry, an editor): `a11y_obj_text` is asked for the text itself.
	has_text:                bool,
	// …and whether a reader may type into it. A read-only editor holds text
	// and is not editable, which is exactly the distinction a reader needs.
	editable:                bool,
	// whether pressing it does something — a button, a checkbox, a menu
	// item — so a reader can offer to press it.
	has_action:              bool,
	// whether it holds a selection a reader can read (a list, a tree, a
	// table): the selected children are the ones whose flags say so.
	has_selection:           bool,
}

// A11y_Text is what an object holding text answers with. Offsets are
// **bytes** into `text`, the way a toolkit keeps them; a platform converts
// to whatever its own interface counts in.
@(private)
A11y_Text :: struct {
	text:     string,
	caret:    int, // byte offset of the caret (-1: it has none just now)
	sel_lo:   int, // the selection, in bytes; equal when nothing is selected
	sel_hi:   int,
	editable: bool,
}

// A11y_Clip is a clipboard action a reader asks for on an object holding
// text, which it does exactly as that widget's own shortcut would.
@(private)
A11y_Clip :: enum u8 { Cut, Copy, Paste }

// A11y_Act is something a reader asks us to *do*, rather than tell it:
// pressing a button for someone who cannot, moving focus to what they
// picked, or moving a caret. It goes back through the run loop because
// acting means queueing the app's message, which the tree alone cannot do.
@(private)
A11y_Act :: enum {
	Click, // activate the node: the button's message, the checkbox's flip
	Focus, // move the keyboard focus to it
	Edit,  // replace text in it, as typing would (a11y.edit says what)
	Clip,  // cut, copy or paste in it (a11y.clip says which)
	Wake,  // something changed under us: build a frame
}

// A11y_Window is one window the bridge tells the desktop about.
@(private)
A11y_Window :: struct {
	tree:         ^Tree,
	title:        string,
	origin:       [2]i32, // where it is on screen, when the desktop says
	origin_known: bool,
	active:       bool,
	// the platform's own object for this window (an NSView on macOS, an
	// HWND on Windows), for an interface that is answered *through* the
	// window rather than on a bus of its own. Nil where there is none, and
	// ignored by a bridge that does not need one.
	native:       rawptr,
	// how to act on this window (set by the run loop, which has the app's
	// message type); nil in tests, and then nothing can be acted on.
	act:          proc(user: rawptr, n: Node, what: A11y_Act) -> bool,
	user:         rawptr,
	// …and how to wake the loop once something has been acted on. Acting
	// queues the app's message and marks the surface for a frame, but a loop
	// asleep waiting for input notices neither, so a reader's press would
	// change nothing on screen until the next real input. Waking here keeps
	// that the same on every platform, however each delivers the call.
	wake:         proc(user: rawptr),
	wake_user:    rawptr,
}

// --------------------------------------------------------- what we say, and when

// A11y_Said is one thing the toolkit has decided to tell the desktop. A
// platform file delivers it; a test watches for it.
//
// It is a union rather than a flat record so that a new bridge cannot
// quietly forget one: a `switch` over it that misses a case is a compile
// error, which is the only reminder that reliably arrives.
@(private)
A11y_Said :: union {
	Said_Focus,
	Said_Flag,
	Said_Window,
	Said_Name,
	Said_Describe,
	Said_Value,
	Said_Caret,
	Said_Text_Edit,
	Said_Text_Selection,
	Said_Active_Item,
	Said_Selection,
	Said_Children,
	Said_Announce,
}

// Said_Focus: the keyboard focus arrived at this object. (Nothing says it
// *left* one: the flag going off does that, and a platform that wants only
// the arrival ignores the other.)
@(private)
Said_Focus :: struct { id: u64 }

// Said_Flag: one of an object's state flags went on or off.
@(private)
Said_Flag :: struct {
	id:   u64,
	flag: A11y_Flag,
	on:   bool,
}

// Said_Window: a window was activated or deactivated.
@(private)
Said_Window :: struct {
	id:      u64,
	active:  bool,
	title:   string, // on activation, what it is called
}

// Said_Name / Said_Describe: an object's name or description changed under
// the reader.
@(private)
Said_Name     :: struct { id: u64, name: string }
@(private)
Said_Describe :: struct { id: u64, describe: string }

// Said_Value: a slider, spin button or progress bar is worth something else
// now.
@(private)
Said_Value :: struct { id: u64, value: f64 }

// Said_Caret: the caret in an object holding text is at `at` — in
// **characters**, which is what every platform's text interface counts in.
@(private)
Said_Caret :: struct { id: u64, at: int }

// Said_Text_Edit: `count` characters were inserted at `at`, or deleted from
// there, carrying the text itself so a reader can echo what was typed.
@(private)
Said_Text_Edit :: struct {
	id:       u64,
	inserted: bool,
	at:       int,
	count:    int,
	text:     string,
}

// Said_Text_Selection: what is selected inside an object holding text
// changed.
@(private)
Said_Text_Selection :: struct { id: u64 }

// Said_Active_Item: the item the cursor is on inside this object is now
// `child`. A view that keeps the focus itself — a list, a grid, a tree — has
// no other way to say which row is current: focus never moved, so a reader
// following the keyboard would hear nothing at all.
@(private)
Said_Active_Item :: struct {
	id:    u64,
	child: u64,
	index: int,
}

// Said_Selection: what is selected inside a container changed — another row
// picked, a Ctrl+A, a band drawn over half a grid.
@(private)
Said_Selection :: struct { id: u64 }

// Said_Children: a child arrived at, or left, index `index` of this object.
@(private)
Said_Children :: struct {
	id:    u64,
	added: bool,
	index: int,
	child: u64,
}

// Said_Announce: something a reader should say out loud although nothing
// took focus — a copy that started, a file that finished, an error that
// appeared somewhere else on the screen. `assertive` interrupts what is
// being spoken; polite waits its turn.
@(private)
Said_Announce :: struct {
	id:        u64,
	text:      string,
	assertive: bool,
}

// a11y_say hands one decision to the platform, and to anything watching.
// Strings in `said` point at the toolkit's own storage and are only valid
// for the call: a platform that keeps one copies it.
@(private)
a11y_say :: proc(said: A11y_Said) {
	if a11y.watcher != nil do a11y.watcher(a11y.watch_user, said)
	a11y_deliver(said)
}

// a11y_said_id is which object a decision is about, for a platform that
// dispatches on it before looking at the kind.
@(private)
a11y_said_id :: proc(said: A11y_Said) -> u64 {
	switch s in said {
	case Said_Focus:          return s.id
	case Said_Flag:           return s.id
	case Said_Window:         return s.id
	case Said_Name:           return s.id
	case Said_Describe:       return s.id
	case Said_Value:          return s.id
	case Said_Caret:          return s.id
	case Said_Text_Edit:      return s.id
	case Said_Text_Selection: return s.id
	case Said_Active_Item:    return s.id
	case Said_Selection:      return s.id
	case Said_Children:       return s.id
	case Said_Announce:       return s.id
	}
	return 0
}

// ------------------------------------------------------------- the bridge's books

@(private)
A11y :: struct {
	windows:  [dynamic]A11y_Window,
	app_name: string,
	started:  bool,
	// `attached`: this platform can be asked about us (on Linux, the bus
	// connection stands; on macOS, always, since AppKit asks a view whenever
	// anything wants to know). `live`: someone is actually listening, which
	// decides whether diffing the tree for changes is worth it. The tree is
	// answered off `attached`, so a client that never announces itself (an
	// automation tool) gets the truth on the first ask.
	attached: bool,
	live:     bool,
	// what anything watching what we say hears (the tests; the debug log)
	watcher:    proc(user: rawptr, said: A11y_Said),
	watch_user: rawptr,
	// what the desktop was last told about (a11y_events.odin)
	watch:         A11y_Watch,
	active_window: u64,
	// what an Edit or a Clip act is carrying: the run loop reads these when
	// it is called, because a proc pointer cannot take the toolkit's own
	// types through the bridge
	edit: struct {
		node:     Node,
		from, to: int,
		text:     string,
		want:     bool,
	},
	clip: struct {
		node: Node,
		act:  A11y_Clip,
		want: bool,
	},
	live_said:     map[u64]string, // what each live region last said out loud (a11y_events.odin)
	// …and about every object it has asked us for (a11y_changes.odin)
	known:         map[u64]A11y_Seen,
	order:         [dynamic]u64, // the same ids, for looking at a few per wake-up
	cursor:        int,
	sweeping:      bool, // inside the sweep: questions we ask ourselves are not the reader asking
}

@(private, thread_local)
a11y: A11y

// a11y_on says whether anything is listening, so the run loop can skip its
// work. A platform keeps it current — it is set when the bridge starts and
// cleared when it stops or the connection goes.
@(private)
a11y_on :: proc() -> bool { return a11y.live }

// a11y_windows tells the bridge which windows exist now. The run loop calls
// it when its surfaces change; the slice is copied.
@(private)
a11y_windows :: proc(windows: []A11y_Window) {
	if !a11y.attached do return
	clear(&a11y.windows)
	append(&a11y.windows, ..windows)
	when ODIN_OS == .Darwin {
		// macOS is asked through the window, so this is where the toolkit's
		// root objects are hung on it. It costs a comparison when the roots
		// have not changed, which is every frame but the ones that matter.
		ax_bridge_attach()
	} else when ODIN_OS == .Windows {
		// Windows is asked through the window too, by a message, so this is
		// where a new one is subclassed to hear it.
		uia_bridge_attach()
	}
}

// a11y_books_open and a11y_books_close are the half of starting and stopping
// that is the same everywhere: the window list and the app's name. A platform
// calls them around its own connection.
@(private)
a11y_books_open :: proc(app_name: string) {
	a11y.app_name = strings.clone(app_name)
	a11y.windows = make([dynamic]A11y_Window)
}

@(private)
a11y_books_close :: proc() {
	a11y_watch_free(&a11y.watch)
	a11y_forget()
	delete(a11y.app_name)
	delete(a11y.windows)
	a11y = {}
}

// ------------------------------------------------------------------ the seam
//
// Six procedures reach a platform, and this is the whole of the dispatch.
// It is `when` inside a body rather than one stub file per platform because
// a build tag cannot say "every platform but these three" — and this way a
// platform that has no bridge needs no file at all, while one that does
// cannot forget a piece: leave a proc out and the branch below will not
// compile.

// a11y_start puts this application where an assistive technology can find
// it. False (with a reason) when there is nowhere to put it — no reader
// running, or a desktop without an accessibility interface at all — and then
// nothing else here does anything.
@(private)
a11y_start :: proc(app_name: string) -> (ok: bool, why: string) {
	if a11y.started do return a11y.live, ""
	a11y.started = true
	a11y_books_open(app_name)
	when ODIN_OS == .Linux {
		ok, why = atspi_bridge_start()
		a11y.live = ok // AT-SPI only answers at all when a reader has asked for a bus
	} else when ODIN_OS == .Darwin {
		ok, why = ax_bridge_start()
		a11y.live = ax_bridge_listening()
	} else when ODIN_OS == .Windows {
		ok, why = uia_bridge_start()
		a11y.live = uia_bridge_listening()
	} else {
		ok, why = false, "no accessibility bridge on this platform"
	}
	a11y.attached = ok
	return
}

@(private)
a11y_stop :: proc() {
	if !a11y.started do return
	when ODIN_OS == .Linux {
		atspi_bridge_stop()
	} else when ODIN_OS == .Darwin {
		ax_bridge_stop()
	} else when ODIN_OS == .Windows {
		uia_bridge_stop()
	}
	a11y_books_close()
}

// a11y_fd is a socket to wait on beside the display's, for an interface that
// has one (-1: none — a platform where a reader's questions arrive inside
// the ordinary event loop, which is both of the others).
@(private)
a11y_fd :: proc() -> i32 {
	when ODIN_OS == .Linux {
		return atspi_bridge_fd()
	} else {
		return -1
	}
}

// a11y_attached says a platform can be asked about us at all, which is when
// the window list is worth keeping current.
@(private)
a11y_attached :: proc() -> bool { return a11y.attached }

// a11y_pump answers whatever was asked while we were away.
@(private)
a11y_pump :: proc() {
	when ODIN_OS == .Linux {
		atspi_bridge_pump()
	} else when ODIN_OS == .Darwin {
		// Nothing to read — AppKit asks us inside its own loop — but
		// VoiceOver can be switched on while we are running, and this is
		// where we notice.
		a11y.live = ax_bridge_listening()
	} else when ODIN_OS == .Windows {
		// Likewise: a client's questions arrive as window messages, and
		// UiaClientsAreListening is how we hear that one turned up.
		a11y.live = uia_bridge_listening()
	}
}

// a11y_deliver hands one decision to the platform, which says it in its own
// words. Nothing listening, or no bridge at all: nothing to do.
@(private)
a11y_deliver :: proc(said: A11y_Said) {
	when ODIN_OS == .Linux {
		atspi_bridge_deliver(said)
	} else when ODIN_OS == .Darwin {
		ax_bridge_deliver(said)
	} else when ODIN_OS == .Windows {
		uia_bridge_deliver(said)
	}
}

// a11y_debug is a line under BALDR_A11Y_DEBUG, nothing otherwise.
@(private)
a11y_debug :: proc(format: string, args: ..any) {
	when ODIN_OS == .Linux {
		atspi_bridge_debug(format, ..args)
	} else when ODIN_OS == .Darwin {
		ax_bridge_debug(format, ..args)
	} else when ODIN_OS == .Windows {
		uia_bridge_debug(format, ..args)
	}
}

// ------------------------------------------------------------------ the tree

// The three fields of an id. A node's index is bounded by the pool it sits
// in — a tree of sixteen million nodes is not a thing — and there is room
// for 255 windows; a node past either bound is simply not exposed.
@(private) A11Y_WINDOW_SHIFT :: 56
@(private) A11Y_GEN_SHIFT    :: 24
@(private) A11Y_INDEX_MASK   :: u64(1) << A11Y_GEN_SHIFT - 1
@(private) A11Y_WINDOW_MAX   :: 255

// a11y_id packs a window and a node into one id; a11y_unpack takes it apart.
// NODE_NONE is the window's own object. False when the node cannot be named
// (see the bounds above), and then the reader never hears about it.
@(private)
a11y_id :: proc(window: int, n: Node) -> (u64, bool) {
	if window < 0 || window >= A11Y_WINDOW_MAX do return 0, false
	base := u64(window + 1) << A11Y_WINDOW_SHIFT
	if n == NODE_NONE do return base, true
	idx, gen := node_index(n), node_gen(n)
	if u64(idx) > A11Y_INDEX_MASK do return 0, false
	return base | u64(gen) << A11Y_GEN_SHIFT | u64(idx), true
}

@(private)
a11y_unpack :: proc(id: u64) -> (window: int, n: Node, ok: bool) {
	w := int(id >> A11Y_WINDOW_SHIFT) - 1
	if w < 0 || w >= len(a11y.windows) do return 0, NODE_NONE, false
	gen := u32(id >> A11Y_GEN_SHIFT & 0xFFFF_FFFF)
	if gen == 0 do return w, NODE_NONE, true // the window itself: no live node has generation 0
	return w, node_make(u32(id & A11Y_INDEX_MASK), gen), true
}

// a11y_shown: a node a reader should see. A role of None is transparent —
// its children stand in its place — and hidden or inert subtrees are gone,
// exactly as access_dump prints them. The tree's own root and its overlay
// are transparent too: the window is the one frame a reader is shown, and
// both are walked through by a11y_roots, so neither may turn up as an
// object or as anything's parent (a reader would see a frame inside a frame
// with no index among its siblings).
@(private)
a11y_shown :: proc(t: ^Tree, n: Node) -> bool {
	if t != nil && (n == t.root || n == t.overlay) do return false
	d := node_get(t, n)
	return d != nil && d.flags & {.Hidden, .Inert} == {} && d.access.role != .None
}

// a11y_reachable: an object a reader can be handed — shown itself, and
// inside nothing hidden or inert. A node under a hidden ancestor still has
// a rect and answers every question about itself, but its parent does not
// list it among its children, so a reader would get an object it cannot
// place. Gone is a better answer than unplaceable.
@(private)
a11y_reachable :: proc(t: ^Tree, n: Node) -> bool {
	if !a11y_shown(t, n) do return false
	for cur := node_parent(t, n); cur != NODE_NONE; cur = node_parent(t, cur) {
		if !a11y_walkable(t, cur) do return false
	}
	return true
}

// a11y_actable: a node a reader may press, type into or move a caret in —
// reachable, and not behind an open dialog. The window behind a dialog is
// still read (a reader may look back at what the dialog is about), but a
// click there lands on the scrim, and a reader's action does no more.
@(private)
a11y_actable :: proc(t: ^Tree, n: Node) -> bool {
	return a11y_reachable(t, n) && !behind_modal(t, n)
}

@(private)
a11y_walkable :: proc(t: ^Tree, n: Node) -> bool {
	d := node_get(t, n)
	return d != nil && d.flags & {.Hidden, .Inert} == {}
}

// a11y_kids collects the accessible children of `n`: the nearest shown
// descendants, with transparent nodes walked through.
@(private)
a11y_kids :: proc(t: ^Tree, n: Node, out: ^[dynamic]Node) {
	d := node_get(t, n)
	if d == nil do return
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if !a11y_walkable(t, c) do continue
		if a11y_shown(t, c) {
			append(out, c)
		} else {
			a11y_kids(t, c, out)
		}
	}
}

// a11y_roots are a window's top-level accessible nodes: the widgets under
// its tree, then whatever is in its overlay (popovers, menus and dialogs
// live there). The tree's own root is the window — a reader is shown one
// frame, not a frame inside a frame — so it is walked through, as is the
// overlay.
@(private)
a11y_roots :: proc(t: ^Tree, out: ^[dynamic]Node) {
	a11y_kids(t, t.root, out)
	a11y_kids(t, t.overlay, out)
}

// a11y_parent_of is the nearest shown ancestor of `n`, or NODE_NONE when it
// hangs straight off the window.
@(private)
a11y_parent_of :: proc(t: ^Tree, n: Node) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	for cur := d.parent; cur != NODE_NONE; {
		if a11y_shown(t, cur) do return cur
		p := node_get(t, cur)
		if p == nil do break
		cur = p.parent
	}
	return NODE_NONE
}

// a11y_index is where `n` sits among its accessible siblings.
@(private)
a11y_index :: proc(t: ^Tree, n: Node) -> int {
	kids := make([dynamic]Node, context.temp_allocator)
	if parent := a11y_parent_of(t, n); parent != NODE_NONE {
		a11y_kids(t, parent, &kids)
	} else {
		a11y_roots(t, &kids)
	}
	for k, i in kids do if k == n do return i
	return -1
}

// a11y_obj answers "what is this object?".
@(private)
a11y_obj :: proc(id: u64) -> (out: A11y_Obj, ok: bool) {
	if id == A11Y_APP_ID {
		return A11y_Obj{
			id = id, parent = 0, index = -1, role = .Application,
			name = a11y.app_name, child_count = len(a11y.windows), flags = {.Enabled, .Sensitive},
		}, true
	}
	window, n, unpacked := a11y_unpack(id)
	if !unpacked do return
	w := a11y.windows[window]
	t := w.tree
	if t == nil do return

	kids := make([dynamic]Node, context.temp_allocator)
	if n == NODE_NONE { // the window itself
		a11y_roots(t, &kids)
		flags := A11y_Flags{.Enabled, .Sensitive, .Showing, .Visible, .Resizable}
		if w.active do flags += {.Active}
		win := A11y_Obj{
			id = id, parent = A11Y_APP_ID, index = window, role = .Window,
			name = w.title, child_count = len(kids), flags = flags,
			extents = {0, 0, i32(t.viewport.x), i32(t.viewport.y)},
			origin = w.origin, origin_known = w.origin_known,
		}
		a11y_seen_record(id, t, n, win) // the reader is holding the window now
		return win, true
	}
	d := node_get(t, n)
	if d == nil || !a11y_reachable(t, n) do return
	a11y_kids(t, n, &kids)
	parent := a11y_parent_of(t, n)
	parent_id, _ := a11y_id(window, parent) // parent NODE_NONE: the window's own object
	out = A11y_Obj{
		id          = id,
		parent      = parent_id,
		index       = a11y_index(t, n),
		child_count = len(kids),
		role        = a11y_role_of(t, n, d),
		name        = d.access.name,
		describe    = d.access.describe,
		flags       = a11y_flags(t, n, d),
		extents     = {i32(d.abs.x), i32(d.abs.y), i32(d.abs.w), i32(d.abs.h)},
		origin      = w.origin,
		origin_known = w.origin_known,
		has_text    = a11y_has_text(t, n, d),
		editable    = a11y_has_text(t, n, d) && a11y_editable(t, n, d),
		has_action  = a11y_has_action(t, n, d),
		has_selection = a11y_has_selection(d),
	}
	if d.access.has_value && !out.has_text { // a text field's "value" is its text, which the text interface serves
		out.has_value = true
		out.value     = f64(d.access.value)
		out.value_min = f64(d.access.value_min)
		out.value_max = f64(d.access.value_max)
		out.value_step = f64(access_value_step(t, n, d))
		out.value_text = d.access.value_text // a slider's formatted value ("3:25"), when it has one
	}
	a11y_seen_record(id, t, n, out) // the reader is holding this one now
	return out, true
}

// a11y_obj_child is the id of one child, by index.
@(private)
a11y_obj_child :: proc(id: u64, index: int) -> (u64, bool) {
	if index < 0 do return 0, false
	if id == A11Y_APP_ID {
		if index >= len(a11y.windows) do return 0, false
		return a11y_id(index, NODE_NONE)
	}
	window, n, unpacked := a11y_unpack(id)
	if !unpacked do return 0, false
	t := a11y.windows[window].tree
	if t == nil do return 0, false
	kids := make([dynamic]Node, context.temp_allocator)
	if n == NODE_NONE { a11y_roots(t, &kids) } else { a11y_kids(t, n, &kids) }
	if index >= len(kids) do return 0, false
	return a11y_id(window, kids[index])
}

// a11y_has_text: an object a reader can read character by character — an
// entry or an editor, not a label (a label's text *is* its name).
@(private)
a11y_has_text :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> bool {
	#partial switch d.access.role {
	// A field is a text object whether or not anything is in it: an empty
	// one is still somewhere to type, and with no text interface a reader
	// would find no characters, no selection and no insertion point.
	case .Text_Input, .Search_Box, .Combo_Box: return true
	// A static that holds a body of text and says so is read through the
	// text interface: line by line, and followed as it grows. A label never
	// sets value_text, so it stays a name.
	case .Text: return len(d.access.value_text) > 0
	}
	if _, is_area := t.areas[n]; is_area do return true
	return false
}

// a11y_has_action: pressing it does something, so a reader can offer to
// press it for someone. The role says — it is the widgets that hand out
// roles, and they hand out these ones exactly when a press means something.
// (An entry is not one of them: pressing an entry only puts focus in it,
// which is what taking the focus is for.)
@(private)
a11y_has_action :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> bool {
	if .Disabled in d.flags do return false
	#partial switch d.access.role {
	case .Button, .Toggle_Button, .Checkbox, .Radio, .Switch, .Link,
	     .Menu_Item, .Tab, .List_Item, .Tree_Item, .Row, .Cell, .Column_Header:
		return true
	}
	return false
}

// a11y_has_selection: a container whose children are chosen from.
@(private)
a11y_has_selection :: proc(d: ^Node_Data) -> bool {
	#partial switch d.access.role {
	case .List, .Tree, .Table, .Tab_List, .Menu, .Combo_Box: return true
	}
	return false
}

// access_value_step is how far one step moves a value — what a reader offers
// when someone asks it to nudge a control. It is the widget's own step where
// it has one, and a hundredth of the range otherwise, which is what a
// slider's arrow keys move by.
@(private)
access_value_step :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> f32 {
	if st, is_slider := t.sliders[n]; is_slider && st.step > 0 do return st.step
	// A number input's own step is the one to offer: 0 to 99 steps by one,
	// not by the 0.99 a hundredth of the range works out at. The map is keyed
	// by the input's outer node and the Spin_Button role is on its field, so
	// this looks for the state whose field is the node asked about (one entry
	// per number input on screen).
	for _, st in t.spins do if st != nil && st.field == n && st.step > 0 do return st.step
	span := d.access.value_max - d.access.value_min
	if span <= 0 do return 0
	return span / 100
}

// a11y_obj_text answers "what text does this hold, and where is its caret?"
// for the fields and editors that hold some. Offsets are bytes into the same
// string, which is what the widgets keep.
@(private)
a11y_obj_text :: proc(id: u64) -> (out: A11y_Text, ok: bool) {
	window, n, unpacked := a11y_unpack(id)
	if !unpacked || n == NODE_NONE do return
	t := a11y.windows[window].tree
	if t == nil do return
	d := node_get(t, n)
	if d == nil || !a11y_shown(t, n) do return
	out.text = d.access.value_text
	out.caret = -1
	if s, is_input := &t.inputs[n]; is_input {
		// value_text is what the field *draws* — bullets in a password
		// field, the composition included — so the offsets are too
		src := input_src(s)
		out.caret = input_display_off(s, src, s.caret)
		out.sel_lo = input_display_off(s, src, min(s.caret, s.anchor))
		out.sel_hi = input_display_off(s, src, max(s.caret, s.anchor))
		out.editable = .Readonly not_in d.access.states
		return out, true
	}
	if st, is_term := &t.terminals[n]; is_term { // the screen, a line a row, the caret at its cursor
		out.caret = st.caret
		out.sel_lo, out.sel_hi = st.caret, st.caret
		return out, true
	}
	if s, is_area := &t.areas[n]; is_area {
		doc := s.doc
		if doc == nil do return out, len(out.text) > 0
		lo, hi := pos_order(s.caret, s.anchor)
		out.caret = document_flat_off(doc, s.caret)
		out.sel_lo = document_flat_off(doc, lo)
		out.sel_hi = document_flat_off(doc, hi)
		out.editable = !s.readonly
		return out, true
	}
	return out, len(out.text) > 0
}

// ------------------------------------------------------------------- acting

// a11y_act asks the run loop to do something to a node: it owns the app's
// message type, which is what acting needs.
@(private)
a11y_act :: proc(window: int, n: Node, what: A11y_Act) -> bool {
	if window < 0 || window >= len(a11y.windows) do return false
	w := a11y.windows[window]
	if w.act == nil do return false
	done := w.act(w.user, n, what)
	if done && w.wake != nil do w.wake(w.wake_user)
	return done
}

// a11y_can_act: there is a run loop behind this window to act through. A
// tree on its own (a headless test) can be read but not acted on, and
// saying so before touching anything keeps the two answers honest.
@(private)
a11y_can_act :: proc(window: int) -> bool {
	return window >= 0 && window < len(a11y.windows) && a11y.windows[window].act != nil
}

// a11y_do_action is a reader pressing a button for someone: the same thing
// a click does, message and all. Like every action here it reaches only what
// a reader is shown: nothing hidden, and nothing behind an open dialog, which
// any program on the accessibility bus could otherwise press or type into.
@(private)
a11y_do_action :: proc(id: u64) -> bool {
	window, n, ok := a11y_unpack(id)
	if !ok || n == NODE_NONE do return false
	t := a11y.windows[window].tree
	if t == nil || !a11y_actable(t, n) do return false
	d := node_get(t, n)
	if d == nil || .Disabled in d.flags do return false
	return a11y_act(window, n, .Click)
}

// a11y_grab_focus moves the keyboard focus to a node, which is how a reader
// hands someone what they picked out of the tree.
@(private)
a11y_grab_focus :: proc(id: u64) -> bool {
	window, n, ok := a11y_unpack(id)
	if !ok || n == NODE_NONE do return false
	t := a11y.windows[window].tree
	if t == nil || !focusable(t, n) do return false
	return a11y_act(window, n, .Focus)
}

// a11y_editable: a reader may type into it. A read-only editor holds text
// and is not editable, which is the distinction a reader needs before it
// offers someone a way to change something they cannot change.
@(private)
a11y_editable :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> bool {
	if .Disabled in d.flags || .Readonly in d.access.states do return false
	if s, is_area := &t.areas[n]; is_area do return !s.readonly
	if _, is_input := t.inputs[n]; is_input do return true
	return false
}

// a11y_select_range puts a field or editor's selection between two byte
// offsets, so an action that works on a selection works on what the reader
// asked for.
@(private)
a11y_select_range :: proc(id: u64, from, to: int) -> bool {
	window, n, ok := a11y_unpack(id)
	if !ok || n == NODE_NONE do return false
	t := a11y.windows[window].tree
	if t == nil || !a11y_can_act(window) || !a11y_actable(t, n) do return false
	if s, is_input := &t.inputs[n]; is_input {
		src := input_src(s)
		s.anchor = grapheme_snap(src, clamp(input_src_off(s, src, from), 0, len(src)))
		s.caret = grapheme_snap(src, clamp(input_src_off(s, src, to), 0, len(src)))
		return a11y_act(window, n, .Wake)
	}
	if s, is_area := &t.areas[n]; is_area && s.doc != nil {
		s.anchor = document_pos_at(s.doc, from)
		s.caret = document_pos_at(s.doc, to)
		return a11y_act(window, n, .Wake)
	}
	return false
}

// a11y_edit is a reader typing on someone's behalf: the same edit typing
// makes, through the same path, so the undo steps, any composition in
// flight and whatever the app watches for a change all behave as they would
// under a keyboard. It is never a "set the text" back door.
@(private)
a11y_edit :: proc(id: u64, from, to: int, text: string) -> bool {
	window, n, ok := a11y_unpack(id)
	if !ok || n == NODE_NONE do return false
	t := a11y.windows[window].tree
	if t == nil || !a11y_actable(t, n) do return false
	d := node_get(t, n)
	if d == nil || !a11y_editable(t, n, d) || !a11y_can_act(window) do return false
	a11y.edit = {node = n, from = from, to = to, text = strings.clone(text, t.allocator), want = true}
	done := a11y_act(window, n, .Edit)
	delete(a11y.edit.text, t.allocator)
	a11y.edit = {}
	return done
}

// a11y_clip is one of the clipboard actions, exactly as the widget's own
// shortcut does it.
@(private)
a11y_clip :: proc(id: u64, act: A11y_Clip) -> bool {
	window, n, ok := a11y_unpack(id)
	if !ok || n == NODE_NONE do return false
	t := a11y.windows[window].tree
	if t == nil || !a11y_can_act(window) || !a11y_actable(t, n) do return false
	a11y.clip = {node = n, act = act, want = true}
	done := a11y_act(window, n, .Clip)
	a11y.clip = {}
	return done
}

// a11y_set_caret puts the caret of a field or editor at a byte offset.
@(private)
a11y_set_caret :: proc(id: u64, byte_off: int) -> bool {
	window, n, ok := a11y_unpack(id)
	if !ok || n == NODE_NONE do return false
	t := a11y.windows[window].tree
	if t == nil || !a11y_can_act(window) || !a11y_actable(t, n) do return false // refuse before moving anything, not after
	if s, is_input := &t.inputs[n]; is_input {
		src := input_src(s)
		at := grapheme_snap(src, clamp(input_src_off(s, src, byte_off), 0, len(src)))
		s.caret, s.anchor = at, at
		return a11y_act(window, n, .Wake)
	}
	if s, is_area := &t.areas[n]; is_area && s.doc != nil {
		p := document_pos_at(s.doc, byte_off)
		s.caret, s.anchor = p, p
		return a11y_act(window, n, .Wake)
	}
	return false
}

// ----------------------------------------------------- roles and state flags

// a11y_role_of is the role a reader is told, which is the node's with what
// the widget is taken into account: a document editor is text rather than an
// entry (a reader reads one and fills in the other), and a password field
// says so, so nothing reads it aloud by mistake.
@(private)
a11y_role_of :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> A11y_Role {
	#partial switch d.access.role {
	case .Text_Input, .Search_Box:
		if _, is_area := t.areas[n]; is_area do return .Document
		if s, is_input := t.inputs[n]; is_input && s.password do return .Password
	}
	return a11y_role(d.access.role)
}

// a11y_role maps a node's declared role to the one a platform is told.
@(private)
a11y_role :: proc(r: Role) -> A11y_Role {
	switch r {
	case .None:          return .None
	case .Window:        return .Window
	case .Generic:       return .Panel
	case .Group:         return .Group
	case .Region:        return .Panel
	case .Text:          return .Static
	case .Heading:       return .Heading
	case .Label:         return .Label
	case .Image:         return .Image
	case .Button:        return .Button
	case .Toggle_Button: return .Toggle_Button
	case .Link:          return .Link
	case .Checkbox:      return .Check_Box
	case .Radio:         return .Radio_Button
	case .Radio_Group:   return .Radio_Group
	case .Switch:        return .Toggle_Button // a switch is a toggle that reads Checked where a platform has no switch of its own
	case .Slider:        return .Slider
	case .Spin_Button:   return .Spin_Button
	case .Text_Input:    return .Entry
	case .Search_Box:    return .Entry
	case .Combo_Box:     return .Combo_Box
	case .List:          return .List
	case .List_Item:     return .List_Item
	case .Table:         return .Table
	case .Row:           return .Row
	case .Cell:          return .Cell
	case .Column_Header: return .Column_Header
	case .Tree:          return .Tree
	case .Tree_Item:     return .Tree_Item
	case .Tab_List:      return .Tab_List
	case .Tab:           return .Tab
	case .Tab_Panel:     return .Panel
	case .Menu_Bar:      return .Menu_Bar
	case .Menu:          return .Menu
	case .Menu_Item:     return .Menu_Item
	case .Dialog:        return .Dialog
	case .Alert:         return .Alert
	case .Status:        return .Status_Bar
	case .Progress:      return .Progress_Bar
	case .Tooltip:       return .Tooltip
	case .Separator:     return .Separator
	case .Scroll_Area:   return .Scroll_Area
	case .Toolbar:       return .Tool_Bar
	case .Terminal:      return .Terminal
	}
	return .Panel
}

// a11y_showing is whether the node can actually be seen right now. AT-SPI's
// `visible` is "would be seen if nothing were in the way" and `showing` is
// "is being shown": a row scrolled far down a sidebar is visible and not
// showing, which is what lets a reader say what is on screen now rather than
// what merely exists.
//
// It tests the rect against every clipping ancestor's, so a scrolled-off row
// or one behind a tab page or a squeezed split falls outside. Not against the
// window: a popup is laid out in window coordinates but presents on a surface
// of its own and may sit past the window's edge, so clipping to the window
// would call an open menu not showing.
@(private)
a11y_showing :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> bool {
	if t == nil || d == nil do return true
	if d.abs.w <= 0 || d.abs.h <= 0 do return false // never laid out, or laid out to nothing
	c := rect_clip(ancestor_clip(t, n), d.abs)
	return c.w > 0 && c.h > 0
}

// a11y_flags maps a node's state to what a platform is told. Everything a
// reader needs to say "focused", "checked", "dimmed" comes from here.
@(private)
a11y_flags :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> (out: A11y_Flags) {
	s := d.access.states
	out += {.Visible} // it is in the tree and not hidden: a11y_shown said so
	if a11y_showing(t, n, d) do out += {.Showing}
	if .Disabled not_in s do out += {.Enabled, .Sensitive} // dimmed: neither
	if .Focusable in s || .Focusable in d.flags do out += {.Focusable} // most widgets say it with the flag the focus ring reads
	if .Focused in s do out += {.Focused}
	if t != nil && t.focus != NODE_NONE && n != t.focus { // the row under a focused view's cursor is where the keyboard is
		if fd := node_get(t, t.focus); fd != nil && fd.access.active == n do out += {.Focused}
	}
	if .Checked in s do out += {.Checked}
	if .Mixed in s do out += {.Indeterminate}
	if .Selected in s do out += {.Selected}
	if .Expanded in s do out += {.Expanded, .Expandable}
	if .Collapsed in s do out += {.Collapsed, .Expandable}
	if .Required in s do out += {.Required}
	if .Invalid in s do out += {.Invalid_Entry}
	if .Busy in s do out += {.Busy}
	if .Readonly in s do out += {.Read_Only}
	if .Pressed in s do out += {.Pressed}
	if .Modal in s do out += {.Modal}
	if .Default in s do out += {.Is_Default}
	if .Has_Popup in s do out += {.Has_Popup}
	#partial switch d.access.role {
	case .Checkbox, .Radio, .Switch, .Toggle_Button:
		out += {.Checkable}
	case .Text_Input, .Search_Box:
		out += {.Selectable_Text}
		if .Readonly not_in s do out += {.Editable}
		// a reader moves through a document by line and through a field by
		// character: it needs to be told which this is
		if _, is_area := t.areas[n]; is_area { out += {.Multi_Line} } else { out += {.Single_Line} }
	}
	return
}

// ------------------------------------------------- doing what a reader asked

// a11y_apply_edit does the edit the bridge asked for, through the widget's
// own typing path — not around it. Called from the run loop, which is where
// the app's message type is known.
@(private)
a11y_apply_edit :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	e := a11y.edit
	if !e.want || e.node != n do return false
	t := &ui.tree
	if s, is_input := &t.inputs[n]; is_input {
		d := node_get(t, n)
		if d == nil do return false
		src := input_src(s)
		from := grapheme_snap(src, clamp(input_src_off(s, src, e.from), 0, len(src)))
		to := grapheme_snap(src, clamp(input_src_off(s, src, e.to), 0, len(src)))
		input_replace(ui, n, d, s, from, to, sanitize_input(e.text))
		return true
	}
	if s, is_area := &t.areas[n]; is_area && s.doc != nil {
		if s.readonly do return false
		a := document_pos_at(s.doc, e.from)
		b := document_pos_at(s.doc, e.to)
		area_replace(ui, n, s, a, b, sanitize_input(e.text))
		return true
	}
	return false
}

// a11y_apply_clip does one of the clipboard actions, as the widget's own
// shortcut does it.
@(private)
a11y_apply_clip :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	c := a11y.clip
	if !c.want || c.node != n do return false
	t := &ui.tree
	if _, is_area := t.areas[n]; is_area {
		action: Editor_Action
		switch c.act {
		case .Cut:   action = .Cut
		case .Copy:  action = .Copy
		case .Paste: action = .Paste
		}
		return editor_action(ui, n, action)
	}
	if s, is_input := &t.inputs[n]; is_input {
		d := node_get(t, n)
		if d == nil do return false
		lo, hi := min(s.caret, s.anchor), max(s.caret, s.anchor)
		// the same three things Ctrl+C, Ctrl+X and Ctrl+V do in a field
		switch c.act {
		case .Copy:
			return input_copy(t, s)
		case .Cut:
			if .Readonly in d.access.states do return false
			if !input_copy(t, s) do return false
			input_replace(ui, n, d, s, lo, hi, "")
			return true
		case .Paste:
			if .Readonly in d.access.states || t.clipboard.get == nil do return false
			pasted, got := t.clipboard.get(t.clipboard.user, context.temp_allocator)
			if !got do return false
			clean := sanitize_input(pasted)
			if len(clean) == 0 do return false
			input_replace(ui, n, d, s, lo, hi, clean)
			return true
		}
	}
	return false
}
