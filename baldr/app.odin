package baldr

// The run loop: platform events → dispatch → update → view → layout → paint →
// render, waking only when something happens. Frames are paced by the
// platform (compositor frame callback / vsync), never by a timer loop.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "baldr:gpu"
import "baldr:platform"

// App is what an application hands to run(). `init` may be nil (zero State).
App :: struct($State, $Msg: typeid) {
	title:  string,
	app_id: string,   // reverse-DNS-ish id for the desktop ("" → "baldr.app")
	// icon is every window's icon on Windows and X11, read once at start (the
	// app may free it after `run` returns). Wayland takes the icon from the
	// `.desktop` file named like `app_id`, and macOS from the app bundle. On
	// Windows an icon compiled into the program (`odin build -resource:app.rc`,
	// resource id 1) is used when this is nil.
	icon:   ^Image,
	size:   [2]f32,   // logical; zero → 800×600
	// maximized asks the desktop to open the window maximised — the other
	// half of coming back the way it was left, with `size`. Like
	// `fullscreen` it is a request: `Window_State.maximized` (or
	// `ui.surface.maximized`) is what actually happened. This is
	// `Surface_Desc.maximized` for an app that declares no `surfaces`.
	maximized: bool,
	// How small and how large the desktop may let the window be dragged,
	// in logical pixels; zero on an axis is no limit. `Surface_Desc` has
	// the same pair and the same meaning — these are for an app that
	// declares no `surfaces`, which is most of them.
	min_size: [2]f32,
	max_size: [2]f32,
	clear:  Color,    // window background; zero → theme bg
	theme:  Theme,    // zero (name == "") → follow the system light/dark setting; named → every surface starts pinned to it, as set_theme pins, and follow_system_theme still reaches the desktop's
	// accent is the app's own colour to generate the theme from, for an app
	// with a brand that still belongs on the desktop it runs on: the theme
	// is theme_from_seed(accent, …) built again for the desktop's light or
	// dark and its contrast setting, at start and whenever they change.
	// Zero is Baldr's own blue. `theme` set names a theme outright and wins:
	// that app follows nothing.
	accent: Color,
	// adjust_theme is the app's last word on the theme it runs with, called
	// on every one the runtime hands it — the generated `accent` theme, the
	// high-contrast one, a `theme` named outright, and one a tree is given
	// with `set_theme` — and so again after each rebuild, which keeps an
	// app's own type scale or radii through a light/dark switch. Change the
	// Theme in place; whatever it leaves is what draws, so an app that
	// overwrites colours owns their contrast.
	adjust_theme: proc(th: ^Theme),
	// a11y is the accessibility preferences to run with — text size, reduce
	// motion, reduce transparency — for a desktop that owns them and would
	// rather say than be asked. Nothing (the default) follows the desktop's,
	// and `set_a11y_prefs` changes them while running.
	a11y:   Maybe(A11y_Prefs),
	// titlebar is the choices for a title bar the app draws itself
	// (window_chrome): the buttons and their side, what a double click and
	// the wheel do — for a desktop that owns them and would rather say than
	// be asked. Nothing (the default) follows the desktop's (GNOME's
	// settings, through the Settings portal), and `set_titlebar_prefs`
	// changes them while running.
	titlebar: Maybe(Titlebar_Prefs),
	// gpu_reset runs when the card was reset and the device built again.
	// Every canvas the app made is gone — canvases live in VRAM and have no
	// copy on the CPU — so an editor rebuilds its document from whatever it
	// does keep or says what was lost. An app with no canvases leaves it nil.
	// Anything the toolkit uploaded (glyphs, pictures, images) comes back on
	// its own. `BALDR_SIMULATE_GPU_RESET=2000` (or `2000,1500` to keep doing
	// it) rehearses one.
	gpu_reset: proc(s: ^State) -> Cmd(Msg),
	// init builds the app's first state. **Anything it keeps must be the
	// app's own memory**: it runs inside a frame whose temp allocator is
	// freed under it, so a string borrowed from `os.get_env(…,
	// context.temp_allocator)`, or a slice of a literal built on the
	// stack, is a dangling pointer by the first `update`. Clone what you
	// keep.
	init:   proc() -> State,
	// start runs once after init, for the command an app begins with
	// (read its file, start a job); nil → none.
	start:  proc(s: ^State) -> Cmd(Msg),
	update: proc(s: ^State, m: Msg) -> Cmd(Msg),
	view:   proc(s: ^State, ui: ^Ui(Msg)),
	// surfaces declares which surfaces exist, by tag, for this state (see
	// surface.odin). nil → one window from title / size. Called at start
	// and after every update; declaring none ends the app unless
	// keep_running holds it.
	surfaces: proc(s: ^State, out: ^[dynamic]Surface_Desc(Msg)),
	// on_close is what the app hears when the person closes its window —
	// the title bar's button, the desktop's Close, Alt+F4 — instead of the
	// run ending there. Set it and **the window does not close**: the
	// message reaches `update`, and it is the app that decides, by asking
	// first and then returning `quit`, or by saving and then returning it,
	// or by doing neither. nil ends the run, which is right for a window
	// holding nothing worth keeping.
	//
	// This is `Surface_Desc.on_close` for an app that declares no
	// `surfaces`. An app with a `surfaces` proc sets it per surface instead,
	// and this one is ignored.
	on_close: Maybe(Msg),
	// on_state is what the app hears about its window: its size, whether it
	// has the keyboard, whether the desktop maximised it. It arrives once
	// the window is first configured and then only on a change, so an app
	// that reopens the way it was left keeps the latest, and one that acts
	// on focus reads it in `update`, where that decision is made. See
	// `Window_State`.
	//
	// This is `Surface_Desc.on_state` for an app that declares no
	// `surfaces`, which is most of them; an app with a `surfaces` proc sets
	// it per surface instead and this one is ignored.
	on_state: Handler(Msg, Window_State),
	// single_instance makes this app one copy: a second launch hands its
	// arguments to the first and exits, and the first hears them through
	// `on_relaunch`. Opening an app that is already running (in the tray,
	// behind a window) should bring it forward, not start a second copy.
	//
	// The first copy's `run` carries on as usual; the second's returns
	// `.Already_Running`, which is **not a failure**: it did its job and
	// should exit 0.
	single_instance: bool,
	// on_relaunch hears a later launch, with its arguments (`Relaunch`).
	// The strings live until the update that was given them has run: copy
	// what you keep. Usually the app shows and raises its window, and opens
	// whatever that launch named.
	on_relaunch: Handler(Msg, Relaunch),
	// tray declares what this app shows in the desktop's tray — a status
	// item with an icon, a tooltip and a menu (tray.odin).
	// Called at start and after every update, and diffed, so a menu
	// rebuilt here is a menu updated in place. A declared tray **holds the
	// run open**, as keep_running does: an app in the tray with no window
	// has not finished.
	tray: proc(s: ^State, out: ^[dynamic]Tray_Desc(Msg)),
	// keep_running holds the run while the app is busy with no surface
	// declared — a copy finishing after its window closed. Messages, jobs,
	// subscriptions and delays carry on and no view is built; declaring a
	// surface opens it again. The run ends when nothing is declared and this
	// says false (or is nil), or on `quit`. Called at start and after every
	// update.
	//
	// **This is also how an app lives in the tray**, with no window at all:
	// a `surfaces` proc that appends nothing, and this returning true. Note
	// that *leaving `surfaces` out* is not the same thing — an app without
	// one gets the default window.
	keep_running: proc(s: ^State) -> bool,
	// subscriptions declares what the app listens to for this state:
	// `every` timers and `watch`es (sched.odin). Called at start and after
	// every update; a line that stays keeps running, a gone one stops.
	subscriptions: proc(s: ^State, out: ^[dynamic]Sub(Msg)),
}

// Cmd is what update returns: an effect for the runtime to perform.
// `quit` ends the app; `open_files` / `save_file` show the desktop's own
// dialog and later send a message built from the outcome (a `Files`);
// `job` runs work on a thread and `cancel` stops it (job.odin); `delay`
// sends a message later (sched.odin); `read_file` / `write_file` do file
// IO off the main thread (file_io.odin); `batch` runs several.
Cmd_Kind :: enum u8 { None, Quit, Open_Files, Save_File, Job, Cancel, Batch, Delay, Read_File, Write_File, Copy_Text, Copy_Files, Copy_Html, Paste, Copy_Image, Paste_Image, Gpu_Open, Canvas_Read, Toplevel, Workspace, Activate, Poster, Lock, Unlock, Open_Url, Open_Path, Reveal_Path, Secret_Get, Secret_Set, Secret_Delete, Notify, Notify_Close, Focus, Reveal, Hold, Forget_Image }
// Cmd is a command: what `update` returns to ask the runtime for an effect.
// Build one with the constructors rather than filling the fields — `job`,
// `delay`, `read_file`, `write_file`, `copy_text`, `open_files`, `open_url`,
// `notify`, `quit`, `batch` and the rest — and return `{}` for "do nothing",
// which is the common case. `Cmd_Kind` above lists everything the runtime
// can be asked for. A command never touches the app's state itself: it runs,
// and the runtime delivers a message back to `update`.
Cmd :: struct($Msg: typeid) {
	kind:     Cmd_Kind,
	dialog:   platform.File_Dialog,       // Open_Files / Save_File
	on_files: Handler(Msg, Files),        // …and what their outcome becomes
	work:     proc(^Job(Msg)),            // Job: what runs on the thread
	data:     rawptr,                     // …with this
	on_done:  Handler(Msg, Job_Done),     // …and what its end becomes
	tag:      u64,                        // Job / Read_File / Write_File: echoed in the outcome; Cancel: which jobs
	list:     []Cmd(Msg),                 // Batch
	ms:       i64,                        // Delay
	msg:      Msg,                        // Delay: what is sent
	path:     string,                     // Read_File / Write_File
	bytes:    []u8,                       // Write_File
	on_read:  Handler(Msg, File_Read),    // Read_File
	on_write: Handler(Msg, File_Written), // Write_File
	text:     string,                     // Copy_Text / Copy_Html: the plain text
	html:     string,                     // Copy_Html: the formatted form beside it
	paths:    []string,                   // Copy_Files
	on_paste: Handler(Msg, Pasted),       // Paste
	picture:  ^Clip_Picture,              // Copy_Image: the copy, its PNG on the way
	picture_img: ^Image,                  // Forget_Image: the picture being let go of
	on_image: Handler(Msg, Pasted_Image), // Paste_Image
	on_gpu:    Handler(Msg, Gpu),         // Gpu_Open
	host:      ^Canvas_Host,              // Canvas_Read: the Gpu's
	canvas:    Canvas,                    // …which canvas
	area:      [4]int,                    // …which texels: x, y, w, h
	on_canvas: Handler(Msg, Canvas_Read), // …and what their outcome becomes
	cut:      bool,                       // Copy_Files: the files were cut
	primary:  bool,                       // Copy_Text / Paste: the primary selection, not the clipboard
	reveal:    Reveal_Ask,                // Reveal: which view, which row, and where in it
	hold:      Hold_Ask,                  // Hold: …and which point of it to keep still
	id:        u64,                       // Toplevel / Workspace: which (desktop.odin)
	toplevel:  Toplevel_Action,           // Toplevel: what is asked
	workspace: Workspace_Action,          // Workspace: what is asked
	output:    string,                    // Workspace: the screen an Assign moves it to
	service:   string,                    // Secret_*: what holds the secret ("acme")
	account:   string,                    // …and whose it is ("openai")
	on_secret: Handler(Msg, Secret),      // Secret_*: what the keyring said, and why
	token:     string,                    // Activate: the activation token the app was handed ("": ask for one)
	on_poster: Handler(Msg, Poster(Msg)), // Poster: the message the poster arrives in
	notice:      Notify_Desc,             // Notify: what to show (notify.odin); Notify_Close: only its `tag`
	on_notify:   Handler(Msg, Notification), // …and everything that becomes of it
	url:         string,                  // Open_Url: the link to hand the desktop (url.odin)
	on_url:      Handler(Msg, Url_Opened),// …and what became of it
	on_path:     Handler(Msg, Path_Opened), // Open_Path / Reveal_Path: what became of a local file (path_open.odin); the path is `path`
	on_locked:   Msg,                     // Lock: the session is locked (lock.odin)
	on_finished: Msg,                     // …refused, or ended by the desktop
	on_shown:    Maybe(Msg),              // …every lock surface is on screen
}

// Relaunch is a later launch of a single-instance app: the arguments it
// was started with, which are the frame's — copy what you keep. `args[0]`
// is that launch's own program path, as os.args has it.
Relaunch :: struct {
	args: []string,
}

// Files is a file dialog's outcome: `ok` with the chosen paths, or not, and
// `why` either way — `.Cancelled` is the only one a person chose; `.Not_Shown`
// means no dialog appeared, which an app should say rather than leave the
// person wondering; `.Unusable` means what was picked is not a file on this
// computer, and `uris` says what it was. The paths and the URIs
// live only until the message is handled — clone what you keep.
Files :: struct {
	paths: []string,
	ok:    bool,
	why:   Files_Why,
	uris:  []string,
}

// Files_Why is how a file dialog ended: `.Chosen`, `.Cancelled`, `.Not_Shown`
// or `.Unusable` (see `Files`).
Files_Why :: platform.Files_Why

// File_Filter is one choice in a file dialog's type list: a label a person
// reads and the patterns it matches. Pass a slice of them to `open_files` or
// `save_file`; the desktop's own dialog shows them.
File_Filter :: platform.File_Filter

// Clip_Item is one form of what is on the clipboard: a mime type and its bytes.
Clip_Item :: platform.Clip_Item

// Drag_Icon is the picture a drag carries once the desktop has it, drawn
// by the toolkit as the drag leaves the window.
Drag_Icon :: platform.Drag_Icon

quit :: proc($Msg: typeid) -> Cmd(Msg) { return {kind = .Quit} }

// open_files asks for the desktop's open dialog; the handler receives
// Files with the chosen path(s), or ok = false when cancelled.
//
//	case Pick: return baldr.open_files(Msg, proc(e: baldr.Ev(baldr.Files)) -> Msg { return Picked{e.value} },
//		title = "Choose an image", filters = {{name = "Images", patterns = {"*.png", "*.jpg"}}})
// The strings and filters are copied for the rest of the loop iteration:
// literals written inside update (which live on its stack) are fine.
open_files :: proc($Msg: typeid, on_done: Handler(Msg, Files), title: string = "", multiple := false, directory := false,
	filters: []File_Filter = {}, folder: string = "", accept_label: string = "") -> Cmd(Msg) {
	return {kind = .Open_Files, on_files = on_done,
		dialog = {title = temp_clone(title), multiple = multiple, directory = directory, filters = filters_clone(filters), current_folder = temp_clone(folder), accept_label = temp_clone(accept_label)}}
}

// save_file asks for the desktop's save dialog; the handler receives one
// path to write, or ok = false and `why`. Pass `folder` where you can; on
// Linux a dialog given none starts in the home folder, because the desktop's
// dialog service would otherwise start in whatever folder it was itself
// started from — which can be `/`.
save_file :: proc($Msg: typeid, on_done: Handler(Msg, Files), title: string = "", name: string = "",
	filters: []File_Filter = {}, folder: string = "", accept_label: string = "") -> Cmd(Msg) {
	return {kind = .Save_File, on_files = on_done,
		dialog = {save = true, title = temp_clone(title), current_name = temp_clone(name), filters = filters_clone(filters), current_folder = temp_clone(folder), accept_label = temp_clone(accept_label)}}
}

// app_own_strings takes the toolkit's own copy of the App's strings. An App
// written with `title = fmt.tprintf(…)` holds temp memory freed before the
// first frame, and the title is re-applied on every surface sync. On macOS
// freed bytes are worse than a garbled title: the UTF-8 NSString
// initialisers return nil for invalid bytes, `setTitle:` raises on nil, and
// an ObjC exception out of a Baldr frame aborts the process.
// surface_of_tag is the open surface declared with `tag`, 0 when there is
// none (no tag asked for, or that window is not open).
@(private)
surface_of_tag :: proc(rt: ^Runtime($State, $Msg), tag: Maybe(u64)) -> platform.Surface {
	want, has := tag.?
	if !has do return 0
	for c in rt.ctxs do if c.desc.tag == want && c.fc.surface != 0 do return c.fc.surface
	return 0
}

// window_icon_of converts an RGBA picture to the ARGB words a backend sets as
// a window icon, in memory the caller frees; empty for nil or a bad picture.
@(private)
window_icon_of :: proc(img: ^Image) -> platform.Window_Icon {
	if img == nil || img.width <= 0 || img.height <= 0 || len(img.pixels) < img.width * img.height * 4 do return {}
	out := make([]u32, img.width * img.height)
	for i in 0 ..< len(out) {
		p := img.pixels[i * 4:]
		out[i] = u32(p[3]) << 24 | u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2])
	}
	return {w = img.width, h = img.height, argb = out}
}

@(private)
app_own_strings :: proc(rt: ^Runtime($State, $Msg)) {
	rt.app.title = strings.clone(rt.app.title)
	rt.app.app_id = strings.clone(rt.app.app_id)
}

@(private)
app_free_strings :: proc(rt: ^Runtime($State, $Msg)) {
	delete(rt.app.title)
	delete(rt.app.app_id)
	rt.app.title, rt.app.app_id = "", ""
}


@(private)
temp_clone :: proc(s: string) -> string {
	if len(s) == 0 do return ""
	return strings.clone(s, context.temp_allocator)
}

// filters_clone copies a filter list (names and patterns) into the
// temp allocator: a command outlives the update frame it was written in.
@(private)
filters_clone :: proc(filters: []File_Filter) -> []File_Filter {
	if len(filters) == 0 do return {}
	out := make([]File_Filter, len(filters), context.temp_allocator)
	for f, i in filters {
		pats := make([]string, len(f.patterns), context.temp_allocator)
		for p, j in f.patterns do pats[j] = temp_clone(p)
		out[i] = {name = temp_clone(f.name), patterns = pats, mime = f.mime}
	}
	return out
}

// files_deliver turns a dialog outcome into the app's message through the
// command's handler (a plain message, or a proc given Ev{value, tag =
// token}); nil delivers nothing.
files_deliver :: proc(h: Handler($Msg, Files), files: Files, token: u64, out: ^[dynamic]Msg) -> bool {
	switch v in h {
	case Msg:
		append(out, v)
		return true
	case proc(Ev(Files)) -> Msg:
		append(out, v(Ev(Files){value = files, tag = token}))
		return true
	}
	return false
}

// Frame_Ctx is the non-generic slice of the run loop so a platform modal
// loop (Win32 size/move) can drive a frame through Backend.redraw_callback.
Frame_Ctx :: struct {
	tree:            ^Tree,
	r:               ^gpu.Renderer,
	target:          gpu.Target,
	backend:         ^platform.Backend,
	surface:         platform.Surface,
	size:            [2]f32,
	size_px:         [2]u32,
	scale:           f32,
	transparent:     bool, // swapchain composites with alpha
	debug:           bool, // BALDR_DEBUG_EVENTS: log frames
	timing:          bool, // BALDR_DEBUG_FRAMES: log the ms each frame phase took
	build_ms:        f64,  // the latest view build, for that log line
	req_ms:          f64,  // when the frame was asked for, for the latency in that line
	clear:           Color,
	sink:            Atlas_Sink,
	cmds:            [dynamic]gpu.Cmd,
	damage:          [dynamic][4]f32,
	frame_requested: bool,
	frames:          u64,
	pin_ms:          f64,               // a held popup frame's clock: drawn as laid out when its place was sent (popup_resync)
	drawn_px:        [2]u32,            // the device size it last presented at: a frame at a new size always presents
	t0:              time.Tick,
	input:           Surface_Input,     // where the surface takes the pointer, as declared
	input_sent:      [dynamic][4]f32,   // the region last given the backend
	input_sent_mode: Surface_Input,
	input_sent_ok:   bool,              // something was given (or the default stands)
	input_given:     bool,              // a region was given the backend once: from then on the whole surface is said too
	present_whole:   bool,              // what it paints outside its tree changed (clear, shape, corners, highlight): the next frame presents all of it
	hide:            Layer_Hide,        // how it hides at its edge (Never for anything but a layer surface on one edge; hide.odin)
	hide_edge:       Edge,              // …the edge it slides off
	hidden:          bool,              // …hidden, or on its way: it takes the pointer on its strip only
	hide_placed:     bool,              // …and placed at the screen's edge, its margin dropped while out of sight
	slide:           [2]f32,            // …how far its drawing has slid, logical px
	blur_whole:      bool,              // blurred behind as a whole (glass, backdrop_region All): its blur narrows as it slides
	blur_slid:       [4]f32,            // …the rect it was narrowed to (zero: the whole surface)
	backdrop_region: Backdrop_Region,   // where its blur backdrop reaches, as declared
	blur_sent:       [dynamic][5]f32,   // the rounded rects (x, y, w, h, radius) last given the backend
	blur_sent_ok:    bool,
	popup:           Node,              // a popup's surface: it draws this overlay child (popup.odin)
	origin:          [2]f32,            // …with this tree point at its top-left
	highlight:       Color,             // a glass layer surface's bright line along its top edge (surface_highlight)
	shape:           Color,             // a rounded glass layer surface's tint, drawn as its shape over a clear surface (surface_shape)
	shape_radius:    f32,               // …its corners' radius, logical px (the highlight follows it too)
	shape_square:    Corners,           // …and the corners it keeps square
	applet:          bool,              // an applet surface: it tells its shell the length its content wants (applet_hints)
	edge:            Edge,              // …along its bar on this edge
	hint_sent:       [2]u32,            // the least and preferred length it last told
	hint_size:       [2]f32,            // the slot it measured for
	hint_edge:       Edge,
	hint_layouts:    u64,               // the tree's layout count it measured at
	host_edge:       Maybe(Edge),       // a bar's screen edge, passed to its applet slots (applet_slot.odin)
	fit:             [2]bool,           // a layer surface FIT along x / y: as long as its content (fit_sync)
	declared:        [2]f32,            // …its size as declared, FIT kept
	layer:           ^Layer_Desc,       // …its placement, for asking for a length
	fit_len:         [2]f32,            // …the length it last asked for
	fit_cap:         [2]f32,            // …the most it may take: its screen less its margins (0 = no screen known)
	fit_size:        [2]f32,            // …the size it last measured at
	fit_layouts:     u64,               // …and the tree's layout count then
	rolled:          [2]f32,            // a window rolled up to its title bar: the size it comes back to, and is laid out at (zero: not rolled)
}

// window_roll rolls a window up to `height` (its title bar's bottom) or back
// down: the window takes a size of its own (Backend.surface_set_size), and
// its tree is laid out at the size it had, so nothing in it moves; the run
// loop hears the configure that follows. False when the backend can't, or
// there is nothing to do.
@(private)
window_roll :: proc(fc: ^Frame_Ctx, up: bool, height: f32) -> bool {
	b := fc.backend
	if b == nil || b.surface_set_size == nil do return false
	if up {
		if fc.rolled != {} || height <= 0 || height >= fc.size.y do return false
		fc.rolled = fc.size
		b.surface_set_size(b, fc.surface, {fc.size.x, height})
		return true
	}
	if fc.rolled == {} do return false
	b.surface_set_size(b, fc.surface, {fc.size.x, fc.rolled.y}) // the size it had, now…
	b.surface_set_size(b, fc.surface, {})                       // …and the desktop's to change from here
	fc.rolled = {}
	return true
}

// frame_layout_size is the size a surface's tree is laid out at: its own,
// or while rolled up the size it had, so nothing in it moves and only its
// title bar shows.
@(private)
frame_layout_size :: proc "contextless" (fc: ^Frame_Ctx) -> [2]f32 {
	if fc.rolled != {} do return {fc.size.x, fc.rolled.y}
	return fc.size
}

// applet_hints tells an applet's shell the length along the bar its content
// wants when its layout, slot or edge changed since it last measured, and
// the lengths did. Runs before layout: measuring leaves the tree to be laid
// out at the slot's size.
@(private)
applet_hints :: proc(fc: ^Frame_Ctx) {
	b := fc.backend
	root := node_get(fc.tree, fc.tree.root)
	if b == nil || b.surface_set_size_hint == nil || root == nil do return
	// unchanged since it measured: nothing laid out since (the view's changes may already be, for its popups) and nothing waiting
	if fc.tree.layouts == fc.hint_layouts && len(fc.tree.dirty_roots) == 0 && fc.size == fc.hint_size && fc.edge == fc.hint_edge do return
	least, preferred := applet_size_hint(fc.tree, fc.edge, fc.size)
	layout(fc.tree, fc.size) // measuring laid it out for itself: at the slot's size again, and counted
	fc.hint_size, fc.hint_edge, fc.hint_layouts = fc.size, fc.edge, fc.tree.layouts
	h := [2]u32{u32(math.ceil(least)), u32(math.ceil(preferred))}
	if h == fc.hint_sent do return
	fc.hint_sent = h
	b.surface_set_size_hint(b, fc.surface, h.x, h.y)
}

// frame_clear is the colour a surface is cleared with, premultiplied in
// linear light as the renderer blends: a glass tint given straight would
// hold more colour than alpha under everything drawn over it. The renderer's
// present pass turns a transparent surface's pixels into the premultiplied
// sRGB the compositor reads (gpu/present.odin).
@(private)
frame_clear :: proc "contextless" (c: Color) -> [4]f32 {
	return {c.r * c.a, c.g * c.a, c.b * c.a, c.a}
}

// surface_shape_cmds draws what a surface shows before its tree: a rounded
// glass surface's tint as its shape (the surface cleared outside it), then
// the glass highlight along its top, rounded alike.
@(private)
surface_shape_cmds :: proc(fc: ^Frame_Ctx) {
	whole := [4]f32{fc.slide.x * fc.scale, fc.slide.y * fc.scale, f32(fc.size_px.x), f32(fc.size_px.y)} // moved with a surface sliding off its edge
	if fc.shape.a > 0 do append(&fc.cmds, gpu.Quad{rect = whole, color = fc.shape, radius = fc.shape_radius * fc.scale, square = fc.shape_square})
	if fc.highlight.a > 0 {
		append(&fc.cmds, gpu.Highlight{rect = whole, color = fc.highlight, width = max(math.round(fc.scale), 1), radius = fc.shape_radius * fc.scale, square = fc.shape_square})
	}
}

// rounded_region is where a rounded surface takes the pointer: its rect less
// the corners outside `radius` (those not in `square`), stepped in bands a
// few px tall since a Wayland region is made of rectangles.
@(private)
rounded_region :: proc(size: [2]f32, radius: f32, square: Corners, out: ^[dynamic][4]f32) {
	r := min(radius, size.x / 2, size.y / 2)
	if r <= 0 {
		append(out, [4]f32{0, 0, size.x, size.y})
		return
	}
	steps := max(int(math.ceil(r / 3)), 1)
	band := r / f32(steps)
	inset :: proc(r, from_edge: f32) -> f32 { // how far in the arc is, `from_edge` px in from the edge it meets
		dy := r - from_edge
		return r - math.sqrt(max(r * r - dy * dy, 0))
	}
	for i in 0 ..< steps {
		mid := (f32(i) + 0.5) * band
		l := inset(r, mid) if .Top_Left not_in square else 0
		rt := inset(r, mid) if .Top_Right not_in square else 0
		append(out, [4]f32{l, f32(i) * band, size.x - l - rt, band})
	}
	if size.y > 2 * r do append(out, [4]f32{0, r, size.x, size.y - 2 * r})
	for i in 0 ..< steps {
		mid := (f32(i) + 0.5) * band // from the bottom edge
		l := inset(r, mid) if .Bottom_Left not_in square else 0
		rt := inset(r, mid) if .Bottom_Right not_in square else 0
		append(out, [4]f32{l, size.y - f32(i + 1) * band, size.x - l - rt, band})
	}
}

// fit_sync keeps a layer surface FIT along an axis as long as its content.
// When anything was laid out or its size changed since it
// last looked (a change inside the view is often laid out before the frame,
// for its popups, so the tree's layout count says it, not a dirty flag), it
// measures the content's natural length at the surface's thickness, up to
// its cap, and asks for that length when it isn't the one last asked for.
// True when it asked: the frame at the old length is skipped and the
// compositor's configure brings the next. A length the compositor settles
// on instead is kept.
@(private)
fit_sync :: proc(fc: ^Frame_Ctx) -> bool {
	b := fc.backend
	root := node_get(fc.tree, fc.tree.root)
	if b == nil || b.surface_set_layer == nil || fc.layer == nil || root == nil do return false
	// unchanged since it measured: nothing laid out since (the view's changes may already be, for its popups) and nothing waiting
	if fc.tree.layouts == fc.fit_layouts && len(fc.tree.dirty_roots) == 0 && fc.size == fc.fit_size do return false
	want := fc.fit_len
	for i in 0 ..< 2 {
		if !fc.fit[i] do continue
		_, natural := content_length(fc.tree, i == 0, fc.size[1 - i])
		length := max(math.ceil(natural), 1)
		if fc.fit_cap[i] > 0 do length = min(length, fc.fit_cap[i])
		want[i] = length
	}
	layout(fc.tree, fc.size) // measuring laid it out for itself: at its size again, and counted
	fc.fit_size, fc.fit_layouts = fc.size, fc.tree.layouts
	if want == fc.fit_len do return false
	fc.fit_len = want
	b.surface_set_layer(b, fc.surface, fc.layer^, layer_size(fc))
	return true
}

// layer_size is the size a layer surface asks for: as declared, a FIT axis
// at the length last measured for it (FIT_START_LEN before that).
@(private)
layer_size :: proc(fc: ^Frame_Ctx) -> [2]f32 {
	size := fc.declared
	for i in 0 ..< 2 do if fc.fit[i] do size[i] = fc.fit_len[i] if fc.fit_len[i] > 0 else FIT_START_LEN
	return size
}

// fit_cap is the most a FIT layer surface may take along each axis: its
// screen's size (the one named, else the largest known) less its margins
// on that axis; 0 where no screen is known.
@(private)
fit_cap :: proc(l: Layer_Desc, output: string, outputs: []Output) -> (cap: [2]f32) {
	o, known := screen_of(output, outputs)
	if !known do return
	cap ={max(f32(o.size.x - l.margin[1] - l.margin[3]), 1), max(f32(o.size.y - l.margin[0] - l.margin[2]), 1)}
	return
}

// window_resize asks the desktop for a window's new size, which is the
// app's to choose while the window is floating (a video player fitting its
// window to the film it opened). An app declares it once; the person's own
// resizing afterwards is theirs, because nothing asks again until the
// declaration changes.
//
// It is an ask, not a hold: the size is handed straight back to the desktop,
// leaving the next configure free to say otherwise. `surface_set_size` is
// also the rolled-up title bar's mechanism, which holds a size against every
// configure, so without the hand-back the window could not be resized by
// hand at all.
//
// Dropped, not remembered, while the desktop is sizing the window
// (maximised, full screen or tiled): a window should not jump to an old size
// when unmaximised. An app that still wants it hears the change in
// `on_state` and asks again. The size is kept to the screen the window is
// on, here rather than by the app, which would first have to find its own
// window among `outputs()`; a size the desktop argues with is a frame drawn
// at one size and shown at another.
@(private)
window_resize :: proc(c: ^Surface_Ctx($Msg), b: ^platform.Backend, size: [2]f32, outputs: []Output) {
	trouble :: proc(c: ^Surface_Ctx($Msg), why: string) {
		if c.resize_said do return
		c.resize_said = true
		fmt.eprintfln("baldr: surface %d: %s, so its own size was not asked for", c.desc.tag, why)
	}
	if b == nil || b.surface_set_size == nil {
		if size.x > 0 && size.y > 0 do trouble(c, "this backend cannot size a window")
		return
	}
	desktop_sizes := c.ui.surface.maximized || c.ui.surface.fullscreen || c.ui.surface.tiled
	want, ask := window_size_wanted(size, desktop_sizes, c.output, outputs)
	if !ask {
		if desktop_sizes && size.x > 0 && size.y > 0 {
			trouble(c, "the desktop is sizing this window (maximised, full screen or tiled)")
		}
		return
	}
	b.surface_set_size(b, c.surf, want)
	b.surface_set_size(b, c.surf, {}) // asked for, and the desktop's again
}

// window_size_wanted is window_resize's decision on its own, so it can be
// read and tested without a window: what to ask the desktop for, and whether
// to ask at all. Nothing is asked for while the desktop is sizing the window,
// nor for a size of nothing (0 means "the desktop's to choose", and FIT is a
// layer surface's word, not a window's); what is asked for never exceeds the
// screen the window is on.
@(private)
window_size_wanted :: proc(size: [2]f32, desktop_sizes: bool, output: string, outputs: []Output) -> (want: [2]f32, ask: bool) {
	if size.x <= 0 || size.y <= 0 || desktop_sizes do return {}, false
	want = size
	if o, known := screen_of(output, outputs); known {
		want = {min(want.x, f32(o.size.x)), min(want.y, f32(o.size.y))}
	}
	return want, true
}

// screen_of is the screen named by `output`, or the biggest when it names
// none of them — which is the honest guess before a surface has entered one,
// and is why a cap is a cap rather than a promise.
@(private)
screen_of :: proc(output: string, outputs: []Output) -> (Output, bool) {
	screen: Maybe(Output)
	for o in outputs do if output != "" && o.name == output { screen = o; break }
	if screen == nil {
		for o in outputs {
			if big, has := screen.?; !has || o.size.x * o.size.y > big.size.x * big.size.y do screen = o
		}
	}
	return screen.? or_else {}, screen != nil
}

// input_region_sync tells the backend where the surface takes the pointer
// when that changed since it last said: the input_area
// nodes and open popovers after this layout, nowhere, or everywhere.
@(private)
input_region_sync :: proc(fc: ^Frame_Ctx) {
	b := fc.backend
	if b == nil || b.surface_set_input_region == nil do return
	if fc.hidden { // hidden at its edge: its strip reveals it
		strip := hide_strip(fc.hide_edge, fc.size, fc.hide.strip)
		if fc.input_sent_ok && len(fc.input_sent) == 1 && fc.input_sent[0] == strip do return
		b.surface_set_input_region(b, fc.surface, {strip}, false)
		fc.input_given = true
		clear(&fc.input_sent)
		append(&fc.input_sent, strip)
		fc.input_sent_ok = true
		return
	}
	rounded := fc.input == .All && fc.shape_radius > 0 // its clear corners take no pointer
	if !fc.input_given && fc.input == .All && !rounded { // the whole surface is where every surface starts: nothing to say yet
		fc.input_sent_mode, fc.input_sent_ok = .All, true
		return
	}
	rects := make([dynamic][4]f32, context.temp_allocator)
	if rounded do rounded_region(fc.size, fc.shape_radius, fc.shape_square, &rects)
	if fc.input == .Marked {
		input_rects_of(fc.tree, fc.tree.root, &rects)
		for c := node_first(fc.tree, fc.tree.overlay); c != NODE_NONE; c = node_next(fc.tree, c) {
			d := node_get(fc.tree, c)
			if d != nil && .Exiting not_in d.flags && d.abs.w > 0 && d.abs.h > 0 && !popup_candidate(fc.tree, c) do append(&rects, [4]f32{d.abs.x, d.abs.y, d.abs.w, d.abs.h})
		}
	}
	if fc.input_sent_ok && fc.input_sent_mode == fc.input && len(rects) == len(fc.input_sent) {
		same := true
		for r, i in rects do if r != fc.input_sent[i] { same = false; break }
		if same do return
	}
	b.surface_set_input_region(b, fc.surface, rects[:], fc.input == .All && !rounded)
	fc.input_given = true
	clear(&fc.input_sent)
	append(&fc.input_sent, ..rects[:])
	fc.input_sent_mode, fc.input_sent_ok = fc.input, true
}

// backdrop_region_sync tells the backend where the compositor blurs behind a
// surface whose backdrop_region is Marked: the rounded rects of
// its backdrop_area nodes where they are drawn now, when that changed since
// it last said.
@(private)
backdrop_region_sync :: proc(fc: ^Frame_Ctx) {
	b := fc.backend
	if b == nil || b.surface_set_blur_region == nil do return
	if fc.backdrop_region != .Marked {
		hide_blur_sync(fc) // a whole-surface blur narrows to where a hiding surface's drawing slid
		return
	}
	rects := make([dynamic][5]f32, context.temp_allocator)
	backdrop_rects_of(fc.tree, fc.tree.root, fc.slide, &rects)
	if fc.blur_sent_ok && len(rects) == len(fc.blur_sent) {
		same := true
		for r, i in rects do if r != fc.blur_sent[i] { same = false; break }
		if same do return
	}
	boxes := make([][4]f32, len(rects), context.temp_allocator)
	radii := make([]f32, len(rects), context.temp_allocator)
	for r, i in rects do boxes[i], radii[i] = {r[0], r[1], r[2], r[3]}, r[4]
	b.surface_set_blur_region(b, fc.surface, boxes, radii)
	clear(&fc.blur_sent)
	append(&fc.blur_sent, ..rects[:])
	fc.blur_sent_ok = true
}

// backdrop_rects_of gathers the backdrop_area nodes under `n` where they are
// drawn: their layout place moved by the glides and slides they, or what
// holds them, are in the middle of (`shift`). A node on its way out is left
// out: its tint fades, the compositor's blur can't.
@(private)
backdrop_rects_of :: proc(t: ^Tree, n: Node, shift: [2]f32, out: ^[dynamic][5]f32) {
	d := node_get(t, n)
	if d == nil || .Hidden in d.flags || .Exiting in d.flags do return
	sh := shift
	if d.move_from != {} do sh += d.move_from * anim_value(t, n, .Move)
	if d.style.enter.kind != .None do sh += transition_shift(d, anim_value(t, n, .Enter))
	if .Backdrop_Area in d.flags {
		if d.abs.w > 0 && d.abs.h > 0 do append(out, [5]f32{d.abs.x + sh.x, d.abs.y + sh.y, d.abs.w, d.abs.h, d.style.radius})
		return
	}
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do backdrop_rects_of(t, c, sh, out)
}

@(private)
input_rects_of :: proc(t: ^Tree, n: Node, out: ^[dynamic][4]f32) {
	d := node_get(t, n)
	if d == nil || .Hidden in d.flags || .Exiting in d.flags do return
	if .Input_Area in d.flags {
		if d.abs.w > 0 && d.abs.h > 0 do append(out, [4]f32{d.abs.x, d.abs.y, d.abs.w, d.abs.h})
		return // what it holds is inside it
	}
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do input_rects_of(t, c, out)
}

@(private)
clock_ms :: proc(fc: ^Frame_Ctx) -> f64 {
	return time.duration_milliseconds(time.tick_since(fc.t0))
}

@(private)
atlas_create_cb :: proc(user: rawptr, format: gpu.Page_Format, size: [2]u32) -> gpu.Page {
	return gpu.atlas_create((^gpu.Renderer)(user), format, size)
}

@(private)
atlas_upload_cb :: proc(user: rawptr, page: gpu.Page, x, y, w, h: u32, pixels: []u8) {
	gpu.atlas_upload((^gpu.Renderer)(user), page, x, y, w, h, pixels)
}

@(private)
picture_create_cb :: proc(user: rawptr, size: [2]u32) -> gpu.Page {
	return gpu.picture_create((^gpu.Renderer)(user), size)
}

@(private)
page_destroy_cb :: proc(user: rawptr, page: gpu.Page) {
	gpu.atlas_destroy((^gpu.Renderer)(user), page)
}

// surface_damage appends to `out`, in device px, the part of each rect that
// changed in the tree (`taken`) lying on a surface of `size`. False when
// nothing changed on this surface but something did off it: a rect beyond its
// edges, or `elsewhere`, a change inside a popup presenting on a surface of
// its own. That frame has nothing to present. Nothing changed at all presents
// the whole surface.
@(private)
surface_damage :: proc(taken: []Rect, elsewhere: bool, size: [2]f32, scale: f32, out: ^[dynamic][4]f32) -> bool {
	on := 0
	for d in taken {
		x0, y0 := max(d.x, 0), max(d.y, 0)
		x1, y1 := min(d.x + d.w, size.x), min(d.y + d.h, size.y)
		if x1 <= x0 || y1 <= y0 do continue
		append(out, [4]f32{x0 * scale, y0 * scale, (x1 - x0) * scale, (y1 - y0) * scale})
		on += 1
	}
	return on > 0 || (len(taken) == 0 && !elsewhere)
}

// frame_damage works out what a surface's frame presents, into fc.damage
// (empty: all of it): what changed in its tree on it, or all of it when what
// it paints outside its tree changed (present_whole). False when nothing
// changed on it but
// something did off it, a popup presenting on its own surface: that frame is
// skipped.
@(private)
frame_damage :: proc(fc: ^Frame_Ctx) -> bool {
	elsewhere := fc.tree.damage_elsewhere
	fc.tree.damage_elsewhere = false
	on := surface_damage(take_damage(fc.tree), elsewhere, fc.size, fc.scale, &fc.damage)
	if on && fc.slide != {} do clear(&fc.damage) // slid off its edge: a change lies elsewhere on screen than in the tree, so all of it
	if fc.present_whole {
		fc.present_whole = false
		clear(&fc.damage)
		return true
	}
	return on || fc.drawn_px != fc.size_px
}

@(private)
do_frame :: proc(fc: ^Frame_Ctx) {
	if fc.target == 0 || fc.size_px.x == 0 || fc.size_px.y == 0 do return
	t_start := time.tick_now()
	anim_tick(fc.tree, fc.pin_ms if fc.pin_ms > 0 else clock_ms(fc))
	fc.pin_ms = 0
	if fc.applet && fc.popup == NODE_NONE do applet_hints(fc)
	if (fc.fit[0] || fc.fit[1]) && fc.popup == NODE_NONE && fit_sync(fc) do return // a new length asked for: its configure brings the frame
	layout(fc.tree, frame_layout_size(fc) if fc.popup == NODE_NONE else fc.tree.viewport) // a popup's surface shows a piece of its surface's tree
	if fc.popup == NODE_NONE do hide_frame(fc) // how far a surface hiding at its edge has slid
	if fc.popup == NODE_NONE do input_region_sync(fc) // where the surface takes the pointer follows layout
	if fc.popup == NODE_NONE do backdrop_region_sync(fc) // …and where it is blurred behind
	if fc.popup == NODE_NONE do slots_sync(fc) // applet slots follow layout too, landing with this frame's commit
	t_layout := time.tick_now()
	paint(fc.tree)
	t_paint := time.tick_now()
	clear(&fc.cmds)
	clear(&fc.damage)
	if fc.popup == NODE_NONE do surface_shape_cmds(fc)
	if fc.popup == NODE_NONE && !frame_damage(fc) { // a popup presents whole: the damage is its surface's
		if fc.debug do fmt.eprintfln("baldr/events: surface %d frame skipped: nothing changed on it", fc.surface)
		return
	}
	if len(fc.damage) > 0 {
		// Glass samples what is behind it: any change means every glass
		// surface must be presented again too.
		for _, l in fc.tree.layers {
			for c in l.cmds {
				if b, ok := c.(Draw_Backdrop); ok {
					append(&fc.damage, [4]f32{b.rect.x * fc.scale, b.rect.y * fc.scale, b.rect.w * fc.scale, b.rect.h * fc.scale})
				}
			}
		}
	}
	waiting := fc.popup != NODE_NONE && popup_waiting(fc.tree, fc.popup, clock_ms(fc))
	if waiting {
		popup_hold(fc.tree, fc.popup) // presented empty until the compositor has measured behind it (popup.odin)
		if fc.debug do fmt.eprintfln("baldr/events: popup %d waits for its backdrop", fc.surface)
	} else if fc.popup != NODE_NONE {
		render_popup(fc.tree, fc.popup, fc.origin, fc.scale, &fc.sink, &fc.cmds)
	} else {
		render_prepare(fc.tree, fc.scale, &fc.sink, &fc.cmds, fc.slide)
	}
	t_prep := time.tick_now()
	// The desktop is told "this is the size you asked for" here, one request
	// before the commit that carries the frame — acking any earlier promises
	// a size we have not drawn, and the compositor fills the gap by
	// stretching the last frame (surface_ack_configure).
	if b := fc.backend; b != nil && b.surface_ack_configure != nil do b.surface_ack_configure(b, fc.surface)
	res := gpu.render(fc.r, fc.target, fc.cmds[:], frame_clear(fc.clear), fc.damage[:])
	if res == .OK || res == .Recreated do fc.drawn_px = fc.size_px
	fc.frames += 1
	if te := fc.tree.text; te != nil && te.images_full && !fc.frame_requested {
		// the picture atlas filled: the next frame starts it over and draws every picture again
		mark_paint_dirty(fc.tree, fc.tree.root)
		fc.backend.surface_request_frame(fc.backend, fc.surface)
		fc.frame_requested = true
	}
	if fc.timing {
		ms :: proc(a, b: time.Tick) -> f64 { return time.duration_milliseconds(time.tick_diff(a, b)) }
		shaped, icons, pictures, picture_mb := 0, 0, 0, 0
		icon_ms, flush_ms: f64
		if te := fc.tree.text; te != nil {
			shaped, icons, icon_ms, flush_ms = te.shaped, te.icons_made, te.icon_ms, te.flush_ms
			te.shaped, te.icons_made, te.icon_ms, te.flush_ms = 0, 0, 0, 0
			for _, p in te.pictures do if p.real {
				pictures += 1
				picture_mb += p.bytes
			}
			picture_mb /= 1024 * 1024
		}
		fmt.eprintfln("baldr/frames: build %.2f  layout %.2f  paint %.2f  prepare %.2f (icons %d in %.2f, upload %.2f)  gpu %.2f ms  (%d cmds, %d shaped, %d pictures of their own in %d MB)  asked→drawn %.1f ms",
			fc.build_ms, ms(t_start, t_layout), ms(t_layout, t_paint), ms(t_paint, t_prep), icons, icon_ms, flush_ms, ms(t_prep, time.tick_now()), len(fc.cmds), shaped, pictures, picture_mb, clock_ms(fc) - fc.req_ms if fc.req_ms > 0 else 0)
		fc.build_ms = 0
		fc.req_ms = 0
	}
	if res == .Lost {
		gpu_note_lost(fc) // once, and the run loop rebuilds the device
	} else if res == .Error {
		fmt.eprintfln("baldr: render: %v", res)
	}
	if fc.debug do fmt.eprintfln("baldr/events: surface %d frame %d: %d cmds, %d damage rects, %v", fc.surface, fc.frames, len(fc.cmds), len(fc.damage), res)
	if (fc.tree.anim_active || waiting) && !fc.frame_requested {
		// Something is still moving: ask for the next frame right away.
		fc.backend.surface_request_frame(fc.backend, fc.surface)
		fc.frame_requested = true
	}
}

// ime_set_cb passes the focused field's state to the backend's input
// method, naming the surface it is on (ime.odin).
@(private)
ime_set_cb :: proc(user: rawptr, surface: u32, info: Ime_Info) {
	b := (^platform.Backend)(user)
	if b.ime_set == nil do return
	b.ime_set(b, platform.Ime_State{
		surface     = platform.Surface(surface),
		on          = info.on,
		purpose     = platform.Ime_Purpose(info.purpose),
		hints       = transmute(platform.Ime_Hints)info.hints,
		surrounding = info.surrounding,
		cursor      = info.cursor,
		anchor      = info.anchor,
		cause       = platform.Ime_Cause(info.cause),
		caret       = {info.caret.x, info.caret.y, info.caret.w, info.caret.h},
	})
}

// a11y_begin puts the app on the accessibility bus and asks the backend to
// poll it, so a reader's questions wake us like any other event.
@(private)
a11y_begin :: proc(rt: ^Runtime($State, $Msg), title: string) {
	if os.get_env("BALDR_A11Y", context.temp_allocator) == "0" do return
	ok, why := a11y_start(title)
	if !ok {
		if os.get_env("BALDR_A11Y_DEBUG", context.temp_allocator) == "1" do fmt.eprintfln("baldr/a11y: off: %s", why)
		return
	}
	if fd := a11y_fd(); fd < 0 {
		// nothing to wait on: this platform asks us inside its own event
		// loop (macOS, Windows), so there is no socket to add
	} else if b := rt.backend; b != nil && b.watch_fd != nil {
		b.watch_fd(b, fd, true)
	} else if os.get_env("BALDR_A11Y_DEBUG", context.temp_allocator) == "1" {
		fmt.eprintfln("baldr/a11y: the backend cannot poll us; a reader's questions wait for the next frame")
	}
}

// a11y_frame tells the bridge which windows exist now and answers whatever
// the desktop asked while we were asleep.
@(private)
a11y_frame :: proc(rt: ^Runtime($State, $Msg)) {
	if !a11y_attached() do return
	windows := make([dynamic]A11y_Window, 0, len(rt.ctxs), context.temp_allocator)
	for c in rt.ctxs {
		if c.kind == .Applet do continue // an applet is drawn inside another app's bar
		w := A11y_Window{
			tree = &c.ui.tree, title = c.desc.title, active = c.hide_st.focus_on != 0,
			user = c,
			// acting on a node means queueing the app's message, which only
			// the run loop can do: it is the one place that knows Msg
			act = proc(user: rawptr, n: Node, what: A11y_Act) -> bool {
				c := (^Surface_Ctx(Msg))(user)
				done := false
				switch what {
				case .Click: done = click(&c.ui, n)
				case .Focus: done = set_focus(&c.ui.tree, n, true)
				case .Edit:  done = a11y_apply_edit(&c.ui, n)
				case .Clip:  done = a11y_apply_clip(&c.ui, n)
				case .Wake:  done = true
				}
				c.needs_frame = true
				return done
			},
		}
		if c.kind == .Layer {
			if r, _, have := surface_rect(c.desc.tag); have {
				w.origin, w.origin_known = {i32(r.x), i32(r.y)}, true
			}
		}
		// On a platform whose accessibility interface is answered through
		// the window — NSAccessibility, UI Automation — the bridge needs the
		// object the desktop will name. Nil everywhere else.
		if b := rt.backend; b != nil {
			if b.surface_native != nil do w.native = b.surface_native(b, c.surf)
			if b.wake != nil {
				// what a reader's press has to wake; see A11y_Window.wake
				w.wake = proc(user: rawptr) {
					b := (^platform.Backend)(user)
					b.wake(b)
				}
				w.wake_user = b
			}
		}
		append(&windows, w)
	}
	a11y_windows(windows[:])
	a11y_events() // …what moved since the last look: focus, the caret, a value
	a11y_pump()
}

@(private)
clipboard_get_cb :: proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
	b := (^platform.Backend)(user)
	return b.clipboard_get(b, allocator)
}

// drag_source_ctx is the window whose drag the compositor carries now, if
// it is one of ours.
@(private)
drag_source_ctx :: proc(rt: ^Runtime($State, $Msg)) -> ^Surface_Ctx(Msg) {
	for c in rt.ctxs do if c.ui.drag.active && c.ui.drag.compositor do return c
	return nil
}

@(private)
dnd_start_cb :: proc(user: rawptr, surface: u32, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool {
	b := (^platform.Backend)(user)
	return b.drag_start(b, platform.Surface(surface), items, serial, icon)
}

@(private)
dnd_accept_cb :: proc(user: rawptr, accept: bool) {
	b := (^platform.Backend)(user)
	b.drag_accept(b, accept)
}

@(private)
dnd_receive_cb :: proc(user: rawptr, mime: string) -> bool {
	b := (^platform.Backend)(user)
	return b.drag_receive(b, mime)
}

@(private)
dnd_finish_cb :: proc(user: rawptr, accepted: bool) {
	b := (^platform.Backend)(user)
	b.drag_finish(b, accepted)
}

@(private)
clipboard_types_cb :: proc(user: rawptr, allocator := context.allocator) -> []string {
	b := (^platform.Backend)(user)
	return b.clipboard_types(b, allocator)
}

@(private)
clipboard_get_data_cb :: proc(user: rawptr, mime: string, allocator := context.allocator) -> ([]u8, bool) {
	b := (^platform.Backend)(user)
	return b.clipboard_get_data(b, mime, allocator)
}

@(private)
clipboard_set_data_cb :: proc(user: rawptr, items: []Clip_Item) -> bool {
	b := (^platform.Backend)(user)
	return b.clipboard_set_data(b, items)
}

@(private)
primary_get_cb :: proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
	b := (^platform.Backend)(user)
	return b.primary_get(b, allocator)
}

@(private)
primary_set_cb :: proc(user: rawptr, text: string) -> bool {
	b := (^platform.Backend)(user)
	return b.primary_set(b, text)
}

@(private)
clipboard_set_cb :: proc(user: rawptr, text: string) -> bool {
	b := (^platform.Backend)(user)
	return b.clipboard_set(b, text)
}

@(private)
modal_redraw :: proc(user: rawptr, s: platform.Surface) {
	// Inside an OS modal loop the Ev_Configure events are still queued, so
	// ask the backend for the live geometry before painting.
	fc: ^Frame_Ctx
	for f in (^[dynamic]^Frame_Ctx)(user)^ do if f.surface == s { fc = f; break }
	if fc == nil do return
	size, size_px, scale := fc.backend.surface_geometry(fc.backend, fc.surface)
	if size_px != fc.size_px || scale != fc.scale {
		fc.size, fc.size_px, fc.scale = size, size_px, scale
		if fc.target != 0 && size_px.x > 0 && size_px.y > 0 do gpu.target_resize(fc.r, fc.target, size_px)
	}
	// This paint answers the frame that was asked for (the backend paints
	// here instead of sending Ev_Redraw), so the ask is spent. Left set, the
	// next change would see a frame on its way, ask for none, and the window
	// would stand still.
	fc.frame_requested = false
	do_frame(fc)
}

@(private)
map_key :: proc "contextless" (k: platform.Key) -> Key {
	#partial switch k {
	case .Tab:       return .Tab
	case .Enter, .KP_Enter: return .Enter
	case .Space:     return .Space
	case .Escape:    return .Escape
	case .Left:      return .Left
	case .Right:     return .Right
	case .Up:        return .Up
	case .Down:      return .Down
	case .Home:      return .Home
	case .End:       return .End
	case .Page_Up:   return .Page_Up
	case .Page_Down: return .Page_Down
	// text_input hook
	case .Backspace: return .Backspace
	case .Delete:    return .Delete
	case .A:         return .A
	case .C:         return .C
	case .V:         return .V
	case .X:         return .X
	case .Menu:      return .Menu
	case .F10:       return .F10
	case .Z:         return .Z
	case .Y:         return .Y
	case .F:         return .F
	case .G:         return .G
	case .H:         return .H
	case .B:         return .B
	case .I:         return .I
	case .U:         return .U
	case .E:         return .E
	case .K:         return .K
	case .Slash:     return .Slash
	case .F3:        return .F3
	// the rest of the keyboard, for shortcuts
	case .D: return .D
	case .J: return .J
	case .L: return .L
	case .M: return .M
	case .N: return .N
	case .O: return .O
	case .P: return .P
	case .Q: return .Q
	case .R: return .R
	case .S: return .S
	case .T: return .T
	case .W: return .W
	case .N0, .KP_0: return .N0
	case .N1, .KP_1: return .N1
	case .N2, .KP_2: return .N2
	case .N3, .KP_3: return .N3
	case .N4, .KP_4: return .N4
	case .N5, .KP_5: return .N5
	case .N6, .KP_6: return .N6
	case .N7, .KP_7: return .N7
	case .N8, .KP_8: return .N8
	case .N9, .KP_9: return .N9
	case .F1: return .F1
	case .F2: return .F2
	case .F4: return .F4
	case .F5: return .F5
	case .F6: return .F6
	case .F7: return .F7
	case .F8: return .F8
	case .F9: return .F9
	case .F11: return .F11
	case .F12: return .F12
	case .Insert: return .Insert
	case .Minus, .KP_Subtract: return .Minus
	case .Equal, .KP_Add, .KP_Equal: return .Equal
	case .Comma: return .Comma
	case .Period, .KP_Decimal: return .Period
	case .Grave: return .Grave
	case .Bracket_L: return .Bracket_L
	case .Bracket_R: return .Bracket_R
	case .Backslash: return .Backslash
	case .Semicolon: return .Semicolon
	case .Apostrophe: return .Apostrophe
	case .F13: return .F13
	case .F14: return .F14
	case .F15: return .F15
	case .F16: return .F16
	case .F17: return .F17
	case .F18: return .F18
	case .F19: return .F19
	case .F20: return .F20
	case .F21: return .F21
	case .F22: return .F22
	case .F23: return .F23
	case .F24: return .F24
	// the modifiers as keys, for a chord being pressed (key_capture.odin)
	case .Shift_L: return .Shift_L
	case .Shift_R: return .Shift_R
	case .Ctrl_L:  return .Ctrl_L
	case .Ctrl_R:  return .Ctrl_R
	case .Alt_L:   return .Alt_L
	case .Alt_R:   return .Alt_R
	case .Super_L: return .Super_L
	case .Super_R: return .Super_R
	case .Caps_Lock:   return .Caps_Lock
	case .Num_Lock:    return .Num_Lock
	case .Scroll_Lock: return .Scroll_Lock
	case .Print: return .Print
	case .Pause: return .Pause
	// the keys beyond the typewriter
	case .Volume_Up:   return .Volume_Up
	case .Volume_Down: return .Volume_Down
	case .Volume_Mute: return .Volume_Mute
	case .Mic_Mute:    return .Mic_Mute
	case .Media_Play:       return .Media_Play
	case .Media_Pause:      return .Media_Pause
	case .Media_Play_Pause: return .Media_Play_Pause
	case .Media_Stop:       return .Media_Stop
	case .Media_Prev:       return .Media_Prev
	case .Media_Next:       return .Media_Next
	case .Media_Rewind:     return .Media_Rewind
	case .Media_Forward:    return .Media_Forward
	case .Media_Record:     return .Media_Record
	case .Brightness_Up:       return .Brightness_Up
	case .Brightness_Down:     return .Brightness_Down
	case .Kbd_Brightness_Up:   return .Kbd_Brightness_Up
	case .Kbd_Brightness_Down: return .Kbd_Brightness_Down
	case .Power: return .Power
	case .Sleep: return .Sleep
	case .Wake:  return .Wake
	case .Eject: return .Eject
	case .Search:     return .Search
	case .Home_Page:  return .Home_Page
	case .Mail:       return .Mail
	case .Calculator: return .Calculator
	case .Explorer:   return .Explorer
	case .Favorites:  return .Favorites
	case .Tools:      return .Tools
	case .Refresh:    return .Refresh
	case .Browser_Back:    return .Browser_Back
	case .Browser_Forward: return .Browser_Forward
	case .Display_Switch:  return .Display_Switch
	case .Touchpad_Toggle: return .Touchpad_Toggle
	case .Wlan:      return .Wlan
	case .Bluetooth: return .Bluetooth
	case .Rf_Kill:   return .Rf_Kill
	}
	return .Unknown
}

@(private)
map_mods :: proc "contextless" (m: platform.Mods) -> Mods {
	out: Mods
	if .Shift in m do out += {.Shift}
	if .Ctrl in m do out += {.Ctrl}
	if .Alt in m do out += {.Alt}
	if .Super in m do out += {.Super}
	return out
}

// theme_accent is the colour the generated theme is seeded from: the app's
// own where it named one (an app's brand is its own, and a desktop accent
// must not repaint it), the desktop's otherwise.
//
// The desktop states its accent in sRGB (see `platform.Ev_Theme.accent`) and
// `Color` is linear: sRGB 0.5 is linear 0.214, so unconverted channels would
// seed the theme from a much darker colour than the one on screen.
@(private)
theme_accent :: proc(app_accent: Color, sys: platform.Ev_Theme) -> Color {
	if app_accent != {} do return app_accent
	if !sys.has_accent do return {}
	return Color{
		srgb_to_linear(sys.accent[0]),
		srgb_to_linear(sys.accent[1]),
		srgb_to_linear(sys.accent[2]),
		1,
	}
}

// theme_fonts puts the desktop's UI fonts on a generated theme, for the
// families it does not already name.
//
// The same rule as the accent: a theme that names a face named it, and the
// desktop is the fallback. It is applied *before* `App.adjust_theme`, so an
// app's own last word still wins. A family the machine does not have falls
// through to the embedded faces, which is what `font_family.odin` already
// does for a theme that names something missing.
//
// The size the desktop states alongside the family is deliberately not used
// — see `platform.Ev_Theme.font_family`.
@(private)
theme_fonts :: proc(th: ^Theme, sys: platform.Ev_Theme) {
	if th.font_family == "" do th.font_family = sys.font_family
	if th.mono_family == "" do th.mono_family = sys.mono_family
}

// desktop_theme is the theme for a desktop that says it is light or dark and
// whether it wants high contrast: the app's own accent generated for both
// when it gave one, Baldr's own otherwise. High contrast is the desktop's
// to ask for, so every app that named no theme of its own follows it.
@(private)
desktop_theme :: proc(accent: Color, dark, high_contrast: bool) -> Theme {
	mode := Theme_Mode.Dark if dark else Theme_Mode.Light
	if accent != {} do return theme_from_seed(accent, mode, .High if high_contrast else .Normal)
	if high_contrast do return theme_high_contrast(mode)
	return theme_dark() if dark else theme_light()
}

// theme_finish is the last step of every theme the runtime builds: the
// app's own adjustments, then the debug motion scale over what it left.
@(private)
theme_finish :: proc(th: ^Theme, adjust: proc(th: ^Theme)) {
	if adjust != nil do adjust(th)
	// BALDR_DENSITY=-1 / =1 previews compact or spacious without changing the app.
	if d, ok := strconv.parse_f32(os.get_env("BALDR_DENSITY", context.temp_allocator)); ok do th.density = d
	// The accent as ink falls back to the accent as a fill, for a theme an
	// app assembled itself or an `adjust_theme` that moved `primary` alone.
	// After the adjust, so an app's own ink stays; a zero here would leave
	// every ghost button's label transparent.
	if th.color.accent_text.a <= 0 do th.color.accent_text = th.color.primary
	motion_scale(th)
}

// `raw` is the theme before the app's adjust ran: refresh_theme starts
// again from it rather than adjusting an adjusted theme.
@(private)
pick_theme :: proc(app_theme: Theme, accent: Color, sys: platform.Ev_Theme, adjust: proc(th: ^Theme) = nil) -> (th: Theme, raw: Theme) {
	switch {
	case app_theme.name != "": th = app_theme
	case os.get_env("BALDR_THEME", context.temp_allocator) == "dark":  th = desktop_theme(theme_accent(accent, sys), true, sys.high_contrast)
	case os.get_env("BALDR_THEME", context.temp_allocator) == "light": th = desktop_theme(theme_accent(accent, sys), false, sys.high_contrast)
	case sys.palette.ok: th = theme_from_system(sys.palette, sys.high_contrast, {} if sys.high_contrast else accent) // the desktop's own scheme
	case: th = desktop_theme(theme_accent(accent, sys), sys.dark, sys.high_contrast)
	}
	if app_theme.name == "" do theme_fonts(&th, sys) // a theme the app named keeps its own faces
	raw = th
	theme_finish(&th, adjust)
	return
}

// prefs_now is the accessibility preferences to run with: the app's when it
// said (App.a11y), the desktop's otherwise.
@(private)
prefs_now :: proc(rt: ^Runtime($State, $Msg)) -> A11y_Prefs {
	if p, said := rt.prefs_app.?; said do return p
	return rt.prefs
}

// titlebar_now is what title bars follow: the app's choices when it gave
// them (App.titlebar), else the desktop's.
@(private)
titlebar_now :: proc(rt: ^Runtime($State, $Msg)) -> Chrome_Prefs {
	if p, said := rt.app.titlebar.?; said do return chrome_prefs(p)
	return rt.titlebar
}

// titlebar_of reads the desktop's choices for a title bar from its theme
// event (GNOME's words); a double-click action it doesn't know maximises.
@(private)
titlebar_of :: proc(sys: platform.Ev_Theme) -> Chrome_Prefs {
	action, _ := titlebar_action_of(sys.double_click)
	return chrome_prefs({button_layout = sys.button_layout, double_click = action})
}

// a11y_prefs_of reads the desktop's accessibility preferences from its
// theme event; BALDR_GLASS=0 and BALDR_MOTION=0 turn them on for testing,
// and BALDR_TEXT_SCALE=1.5 sets the text size the desktop would ask for.
@(private)
a11y_prefs_of :: proc(sys: platform.Ev_Theme) -> A11y_Prefs {
	out := A11y_Prefs{
		reduce_motion       = sys.reduce_motion || os.get_env("BALDR_MOTION", context.temp_allocator) == "0",
		reduce_transparency = sys.reduce_transparency || os.get_env("BALDR_GLASS", context.temp_allocator) == "0",
		text_scale          = (sys.text_scale if sys.text_scale > 0 else 1) * desktop_font_scale(sys.font_size),
	}
	if sc, ok := strconv.parse_f32(os.get_env("BALDR_TEXT_SCALE", context.temp_allocator)); ok && sc > 0 do out.text_scale = sc
	return out
}

// Told_Dark is what a backend was last told about a window's theme.
@(private)
Told_Dark :: enum u8 { Never, Light, Dark }

// frame_dark_sync tells the backend whether a window's theme is dark when
// that changes, so a frame the platform draws matches the app's theme rather
// than the desktop's (a dark app on a light Mac or Windows desktop would
// otherwise get a light title bar). It runs where glass is brought up to
// date — after every build, at creation and on every desktop change — which
// is everywhere a window's theme can move.
@(private)
frame_dark_sync :: proc(b: ^platform.Backend, surf: platform.Surface, th: ^Theme, told: ^Told_Dark) {
	if b == nil || b.surface_set_dark == nil do return
	want := Told_Dark.Dark if th.dark else Told_Dark.Light
	if told^ == want do return
	told^ = want
	b.surface_set_dark(b, surf, th.dark)
}

// DESKTOP_FONT_BASELINE_PT is the desktop font size Baldr's type scale is
// drawn for. Its body text is 15 px, and an 11 pt font in GTK is
// 11 × 96 / 72 = 14.7 px: GNOME's default, and what GTK apps on such a
// desktop draw. So an 11 pt desktop changes nothing, and any other size
// moves every role by the same ratio — a 10 pt KDE desktop draws Baldr at
// the size of its own apps, a 13 pt one 18 % larger.
@(private)
DESKTOP_FONT_BASELINE_PT :: f32(11)

// desktop_font_scale is how much the desktop's UI font size asks for text
// to grow or shrink: its points over the baseline, 1 when it said nothing.
// Folded into the desktop's text scale, so it multiplies with
// `text-scaling-factor` (as GTK does: GNOME's Large Text and a font size set
// in Tweaks are two settings) and reaches an app's own `set_text_scale` the
// same way. Clamped, so a description nobody meant cannot make text
// unreadably small or absurdly large.
@(private)
desktop_font_scale :: proc "contextless" (points: f32) -> f32 {
	if points <= 0 do return 1
	return clamp(points / DESKTOP_FONT_BASELINE_PT, 0.6, 2.5)
}

// motion_scale: BALDR_MOTION_SCALE=8 slows every transition 8× for
// eyeballing / recording.
@(private)
motion_scale :: proc(th: ^Theme) {
	if sc, ok := strconv.parse_f32(os.get_env("BALDR_MOTION_SCALE", context.temp_allocator)); ok && sc > 0 {
		th.motion.fast *= sc
		th.motion.base *= sc
		th.motion.slow *= sc
	}
}

// The renderer's drawable for a surface, as the backend handed it over: a
// VkSurfaceKHR on Vulkan, a CAMetalLayer on macOS. The toolkit only carries
// it from `drawable_create` to `gpu.target_add` and never looks inside.
@(private)
Vk_Surface :: gpu.Drawable

// Surface_Ctx is one open surface: its own tree, interaction state and
// swapchain target. Heap-allocated so the Frame_Ctx pointer the backend
// holds for modal redraws stays put.
@(private)
Surface_Ctx :: struct($Msg: typeid) {
	ui:          Ui(Msg),
	fc:          Frame_Ctx,
	desc:        Surface_Desc(Msg),
	surf:        platform.Surface,
	kind:        Surface_Kind, // what it opened as (an applet with no shell to embed it is a window)
	told_dark:   Told_Dark, // what the backend was last told of this window's theme (frame_dark_sync)
	vk_surf:     Vk_Surface,
	last_cursor: Cursor,
	last_picture: Cursor_Picture_Key, // the cursor picture last sent (cursor_sync)
	inhibiting:  bool, // the desktop's own shortcuts are held off for this surface (key_capture.odin)
	awake:       bool, // …and the screen is being held on for it (keep_awake.odin)
	needs_view:  bool,
	view_from:   runtime.Source_Code_Location, // what first asked for the view since it was last built (ask_view; BALDR_DEBUG_EVENTS says)
	needs_frame: bool,
	draw_now:    bool, // a frame was asked for and is drawn once this wake-up's view is up to date (Ev_Redraw)
	keyboard_dropped: bool, // told the compositor it wants no keyboard (panel_escape); put back on the next frame
	warned:      Surface_Changes, // changes to fixed fields already reported
	state_sent:  Window_State, // what on_state last reported
	state_told:  bool,         // …and whether it has reported at all yet
	popups:        [dynamic]^Popup_Ctx, // its anchored overlays on surfaces of their own, parents before children (popup.odin)
	popups_failed: bool,               // the backend couldn't open one: overlays stay inside
	target_warned: bool,               // said once that there was no swapchain slot
	resize_said:   bool,               // …and once that a window's own size could not be asked for
	output:        string,             // the screen it entered (owned; "" until it does), for a FIT layer's cap
	hide_st:       Hide_State,         // where the pointer and the keyboard are, for a surface that hides (hide.odin)
}

// Runtime is everything run() shares between surfaces.
@(private)
Runtime :: struct($State, $Msg: typeid) {
	icon:     platform.Window_Icon, // App.icon as the backends take it, the runtime's own copy
	app:           App(State, Msg),
	backend:       ^platform.Backend,
	r:             ^gpu.Renderer,
	te:            ^Text_Engine,
	activations:   [dynamic]Activation, // `activate` commands waiting for their window (activations_run)
	toplevel_sent: [dynamic]Toplevel_Rect, // where each window was last said to be shown (toplevel_rects_sync)
	posters:       [dynamic]rawptr,     // ^Poster_Box(Msg): shut when the run ends, never freed (Poster)
	state:         State,
	theme:         Theme, // the desktop's, finished: what a surface that follows the desktop shows, and what follow_system_theme goes back to. An App.theme is not here; it is pinned on each tree (tree_start_theme)
	theme_raw:     Theme, // …the same theme before App.adjust_theme ran, for refresh_theme
	accent:        Color, // App.accent: the seed the theme is generated from while following the desktop
	adjust_theme:  proc(th: ^Theme), // App.adjust_theme: run over every theme built, after each rebuild
	prefs:         A11y_Prefs, // the desktop's accessibility preferences, folded into every surface's theme
	prefs_app:     Maybe(A11y_Prefs), // what the app said instead (App.a11y): the desktop's are then never applied
	gpu_retry_ms:  f64, // when the device may be asked for again after a reset (gpu_reset.odin)
	rehearse_ms:   f64, // BALDR_SIMULATE_GPU_RESET: when to pretend the device has gone (0: never)
	rehearse_every: f64, // …and how often after that (0: once)
	titlebar:      Chrome_Prefs, // the desktop's choices for a title bar the app draws (widget_chrome.odin)
	locale:        Locale, // the desktop's, applied to every surface
	ctxs:          [dynamic]^Surface_Ctx(Msg),
	frames:        [dynamic]^Frame_Ctx, // the same surfaces, for the backend's modal redraw
	wanted:        [dynamic]Surface_Desc(Msg),
	tray_wanted:   [dynamic]Tray_Desc(Msg),      // scratch for app.tray
	tray_live:     map[u64]Tray_Live(Msg),       // what is in the tray now, by tag (tray.odin)
	t0:            time.Tick,
	pending_files: map[u64]Handler(Msg, Files), // file dialogs on screen, by token
	pending_urls:  map[u64]Url_Ask(Msg),        // links handed to the desktop, waiting for its answer (url.odin)
	pending_paths: map[u64]Path_Ask(Msg),       // …and local files handed to it (path_open.odin); one token counter serves both
	// The strings those asks answered with, freed once the update that was
	// given them has run. A message carries the string, not a copy of it, so
	// freeing it at delivery would hand the app a dangling slice.
	spent_asks:    [dynamic]string,
	notify_watches: [dynamic]Notify_Watch(Msg), // who to tell about each notification's tag (notify.odin)
	applets_closed: map[u64]string,             // applets the compositor closed, by tag, with the token they had: not opened again with it
	next_token:    u64,
	msgs:          [dynamic]Msg,                // messages the runtime itself produces (dialog outcomes, job posts)
	mailbox:       Mailbox(Msg),                // what worker threads post (job.odin)
	jobs:          [dynamic]^Job(Msg),          // running jobs
	sched:         Sched(Msg),                  // delays, timers, watches (sched.odin)
	wanted_subs:   [dynamic]Sub(Msg),           // scratch for app.subscriptions
	io:            Io,                          // the file IO thread (file_io.odin)
	canvas_host:   ^Canvas_Host,                // the app's Gpu, once asked for (canvas.odin)
	gpu_waiting:   [dynamic]Handler(Msg, Gpu),  // gpu_open asked before the device was up
	lock:          Session_Lock(Msg),           // the app's lock of the session (lock.odin)
	keyboard:      Keyboard_Info,               // the lock keys on and the layout, given every tree (keyboard_info.odin); `layout` owned
}

// run_cmd performs what update asked for. Returns false when the app is done.
@(private)
run_cmd :: proc(rt: ^Runtime($State, $Msg), cmd: Cmd(Msg)) -> bool {
	switch cmd.kind {
	case .None:
	case .Quit:
		return false
	case .Open_Files, .Save_File:
		rt.next_token += 1
		d := cmd.dialog
		d.token = rt.next_token
		shown := rt.backend.file_dialog != nil && rt.backend.file_dialog(rt.backend, d)
		if shown {
			rt.pending_files[d.token] = cmd.on_files
		} else {
			files_deliver(cmd.on_files, Files{ok = false, why = .Not_Shown}, d.token, &rt.msgs) // no dialog on this desktop: say so at once
		}
	case .Job:
		if j := job_start(&rt.mailbox, cmd.work, cmd.data, cmd.on_done, cmd.tag); j != nil {
			append(&rt.jobs, j)
		} else {
			handler_deliver(cmd.on_done, Job_Done{cancelled = true}, cmd.tag, &rt.msgs) // no thread: over before it began
		}
	case .Cancel:
		for j in rt.jobs do if j.tag == cmd.tag do job_stop(j)
	case .Batch:
		for c in cmd.list do if !run_cmd(rt, c) do return false
	case .Delay:
		sched_delay(&rt.sched, clock_now(rt), cmd.ms, cmd.msg)
	case .Secret_Get, .Secret_Set, .Secret_Delete:
		secret_run(&rt.mailbox, cmd)
	case .Read_File:
		file_read(&rt.io, &rt.mailbox, &rt.jobs, cmd.path, cmd.on_read, cmd.tag)
	case .Write_File:
		file_write(&rt.io, &rt.mailbox, &rt.jobs, cmd.path, cmd.bytes, cmd.on_write, cmd.tag)
	case .Copy_Text:
		b := rt.backend
		if cmd.primary {
			if b.primary_set != nil do b.primary_set(b, cmd.text)
		} else if b.clipboard_set != nil {
			b.clipboard_set(b, cmd.text)
		}
	case .Copy_Files:
		b := rt.backend
		if b.clipboard_set_data != nil {
			b.clipboard_set_data(b, clip_files_items(cmd.paths, cmd.cut))
		} else if b.clipboard_set != nil {
			b.clipboard_set(b, strings.join(cmd.paths, "\n", context.temp_allocator)) // a text-only backend: the paths at least
		}
	case .Copy_Html:
		b := rt.backend
		items := clip_html_items(cmd.html, cmd.text)
		// Nothing to offer is left alone rather than offered: setting an
		// empty selection would take what is on the clipboard away (on
		// Windows `clipboard_set_data` empties it before it writes).
		if b == nil || len(items) == 0 do break
		if b.clipboard_set_data != nil {
			b.clipboard_set_data(b, items)
		} else if b.clipboard_set != nil && cmd.text != "" {
			b.clipboard_set(b, cmd.text) // a text-only clipboard: the text at least
		}
	case .Paste:
		b := rt.backend
		forms: Clip_Forms
		if cmd.primary { // text is all a selection is
			if b.primary_get != nil do forms.text, _ = b.primary_get(b, context.temp_allocator)
			handler_deliver(cmd.on_paste, paste_outcome(forms), 0, &rt.msgs)
			break
		}
		if b.clipboard_get != nil do forms.text, _ = b.clipboard_get(b, context.temp_allocator)
		if b.clipboard_get_data != nil {
			forms.uri_list, _ = b.clipboard_get_data(b, MIME_URI_LIST, context.temp_allocator)
			forms.gnome, _ = b.clipboard_get_data(b, MIME_GNOME_FILES, context.temp_allocator)
			forms.kde_cut, _ = b.clipboard_get_data(b, MIME_KDE_CUT, context.temp_allocator)
		}
		handler_deliver(cmd.on_paste, paste_outcome(forms), 0, &rt.msgs)
	case .Copy_Image:
		pic := cmd.picture
		if pic == nil do break
		if b := rt.backend; b != nil && b.clipboard_set_data != nil {
			b.clipboard_set_data(b, {Clip_Item{mime = MIME_PNG, later = &pic.later}}) // the backend holds its own reference
		}
		platform.clip_later_release(&pic.later) // the command's
	case .Paste_Image:
		paste_image_start(rt, cmd.on_image)
	case .Gpu_Open:
		if h := canvas_host_for(rt); h != nil {
			handler_deliver(cmd.on_gpu, Gpu{host = h}, 0, &rt.msgs)
		} else {
			append(&rt.gpu_waiting, cmd.on_gpu) // the device comes with the first surface
		}
	case .Canvas_Read:
		if cmd.host == nil {
			handler_deliver(cmd.on_canvas, Canvas_Read{canvas = cmd.canvas, x = cmd.area[0], y = cmd.area[1], w = cmd.area[2], h = cmd.area[3]}, cmd.tag, &rt.msgs)
			break
		}
		if rt.mailbox.canvas_host == nil do rt.mailbox.canvas_host = cmd.host // a Gpu of its own (gpu_reference)
		id := canvas_host_read(cmd.host, cmd.canvas, cmd.area)
		rt.mailbox.canvas_waiting[id] = {on_read = cmd.on_canvas, tag = cmd.tag}
	case .Toplevel:
		if b := rt.backend; b != nil && b.toplevel_request != nil do b.toplevel_request(b, cmd.id, cmd.toplevel)
	case .Workspace:
		if b := rt.backend; b != nil && b.workspace_request != nil do b.workspace_request(b, cmd.id, cmd.workspace, cmd.output)
	case .Forget_Image:
		// Every surface, because each has its own tree and a picture may be
		// in several at once. This runs during message dispatch, so it is
		// before any view is built and long before anything paints.
		for c in rt.ctxs do image_forget(&c.ui, cmd.picture_img)
		image_destroy(cmd.picture_img)
	case .Focus:
		// Asked of every surface: the key names the widget, not the window,
		// and in practice one surface has it. A widget given a key another
		// widget shares would be ambiguous, which is why `focus` documents
		// that the key must be its own.
		for c in rt.ctxs do c.ui.focus_want, c.ui.focus_tries = cmd.tag, 0
	case .Reveal:
		// The same shape as Focus, and for the same reason: the command
		// usually causes the screen holding the list to be built. Every
		// surface unless the app named one, since a multi-window app gives
		// the same list the same key in each window, and an ask that goes
		// everywhere is taken by whichever window is built first.
		for c in rt.ctxs {
			if !ask_for_surface(cmd.reveal.surface, c.desc.tag) do continue
			reveal_put(&c.ui, cmd.reveal)
		}
	case .Hold:
		for c in rt.ctxs {
			if !ask_for_surface(cmd.hold.surface, c.desc.tag) do continue
			hold_put(&c.ui, cmd.hold)
		}
	case .Activate:
		append(&rt.activations, Activation{tag = cmd.tag, token = strings.clone(cmd.token)})
		activations_run(rt) // now, or when the window it names is opened
	case .Poster:
		box := new(Poster_Box(Msg)) // never freed: a foreign thread may post after the run (see Poster)
		box.mailbox = &rt.mailbox
		append(&rt.posters, box)
		handler_deliver(cmd.on_poster, Poster(Msg){box = box}, 0, &rt.msgs)
	case .Open_Url:
		url_open_start(rt, cmd)
	case .Notify:
		notify_start(rt, cmd)
	case .Notify_Close:
		notify_close_start(rt, cmd)
	case .Open_Path, .Reveal_Path:
		path_open_start(rt, cmd)
	case .Lock:
		lock_start(rt, cmd)
	case .Unlock:
		lock_stop(rt)
	}
	return true
}

// Activation is an `activate` command waiting for its window: its tag, and
// the token it carries (owned).
@(private)
Activation :: struct {
	tag:   u64,
	token: string,
}

// activations_run hands the backend each activation whose window is open;
// one whose window is not yet (a player's, closed while it played) waits
// for it (the backend then activates it as it first shows).
@(private)
activations_run :: proc(rt: ^Runtime($State, $Msg)) {
	b := rt.backend
	for i := 0; i < len(rt.activations); {
		a := rt.activations[i]
		target: ^Surface_Ctx(Msg)
		for c in rt.ctxs do if c.desc.tag == a.tag || (a.tag == 0 && c.desc.kind == .Window) {
			target = c
			break
		}
		if target == nil {
			i += 1
			continue
		}
		if b != nil && b.activate != nil do b.activate(b, target.surf, a.token)
		delete(a.token)
		ordered_remove(&rt.activations, i)
	}
}

@(private)
clock_now :: proc(rt: ^Runtime($State, $Msg)) -> f64 {
	return time.duration_milliseconds(time.tick_since(rt.t0))
}

// sync_subs makes the running timers and watches match what the app
// declares for its state now.
@(private)
sync_subs :: proc(rt: ^Runtime($State, $Msg)) {
	if rt.app.subscriptions == nil do return
	clear(&rt.wanted_subs)
	rt.app.subscriptions(&rt.state, &rt.wanted_subs)
	sched_sync(&rt.sched, rt.wanted_subs[:], clock_now(rt), watch_start_cb, watch_stop_cb, rt.backend)
	// The frame clock is per surface and only while it is asked for: it
	// paints at the screen's rate, which Baldr otherwise never does.
	want := sched_wants_frames(&rt.sched)
	if b := rt.backend; b != nil && b.frames_wanted != nil {
		for c in rt.ctxs do b.frames_wanted(b, c.surf, want)
	}
}

@(private)
watch_start_cb :: proc(user: rawptr, path: string, token: u64) -> bool {
	b := (^platform.Backend)(user)
	return b.watch != nil && b.watch(b, path, token)
}

@(private)
watch_stop_cb :: proc(user: rawptr, token: u64) {
	b := (^platform.Backend)(user)
	if b.unwatch != nil do b.unwatch(b, token)
}

// run_holds says whether a run with no surface carries on (App.keep_running).
@(private)
run_holds :: proc(rt: ^Runtime($State, $Msg)) -> bool {
	// An app in the tray with no window has not finished; one that declares
	// neither has.
	if len(rt.tray_live) > 0 do return true
	return rt.app.keep_running != nil && rt.app.keep_running(&rt.state)
}

// wake_backend is the mailbox's wake: a worker posted, so the loop's
// pump must return.
@(private)
wake_backend :: proc(user: rawptr) {
	b := (^platform.Backend)(user)
	if b.wake != nil do b.wake(b)
}

// debug_hides_typing: the focus is a password field, so the event log, which
// people paste into bug reports, says that typing happened and not what.
@(private)
debug_hides_typing :: proc(t: ^Tree) -> bool {
	s := &t.inputs[t.focus]
	return s != nil && s.password
}

@(private)
ctx_for :: proc(rt: ^Runtime($State, $Msg), s: platform.Surface) -> ^Surface_Ctx(Msg) {
	for c in rt.ctxs {
		if c.surf == s do return c
		for p in c.popups do if p.surf == s do return c
	}
	return nil
}

// popup_ctx_for is the popup `s` is and the surface it belongs to; a nil
// popup when `s` is none.
@(private)
popup_ctx_for :: proc(rt: ^Runtime($State, $Msg), s: platform.Surface) -> (^Surface_Ctx(Msg), ^Popup_Ctx) {
	for c in rt.ctxs do for p in c.popups do if p.surf == s do return c, p
	return nil, nil
}

@(private)
surface_open :: proc(rt: ^Runtime($State, $Msg), desc: Surface_Desc(Msg)) -> bool {
	app_id := rt.app.app_id if rt.app.app_id != "" else "baldr.app"
	pdesc := surface_resolve(desc, rt.backend.caps, app_id)
	pdesc.icon = rt.icon
	pdesc.parent = surface_of_tag(rt, desc.parent) if desc.kind == .Window else 0
	// A position saved on a screen that has since gone would put the window
	// out of reach, so it is dropped rather than honoured (see
	// position_reachable). The size and the maximised state still apply.
	if p, want := pdesc.position.?; want && !position_reachable(p, outputs()) do pdesc.position = nil
	surf, sok := rt.backend.surface_create(rt.backend, pdesc)
	if !sok {
		fmt.eprintfln("baldr: surface_create failed (tag %d, %v)", desc.tag, desc.kind)
		return false
	}
	drawable, vok := rt.backend.drawable_create(rt.backend, surf, gpu.instance(rt.r))
	if !vok {
		fmt.eprintln("baldr: the backend gave no drawable for the surface")
		rt.backend.surface_destroy(rt.backend, surf)
		return false
	}
	c := new(Surface_Ctx(Msg))
	c.desc = desc
	c.desc.title = strings.clone(desc.title) // the app's string may not outlive this build
	c.desc.layer.output = strings.clone(desc.layer.output)
	c.desc.applet.token = strings.clone(desc.applet.token)
	c.desc.output = strings.clone(desc.output)
	c.surf = surf
	c.kind = pdesc.kind
	c.vk_surf = gpu.Drawable(drawable)
	ui_init(&c.ui)
	c.ui.tree.debug_damage = os.get_env("BALDR_DEBUG_DAMAGE", context.temp_allocator) != ""
	c.ui.tree.debug_bounds = os.get_env("BALDR_DEBUG_BOUNDS", context.temp_allocator) != ""
	if c.ui.tree.debug_bounds do fmt.eprintln("baldr/bounds: on: every node is checked to draw inside what a repaint of it clears") // so a clean log is evidence
	c.ui.tree.debug_events = os.get_env("BALDR_DEBUG_EVENTS", context.temp_allocator) != ""
	tree_use_text_engine(&c.ui.tree, rt.te)
	tree_desktop_a11y(&c.ui.tree, prefs_now(rt))
	c.ui.tree.titlebar = titlebar_now(rt)
	c.ui.tree.keyboard = rt.keyboard
	tree_desktop_theme(&c.ui.tree, rt.theme, rt.theme_raw)
	c.ui.tree.adjust_theme = rt.adjust_theme
	tree_start_theme(&c.ui.tree, rt.app.theme) // the app's own, pinned, where it named one
	c.ui.tree.locale = rt.locale
	c.ui.surface = {tag = desc.tag, kind = pdesc.kind, glass = pdesc.backdrop == .Blur} // as created: glass_sync takes the blur back if the theme's glass is Solid
	if pdesc.kind == .Layer do c.ui.surface.edge = layer_edge(desc.layer) // an applet learns its edge from its first configure
	c.fc = Frame_Ctx{
		tree = &c.ui.tree, r = rt.r, backend = rt.backend, surface = surf, scale = 1, t0 = rt.t0,
		transparent = pdesc.transparent,
		debug = os.get_env("BALDR_DEBUG_EVENTS", context.temp_allocator) != "",
		timing = os.get_env("BALDR_DEBUG_FRAMES", context.temp_allocator) != "",
		clear = rt.app.clear,
		sink = {user = rt.r, create = atlas_create_cb, upload = atlas_upload_cb, picture = picture_create_cb, destroy = page_destroy_cb},
		cmds = make([dynamic]gpu.Cmd),
		damage = make([dynamic][4]f32),
		input = desc.input,
		backdrop_region = desc.backdrop_region,
		applet = pdesc.kind == .Applet,
		host_edge = c.ui.surface.edge,
		fit = {pdesc.kind == .Layer && desc.size.x == FIT, pdesc.kind == .Layer && desc.size.y == FIT},
		declared = desc.size,
		layer = &c.desc.layer,
	}
	if c.fc.fit[0] || c.fc.fit[1] do c.fc.fit_cap = fit_cap(c.desc.layer, c.desc.layer.output, known_outputs[:])
	glass_sync(rt.backend, c, rt.app.clear)
	c.hide_st.left_ms = clock_ms(&c.fc) // a surface that hides shows at first, then goes
	if b := rt.backend; b.drag_start != nil && b.drag_accept != nil && b.drag_receive != nil && b.drag_finish != nil {
		c.ui.dnd = {user = b, surface = u32(surf), start = dnd_start_cb, accept = dnd_accept_cb, receive = dnd_receive_cb, finish = dnd_finish_cb}
	}
	{ // a window that draws its own frame asks the desktop through here (widget_chrome.odin)
		c.ui.tree.window = {
			user = &c.fc, surface = u32(surf),
			act = proc(user: rawptr, surface: u32, act: platform.Window_Act, edges: platform.Window_Edges, at: [2]f32) -> bool {
				b := (^Frame_Ctx)(user).backend
				if b == nil || b.surface_act == nil do return false
				return b.surface_act(b, platform.Surface(surface), act, edges, at)
			},
			close = proc(user: rawptr, surface: u32) {
				b := (^Frame_Ctx)(user).backend
				if b == nil do return
				if b.surface_post_close != nil do b.surface_post_close(b, platform.Surface(surface)) // …the same path the desktop's own close takes
			},
			roll = proc(user: rawptr, surface: u32, up: bool, height: f32) -> bool {
				return window_roll((^Frame_Ctx)(user), up, height)
			},
		}
	}
	if rt.backend.ime_set != nil {
		c.ui.tree.ime.hook = {user = rt.backend, surface = u32(surf), set = ime_set_cb}
	}
	if rt.backend.clipboard_get != nil && rt.backend.clipboard_set != nil {
		c.ui.clipboard = {user = rt.backend, get = clipboard_get_cb, set = clipboard_set_cb}
		if rt.backend.primary_get != nil && rt.backend.primary_set != nil do c.ui.clipboard.primary_get, c.ui.clipboard.primary_set = primary_get_cb, primary_set_cb
		if rt.backend.clipboard_types != nil && rt.backend.clipboard_get_data != nil && rt.backend.clipboard_set_data != nil {
			c.ui.clipboard.types, c.ui.clipboard.get_data, c.ui.clipboard.set_data = clipboard_types_cb, clipboard_get_data_cb, clipboard_set_data_cb
		}
	}
	ask_view(c)
	append(&rt.ctxs, c)
	append(&rt.frames, &c.fc)
	return true
}

@(private)
surface_close :: proc(rt: ^Runtime($State, $Msg), i: int) {
	c := rt.ctxs[i]
	popups_close_all(rt.backend, rt.r, c)
	delete(c.popups)
	if c.fc.target != 0 {
		gpu.target_remove(rt.r, c.fc.target)
	} else {
		gpu.drawable_release(rt.r, c.vk_surf) // never became a target: ours to let go of
	}
	rt.backend.surface_destroy(rt.backend, c.surf)
	delete(c.fc.cmds)
	delete(c.fc.damage)
	delete(c.fc.input_sent)
	delete(c.fc.blur_sent)
	ui_destroy(&c.ui)
	delete(c.desc.title)
	delete(c.desc.layer.output)
	delete(c.desc.applet.token)
	delete(c.desc.output)
	delete(c.output)
	for f, j in rt.frames do if f == &c.fc { ordered_remove(&rt.frames, j); break }
	ordered_remove(&rt.ctxs, i)
	free(c)
}

// outputs_event takes a change of screens (Ev_Outputs): the new list, a FIT
// bar's cap, the app's outputs_changed lines, and the surfaces waiting for a
// screen that came or on one that went (a bar, a lock surface). False when
// the run is done.
@(private)
outputs_event :: proc(rt: ^Runtime($State, $Msg)) -> (carry_on: bool) {
	outputs_take(rt.backend)
	for c in rt.ctxs do if c.fc.fit[0] || c.fc.fit[1] { // a FIT bar's screen changed size: capped again
		c.fc.fit_cap = fit_cap(c.desc.layer, c.output if c.output != "" else c.desc.layer.output, known_outputs[:])
		c.fc.fit_size = {}
		c.needs_frame = true
	}
	sched_outputs_changed(&rt.sched, &rt.msgs)
	carry_on = sync_surfaces(rt) || run_holds(rt)
	activations_run(rt) // a window opened again for a screen that came
	return
}

// sync_surfaces asks the app which surfaces should exist and opens / closes
// the difference. Returns false when none is left: the app is done.
@(private)
sync_surfaces :: proc(rt: ^Runtime($State, $Msg)) -> bool {
	clear(&rt.wanted)
	if rt.app.surfaces != nil {
		rt.app.surfaces(&rt.state, &rt.wanted)
	} else {
		append(&rt.wanted, Surface_Desc(Msg){
			title = rt.app.title, size = rt.app.size if rt.app.size != {} else {800, 600},
			min_size = rt.app.min_size, max_size = rt.app.max_size,
			maximized = rt.app.maximized, on_close = rt.app.on_close, on_state = rt.app.on_state,
		})
	}
	for i := 0; i < len(rt.wanted); i += 1 { // a tag declared twice is an app bug: keep the first, say so
		for j := i + 1; j < len(rt.wanted); j += 1 {
			if rt.wanted[j].tag == rt.wanted[i].tag {
				fmt.eprintfln("baldr: surfaces: tag %d declared twice; the second is ignored", rt.wanted[i].tag)
				ordered_remove(&rt.wanted, j)
				j -= 1
			}
		}
	}
	for i := len(rt.wanted) - 1; i >= 0; i -= 1 { // an applet the compositor closed stays closed while declared with the same token
		w := rt.wanted[i]
		if spent, closed := rt.applets_closed[w.tag]; closed && w.kind == .Applet && spent == applet_token(w) do ordered_remove(&rt.wanted, i)
	}
	lock_moved(rt)             // a lock surface for another screen: closed before it opens there
	waiting := lock_hold(rt)   // what the session lock keeps from opening waits for it (lock.odin)
	// a bar declared for a screen that is not there waits for it: not opened, closed if its screen went
	if rt.backend != nil && rt.backend.outputs != nil {
		for i := len(rt.wanted) - 1; i >= 0; i -= 1 {
			if surface_output_present(rt.wanted[i], known_outputs[:]) do continue
			ordered_remove(&rt.wanted, i)
			waiting = true
		}
	}
	open := make([]u64, len(rt.ctxs), context.temp_allocator)
	for c, i in rt.ctxs do open[i] = c.desc.tag
	want := make([]u64, len(rt.wanted), context.temp_allocator)
	for d, i in rt.wanted do want[i] = d.tag
	to_open, to_close := surface_diff(open, want)
	#reverse for i in to_close do surface_close(rt, i)
	for i in to_open do surface_open(rt, rt.wanted[i])
	for c in rt.ctxs {
		for w in rt.wanted {
			if w.tag != c.desc.tag do continue
			surface_update(rt, c, w)
			break
		}
	}
	return len(rt.ctxs) > 0 || waiting
}

// surface_update brings an open surface in line with its declaration: its
// title, backdrop and close message; a layer surface's size and placement
// (anchors, exclusive zone and edge, margins, keyboard, level) in place, and
// its screen by a new platform surface under the same tree. What a surface
// is created as (kind, transparency, decoration, resizability) is reported
// once, since only a new tag can change it; a window's `size` is where it
// opens.
@(private)
surface_update :: proc(rt: ^Runtime($State, $Msg), c: ^Surface_Ctx(Msg), want: Surface_Desc(Msg)) {
	b := rt.backend
	c.desc.on_close = want.on_close
	c.desc.on_state = want.on_state
	ch := surface_changes(c.desc, want)
	if ch == {} do return
	if .Title in ch {
		delete(c.desc.title)
		c.desc.title = strings.clone(want.title)
		if b.surface_set_title != nil do b.surface_set_title(b, c.surf, c.desc.title)
	}
	if .Backdrop in ch {
		c.desc.backdrop = want.backdrop
		c.desc.backdrop_region, c.fc.backdrop_region = want.backdrop_region, want.backdrop_region
		c.fc.blur_sent_ok = false
		glass_sync(b, c, rt.app.clear)
		ask_view(c)
	}
	if .Input in ch {
		c.desc.input = want.input
		c.fc.input = want.input
		c.needs_frame = true // applied after the next layout
	}
	if .Shape in ch {
		c.desc.radius, c.desc.square = want.radius, want.square
		glass_paint(c, rt.app.clear)
		c.fc.input_sent_ok = false // the region follows the shape
		c.needs_frame = true
	}
	if .Fullscreen in ch {
		c.desc.fullscreen = want.fullscreen
		// the ask only: what the desktop does with it comes back in a
		// configure, and ui.surface.fullscreen is what the view reads
		if c.kind == .Window && (b.surface_set_fullscreen == nil || !b.surface_set_fullscreen(b, c.surf, want.fullscreen)) {
			fmt.eprintfln("baldr: surface %d: this backend cannot ask for the whole screen", c.desc.tag)
		}
	}
	if .Hide in ch {
		hiding := c.desc.hide.mode != .Never
		c.desc.hide = want.hide
		if c.kind == .Layer && hiding != (want.hide.mode != .Never) && b.surface_set_layer != nil {
			b.surface_set_layer(b, c.surf, layer_placed(c.desc), layer_size(&c.fc)) // its exclusive zone: none while it hides
		}
		glass_paint(c, rt.app.clear) // hiding draws its tint as its shape, to slide with it
		c.needs_frame = true
	}
	if .Applet in ch && c.kind == .Applet {
		c.desc.applet.keyboard = want.applet.keyboard
		if b.surface_set_applet == nil || !b.surface_set_applet(b, c.surf, c.desc.applet) {
			fmt.eprintfln("baldr: surface %d: this backend cannot change an applet's keyboard setting live", c.desc.tag)
		}
	}
	if c.desc.kind == .Window && .Size in ch {
		// Taken as seen either way: a declaration that cannot be applied now
		// is dropped rather than retried every pass (window_resize says why).
		c.desc.size = want.size
		window_resize(c, b, want.size, known_outputs[:])
	}
	if c.desc.kind == .Layer && .Output in ch { // another screen: a new layer surface under the same tree
		if !surface_reopen(rt, c, want) do ch += {.Kind} // reported below
	} else if c.desc.kind == .Layer && ch & {.Layer, .Size} != {} {
		output := c.desc.layer.output // the owned copy stays
		c.desc.layer = want.layer
		c.desc.layer.output = output
		c.desc.size = want.size
		fit := [2]bool{want.size.x == FIT, want.size.y == FIT}
		if fit != c.fc.fit do c.fc.fit_len = {} // measured and asked for afresh
		c.fc.fit, c.fc.declared, c.fc.fit_size = fit, want.size, {}
		c.fc.fit_cap = fit_cap(c.desc.layer, c.output if c.output != "" else c.desc.layer.output, known_outputs[:])
		c.needs_frame = true
		if b.surface_set_layer == nil || !b.surface_set_layer(b, c.surf, layer_placed(c.desc), layer_size(&c.fc)) {
			fmt.eprintfln("baldr: surface %d: this backend cannot change a layer surface's placement live", c.desc.tag)
		}
		if c.kind == .Layer {
			edge := layer_edge(c.desc.layer)
			if edge != c.ui.surface.edge {
				c.ui.surface.edge = edge // a bar moved to another edge: its view, popups and applet slots follow
				c.fc.host_edge = edge
				ask_view(c)
			}
		}
	}
	if fixed := ch - SURFACE_LIVE_CHANGES - c.warned; fixed != {} {
		fmt.eprintfln("baldr: surface %d: %v cannot change while it is open; give it a new tag to reopen it", c.desc.tag, fixed)
		c.warned += fixed
	}
}

// surface_reopen gives an open surface a new platform surface for a
// declaration no request can apply (a layer surface moving to another
// screen), keeping its tree: focus, open popovers, scroll and hover stay.
@(private)
surface_reopen :: proc(rt: ^Runtime($State, $Msg), c: ^Surface_Ctx(Msg), want: Surface_Desc(Msg)) -> bool {
	app_id := rt.app.app_id if rt.app.app_id != "" else "baldr.app"
	reopen := surface_resolve(want, rt.backend.caps, app_id)
	reopen.icon = rt.icon
	reopen.parent = surface_of_tag(rt, want.parent) if want.kind == .Window else 0
	surf, ok := rt.backend.surface_create(rt.backend, reopen)
	if !ok {
		fmt.eprintfln("baldr: surface %d: could not reopen it on %q", want.tag, want.layer.output)
		return false
	}
	vk_surf: gpu.Drawable
	if rt.r != nil {
		vs, vok := rt.backend.drawable_create(rt.backend, surf, gpu.instance(rt.r))
		if !vok {
			rt.backend.surface_destroy(rt.backend, surf)
			return false
		}
		vk_surf = gpu.Drawable(vs)
	}
	popups_close_all(rt.backend, rt.r, c) // they open again from the new surface
	if c.fc.target != 0 {
		gpu.target_remove(rt.r, c.fc.target) // the swapchain goes before the surface it presents to
		c.fc.target = 0
	} else {
		gpu.drawable_release(rt.r, c.vk_surf) // never became a target: ours to let go of
	}
	rt.backend.surface_destroy(rt.backend, c.surf)
	slots_reset(&c.ui.tree) // its applet slots went with it: made again on the new surface
	c.surf, c.vk_surf, c.fc.surface = surf, vk_surf, surf
	c.fc.frame_requested = false
	c.fc.input_sent_ok = false // the new surface takes the pointer everywhere until told
	if c.ui.dnd.start != nil do c.ui.dnd.surface = u32(surf)
	delete(c.desc.layer.output)
	c.desc.layer = want.layer
	c.desc.layer.output = strings.clone(want.layer.output)
	c.desc.size = want.size
	ask_view(c)
	return true
}

// Output is one screen: connector name, description, logical position and
// size, scale and transform.
Output :: platform.Output
// Output_Transform is how a screen is rotated or flipped, as the compositor
// reports it on an `Output`.
Output_Transform :: platform.Output_Transform

// outputs is the screens as the compositor last reported them, for
// `surfaces` to declare a bar on each. Valid until they change (an
// `outputs_changed` subscription says when); empty where the backend does
// not report screens.
//
// The order is the order the screens arrived, which is no order at all to
// a person: use `Output.primary` for "the first screen" — where a desktop
// puts an icon nobody placed, where a shell puts the thing there should
// only be one of, and where something whose own screen was unplugged goes.
outputs :: proc() -> []Output {
	return known_outputs[:]
}

// output_rect is a screen's rectangle in the desktop's own coordinates, so
// that `Output.pos` and a window's position can be compared without the
// caller knowing which plane this platform uses.
//
// It exists because `Output.pos` is logical on Wayland and X11 but **device
// pixels on Windows**, which has no logical desktop plane — so a screen's
// extent is `size` on the first two and `mode_px` on the third, and an app
// working out "is this point on a screen" would otherwise need that branch
// itself.
output_rect :: proc(o: Output) -> (pos: [2]i32, size: [2]i32) {
	when ODIN_OS == .Windows {
		return o.pos, o.mode_px
	} else {
		return o.pos, o.size
	}
}

// POSITION_GRAB is how far into a window its title bar can be taken hold of,
// used by position_reachable. Not a measurement of any desktop's title bar:
// it is "far enough in to be past a corner and inside the bar", and the
// point of it is only that the bare top-left corner is the wrong thing to
// test — a window a few pixels off the left edge is perfectly usable.
@(private) POSITION_GRAB :: [2]i32{48, 16}

// position_reachable says whether a window opened at `pos` could be got hold
// of: whether a point a little into its title bar lands on a screen that
// exists now.
//
// A saved position outlives the screen it was saved on, and asking for a
// position tells the window manager it was chosen on purpose (X11's
// `US_POSITION`), so the manager honours it onto a screen that is gone: the
// window opens out of sight with its title bar out of reach. A position that
// fails this is dropped and the desktop places the window.
//
// With no screens known at all (a backend that does not report them) it
// answers true: an unknown desktop is not evidence against the position the
// app saved.
@(private)
position_reachable :: proc(pos: [2]i32, outs: []Output) -> bool {
	if len(outs) == 0 do return true
	grab := pos + POSITION_GRAB
	for o in outs {
		op, os := output_rect(o)
		if grab.x >= op.x && grab.x < op.x + os.x && grab.y >= op.y && grab.y < op.y + os.y do return true
	}
	return false
}

@(private, thread_local)
known_outputs: [dynamic]Output // strings owned

// outputs_take copies the backend's screens into known_outputs.
@(private)
outputs_take :: proc(b: ^platform.Backend) {
	for o in known_outputs {
		delete(o.name)
		delete(o.description)
	}
	clear(&known_outputs)
	if b == nil || b.outputs == nil do return
	for o in b.outputs(b) {
		c := o
		c.name = strings.clone(o.name)
		c.description = strings.clone(o.description)
		append(&known_outputs, c)
	}
	outputs_mark_primary()
}

// outputs_mark_primary picks the screen apps should treat as first.
//
// Wayland has no primary-screen protocol: no compositor tells us, and the
// order screens arrive in is the order they were plugged in. So the rule is
// the one every desktop falls back to — the top-left-most screen in the
// layout, which is where a person puts the screen they work on, with the
// connector name breaking a tie so the answer never changes between runs.
// BALDR_PRIMARY_OUTPUT names a connector to use instead, for a desktop
// whose compositor does know (it can pass its own answer down) and for
// testing on one screen.
@(private)
outputs_mark_primary :: proc() {
	want := os.get_env("BALDR_PRIMARY_OUTPUT", context.temp_allocator)
	best := -1
	for &o in known_outputs do o.primary = false
	for o, i in known_outputs {
		if want != "" && o.name == want {
			best = i
			break
		}
		if best < 0 {
			best = i
			continue
		}
		b := known_outputs[best]
		ahead := o.pos.x < b.pos.x || (o.pos.x == b.pos.x && (o.pos.y < b.pos.y || (o.pos.y == b.pos.y && o.name < b.name)))
		if ahead do best = i
	}
	if best >= 0 do known_outputs[best].primary = true
}

// close_event handles a surface closing: the user's close goes to the
// app's on_close (or ends the run without one); a surface the compositor
// took away is closed quietly, and opens again once its screen is back.
// Returns true when the run should end.
@(private)
close_event :: proc(rt: ^Runtime($State, $Msg), e: platform.Ev_Close, debug: bool) -> (quit: bool) {
	for c, i in rt.ctxs {
		if c.surf != e.surface do continue
		if debug do fmt.eprintfln("baldr/events: surface %d (tag %d) closed by the %v", e.surface, c.desc.tag, e.reason)
		if e.reason == .Compositor {
			if c.kind == .Applet { // its slot went, or its token wasn't valid: that token can't bring it back
				if old, had := rt.applets_closed[c.desc.tag]; had do delete(old)
				rt.applets_closed[c.desc.tag] = strings.clone(applet_token(c.desc))
				if m, has := c.desc.on_close.?; has {
					append(&rt.msgs, m) // the app decides
				} else {
					quit = true // an applet with nowhere to be ends, unless the app said otherwise
				}
			}
			surface_close(rt, i)
			return
		}
		if m, has := c.desc.on_close.?; has {
			append(&c.ui.msgs, m) // the app decides (usually: stop declaring it)
			return false
		}
		return true
	}
	return false
}

// message_surface is the tag of the surface whose widget, shortcut or
// dismiss produced the message `update` is handling, so one process with
// several windows applies it to the right one. ok is false for messages the
// app routes itself (job posts, delays, timers, watches, file dialogs,
// pastes) and outside update.
message_surface :: proc() -> (tag: u64, ok: bool) {
	return msg_from.tag, msg_from.ok
}

@(private, thread_local)
msg_from: struct { tag: u64, ok: bool }

// dispatch_msgs hands every queued message to update: the runtime's own
// first, then each surface's with message_surface naming it. `running` is
// false when one of them asked to quit.
@(private)
dispatch_msgs :: proc(rt: ^Runtime($State, $Msg)) -> (got, running: bool) {
	running = true
	if len(rt.msgs) > 0 { // dialog outcomes and other runtime-made messages
		got = true
		for i := 0; i < len(rt.msgs); i += 1 { // a handler may queue more
			if !run_cmd(rt, rt.app.update(&rt.state, rt.msgs[i])) do running = false
		}
		clear(&rt.msgs)
	}
	for c in rt.ctxs {
		if len(c.ui.msgs) == 0 do continue
		got = true
		msg_from = {tag = c.desc.tag, ok = true}
		for m in c.ui.msgs {
			if !run_cmd(rt, rt.app.update(&rt.state, m)) do running = false
		}
		msg_from = {}
		clear(&c.ui.msgs)
	}
	return
}

// apply_theme brings every surface up to date with the desktop: rt.theme
// (unless the app set its own), the accessibility preferences folded into
// either, and glass, which follows those and the compositor's blur and
// changes the clear colour and the blur request.
@(private)
apply_theme :: proc(rt: ^Runtime($State, $Msg)) {
	for c in rt.ctxs {
		tr := &c.ui.tree
		tree_desktop_a11y(tr, prefs_now(rt)) // set_a11y_prefs stays through the desktop's changes, as a set theme does — and follow_system_a11y goes back to these
		if !tr.titlebar_app do tr.titlebar = titlebar_now(rt) // …and set_titlebar_prefs
		tree_desktop_theme(tr, rt.theme, rt.theme_raw) // what follow_system_theme goes back to, and what its adjust re-runs over
		tr.adjust_theme = rt.adjust_theme
		tree_theme(tr, tr.theme_asked if tr.theme_app else rt.theme)
		glass_sync(rt.backend, c, rt.app.clear)
		ask_view(c)
	}
}

// glass_sync brings a surface's glass up to date: whether blurred desktop
// shows through (the theme's glass level with the desktop's preferences
// folded in, the app's request, the compositor), the blur request, the
// theme adapted to what is behind (glass.odin), and the clear colour and
// top-edge highlight. Returns whether the theme changed.
@(private)
glass_sync :: proc(b: ^platform.Backend, c: ^Surface_Ctx($Msg), app_clear: Color) -> (changed: bool) {
	tr := &c.ui.tree
	if c.kind == .Window do frame_dark_sync(b, c.surf, &tr.theme, &c.told_dark) // runs wherever the theme may have changed, as glass does
	if c.kind == .Applet { // on its bar's glass: no blur of its own, text that follows what shows through, glass popups
		on := tr.theme_base.glass != .Solid
		blur := on && .Backdrop_Blur in b.caps && .Transparent in b.caps
		c.ui.surface.glass = blur
		changed = tree_glass(tr, on, blur, .Applet, .Backdrop_Luminance in b.caps)
		glass_paint(c, app_clear)
		return
	}
	glass := surface_glass(c.desc, b.caps, tr.theme_base.glass)
	watch := surface_watches_backdrop(c.desc, b.caps)
	if glass != c.ui.surface.glass || watch != tr.glass.watch {
		c.ui.surface.glass = glass
		// What the compositor is asked for behind this surface. Glass going
		// off is not "stop measuring": a surface that asked to watch its
		// backdrop keeps watching, so a theme turning Solid cannot take the
		// numbers from a view that reads them. And `backdrop` is live, so a
		// surface that asks to be measured after it opened — glass or not —
		// is asked for here rather than only at creation.
		if b.surface_set_backdrop != nil {
			b.surface_set_backdrop(b, c.surf, .Blur if glass else .Measure if watch else .None)
		}
		c.fc.blur_sent_ok = false // the whole surface again: a marked region is sent again
	}
	// Only the marked nodes are over the wallpaper when the surface says so,
	// and the theme is adapted for them rather than for the whole window.
	// Set before tree_glass, which re-themes.
	if marked := c.desc.backdrop_region == .Marked; marked != tr.backdrop_marked {
		tr.backdrop_marked = marked
		tree_theme(tr, tr.theme_asked)
	}
	changed = tree_glass(tr, glass, surface_popups_glass(c.desc, b.caps, tr.theme_base.glass),
		.Panel if c.desc.kind == .Layer else .Window, .Backdrop_Luminance in b.caps, watch)
	glass_paint(c, app_clear)
	return
}

// glass_paint: the clear colour and the highlight follow the adapted theme
// (an applet opened as a window is cleared as a window).
@(private)
glass_paint :: proc(c: ^Surface_Ctx($Msg), app_clear: Color) {
	d := c.desc
	fc := &c.fc
	was_clear, was_highlight, was_shape, was_radius, was_square := fc.clear, fc.highlight, fc.shape, fc.shape_radius, fc.shape_square
	if d.kind == .Applet do d.kind, d.transparent = c.kind, fc.transparent
	if app_clear == {} do fc.clear = surface_clear(&c.ui.tree.theme, d, c.ui.surface.glass)
	fc.highlight = surface_highlight(&c.ui.tree.theme, d, c.ui.surface.glass)
	fc.shape = surface_shape(&c.ui.tree.theme, d, c.ui.surface.glass) if app_clear == {} else {}
	fc.shape_radius, fc.shape_square = 0, {}
	if fc.shape != {} do fc.shape_radius, fc.shape_square = d.radius, d.square
	if fc.clear != was_clear || fc.highlight != was_highlight || fc.shape != was_shape || fc.shape_radius != was_radius || fc.shape_square != was_square {
		fc.present_whole = true // drawn outside its tree: no damage in the tree would show it
	}
}

// run opens the app's surfaces and runs it until the last one closes (or
// update returns quit). Returns the error that stopped it; .None on a
// normal close.
//
// Act on what it returns: `.Disconnected` means the desktop went away or
// dropped the connection — the app did not ask to stop and has no window
// left to say so in — and an app that ignores it exits 0, which looks
// exactly like a clean close. The reason is already on stderr, so the app
// only carries it through:
//
//	if baldr.run_failed(baldr.run(app)) do os.exit(1)
//
// `run_failed` rather than `err != .None`, because a single-instance app's
// second launch ends with `.Already_Running`, which is it doing its job.
run :: proc(app: App($State, $Msg)) -> Error {
	// An app with no `surfaces` proc gets the default window, and a window
	// with no `view` would be a silent call through a nil pointer in the
	// build loop, so it is refused here with the reason.
	if app.view == nil && app.surfaces == nil {
		fmt.eprintln("baldr: this app has no `view` proc, and with no `surfaces` proc it is about to open the default window. To run with no window at all — a tray-resident app — give a `surfaces` that appends nothing, and a `keep_running` to hold the run.")
		return .Platform
	}
	// BALDR_DEBUG_MEMORY: before anything allocates, and its report after
	// everything else has been given back (the first defer runs last).
	mw := memory_watch_start()
	context.allocator = memory_watch_allocator(mw)
	defer memory_watch_stop(mw)
	// Before the backend, the GPU and the window: a second launch that
	// opened a connection and made a device first would flicker.
	inst: Instance
	if app.single_instance {
		owner: bool
		inst, owner = instance_claim(app.app_id if app.app_id != "" else app.title, os.args)
		if !owner do return .Already_Running
	}
	defer instance_stop(&inst)
	when ODIN_OS == .Linux do malloc_keep_large_blocks_mapped() // see glibc_linux.odin
	backend := default_backend()
	if backend == nil {
		fmt.eprintln("baldr: no platform backend for this OS yet")
		return .Platform
	}
	if ok, why := backend.init(backend); !ok {
		fmt.eprintln("baldr: platform init failed:", why)
		return .Platform
	}
	defer backend.shutdown(backend)

	r: gpu.Renderer
	if ok, why := gpu.init(&r, backend.vk_instance_extensions(backend), "baldr"); !ok {
		fmt.eprintln("baldr: gpu init failed:", why)
		return .Gpu
	}
	defer gpu.destroy(&r)

	te: Text_Engine
	if !text_engine_init(&te) {
		fmt.eprintln("baldr: fonts failed to load")
		return .Text
	}
	defer text_engine_destroy(&te)

	rt := Runtime(State, Msg){app = app, backend = backend, r = &r, te = &te, t0 = time.tick_now()}
	// The runtime owns the App's strings: an App's title is often temp
	// memory, and it is re-applied on every surface sync (see
	// app_own_strings).
	rt.app.title = strings.clone(app.title)
	rt.app.app_id = strings.clone(app.app_id)
	rt.icon = window_icon_of(app.icon)
	defer {
		delete(rt.app.title)
		delete(rt.app.app_id)
		delete(rt.icon.argb)
	}
	rt.ctxs = make([dynamic]^Surface_Ctx(Msg))
	rt.frames = make([dynamic]^Frame_Ctx)
	rt.wanted = make([dynamic]Surface_Desc(Msg))
	rt.pending_files = make(map[u64]Handler(Msg, Files))
	rt.pending_paths = make(map[u64]Path_Ask(Msg))
	rt.spent_asks = make([dynamic]string)
	rt.notify_watches = make([dynamic]Notify_Watch(Msg))
	rt.msgs = make([dynamic]Msg)
	rt.jobs = make([dynamic]^Job(Msg))
	rt.mailbox = {wake = wake_backend, wake_user = backend}
	theme_icons_start(&te, wake_backend, backend)
	fonts_start(&te, wake_backend, backend) // the font list from its cache file, built on a worker when it must be
	rt.wanted_subs = make([dynamic]Sub(Msg))
	rt.rehearse_ms, rt.rehearse_every = gpu_rehearsal_read(clock_now(&rt)) // BALDR_SIMULATE_GPU_RESET
	defer {
		io_stop(&rt.io)
		canvases_shutdown(&rt) // its waiting threads post into the mailbox: done with before it goes
		jobs_shutdown(&rt.mailbox, &rt.jobs) // before the backend goes: a late post must not wake a dead loop
		sched_destroy(&rt.sched, watch_stop_cb, backend)
		delete(rt.wanted_subs)
		delete(rt.toplevel_sent)
		for len(rt.ctxs) > 0 do surface_close(&rt, len(rt.ctxs) - 1)
		delete(rt.ctxs)
		delete(rt.frames)
		delete(rt.wanted)
		delete(rt.pending_files)
		for _, token in rt.applets_closed do delete(token)
		delete(rt.applets_closed)
		for _, ask in rt.pending_urls do delete(ask.url)
		delete(rt.pending_urls)
		for _, ask in rt.pending_paths do delete(ask.path)
		delete(rt.pending_paths)
		for str in rt.spent_asks do delete(str)
		delete(rt.spent_asks)
		delete(rt.notify_watches)
		delete(rt.msgs)
		delete(rt.jobs)
		delete(rt.mailbox.mail)
		outputs_take(nil)
		delete(known_outputs)
		delete(known_surfaces)
		known_outputs = nil
		desktop_lists_free()
	}
	sys := backend.system_theme(backend)
	rt.accent = app.accent
	rt.adjust_theme = app.adjust_theme
	// The desktop's theme, always, whether or not the app named one of its
	// own: it is what `follow_system_theme` goes back to, and an app that
	// starts on its own theme and offers System needs it to be there. The
	// app's own is pinned on each surface's tree instead (tree_start_theme).
	rt.theme, rt.theme_raw = pick_theme({}, app.accent, sys, app.adjust_theme)
	rt.prefs = a11y_prefs_of(sys)
	rt.prefs_app = app.a11y // an app that owns these settings says so, as it does with its theme
	rt.titlebar = titlebar_of(sys)
	theme_icons_use(&te, sys.icon_theme)
	rt.locale = backend.locale(backend) if backend.locale != nil else LOCALE_EN
	if rt.te != nil { // which Han shapes a fallback face gives (text_fallback.odin)
		delete(rt.te.lang, rt.te.allocator)
		rt.te.lang = strings.clone(rt.locale.tag, rt.te.allocator)
	}
	outputs_take(backend)
	toplevels_take(backend)
	workspaces_take(backend)
	backend.redraw_callback = modal_redraw
	backend.redraw_user = &rt.frames

	if app.init != nil do rt.state = app.init()
	defer {
		for a in rt.activations do delete(a.token)
		delete(rt.activations)
		delete(rt.keyboard.layout)
		for p in rt.posters do poster_shut((^Poster_Box(Msg))(p)) // a foreign thread posting after the run posts nowhere
		delete(rt.posters)
		tray_shutdown(&rt)
	}
	// Before the first `run_holds`: a tray-resident app declares no surface
	// and is held open only by its tray item, so the tray must exist by the
	// time anything asks.
	if app.single_instance do instance_listen(&inst, &rt.mailbox, app.on_relaunch)
	tray_sync(&rt)
	if !sync_surfaces(&rt) {
		if len(rt.wanted) > 0 {
			fmt.eprintln("baldr: no surface could be opened")
			return .Platform
		}
		if !run_holds(&rt) do return .None // nothing declared, nothing to wait for
	}
	activations_run(&rt)
	sync_subs(&rt)
	a11y_begin(&rt, app.title) // the accessibility bus, when the desktop has one
	defer a11y_stop()
	if app.start != nil && !run_cmd(&rt, app.start(&rt.state)) do return .None
	if lock_live(&rt) && !sync_surfaces(&rt) && !run_holds(&rt) do return .None // a locker's first command: its lock surfaces open now

	view_all := false
	running := true
	lost := false // the desktop dropped us, rather than the app being asked to stop
	undrawable := false // …or a window turned out to be one nothing can draw on
	said_no_view := false // a declared surface with no `view` is reported once, not drawn
	debug_events := os.get_env("BALDR_DEBUG_EVENTS", context.temp_allocator) != ""
	for running {
		timeout: i32 = -1
		for c in rt.ctxs do if c.ui.wake_at_ms > 0 {
			t := i32(max(c.ui.wake_at_ms - clock_ms(&c.fc), 0))
			timeout = t if timeout < 0 else min(timeout, t)
		}
		for c in rt.ctxs do for p in c.popups do if p.held && p.placing { // a held popup frame waits POPUP_PLACE_WAIT_MS at most
			t := i32(max(p.held_ms + POPUP_PLACE_WAIT_MS - clock_ms(&p.fc), 0))
			timeout = t if timeout < 0 else min(timeout, t)
		}
		if t := sched_timeout(&rt.sched, clock_now(&rt)); t >= 0 do timeout = t if timeout < 0 else min(timeout, t)
		if len(rt.msgs) > 0 do timeout = 0
		for c in rt.ctxs do if len(c.ui.msgs) > 0 do timeout = 0 // the last build queued messages (a list's visible range): handle them now
		// A lost device is asked for again on a clock of its own: the loop
		// must not sleep through the wait, and must not spin either.
		if gpu.lost(&r) do timeout = i32(GPU_RECOVER_WAIT_MS) if timeout < 0 else min(timeout, i32(GPU_RECOVER_WAIT_MS))
		if rt.rehearse_ms > 0 { // a rehearsed reset is due: do not sleep past it
			t := i32(max(rt.rehearse_ms - clock_now(&rt), 0))
			timeout = t if timeout < 0 else min(timeout, t)
		}
		events := backend.pump(backend, timeout)
		mailbox_drain(&rt.mailbox, &rt.jobs, &rt.msgs) // what the workers posted while we slept
		gpu_reset_rehearsal(&rt, clock_now(&rt)) // BALDR_SIMULATE_GPU_RESET, for an app checking its own App.gpu_reset
		if !gpu_recover_step(&rt, clock_now(&rt)) do return .Gpu // the card never came back: exit for a supervisor to restart us
		if fonts_take(rt.te) { // the font list arrived: families found, fallbacks that draw what was a box
			for c in rt.ctxs {
				tree_fonts_changed(&c.ui.tree)
				ask_view(c, {procedure = "fonts"})
				c.needs_frame = true
			}
		}
		// A theme that names the family its text is set in: every surface
		// follows the one last installed, so the surface that did not set it
		// hears of it here.
		for c in rt.ctxs do if tree_fonts_sync(&c.ui.tree) {
			ask_view(c, {procedure = "fonts"})
			c.needs_frame = true
		}
		if theme_icons_take(rt.te) { // icons the loader finished, or a theme whose files changed
			for c in rt.ctxs {
				theme_icons_dirty(&c.ui.tree)
				c.needs_frame = true
			}
		}
		now := time.duration_milliseconds(time.tick_since(rt.t0))
		sched_fire(&rt.sched, now, &rt.msgs) // delays and timers that came due
		memory_watch_tick(mw, now)            // BALDR_DEBUG_MEMORY's report, when one is due
		for c in rt.ctxs {
			timers_before := len(c.ui.timers)
			if ui_tick(&c.ui, now) do c.needs_frame = true
			if len(c.ui.timers) < timers_before {
				// a timer fired and dirtied its node
				text_input_wake(&c.ui.tree) // text_input hook: caret blink phase
				c.needs_frame = true
			}
		}
		for ev in events {
			switch e in ev {
			case platform.Ev_Configure:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				fc, vk_surf := &c.fc, c.vk_surf
				_, pop := popup_ctx_for(&rt, e.surface)
				if pop != nil {
					fc, vk_surf = &pop.fc, pop.vk_surf
				} else {
					if c.fc.rolled != {} && (e.maximized || e.fullscreen || e.tiled) do c.fc.rolled = {} // the desktop sized it: no longer rolled up
					if rolled := c.fc.rolled != {}; rolled != c.ui.surface.rolled {
						c.ui.surface.rolled, c.ui.tree.rolled = rolled, rolled
						roll_inert(&c.ui.tree, rolled)
						ask_view(c)
					}
					vp := e.size if c.fc.rolled == {} else [2]f32{e.size.x, c.fc.rolled.y} // rolled up: laid out at the size it had
					if c.ui.read_viewport && c.ui.tree.viewport != vp do ask_view(c) // it sized something by the window: build it for the new size
					set_viewport(&c.ui.tree, vp) // the view that follows sees the real size and size class
					if e.scale > 0 && c.ui.surface.scale != e.scale { // another screen's scale: a view sizing by device pixels builds again
						c.ui.surface.scale = e.scale
						ask_view(c)
					}
					if c.ui.surface.fullscreen != e.fullscreen || c.ui.surface.maximized != e.maximized || c.ui.surface.tiled != e.tiled {
						// what the desktop did, which is not always what was
						// asked: a view that puts its chrome away full screen
						// builds again on the truth
						c.ui.surface.fullscreen, c.ui.surface.maximized, c.ui.surface.tiled = e.fullscreen, e.maximized, e.tiled
						ask_view(c)
					}
					if old, known := c.ui.surface.edge.?; c.kind == .Applet && (!known || old != e.edge) { // its bar is on another edge: the view lays out again
						c.ui.surface.edge = e.edge
						c.fc.edge = e.edge
						ask_view(c)
					}
				}
				fc.size, fc.size_px, fc.scale = e.size, e.size_px, e.scale
				if fc.target == 0 {
					if e.size_px.x > 0 && e.size_px.y > 0 {
						t, ok := gpu.target_add(&r, vk_surf, e.size_px, fc.transparent)
						if !ok {
							// Running out of swapchain slots is not the end of
							// the app: a drag's ghost can open popups faster
							// than they close.
							why := target_why(&r)
							if pop != nil {
								// Draw it inside instead, which is what
								// `popups_failed` means: a popover drawn in its
								// parent needs no surface of its own.
								target_warn_popup(c, why)
								c.popups_failed = true
								for q, i in c.popups do if q.surf == e.surface {
									popup_close(rt.backend, &r, c, i)
									break
								}
								continue
							}
							if target_retry(gpu.target_fault(&r)) {
								// A window whose slot may free up: leave the
								// target unmade and try again on its next
								// configure. It draws nothing until then, which
								// is visible and recoverable; quitting is
								// neither.
								target_warn_surface(c, why)
							} else {
								// A window the GPU cannot present to, which no
								// configure will fix. Say so once and stop: the
								// surface stays the toolkit's to let go of, and
								// a retry would hand the driver a surface it has
								// already given up on.
								target_fail_surface(c, why)
								undrawable, running = true, false
							}
						}
						fc.target = t
					}
				} else {
					gpu.target_resize(&r, fc.target, e.size_px)
				}
				c.needs_frame = true
			case platform.Ev_Redraw:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				if _, pop := popup_ctx_for(&rt, e.surface); pop != nil {
					pop.fc.frame_requested = false
					if popup_resync(backend, c, pop, clock_ms(&pop.fc)) {
						pop.fc.frame_requested = true // nothing commits it before the frame its configure brings
						continue
					}
					do_frame(&pop.fc)
					continue
				}
				c.fc.frame_requested = false
				// Not drawn here: the backend hands a wake-up's input and its
				// frame callback over in one batch, so painting inside this
				// loop would lay out the new scroll offset over a view built
				// for the old one. A scroll bar's thumb moves a long list by
				// hundreds of rows per sample, so the built rows would land
				// outside the clip and the view go blank. The frame is drawn
				// below, after `ui_after_events` and any rebuilt view.
				c.draw_now = true
			case platform.Ev_Popup_Configure:
				c, pop := popup_ctx_for(&rt, e.surface)
				if pop == nil do continue
				popup_configured(c, pop, e.pos)
				if debug_events do fmt.eprintfln("baldr/events: popup %d placed at %v, card %v", e.surface, e.pos, e.size)
			case platform.Ev_Popup_Done:
				c, pop := popup_ctx_for(&rt, e.surface)
				if pop == nil do continue
				popup_dismissed(c, pop)
				if debug_events do fmt.eprintfln("baldr/events: popup %d dismissed by the compositor", e.surface)
			case platform.Ev_Backdrop:
				bd := Backdrop_Range{e.min, e.avg, e.max}
				if debug_events do fmt.eprintfln("baldr/events: surface %d backdrop %.3f / %.3f / %.3f", e.surface, e.min, e.avg, e.max)
				if pc, pop := popup_ctx_for(&rt, e.surface); pop != nil {
					if popup_backdrop(&pc.ui.tree, pop.node, bd) do ask_view(pc)
				} else if c := ctx_for(&rt, e.surface); c != nil && tree_backdrop(&c.ui.tree, bd) {
					glass_paint(c, rt.app.clear)
					ask_view(c)
				}
				if debug_events do fmt.eprintfln("baldr/events: surface %d backdrop luminance %.3f / %.3f / %.3f", e.surface, e.min, e.avg, e.max)
			case platform.Ev_Backdrop_Map:
				// The cells behind a surface moved, so every node that picks
				// its own ink picks again and repaints. No view is rebuilt:
				// what changed is behind the app, not in it.
				if c := ctx_for(&rt, e.surface); c != nil {
					if tree_backdrop_map(&c.ui.tree, e.columns, e.rows, e.cell, e.origin, e.cells) {
						legible_pass(&c.ui.tree)
						c.needs_frame = true
					}
				}
				if debug_events {
					fmt.eprintfln("baldr/events: surface %d backdrop map %dx%d cells of %d px at %v",
						e.surface, e.columns, e.rows, e.cell, e.origin)
				}
			case platform.Ev_Close:
				if close_event(&rt, e, debug_events) do running = false
			case platform.Ev_Pointer_Enter:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				c.hide_st.pointer_on = e.surface
				if pointer_move(&c.ui, popup_pointer(c, e.surface, e.pos), moved = false) do c.needs_frame = true // a surface appearing under a still pointer: no rest heard yet
				if debug_events do fmt.eprintfln("baldr/events: pointer enter surface %d at %v", e.surface, e.pos)
			case platform.Ev_Pointer_Motion:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				before := c.ui.pointer.hover
				at := popup_pointer(c, e.surface, e.pos)
				c.ui.pointer.mods = map_mods(e.mods)
				if pointer_move(&c.ui, at) do c.needs_frame = true
				mouse_sample(&c.ui, .Move, .Left, e.time_ms, at) // every sample, for a canvas that hears them (pointer_samples.odin)
				if debug_events && c.ui.pointer.hover != before {
					hv := node_get(&c.ui.tree, c.ui.pointer.hover)
					fmt.eprintfln("baldr/events: hover → %v %q at %v", hv.access.role if hv != nil else Role.None, hv.access.name if hv != nil else "", e.pos)
				}
			case platform.Ev_Pointer_Leave:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				hide_pointer_left(c, e.surface, clock_ms(&c.fc))
				if drag_leave_window(&c.ui) do c.needs_frame = true // a file drag goes on outside, through the compositor
				if pointer_leave(&c.ui) do c.needs_frame = true
			case platform.Ev_Drag_Enter:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				hide_drag_over(c, e.surface) // a hidden bar shows for a drag as it does for the pointer
				has_files := false
				for m in e.mimes do if m == MIME_URI_LIST do has_files = true
				from := drag_source_ctx(&rt) if e.own else nil
				if from != nil && from != c { // another of our windows' drag: taken as that drag
					if drag_sibling_enter(&c.ui, &from.ui, e.pos) do c.needs_frame = true
				} else if drag_ext_enter(&c.ui, e.pos, has_files) {
					c.needs_frame = true
				}
			case platform.Ev_Drag_Motion:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				if drag_ext_motion(&c.ui, e.pos) do c.needs_frame = true
			case platform.Ev_Drag_Leave:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				hide_drag_left(c, e.surface, clock_ms(&c.fc))
				if drag_ext_leave(&c.ui) do c.needs_frame = true
			case platform.Ev_Drag_Drop:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				src: ^Ui(Msg)
				if c.ui.drag.sibling {
					if from := drag_source_ctx(&rt); from != nil {
						src = &from.ui
						from.needs_frame = true
					}
				}
				hide_drag_left(c, e.surface, clock_ms(&c.fc)) // no leave follows a drop
				if drag_ext_drop(&c.ui, e.pos, e.action, map_mods(e.mods), src) do c.needs_frame = true
				if debug_events do fmt.eprintfln("baldr/events: drop %s at %v", "from another of our windows" if src != nil else "from the compositor", e.pos)
			case platform.Ev_Drag_End:
				for c in rt.ctxs {
					hide_drag_left(c, 0, clock_ms(&c.fc)) // wherever it was: a drag that ends names no surface
					if drag_ext_end(&c.ui, e.dropped, e.action) do c.needs_frame = true
				}
			case platform.Ev_Drag_Data:
				for c in rt.ctxs do if drag_ext_data(&c.ui, e.data, e.ok) do c.needs_frame = true
				if debug_events do fmt.eprintfln("baldr/events: a drop's data: %d bytes, ok %v", len(e.data), e.ok)
			case platform.Ev_Pointer_Button:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				c.ui.pointer.mods = map_mods(e.mods)
				if e.pressed do c.ui.pointer.press_serial = e.serial
				at := popup_pointer(c, e.surface, e.pos)
				scope := c.ui.tree.pointer_scope
				// Counted, acted on, sampled — in that order, in one place
				// (pointer_samples.odin), so a widget asking how many clicks
				// this was hears this press's count.
				if mouse_button_event(&c.ui, Mouse_Button(u8(e.button)), e.pressed, at, e.time_ms) do c.needs_frame = true
				if debug_events {
					hv := node_get(&c.ui.tree, c.ui.pointer.hover)
					fmt.eprintfln("baldr/events: button %v %s on surface %d at %v (%v in the tree, over popup node %v) → hover %v %q", e.button, "press" if e.pressed else "release",
						e.surface, e.pos, at, scope, hv.access.role if hv != nil else Role.None, hv.access.name if hv != nil else "")
					if sd := node_get(&c.ui.tree, scope); sd != nil {
						h := node_get(&c.ui.tree, hit_test(&c.ui.tree, at))
						fmt.eprintfln("baldr/events:   popup node %v at %v, flags %v; hit %v %q", scope, sd.abs, sd.flags, h.access.role if h != nil else Role.None, h.access.name if h != nil else "")
					}
				}
			case platform.Ev_Key:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				// Keys are logged like text is, to answer "did that chord
				// arrive at all".
				if debug_events {
					if debug_hides_typing(&c.ui.tree) {
						fmt.eprintfln("baldr/events: key (a password field has focus) %s on surface %d", "down" if e.pressed else "up", e.surface)
					} else {
						fmt.eprintfln("baldr/events: key %v %s mods %v on surface %d", e.key, "down" if e.pressed else "up", e.mods, e.surface)
					}
				}
				// a view listening for a chord takes every key first: that is
				// the whole point of it (key_capture.odin)
				if c.ui.capture.on {
					name := backend.key_name(backend, e.native, context.temp_allocator) if backend.key_name != nil else ""
					if capture_key(&c.ui, map_key(e.key), e.pressed, map_mods(e.mods), name) {
						c.needs_frame = true
						continue
					}
				}
				// a focused terminal takes every key its app's shortcuts don't (widget_terminal.odin)
				if term_key_event(&c.ui, map_key(e.key), e.native, e.pressed, e.repeat, map_mods(e.mods)) {
					c.needs_frame = true
					continue
				}
				if key_event(&c.ui, map_key(e.key), e.pressed, map_mods(e.mods)) || key_hold_event(&c.ui, map_key(e.key), e.pressed, map_mods(e.mods)) || shortcut_fire(&c.ui, map_key(e.key), e.pressed, map_mods(e.mods)) do c.needs_frame = true
				if c.ui.release_keyboard { // Escape in a bar or an applet: hand the keyboard back (panel_escape)
					c.ui.release_keyboard = false
					keyboard_release(rt.backend, c)
				}
			case platform.Ev_Theme:
				// The desktop's theme again: the app's accent where it named one
				// and the desktop's otherwise, with the desktop's light/dark and
				// contrast, and the app's own last word on it. Always,
				// even for an app that named a theme of its own: its pinned
				// surfaces keep theirs (apply_theme), and one it has put back on
				// System follows this.
				rt.theme, rt.theme_raw = pick_theme({}, rt.accent, e, rt.adjust_theme)
				rt.prefs = a11y_prefs_of(e)
				rt.titlebar = titlebar_of(e)
				if theme_icons_use(rt.te, e.icon_theme) do for c in rt.ctxs do theme_icons_dirty(&c.ui.tree)
				apply_theme(&rt)
			case platform.Ev_Caps:
				rt.backend.caps = e.caps // the compositor turned blur off or on: glass follows
				apply_theme(&rt)
			case platform.Ev_Outputs:
				if running && !outputs_event(&rt) do running = false
			case platform.Ev_Surface_Output:
				c := ctx_for(&rt, e.surface)
				if c == nil || c.surf != e.surface do continue // a popup's surface: its parent's screen counts
				delete(c.output)
				c.output = strings.clone(e.output)
				if c.fc.fit[0] || c.fc.fit[1] {
					c.fc.fit_cap = fit_cap(c.desc.layer, c.output, known_outputs[:])
					c.fc.fit_size = {}
					c.needs_frame = true
				}
				if debug_events do fmt.eprintfln("baldr/events: surface %d is on %s", e.surface, e.output)
				sched_outputs_changed(&rt.sched, &rt.msgs) // surface_rect's screen changed: the app's outputs_changed lines hear that too
			case platform.Ev_Lock:
				if debug_events do fmt.eprintfln("baldr/events: session lock: %v", e.event)
				lock_event(&rt, e.event)
			case platform.Ev_Frame:
				// The compositor said how far ahead the frame is; the time
				// it lands on is this clock's, not the compositor's.
				at := clock_now(&rt) // this clock's, not the loop's `now` from earlier in the turn
				sched_frame_event(&rt.sched, Frame_Time{
					now_ms = at, present_ms = at + e.ahead_ms,
					refresh_ms = e.refresh_ms, estimated = e.estimated,
				}, &rt.msgs)
				if c := ctx_for(&rt, e.surface); c != nil do c.needs_frame = true // keep drawing while it is wanted
			case platform.Ev_Tray:
				if debug_events do fmt.eprintfln("baldr/events: tray %d: %v id %d", e.tag, e.kind, e.id)
				tray_event(&rt, e)
			case platform.Ev_Notify:
				if debug_events do fmt.eprintfln("baldr/events: notification %d: %v %q%s", e.tag, e.event, e.action, e.error)
				notify_deliver(&rt, e)
			case platform.Ev_Url:
				if debug_events do fmt.eprintfln("baldr/events: open (token %d): %v", e.token, "opened" if e.ok else "not opened")
				// One token counter serves links and local files, so the
				// token says which ask this answers (path_open.odin).
				if !path_open_done(&rt, e.token, e.ok) do url_open_done(&rt, e)
			case platform.Ev_Keyboard:
				if debug_events do fmt.eprintfln("baldr/events: keyboard: locks %v, layout %q of %d", e.locks, e.layout, e.layouts)
				keyboard_event(&rt, e)
			case platform.Ev_Toplevels:
				toplevels_take(rt.backend)
				sched_signal(rt.sched.toplevels[:], &rt.msgs) // the app's toplevels_changed lines
			case platform.Ev_Workspaces:
				workspaces_take(rt.backend)
				sched_signal(rt.sched.workspaces[:], &rt.msgs) // the app's workspaces_changed lines
			case platform.Ev_Slot:
				for c in rt.ctxs {
					n, found := slot_node_of(&c.ui.tree, e.slot)
					if !found do continue
					slot_deliver(&c.ui, n, e)
					break
				}
				if debug_events do fmt.eprintfln("baldr/events: slot %d: %v %q pid %d hint %d..%d", e.slot, e.kind, e.token, e.pid, e.least, e.preferred)
			case platform.Ev_Scroll:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				delta := e.delta
				pos := popup_pointer(c, e.surface, e.pos)
				if .Ctrl in map_mods(e.mods) && zoom_event(&c.ui, pos, delta) { // Ctrl+wheel zooms where a node asked for it
					if debug_events do fmt.eprintfln("baldr/events: zoom by %v at %v (precise %v)", delta, e.pos, e.precise)
					c.needs_frame = true
					continue
				}
				if .Shift in map_mods(e.mods) && delta.x == 0 do delta = {delta.y, 0} // Shift+wheel scrolls sideways
				if scroll_event(&c.ui, pos, delta, e.precise, map_mods(e.mods)) do c.needs_frame = true
			case platform.Ev_Touch:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				pos := popup_pointer(c, e.surface, e.pos)
				switch e.phase {
				case .Down:   if touch_down(&c.ui, e.id, pos, now) do c.needs_frame = true
				case .Move:   if touch_move(&c.ui, e.id, pos, now) do c.needs_frame = true
				case .Up:     if touch_up(&c.ui, e.id, now) do c.needs_frame = true
				case .Cancel: if touch_cancel(&c.ui) do c.needs_frame = true
				}
				if debug_events do fmt.eprintfln("baldr/events: touch %v id %d at %v", e.phase, e.id, e.pos)
			case platform.Ev_Pen: // a tablet's pen: the pointer for the window, every sample for a canvas
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				if pen_event(&c.ui, e, popup_pointer(c, e.surface, e.pos)) do c.needs_frame = true
				if debug_events && e.phase != .Move do fmt.eprintfln("baldr/events: pen %v %v at %v, pressure %.2f, tilt %v", e.phase, e.tool, e.pos, e.pressure, e.tilt)
			case platform.Ev_Input_Caps:
				for c in rt.ctxs do if c.ui.tree.touch != e.touch {
					set_touch(&c.ui.tree, e.touch)
					c.needs_frame = true
				}
			case platform.Ev_Text:
				c := ctx_for(&rt, e.surface)
				if debug_events {
					if c != nil && debug_hides_typing(&c.ui.tree) {
						fmt.eprintfln("baldr/events: text of %d bytes into a password field on surface %d", len(e.text), e.surface)
					} else {
						fmt.eprintfln("baldr/events: text %q on surface %d", e.text, e.surface)
					}
				}
				if c == nil do continue
				if capture_takes_text(&c.ui) do continue // the chord was the answer, not something to type
				if term_text_event(&c.ui, e.text) do continue // the text of the key a terminal holds back, or its own
				if text_area_text(&c.ui, e.text) || text_event(&c.ui, e.text) || time_type(&c.ui, e.text) || type_ahead_text(&c.ui, e.text) do c.needs_frame = true
			case platform.Ev_Ime:
				c := ctx_for(&rt, e.surface)
				if c == nil do continue
				if capture_takes_text(&c.ui) do continue // …nor is a composition
				round := Ime_Event{
					delete_before = int(e.delete_before), delete_after = int(e.delete_after),
					commit = e.commit, preedit = e.preedit,
					cursor_begin = int(e.cursor_begin), cursor_end = int(e.cursor_end),
				}
				if ime_apply(&c.ui, round) do c.needs_frame = true
				if debug_events {
					if debug_hides_typing(&c.ui.tree) {
						fmt.eprintfln("baldr/events: input method into a password field: delete %d/%d, commit of %d bytes", e.delete_before, e.delete_after, len(e.commit))
					} else {
						fmt.eprintfln("baldr/events: input method: delete %d/%d, commit %q, preedit %q", e.delete_before, e.delete_after, e.commit, e.preedit)
					}
				}
			case platform.Ev_Focus:
				// the focus ring stays where it was; a surface that hides stays shown while it has the keyboard,
				// and a view that shows something only where the keyboard is (a lock screen's password) is built again
				if c := ctx_for(&rt, e.surface); c != nil {
					keyboard_focus(c, e.surface, e.focused)
					// Which *surface* has the keys decides where Tab may go: a
					// popover on one of its own keeps Tab inside it, as a
					// dialog does.
					if _, pop := popup_ctx_for(&rt, e.surface); pop != nil {
						c.ui.tree.keyboard_popup = pop.node if e.focused else NODE_NONE
					} else if e.focused {
						c.ui.tree.keyboard_popup = NODE_NONE // the keys are on the surface itself
					}
					if !e.focused do key_holds_release(&c.ui) // no release will come for a key held as the keyboard went
					if debug_events do fmt.eprintfln("baldr/events: keyboard %s surface %v", "entered" if e.focused else "left", e.surface)
				}
			case platform.Ev_Files:
				if h, has := rt.pending_files[e.token]; has {
					delete_key(&rt.pending_files, e.token)
					files_deliver(h, Files{paths = e.paths, ok = e.ok, why = e.why, uris = e.uris}, e.token, &rt.msgs)
				}
			case platform.Ev_Watch:
				sched_watch_event(&rt.sched, e.token, e.name, e.kind, &rt.msgs)
			case platform.Ev_Quit:
				// A desktop that went away is not the app being asked to
				// stop: the caller hears it, so a script or a shell can tell
				// a crash from a close.
				if e.lost do lost = true
				running = false
			}
		}
		for c in rt.ctxs do term_flush(&c.ui) // a terminal's key that typed nothing: no text came for it
		for c in rt.ctxs do window_state_sync(c, &rt.msgs) // the desktop's doing, told to update once and then only when it changes
		for c in rt.ctxs {
			// a view that is listening for a chord (or asked outright) wants
			// the desktop to stop acting on its own shortcuts
			if want := c.ui.capture.inhibit; want != c.inhibiting {
				c.inhibiting = want
				if b := rt.backend; b != nil && b.inhibit_shortcuts != nil do b.inhibit_shortcuts(b, c.surf, want)
			}
			// …and one showing something to watch wants the screen kept on
			awake_sync(rt.backend, c.surf, c.ui.keep_awake, &c.awake)
			cursor_sync(c, backend)
		}

		surfaces_known(&rt) // surface_rect answers from where each shows now
		a11y_frame(&rt)     // …and the accessibility bus hears about the windows, then answers what it was asked
		got_msgs, carry_on := dispatch_msgs(&rt)
		if !carry_on do running = false
		canvases_step(&rt) // the canvas work the updates queued goes to the GPU before any frame shows it
		if got_msgs {
			view_all = true
			tray_sync(&rt) // what the app wants in the tray, after whatever those messages changed
			if running && !sync_surfaces(&rt) && !run_holds(&rt) do running = false // no surface declared and nothing holds the run: done
			activations_run(&rt) // a window the messages opened again, for an activation waiting on it
			sync_subs(&rt)
		}
		for c in rt.ctxs {
			// update ran, so a build follows: until it does a node may point at
			// a Document the app freed, and what reads one waits
			c.ui.build_pending = view_all || c.needs_view
			ui_after_events(&c.ui, now) // tooltips and virtual-list ranges react to what the events above did
			if c.ui.needs_rebuild {
				c.ui.needs_rebuild = false
				ask_view(c, c.ui.rebuild_from)
			}
			if view_all && !c.needs_view do ask_view(c, {procedure = "messages"})
			if c.needs_view && app.view == nil {
				if !said_no_view {
					said_no_view = true
					fmt.eprintln("baldr: a surface was declared but this app has no `view` proc; its window will stay empty")
				}
				c.needs_view = false
				// …and on, rather than `continue`: the frame this wake-up
				// asked for is drawn below, and skipping it would strand the
				// ask (`frame_requested` is already spent). There is nothing
				// to build, so the build below is skipped by `needs_view`.
			}
			if c.needs_view {
				if debug_events do fmt.eprintfln("baldr/events: surface %d view built again: %s", c.surf, loc_text(c.view_from))
				t_build := time.tick_now()
				for pass in 0 ..< 2 {
					begin_view(&c.ui)
					app.view(&rt.state, &c.ui)
					end_view(&c.ui)
					// the view may have switched themes (set_theme), and with them its glass: built again with glass that changed
					if !glass_sync(backend, c, app.clear) || pass == 1 do break
				}
				if c.fc.timing do c.fc.build_ms += time.duration_milliseconds(time.tick_since(t_build))
				if c.fc.rolled != {} do roll_inert(&c.ui.tree, true) // what the build made below a rolled-up window's bar is out of reach too
				if len(c.ui.diags) > 0 {
					for d in c.ui.diags {
						fmt.eprintfln("baldr: %s:%d: %s", d.loc.file_path, d.loc.line, d.msg)
						delete(d.msg, c.ui.allocator)
					}
					clear(&c.ui.diags)
				}
				c.needs_view = false
				c.needs_frame = true
				cursor_sync(c, backend) // a view that asked for another pointer shape (a slideshow hiding it) has it now, not at the next event
				ui_after_build(&c.ui)   // the input method and the primary selection, against the tree this build made
			}
			if c.draw_now { // the frame this wake-up asked for, now the view describes what the input did
				c.draw_now = false
				do_frame(&c.fc)
				c.needs_frame = false
				keyboard_restore(rt.backend, c) // the surface said it wanted no keyboard; it is clickable again from here
				terminal_tick(&c.ui) // a terminal laid out at a new size: its app resizes the pty
			}
			for p in c.popups do if pin, due := popup_take_held(p, clock_ms(&p.fc)); due { // placed, or waited long enough: the frame it held
				p.fc.pin_ms = pin
				do_frame(&p.fc)
			}
			if c.needs_frame || len(c.popups) > 0 do popups_sync(backend, &r, c) // anchored overlays of a shell surface on surfaces of their own
			hide_sync(c, clock_ms(&c.fc)) // a surface hiding at its edge: shown or not, now its popups are known
			hide_place_sync(c, backend)   // …at the screen's edge while out of sight, its margin back as it slides out
			if c.needs_frame do for p in c.popups do if p.fc.target != 0 && !p.fc.frame_requested {
				backend.surface_request_frame(backend, p.surf)
				p.fc.frame_requested = true
			}
			if c.needs_frame && c.fc.target != 0 && !c.fc.frame_requested {
				backend.surface_request_frame(backend, c.surf)
				c.fc.frame_requested = true
				if c.fc.timing && c.fc.req_ms == 0 do c.fc.req_ms = clock_ms(&c.fc)
			}
		}
		toplevel_rects_sync(&rt) // where this app shows each window, after the layouts that moved them
		view_all = false
		mailbox_release(&rt.mailbox) // file data the messages above pointed into
		for str in rt.spent_asks do delete(str) // …and the links and paths they pointed into
		clear(&rt.spent_asks)
		free_all(context.temp_allocator)
	}
	if undrawable do return .Gpu // the reason is already on stderr
	return .Disconnected if lost else .None
}

// toplevel_rects_sync tells the compositor where each window is shown on
// this app's surfaces, when that changed since it last said.
//
// It runs for the app rather than per surface, unlike the other two things
// that follow layout (`input_region_sync`, `backdrop_region_sync`), because
// the answer is a window's and not a surface's: several bars may show the
// same window, the protocol keeps the last rectangle it was given, and
// which bar should win is not a question one surface can answer on its own.
@(private)
toplevel_rects_sync :: proc(rt: ^Runtime($State, $Msg)) {
	b := rt.backend
	if b == nil || b.toplevel_set_rectangle == nil do return
	if len(rt.toplevel_sent) == 0 { // nothing said yet: and nothing to say unless a view has asked
		any := false
		for c in rt.ctxs do if len(c.ui.tree.toplevel_spots) > 0 { any = true; break }
		if !any do return
	}
	now := make([dynamic]Toplevel_Rect, context.temp_allocator)
	for c in rt.ctxs {
		if len(c.ui.tree.toplevel_spots) == 0 do continue
		toplevel_spots_of(&c.ui.tree, u32(c.surf), c.output, known_toplevels[:], &now)
	}
	clears, sends := toplevel_rect_changes(rt.toplevel_sent[:], now[:])
	for c in clears do b.toplevel_set_rectangle(b, c.id, platform.Surface(c.surface), {})
	for s in sends do b.toplevel_set_rectangle(b, s.id, platform.Surface(s.surface), s.rect)
	clear(&rt.toplevel_sent)
	append(&rt.toplevel_sent, ..now[:])
}

// cursor_sync gives surface `c` (and its popups) the pointer shape its
// tree wants, when that changed.
@(private)
cursor_sync :: proc(c: ^Surface_Ctx($Msg), backend: ^platform.Backend) {
	cur := cursor_for(&c.ui)
	if cur == .Picture { // a picture the app drew: sent again when it changes
		img, hot, ok := pointer_area_picture(&c.ui)
		if ok && backend.surface_set_cursor_image != nil {
			if img.id == 0 do img.id = image_new_id()
			key := Cursor_Picture_Key{img.id, img.version, img.touched, hot, c.fc.scale}
			if cur == c.last_cursor && key == c.last_picture do return
			c.last_cursor, c.last_picture = cur, key
			size := [2]i32{i32(img.width), i32(img.height)}
			backend.surface_set_cursor_image(backend, c.surf, img.pixels, size, {i32(hot.x), i32(hot.y)}, c.fc.scale)
			for p in c.popups do backend.surface_set_cursor_image(backend, p.surf, img.pixels, size, {i32(hot.x), i32(hot.y)}, c.fc.scale)
			return
		}
		cur = .Crosshair // no picture to give, or no way to: the nearest shape to a brush
	}
	if cur == c.last_cursor do return
	c.last_cursor = cur
	backend.surface_set_cursor(backend, c.surf, platform.Cursor(u8(cur)))
	for p in c.popups do backend.surface_set_cursor(backend, p.surf, platform.Cursor(u8(cur)))
}

// Cursor_Picture_Key says which picture a cursor last was: its identity,
// version, touches, hotspot and the screen's scale.
@(private)
Cursor_Picture_Key :: struct {
	id, version, touched: u64,
	hotspot:              [2]int,
	scale:                f32,
}

// ask_view asks for surface `c`'s view to be built again, remembering the
// first place that asked since it was last built for BALDR_DEBUG_EVENTS.
@(private)
ask_view :: proc(c: ^Surface_Ctx($Msg), loc := #caller_location) {
	if !c.needs_view do c.view_from = loc
	c.needs_view = true
}
