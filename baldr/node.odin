package baldr

import "base:runtime"
import "core:strings"

// Node is a generational handle into a Tree's node pool: low 32 bits index,
// high 32 bits generation. A stale handle (its slot was freed and reused)
// fails `node_get` instead of aliasing another node. Zero is "no node".
Node :: distinct u64

NODE_NONE :: Node(0)

@(private) node_make  :: proc "contextless" (index, gen: u32) -> Node { return Node(u64(index) | (u64(gen) << 32)) }
@(private) node_index :: proc "contextless" (n: Node) -> u32 { return u32(u64(n) & 0xffff_ffff) }
@(private) node_gen   :: proc "contextless" (n: Node) -> u32 { return u32(u64(n) >> 32) }

// Node_Flag is one bit of per-node state. Invalidation bits are set by the
// mutation procs and cleared by the passes; structure bits are set by
// builders; interaction bits by event dispatch.
Node_Flag :: enum u8 {
	Alive,
	// invalidation
	Dirty_Layout,      // size/position may have changed; layout pass must visit
	Dirty_Paint,       // appearance changed; owning layer must re-emit this node
	Blink_Only,        // with Dirty_Paint: only its caret's blink changed, so the damage is where its paint says the caret is (caret_painted)
	Dirty_Root,        // queued in Tree.dirty_roots
	Layer_Dirty,       // set on a Layer node when any node it paints is Dirty_Paint
	// structure
	Drop_Target,       // a drop may ring it: the ring is drawn outside its rect, so paint_bounds reserves the room
	Relayout_Boundary, // layout below here never changes this node's size given the same constraints
	Layer,             // owns a cached draw list (root, scroll viewports, opacity groups, popovers)
	Clips,             // children are clipped to this node's rect
	Keep,              // parked by the reconciler instead of destroyed when not emitted
	Scroll_V,          // children may overflow vertically; Scroll_State.offset.y shifts them
	Scroll_H,          // …horizontally
	Exiting,           // playing its exit transition; not hit-testable, not focusable, destroyed when done
	Overlay,           // the overlay root: a second top-level node over the viewport, hit only through its children
	Animate_Moves,     // children glide to a new position when a rebuild moves them (paint-time shift, layout untouched)
	Animate_Resize,    // with Animate_Moves: they glide on a window resize too (an icon view's reflow)
	Revealed,          // a parked (Keep) node was shown again this build; the builder that owns it consumes the flag
	Hit_Transparent,   // never hit-tested, nor its children (a drag ghost under the pointer)
	Hit_Children,      // its own space lets the pointer through; only its children are hit (set_hit_children)
	Inert,             // draws, but it and its subtree take no pointer, focus or place in the accessibility tree (set_inert)
	Input_Area,        // where its surface takes the pointer, when the surface declares input = .Marked
	Backdrop_Area,     // where its surface is blurred behind, when the surface declares backdrop_region = .Marked
	Theme_Area,        // it and its subtree are built and painted in a theme of the app's own (theme_area)
	Glass_In_App,      // its glass is over the app's own content: it and its subtree are built and painted in the worst-case theme (in_app_theme)
	Ring_Inside,       // paints its own focus indication (a cursor row, the picked radio): no ring around the whole node
	Tab_First,         // Tab reaches it before the siblings built ahead of it: a part drawn over another (a slider's mute icon over its track)
	Glows,             // its text or icons have a glow behind them (Clear glass): it paints GLOW_OVERHANG past its rect
	Quiet,             // no hover or press wash: what it does instead (a dock icon growing) says what the pointer is on (button_options quiet)
	// behaviour
	Hidden,
	Disabled,
	Focusable,
	Keys_Only_Focus,   // Tab reaches it, a press does not: a tool button, a toolbar, a transport (button_options focus_on_click = false)
	Pointer_Only_Focus, // the mirror: a press focuses it, Tab passes it by — a read-only paragraph a chat has hundreds of (Qt's ClickFocus, HTML's tabindex=-1)
	Check_Item,        // a menu item that ticks: readers hear a check menu item, ticked or not
	Radio_Item,        // …one of a set, picked or not
	// interaction
	Hovered,
	Pressed,
	Focused,
	Active,
}
// u64 because there are more than 32 flags; the extra bits land in padding
// Node_Data already had, so it costs no size.
Node_Flags :: bit_set[Node_Flag; u64]

// Kind is the small, hot per-kind data. Rare or heavy state (text buffers,
// scroll velocities, custom user pointers) lives in Tree side tables.
Kind :: union {
	Box_Kind,
	Text_Kind,
	Custom_Kind,
	Text_Input_Kind, // text_input hook (widget_text_input.odin)
}
Box_Kind  :: struct {}

// Custom_Kind is the node door for widgets that paint themselves: a fixed
// intrinsic `size` and a `paint` proc that appends Draw_Cmds after the node's
// own background (and before its children). Interaction still goes through
// the ordinary flags, handlers, and side tables.
Custom_Kind :: struct {
	size:     [2]f32,
	paint:    proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer),
	user:     rawptr,
	overhang: f32, // px the painter may draw beyond the rect (shadows, rings): damage and culling include it
	paint_over: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer), // drawn after the children (guides, indicators)
	measure:    proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32, // custom layout: the node's size under `cc` (a text area's wrapped height)
}
Text_Kind :: struct {
	str:    string, // owned by the tree allocator
	size:   f32,    // font size, logical px
	wrap_w: f32,    // max width the text was measured with (0 = unwrapped); set by layout
	weight: Font_Weight, // Regular, Medium or Semibold: the theme's role sets it, `text`'s weight overrides
	mono:   bool,        // the code face, not the UI one
	family: Family_Id,   // a family of its own — an app's wordmark, an editor's chosen face — 0 for the theme's
	nowrap: bool,   // never wrap: one line, cut at its box when it is given less room
	// Figures of one width (OpenType `tnum`), so a changing number keeps
	// its width: a stopwatch, a column of figures. Only the digits'
	// advances change, not the face.
	tabular: bool,
	italic:  bool, // the face's italic: a provisional thing, a title, a term — `text(italic = true)`
	// A secret shown on purpose (a revealed key, a recovery phrase): the
	// tree's copy is overwritten before it is freed, and the accessibility
	// bridge gets the node without its characters. `text(sensitive = true)`.
	sensitive: bool,
	ellipsis:  Ellipsis, // trim with "…" when the text does not fit its width (one line, or `max_lines`)
	max_lines: int,      // with ellipsis: wrap up to this many lines before trimming (0 = one line)
	display:   string,   // the trimmed text actually drawn (owned by the tree allocator); "" = str
	align:     Text_Align, // where each line sits within the node when lines differ in width
	inset_y:   f32,        // how far its lines sit below its top: an interactive text grown to its target size is centred in it (layout sets it)
	spills:    bool,       // wider than its box (a word or a glyph that cannot break, an ellipsis with no room): paint clips it at its sides, so it never draws over a neighbour or outside its damage (layout sets it)
	drawn_h:   f32,        // the height its lines take, which a row squeezed shorter than a line does not cut: its damage covers it (layout sets it)
}

Text_Align :: enum u8 { Start, Center, End }

// Font_Weight is how heavy text is set: Regular (400), Medium (500) or
// Semibold (600), from the UI typeface's weight axis.
Font_Weight :: enum u8 { Regular, Medium, Semibold }

// Ellipsis says where a text that does not fit loses characters: at the end
// ("Quarterly rep…") or in the middle, which keeps file extensions
// ("Quarterly…2026.pdf"). The accessible name stays the full text.
Ellipsis :: enum u8 { None, End, Middle }

Kind_Tag :: enum u8 { None, Box, Text, Custom, Text_Input }

kind_tag :: proc "contextless" (k: Kind) -> Kind_Tag {
	switch _ in k {
	case Box_Kind:        return .Box
	case Text_Kind:       return .Text
	case Custom_Kind:     return .Custom
	case Text_Input_Kind: return .Text_Input // text_input hook
	}
	return .None
}

// Node_Data is one slot of the pool. Keep it small: layout and paint walk
// these arrays and cache misses are the cost model.
Node_Data :: struct {
	gen:      u32,
	epoch:    u32,        // build epoch that last visited this node (reconciler)
	flags:    Node_Flags,
	parent, first, last, prev, next: Node,
	key:      u64,        // reconciliation key; 0 = positional
	tag:      u64,        // app-supplied identity echoed in Ev.tag
	kind:     Kind,
	layout:   Layout_Props,
	style:    Style,
	access:   Access,
	rect:     Rect,       // parent-local, logical px (set by the parent's layout)
	abs:      Rect,       // absolute, logical px (set by resolve_abs)
	move_from: [2]f32,    // where the node was drawn before its last layout move, relative to abs (× the Move anim)
	cached_c: Constraints,// constraints received at the last layout
	loc:      runtime.Source_Code_Location, // where the builder was called; used by every diagnostic
	builder:  string,   // which builder made it ("button", "column"): part of its identity, so a key cannot hand one builder's node to another
}

// Diag is a diagnostic produced by the core (unbalanced scope, lint hit).
// Headless callers read Tree.diags; the run loop logs them in debug builds.
Diag :: struct {
	msg: string,
	loc: runtime.Source_Code_Location,
}

Stats :: struct {
	layout_nodes:   int, // nodes laid out since reset
	paint_nodes:    int, // nodes emitted since reset
	layers_rebuilt: int,
	term_rows:      int, // terminal rows drawn again (the rest were kept)
}

// Text_Measure measures a run of text. `max_w` of 0 means no wrapping.
// The headless default is a fixed-advance approximation; the runtime installs
// runa.
Text_Measure :: #type proc(t: ^Tree, s: string, size: f32, max_w: f32, weight: Font_Weight, mono: bool, family: Family_Id, tabular: bool) -> [2]f32

// Tree owns the node pool and everything the passes need. It is not
// parameterised by the app's message type so layout/paint/a11y are compiled
// once; Ui($Msg) embeds it.
Tree :: struct {
	allocator:    runtime.Allocator,
	nodes:        [dynamic]Node_Data,
	free:         [dynamic]u32,
	root:         Node,
	dirty_roots:  [dynamic]Node,
	damage:       [dynamic]Rect,
	damage_off:       bool, // laying out or painting inside a popup on a surface of its own, which presents whole: nothing there is damage
	damage_elsewhere: bool, // …but something there changed since the last take_damage (surface_damage)
	debug_damage:     bool, // BALDR_DEBUG_DAMAGE: print each node that damages its surface (damage_log)
	blink_rect:       Rect, // where the node being painted drew its caret, or would have (caret_painted)…
	blink_said:       bool, // …and whether its paint said so: a blink-only repaint damages that alone
	debug_bounds:     bool, // BALDR_DEBUG_BOUNDS: report each node that draws outside its paint bounds (bounds_check)
	bounds_faults:    [dynamic]Bounds_Fault, // what bounds_check found
	debug_events:     bool, // BALDR_DEBUG_EVENTS: say why each overlay (a select's list, a menu, a popover) opens and closes
	layers:       map[Node]Layer,
	// toplevel_spots says which node stands for which window on this
	// surface, so the compositor can fly a minimising window into it
	// (desktop.odin). Keyed by the window: one button may stand for several
	// windows, but each window is shown in one place.
	//
	// Not cleared per build, because a skipped `component` must keep the
	// spots declared inside it. When the rectangles are sent, a spot is
	// dropped if its node has gone, its window closed, or the node was
	// built again without declaring it; the spot's epoch tells the last
	// case apart.
	toplevel_spots: map[u64]Toplevel_Spot,
	measure_text: Text_Measure,
	text:         ^Text_Engine, // installed by the run loop; nil in headless tests (mono measurer)
	// The families its text was last laid out in: the ones its theme names,
	// resolved by the engine. Compared against the engine's to notice a
	// family that has arrived since, or one another surface's theme named
	// (tree_fonts_sync).
	ui_family:    Family_Id,
	mono_family:  Family_Id,
	role_family:  [Text_Role]Family_Id,
	theme:        Theme,
	theme_asked:  Theme, // what the theme was set to; `theme` is it with a11y_prefs folded in
	a11y_prefs:   A11y_Prefs, // the desktop's, kept current by the run loop
	theme_app:    bool, // the app set this tree's theme: the desktop's theme changes leave it
	theme_desktop: Theme, // …and what the desktop's theme is meanwhile, so follow_system_theme can go back to it
	// The same two themes before `adjust_theme` ran over them. Re-running an
	// adjust on an adjusted theme compounds (a multiplied size doubles each
	// time), so refresh_theme starts again from these.
	theme_desktop_raw: Theme,
	theme_app_raw:     Theme,
	adjust_theme: proc(th: ^Theme), // App.adjust_theme: the app's last word on any theme this tree runs with, set themes included
	a11y_app:     bool, // the app set this tree's accessibility preferences (set_a11y_prefs): the desktop's leave them
	a11y_desktop: A11y_Prefs, // …and what the desktop's are meanwhile, so follow_system_a11y can go back to them
	// The app's own text size (set_text_scale), multiplied with the
	// desktop's rather than replacing it, and leaving reduce-motion and
	// reduce-transparency following the desktop. 0 = the app has no say.
	app_text_scale: f32,
	keyboard:     Keyboard_Info, // the lock keys on and the keyboard layout (keyboard_info.odin); set by the run loop
	titlebar:     Chrome_Prefs, // what its title bars follow: the desktop's (kept current by the run loop) or the app's (widget_chrome.odin)
	titlebar_app: bool,         // the app set them (set_titlebar_prefs): the desktop's leave this tree
	rolled:       bool,         // its window is rolled up to its title bar (set by the run loop)
	roll_bar:     Node,         // …to this bar
	roll_inert:   [dynamic]Node, // …what it hides, made inert by the roll (roll_inert)
	roll_focus:   Node,         // …where the keyboard was before, below the bar
	theme_base:   Theme, // theme_asked with a11y_prefs folded in; `theme` adds what shows through glass (glass.odin)
	glass:        Tree_Glass, // whether the surface is glass, and how bright it is behind (set by the run loop)
	// A surface that declares `backdrop_region = .Marked` is glass only
	// where its backdrop_area nodes are, so the theme is adapted for them
	// and the rest of the window keeps the app's colours. False (`.All`):
	// the whole surface is glass and `theme` itself is adapted.
	backdrop_marked: bool,
	glass_theme:     Theme, // …the adapted one, for what is drawn on a marked node
	glass_theme_ok:  bool,
	// Glass inside the window (a menu, a popover, a select's list) shows
	// what the app drew under it, which nobody measures: the compositor
	// reports only the desktop behind the window. So it takes the
	// worst-case theme, as an unreported popup surface does.
	in_app_theme:    Theme,
	in_app_theme_ok: bool,
	popup_themes: map[Node]Theme, // glass popups' themes over their own backdrops, made on first use
	slot_places:  map[Node]Slot_Place, // applet_slot nodes and their platform slots (applet_slot.odin)
	glass_families: Glass_Families, // the seed's Light and Dim colours, for Clear
	locale:       Locale, // how dates, times and numbers are written and what days and months are called (set by run from the desktop; LOCALE_EN otherwise)
	focus:        Node, // keyboard focus (see focus.odin)
	focus_visible: bool,
	// The overlay child whose popup surface holds the keyboard, NODE_NONE
	// otherwise. Tab is trapped inside it, as in a dialog: the keys go to
	// that surface, so focus moved off it could not be typed into.
	keyboard_popup: Node,
	// Whether this tree's surface has the keyboard, set by the run loop. A
	// control keeps focus when the keyboard leaves (Tab resumes there, and
	// assistive technology still knows where focus is), but its focus ring
	// is drawn only while this is true, as in an inactive window. True
	// until the run loop says otherwise, so a headless tree draws rings.
	keyboard_on:  bool,
	anims:        map[Node]Anim_State, // running/resting tweens (anim.odin)
	scrolls:      map[Node]Scroll_State, // scroll containers (scroll.odin)
	sliders:      map[Node]Slider_State, // sliders (widget_controls.odin)
	charts:       map[Node]Chart_State,  // charts: where the pointer and the keyboard are (widget_chart.odin)
	chart_data:   map[Node]Chart_Kept,   // …and the series themselves, kept past the build that passed them
	sparklines:   map[Node]Sparkline_Kept, // sparklines' values, kept for paint (widget_sparkline.odin)
	lines_data:   map[Node]Lines_Kept,   // polylines drawn over a node, kept for paint (widget_lines.odin)
	terminals:    map[Node]Term_State, // terminals: the screen shown and each row's drawing (widget_terminal.odin)
	reveals:      map[Node]Reveal,       // nodes shown only while what they belong to is hovered or focused (reveal.odin)
	reveals_built: map[Node]bool,        // …asked for by the build in progress
	hover:        Node,                  // the node the pointer is over, as the Ui's hover (reveal.odin reads it while painting)
	chart_note:   map[Node]string,       // the sentence the app gave a chart, kept so a moving cursor can be added to it
	graphs:       map[Node]Graph_State,  // node graphs: how the canvas is being looked at (widget_graph.odin)
	graph_data:   map[Node]Graph_Kept,   // …and the nodes and wires themselves
	graph_grid:   map[Node]bool,         // …and whether it draws its dot grid
	chrome:       map[Node]Chrome_State, // a window's own title bar (widget_chrome.odin)
	chrome_btn:   map[Node]Chrome_Button, // …its buttons
	chrome_of:    map[Node]Node,         // …and which bar each belongs to
	window:       Window_Hook,           // how this tree asks the desktop about its own frame; zero in headless tests
	exiting:      [dynamic]Node,         // nodes playing an exit transition (build.odin)
	overlay:      Node,                  // overlay root (popovers, dialogs, tooltips): parentless, laid out to the viewport (overlay.odin)
	overlay_rules: map[Node]Overlay_Rule, // how each overlay child is placed, resolved at layout time
	tables:       map[Node]Table_State,  // tables: columns, resolved geometry, interaction state (widget_table.odin)
	icon_views:   map[Node]Icon_View_State, // icon views: tile grid geometry, marquee (widget_icon_view.odin)
	lives:        map[Node]struct{},        // live regions: what a reader is told about without focus (set_live)
	legibles:     map[Node]Legible_Want,    // nodes that pick their own ink from what is measured behind them (legible_over)
	backdrop_map: Backdrop_Map,             // …and the cells they pick it from
	areas:        map[Node]Text_Area_State, // multiline text areas (widget_text_area.odin)
	styled:       map[Node]Styled_State,    // app-built styled paragraphs (widget_styled_text.odin)
	typesets:     map[Node]Typeset_View_State, // pages of a laid-out paragraph (widget_typeset_view.odin)
	typeset_serial: u64,                 // the last serial handed to a Typeset (typeset); never reused, so a new setting at a freed one's address is still new
	theme_areas:  map[Node]Theme,           // parts of the window in a theme of the app's own (theme_area)
	customs:      map[Node]Custom_State,    // widgets of the app's own: what paints them, and the text they drew (widget_custom.odin)
	theme_saves:  [dynamic]Theme,           // themes emit_node swapped out, restored as each subtree ends: on the heap, not in a recursive frame
	md_views:     map[Node]Md_View_State,   // read-only markdown views (widget_markdown_view.odin)
	editor_ctl_of: map[Node]Node,           // an editor's bar field / button / list item → its area (code and rich editors)
	md_copy_of:    map[Node]Node,           // a reply's "Copy code" button → the view it belongs to (its tag is the run's first block)
	sel_scopes:    map[Node]Sel_Scope,      // a container owning one selection across the text views in it
	editor_owned:  map[Node]Node,           // a control of the app's own counted as part of an editor → its area (editor_control)
	area_of_frame: map[Node]Node,           // an editor's frame → its area
	tree_views:   map[Node]Tree_View_State, // tree views: cursor row (widget_tree.odin)
	tree_rows:    map[Node]Tree_Row,        // tree items: which tree, depth, expander, children container
	tree_branches: map[Node]Node,           // a tree item's children container → its row
	splits:       map[Node]Split_State,     // split panes: axis, size, divider, drag (widget_split.odin)
	drops:        map[Node]Drop_Target,     // drop targets: positions and accepted kind (dnd.odin)
	rests:        map[Node]Rest_Target,     // nodes that hear a drag rest on them, whether or not they take it
	choices:      map[Node]Choice_State,    // radio groups / segmented controls: items and the pick (widget_choice.odin)
	pictures:     map[Node]Picture,         // what image nodes last showed (image.odin)
	picture_said: bool,                     // a picture that did not add up has been reported once (image.odin): a line a frame would be noise
	canvases:     map[Node]Canvas_Shown,    // what canvas nodes last showed (canvas.odin)
	theme_icons:  map[Node]Theme_Icon_Use,  // the names theme_icon nodes show (theme_icon.odin)
	button_marks: map[Node]Button_Mark_Use, // the marks buttons draw inside their edge (button_options)
	button_badges: map[Node]Button_Badge_Use, // the badges buttons draw at their icon's corner (button_options)
	button_progress: map[Node]Button_Progress_Use, // …and the progress they draw across its bottom
	icon_toggles: map[Node]Icon,            // the icon each icon_toggle shows (widget_controls.odin)
	pages:        map[Node]Pages_State,     // pages containers: the page shown, how deep, who opened what (widget_pages.odin)
	popups_on:     bool,                 // anchored overlays show on popup surfaces of their own (popup.odin)
	popups:        map[Node]Popup_Place, // where each sits in the tree once its surface is placed
	pointer_scope: Node,                 // the popup the pointer is over, its hits kept inside it; NODE_NONE: the surface's own
	choice_of:    map[Node]Node,            // a choice item → its group
	spins:        map[Node]^Spin_State,     // number inputs, keyed by the outer node (widget_number.odin)
	spin_of:      map[Node]Node,            // a number input's field → its outer node
	calendars:    map[Node]Calendar_State,  // date pickers: page, cursor, cells (widget_date.odin)
	cal_day_of:   map[Node]Node,            // a day cell → its date picker
	pickers:      map[Node]^Picker_State,   // colour pickers (widget_color.odin)
	picker_of:    map[Node]Node,            // a picker's slider or hex field → the picker
	times:        map[Node]Time_State,      // time pickers (widget_time.odin)
	time_seg_of:  map[Node]Node,            // a time picker's segment or ▲ ▼ → the picker
	field_of_time: map[Node]Node,           // a picker inside a time_field's popover → the field
	field_of_cal: map[Node]Node,            // a calendar inside a date_field's popover → the field
	drag_source:  Node,                     // the node being dragged (painted faded)
	drag_over:    Node,                     // target showing drop feedback, and where on it
	drag_over_pos: Drop_Position,
	touch:        bool,                  // a touchscreen is present: interactive targets grow to TOUCH_TARGET
	reveal:       Node,                  // scrolled into view after the next layout (a newly selected tab)
	viewport_changed: bool,              // this layout pass follows a resize: moves are not animated
	scroll_hover: Node,                  // scroll container under the pointer (its bar shows dimmed)
	bar_hover:    Node,                  // scroll container whose scrollbar zone the pointer is in (bar widens)
	bar_hover_axis: int,                 // …which of its bars: 1 the vertical one, 0 the horizontal one (a list that scrolls both ways has both)
	modal:        Node,                  // open modal dialog card: focus is trapped inside; NODE_NONE when none
	paint_opacity: f32,                  // effective opacity of the node being painted (for Custom_Kind painters)
	now_ms:       f64,                 // frame clock; set by anim_tick
	anim_active:  bool,                // something is still in motion → draw another frame
	// wake_at_ms is the earliest pending timer (0 = none); the run loop uses
	// it as its wait deadline. Timers are set with tree_wake_at and fired by
	// anim_tick, which repaints the node that asked (caret blink, scrollbar
	// fade, tooltips, auto-repeat).
	wake_at_ms:   f64,
	timers:       [dynamic]Timer,
	clipboard:    Clipboard, // installed by the run loop; zero in headless tests
	primary_pending: Node,   // a field whose selection the person just changed: the primary selection's, this wake (primary.odin)
	primary_sent:    string, // what it was last given (tree allocator)
	ime:          Ime,       // input methods: the hook the run loop installs, and what is being composed (ime.odin)
	inputs:       map[Node]Text_Input_State, // text_input hook: per-field caret/selection/scroll (widget_text_input.odin)
	stats:        Stats,
	layouts:      u64, // layout passes that laid out something outside a popup: a measurement taken since can tell the surface's content changed (fit_sync, applet_hints)
	layout_here:  bool, // something outside a popup was marked for layout since a pass counted it
	diags:        [dynamic]Diag,
	viewport:     [2]f32,
}

// tree_init prepares an empty tree with a root Box node that is also the
// root layer and relayout boundary. All allocations use `allocator`.
tree_init :: proc(t: ^Tree, allocator := context.allocator) {
	t.allocator = allocator
	t.ime.node = NODE_NONE
	t.ime.lo, t.ime.hi = -1, -1
	t.nodes = make([dynamic]Node_Data, 1, 64, allocator) // slot 0 is the null node
	t.free = make([dynamic]u32, allocator)
	t.dirty_roots = make([dynamic]Node, allocator)
	t.damage = make([dynamic]Rect, allocator)
	t.locale = LOCALE_EN
	t.keyboard_on = true // until a run loop says the keyboard has gone
	t.layers = make(map[Node]Layer, allocator)
	t.diags = make([dynamic]Diag, allocator)
	when ODIN_TEST do t.debug_bounds = true // every test's views are held to their paint bounds (build.sh test fails on a fault)
	t.anims = make(map[Node]Anim_State, allocator)
	t.scrolls = make(map[Node]Scroll_State, allocator)
	t.overlay_rules = make(map[Node]Overlay_Rule, allocator)
	t.tables = make(map[Node]Table_State, allocator)
	t.icon_views = make(map[Node]Icon_View_State, allocator)
	t.lives = make(map[Node]struct{}, allocator)
	t.legibles = make(map[Node]Legible_Want, allocator)
	t.areas = make(map[Node]Text_Area_State, allocator)
	t.styled = make(map[Node]Styled_State, allocator)
	t.typesets = make(map[Node]Typeset_View_State, allocator)
	t.tree_views = make(map[Node]Tree_View_State, allocator)
	t.tree_rows = make(map[Node]Tree_Row, allocator)
	t.tree_branches = make(map[Node]Node, allocator)
	t.splits = make(map[Node]Split_State, allocator)
	t.drops = make(map[Node]Drop_Target, allocator)
	t.rests = make(map[Node]Rest_Target, allocator)
	t.choices = make(map[Node]Choice_State, allocator)
	t.pictures = make(map[Node]Picture, allocator)
	t.canvases = make(map[Node]Canvas_Shown, allocator)
	t.theme_icons = make(map[Node]Theme_Icon_Use, allocator)
	t.button_marks = make(map[Node]Button_Mark_Use, allocator)
	t.button_badges = make(map[Node]Button_Badge_Use, allocator)
	t.button_progress = make(map[Node]Button_Progress_Use, allocator)
	t.icon_toggles = make(map[Node]Icon, allocator)
	t.pages = make(map[Node]Pages_State, allocator)
	t.popups = make(map[Node]Popup_Place, allocator)
	t.popup_themes = make(map[Node]Theme, allocator)
	t.slot_places = make(map[Node]Slot_Place, allocator)
	t.pointer_scope = NODE_NONE
	t.choice_of = make(map[Node]Node, allocator)
	t.spins = make(map[Node]^Spin_State, allocator)
	t.spin_of = make(map[Node]Node, allocator)
	t.calendars = make(map[Node]Calendar_State, allocator)
	t.cal_day_of = make(map[Node]Node, allocator)
	t.pickers = make(map[Node]^Picker_State, allocator)
	t.picker_of = make(map[Node]Node, allocator)
	t.times = make(map[Node]Time_State, allocator)
	t.time_seg_of = make(map[Node]Node, allocator)
	t.editor_ctl_of = make(map[Node]Node, allocator)
	t.md_copy_of = make(map[Node]Node, allocator)
	t.sel_scopes = make(map[Node]Sel_Scope, allocator)
	t.editor_owned = make(map[Node]Node, allocator)
	t.area_of_frame = make(map[Node]Node, allocator)
	t.field_of_time = make(map[Node]Node, allocator)
	t.field_of_cal = make(map[Node]Node, allocator)
	t.sliders = make(map[Node]Slider_State, allocator)
	t.timers = make([dynamic]Timer, allocator)
	t.exiting = make([dynamic]Node, allocator)
	t.inputs = make(map[Node]Text_Input_State, allocator) // text_input hook
	t.terminals = make(map[Node]Term_State, allocator)
	t.primary_pending = NODE_NONE
	t.measure_text = measure_text_mono
	t.theme = theme_dark()
	t.theme_asked = t.theme
	t.theme_desktop = t.theme // until the run loop says what the desktop's is
	t.theme_desktop_raw = t.theme
	t.theme_app_raw = t.theme
	t.theme_base = t.theme
	t.root = node_new(t, Box_Kind{})
	r := node_get(t, t.root)
	r.flags += {.Layer, .Relayout_Boundary}
	r.access.role = .Window
	r.layout = {axis = .Column, align = .Stretch} // children fill the surface width; `flex = 1` fills its height
	t.layers[t.root] = Layer{cmds = make([dynamic]Draw_Cmd, allocator)}
	// The overlay root: a second top-level node (no parent) laid out over the
	// whole viewport, painted after root and hit-tested before it.
	t.overlay = node_new(t, Box_Kind{})
	o := node_get(t, t.overlay)
	o.flags += {.Overlay, .Layer, .Relayout_Boundary}
	o.layout = {axis = .Stack}
	t.layers[t.overlay] = Layer{cmds = make([dynamic]Draw_Cmd, allocator)}
}

tree_destroy :: proc(t: ^Tree) {
	for &d in t.nodes {
		if .Alive in d.flags do node_free_owned(t, &d)
	}
	for _, &l in t.layers do delete(l.cmds)
	delete(t.layers)
	delete(t.toplevel_spots)
	if len(t.ime.text) > 0 do delete(t.ime.text, t.allocator)
	if len(t.ime.sent_text) > 0 do delete(t.ime.sent_text, t.allocator)
	delete(t.nodes)
	delete(t.free)
	delete(t.dirty_roots)
	delete(t.damage)
	for d in t.diags do delete(d.msg, t.allocator)
	delete(t.diags)
	delete(t.bounds_faults)
	delete(t.anims)
	delete(t.scrolls)
	for _, &ts in t.tables do table_state_destroy(&ts)
	delete(t.tables)
	for _, &vs in t.icon_views {
		delete(vs.cells)
		delete(vs.taken)
		delete(vs.grid.base)
		delete(vs.prev)
	}
	delete(t.icon_views)
	delete(t.lives)
	delete(t.legibles)
	tree_backdrop_map_free(t)
	for _, &as in t.areas do text_area_state_destroy(t, &as)
	delete(t.areas)
	for _, &ss in t.styled do styled_state_destroy(t, &ss)
	delete(t.styled)
	for _, &ts in t.typesets do typeset_view_state_free(t, &ts)
	delete(t.typesets) // the Typesets are the app's; only the references go
	delete(t.theme_areas)
	delete(t.theme_saves)
	for _, &cs in t.customs {
		for s in cs.strings do delete(s, t.allocator)
		delete(cs.strings)
	}
	delete(t.customs)
	for _, &mv in t.md_views { md_view_images_free(t, &mv); md_view_cache_clear(t, &mv); delete(mv.blocks); delete(mv.marks); delete(mv.words) }
	delete(t.md_views)
	delete(t.tree_views)
	delete(t.tree_rows)
	delete(t.tree_branches)
	for _, &sp in t.splits do split_state_destroy(t, &sp)
	delete(t.splits)
	for _, &dt in t.drops do drop_target_destroy(t, &dt)
	delete(t.drops)
	for _, &rt in t.rests do rest_target_destroy(t, &rt)
	delete(t.rests)
	for _, &cs in t.choices do delete(cs.items)
	delete(t.choices)
	delete(t.pictures)
	delete(t.canvases)
	for _, use in t.theme_icons do theme_icon_use_free(t, use)
	delete(t.theme_icons)
	delete(t.button_marks)
	for _, u in t.button_badges {
		delete(u.badge.text, t.allocator)
		delete(u.shown.text, t.allocator)
	}
	delete(t.button_badges)
	delete(t.button_progress)
	delete(t.icon_toggles)
	for _, &ps in t.pages do delete(ps.openers)
	delete(t.pages)
	delete(t.popups)
	delete(t.popup_themes)
	delete(t.slot_places)
	delete(t.choice_of)
	for _, sp in t.spins do spin_state_free(t, sp)
	delete(t.spins)
	delete(t.spin_of)
	for _, &cs in t.calendars do delete(cs.cells)
	delete(t.calendars)
	delete(t.cal_day_of)
	for _, ps in t.pickers do picker_state_free(t, ps)
	delete(t.pickers)
	delete(t.picker_of)
	delete(t.times)
	delete(t.time_seg_of)
	delete(t.editor_ctl_of)
	delete(t.md_copy_of)
	delete(t.sel_scopes)
	delete(t.editor_owned)
	delete(t.area_of_frame)
	delete(t.field_of_time)
	delete(t.field_of_cal)
	delete(t.overlay_rules)
	for _, &st in t.sliders do slider_state_free(t, &st)
	delete(t.sliders)
	for n, _ in t.graphs do graph_free(t, n) // a graph's nodes, wires and the names in them
	delete(t.graphs)
	delete(t.graph_data)
	delete(t.graph_grid)
	delete(t.chrome)
	delete(t.roll_inert)
	delete(t.chrome_btn)
	delete(t.chrome_of)
	for n, _ in t.charts do chart_free(t, n) // the series a chart kept, and the line it was reading
	delete(t.charts)
	delete(t.chart_data)
	delete(t.chart_note)
	for n, _ in t.sparklines do sparkline_free(t, n)
	delete(t.sparklines)
	for n, _ in t.lines_data do lines_node_free(t, n)
	delete(t.lines_data)
	delete(t.primary_sent, t.allocator)
	for n, _ in t.terminals do term_free(t, n)
	delete(t.terminals)
	delete(t.reveals)
	delete(t.reveals_built)
	delete(t.timers)
	delete(t.exiting)
	text_inputs_destroy(t) // text_input hook
}

// node_new allocates a node of `kind`. It is unattached until node_append /
// node_insert_before. Layout is dirty from birth.
node_new :: proc(t: ^Tree, kind: Kind, loc := #caller_location) -> Node {
	idx: u32
	if len(t.free) > 0 {
		idx = pop(&t.free)
	} else {
		append(&t.nodes, Node_Data{})
		idx = u32(len(t.nodes) - 1)
	}
	d := &t.nodes[idx]
	gen := d.gen + 1
	if gen == 0 do gen = 1
	d^ = Node_Data{gen = gen, flags = {.Alive, .Dirty_Layout, .Dirty_Paint}, kind = kind, loc = loc}
	d.style.opacity = 1
	if tk, ok := kind.(Text_Kind); ok {
		d.kind = Text_Kind{str = strings.clone(tk.str, t.allocator), size = tk.size}
		d.access.role = .Text
	}
	return node_make(idx, gen)
}

// node_get resolves a handle. Returns nil for NODE_NONE, stale, or freed
// handles — callers may rely on that instead of checking validity first.
// The pointer is into the tree's own storage and is only good until the
// next node is made: hold the `Node` handle across a build, never this.
node_get :: proc(t: ^Tree, n: Node) -> ^Node_Data {
	idx := node_index(n)
	if idx == 0 || int(idx) >= len(t.nodes) do return nil
	d := &t.nodes[idx]
	if d.gen != node_gen(n) || .Alive not_in d.flags do return nil
	return d
}

node_valid :: proc(t: ^Tree, n: Node) -> bool { return node_get(t, n) != nil }

// node_append attaches `child` as the last child of `parent`.
node_append :: proc(t: ^Tree, parent, child: Node) {
	node_insert_before(t, parent, child, NODE_NONE)
}

// node_insert_before attaches `child` under `parent` immediately before
// `before` (NODE_NONE = append). A child that is already attached somewhere
// is detached first, so this also implements "move".
node_insert_before :: proc(t: ^Tree, parent, child, before: Node) {
	p := node_get(t, parent)
	c := node_get(t, child)
	if p == nil || c == nil || parent == child do return
	if c.parent != NODE_NONE do node_detach(t, child)
	c.parent = parent
	if before == NODE_NONE {
		c.prev = p.last
		c.next = NODE_NONE
		if p.last != NODE_NONE { node_get(t, p.last).next = child } else { p.first = child }
		p.last = child
	} else {
		b := node_get(t, before)
		if b == nil || b.parent != parent { node_insert_before(t, parent, child, NODE_NONE); return }
		c.prev = b.prev
		c.next = before
		if b.prev != NODE_NONE { node_get(t, b.prev).next = child } else { p.first = child }
		b.prev = child
	}
	mark_layout_dirty(t, parent)
	mark_layout_dirty(t, child)
}

// node_detach unlinks a node from its parent without freeing it.
node_detach :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil || d.parent == NODE_NONE do return
	p := node_get(t, d.parent)
	if d.prev != NODE_NONE { node_get(t, d.prev).next = d.next } else { p.first = d.next }
	if d.next != NODE_NONE { node_get(t, d.next).prev = d.prev } else { p.last = d.prev }
	t.damage_off = popup_holds(t, n) // a popup's surface presents whole
	damage_add(t, paint_bounds(d, focus_ring_look(&t.theme).overhang))
	if st, ok := t.anims[n]; ok && st.painted.w > 0 do damage_add(t, st.painted) // where it was last drawn, if it moved as it painted
	t.damage_off = false
	mark_layout_dirty(t, d.parent)
	d.parent, d.prev, d.next = NODE_NONE, NODE_NONE, NODE_NONE
}

// node_destroy frees a node and its whole subtree. Handles into it go stale.
node_destroy :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil do return
	node_detach(t, n)
	node_free_rec(t, n)
}

// node_forget_themes drops a node's popup theme and theme_area. Apart from
// node_free_rec, because removing from those maps hands back a whole Theme,
// which in a recursive frame would cost that much stack a level.
@(private)
node_forget_themes :: proc(t: ^Tree, n: Node) {
	delete_key(&t.popup_themes, n)
	delete_key(&t.theme_areas, n)
}

@(private)
node_free_rec :: proc(t: ^Tree, n: Node) {
	node_forget_themes(t, n)
	custom_forget(t, n)
	d := node_get(t, n)
	if d == nil do return
	if t.focus == n do t.focus = NODE_NONE
	delete_key(&t.anims, n)
	delete_key(&t.scrolls, n)
	delete_key(&t.overlay_rules, n)
	chart_free(t, n) // a chart's series and the line it was reading (widget_chart.odin)
	sparkline_free(t, n)
	lines_node_free(t, n) // …and a lines node's points (widget_lines.odin)
	term_free(t, n)
	delete_key(&t.reveals, n)
	graph_free(t, n) // …and a graph's nodes and wires (widget_graph.odin)
	delete_key(&t.chrome, n)
	delete_key(&t.chrome_btn, n)
	delete_key(&t.chrome_of, n)
	if ts, has_table := &t.tables[n]; has_table {
		table_state_destroy(ts)
		delete_key(&t.tables, n)
	}
	if vs, has_view := &t.icon_views[n]; has_view {
		delete(vs.cells)
		delete(vs.taken)
		delete(vs.grid.base)
		delete(vs.prev)
		delete_key(&t.icon_views, n)
	}
	delete_key(&t.lives, n)
	delete_key(&t.tree_views, n)
	delete_key(&t.tree_rows, n)
	delete_key(&t.tree_branches, n)
	if sp, has_split := &t.splits[n]; has_split {
		split_state_destroy(t, sp)
		delete_key(&t.splits, n)
	}
	if dt, has_drop := &t.drops[n]; has_drop {
		drop_target_destroy(t, dt)
		delete_key(&t.drops, n)
	}
	if rt, has_rest := &t.rests[n]; has_rest {
		rest_target_destroy(t, rt)
		delete_key(&t.rests, n)
	}
	if t.drag_over == n do t.drag_over = NODE_NONE
	if cs, has_choice := &t.choices[n]; has_choice {
		delete(cs.items)
		delete_key(&t.choices, n)
	}
	delete_key(&t.choice_of, n)
	delete_key(&t.pictures, n)
	delete_key(&t.canvases, n)
	delete_key(&t.button_marks, n)
	if u, ok := t.button_badges[n]; ok {
		delete(u.badge.text, t.allocator)
		delete(u.shown.text, t.allocator)
		delete_key(&t.button_badges, n)
	}
	delete_key(&t.button_progress, n)
	delete_key(&t.icon_toggles, n)
	if ps, has := &t.pages[n]; has {
		delete(ps.openers)
		delete_key(&t.pages, n)
	}
	if use, has := t.theme_icons[n]; has {
		theme_icon_use_free(t, use)
		delete_key(&t.theme_icons, n)
	}
	delete_key(&t.popups, n)
	if t.pointer_scope == n do t.pointer_scope = NODE_NONE
	if sp, has_spin := t.spins[n]; has_spin {
		spin_state_free(t, sp)
		delete_key(&t.spins, n)
	}
	delete_key(&t.spin_of, n)
	if cs, has_cal := &t.calendars[n]; has_cal {
		delete(cs.cells)
		delete_key(&t.calendars, n)
	}
	delete_key(&t.cal_day_of, n)
	if ps, has_picker := t.pickers[n]; has_picker {
		picker_state_free(t, ps)
		delete_key(&t.pickers, n)
	}
	delete_key(&t.picker_of, n)
	delete_key(&t.times, n)
	delete_key(&t.time_seg_of, n)
	delete_key(&t.editor_ctl_of, n)
	delete_key(&t.md_copy_of, n)
	delete_key(&t.sel_scopes, n)
	delete_key(&t.editor_owned, n)
	delete_key(&t.area_of_frame, n)
	delete_key(&t.field_of_time, n)
	delete_key(&t.field_of_cal, n)
	if ts, has_page := &t.typesets[n]; has_page {
		typeset_view_state_free(t, ts)
		delete_key(&t.typesets, n)
	}
	if ss, has_styled := &t.styled[n]; has_styled {
		styled_state_destroy(t, ss)
		delete_key(&t.styled, n)
	}
	if as, has_area := &t.areas[n]; has_area {
		text_area_state_destroy(t, as)
		delete_key(&t.areas, n)
	}
	if mv, has_md := &t.md_views[n]; has_md {
		md_view_images_free(t, mv)
		md_view_cache_clear(t, mv)
		delete(mv.blocks)
		delete(mv.marks)
		delete(mv.words)
		delete_key(&t.md_views, n)
	}
	if st, has := &t.sliders[n]; has do slider_state_free(t, st)
	delete_key(&t.sliders, n)
	text_input_free(t, n) // text_input hook
	ch := d.first
	for ch != NODE_NONE {
		next := node_get(t, ch).next
		node_free_rec(t, ch)
		ch = next
	}
	if .Layer in d.flags {
		if l, ok := t.layers[n]; ok {
			delete(l.cmds)
			delete_key(&t.layers, n)
		}
	}
	node_free_owned(t, d)
	d.flags -= {.Alive}
	d.first, d.last = NODE_NONE, NODE_NONE
	append(&t.free, node_index(n))
}

@(private)
node_free_owned :: proc(t: ^Tree, d: ^Node_Data) {
	if tk, ok := d.kind.(Text_Kind); ok {
		// A secret is overwritten before the memory goes back.
		if tk.sensitive {
			secret_scrub_bytes(transmute([]u8)tk.str)
			if len(tk.display) > 0 do secret_scrub_bytes(transmute([]u8)tk.display)
		}
		delete(tk.str, t.allocator)
		if len(tk.display) > 0 do delete(tk.display, t.allocator)
		d.kind = Text_Kind{}
	}
	if d.access.name_owned    do delete(d.access.name, t.allocator)
	if d.access.desc_owned    do delete(d.access.describe, t.allocator)
	d.access.name, d.access.describe = "", ""
	d.access.name_owned, d.access.desc_owned = false, false
}

// node_first / node_next iterate children: `for c := node_first(t, p); c != NODE_NONE; c = node_next(t, c)`.
node_first :: proc(t: ^Tree, p: Node) -> Node { d := node_get(t, p); return d.first if d != nil else NODE_NONE }
node_next  :: proc(t: ^Tree, n: Node) -> Node { d := node_get(t, n); return d.next  if d != nil else NODE_NONE }
node_parent :: proc(t: ^Tree, n: Node) -> Node { d := node_get(t, n); return d.parent if d != nil else NODE_NONE }

// node_within reports whether `n` is `ancestor` or one of its descendants.
node_within :: proc(t: ^Tree, n, ancestor: Node) -> bool {
	for cur := n; cur != NODE_NONE; cur = node_get(t, cur).parent {
		if cur == ancestor do return true
		if node_get(t, cur) == nil do return false
	}
	return false
}

// node_child_count counts a node's children.
node_child_count :: proc(t: ^Tree, p: Node) -> (n: int) {
	for c := node_first(t, p); c != NODE_NONE; c = node_next(t, c) do n += 1
	return
}

// ---------------------------------------------------------------- dirtying

// mark_layout_dirty flags `n` and its ancestors up to (and including) the
// nearest relayout boundary, which is queued for the layout pass. Paint is
// dirtied too, since a size change repaints.
mark_layout_dirty :: proc(t: ^Tree, n: Node) {
	if node_get(t, n) == nil do return
	layout_dirty(t, n)
	if !popup_holds(t, n) do t.layout_here = true // what a popup lays out is its own surface's: a bar measuring its length needn't look again (fit_sync)
	mark_paint_dirty(t, n)
}

// layout_dirty flags `n` and its ancestors up to a relayout boundary for
// layout without repainting anything: what moves repaints as layout places
// it (a measurement that leaves everything where it was repaints nothing).
@(private)
layout_dirty :: proc(t: ^Tree, n: Node) {
	cur := n
	for cur != NODE_NONE {
		d := node_get(t, cur)
		if d == nil do return
		d.flags += {.Dirty_Layout}
		if .Relayout_Boundary in d.flags || d.parent == NODE_NONE {
			if .Dirty_Root not_in d.flags {
				d.flags += {.Dirty_Root}
				append(&t.dirty_roots, cur)
			}
			break
		}
		cur = d.parent
	}
}

// mark_paint_dirty flags `n` for re-emission and its owning layer for
// rebuild. Cheap; safe to call redundantly.
mark_paint_dirty :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil do return
	d.flags += {.Dirty_Paint}
	d.flags -= {.Blink_Only} // something besides a blink: all of it is damage
	cur := n
	for cur != NODE_NONE {
		ld := node_get(t, cur)
		if ld == nil do return
		if .Layer in ld.flags {
			ld.flags += {.Layer_Dirty}
			return
		}
		cur = ld.parent
	}
}

// mark_blink_dirty repaints `n` for its caret's blink alone: what it draws
// is re-emitted, but only the caret is presented, unless something else
// marked it this frame too.
@(private)
mark_blink_dirty :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil do return
	narrow := .Dirty_Paint not_in d.flags || .Blink_Only in d.flags
	mark_paint_dirty(t, n)
	if narrow do d.flags += {.Blink_Only}
}

// mark_host_layer_dirty rebuilds the list that decides whether `n` is drawn
// at all. A node with its own layer appears in its host layer as one
// Draw_Layer command, appended only while it is shown and inside the clip,
// so hiding, showing, moving or resizing it must rebuild the host's list,
// not only its own; otherwise its layer repaints and nothing draws it.
@(private)
mark_host_layer_dirty :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil || .Layer not_in d.flags do return
	for cur := d.parent; cur != NODE_NONE; {
		p := node_get(t, cur)
		if p == nil do return
		if .Layer in p.flags {
			p.flags += {.Layer_Dirty}
			return
		}
		cur = p.parent
	}
}

@(private)
damage_add :: proc(t: ^Tree, r: Rect) {
	if r.w <= 0 || r.h <= 0 do return
	if t.damage_off {
		t.damage_elsewhere = true
		return
	}
	append(&t.damage, r)
}

// ---------------------------------------------------------------- setters

// set_text replaces a Text node's string. No-op (and no dirtying) when the
// text is unchanged, so builders can call it unconditionally.
set_text :: proc(t: ^Tree, n: Node, s: string) {
	d := node_get(t, n)
	if d == nil do return
	tk, ok := d.kind.(Text_Kind)
	if !ok do return
	if tk.str == s do return
	// A secret is overwritten before it is freed, or the characters stay
	// in freed memory until something else lands there.
	if tk.sensitive do secret_scrub_bytes(transmute([]u8)tk.str)
	delete(tk.str, t.allocator)
	tk.str = strings.clone(s, t.allocator)
	if len(tk.display) > 0 {
		delete(tk.display, t.allocator)
		tk.display = ""
	}
	d.kind = tk
	mark_layout_dirty(t, n) // text size may change
}

// set_sensitive marks a text node's string a secret shown on purpose (a
// revealed key, a recovery phrase). The tree's copy is overwritten before
// it is freed, when the text is replaced and when the node goes; and the
// accessibility bridge gets the node without its content, since anything
// on the session accessibility bus can read node text. Nothing is hidden
// on screen. Use `text(sensitive = true)`, or this on a node built
// another way.
set_sensitive :: proc(t: ^Tree, n: Node, on: bool) {
	d := node_get(t, n)
	if d == nil do return
	tk, ok := &d.kind.(Text_Kind)
	if !ok || tk.sensitive == on do return
	tk.sensitive = on
	a11y_text_changed(t, n)
}

// a11y_text_changed tells the bridge a node's published text may differ.
@(private)
a11y_text_changed :: proc(t: ^Tree, n: Node) {
	mark_paint_dirty(t, n)
}

set_hidden :: proc(t: ^Tree, n: Node, hidden: bool) {
	d := node_get(t, n)
	if d == nil || (.Hidden in d.flags) == hidden do return
	if hidden { d.flags += {.Hidden} } else { d.flags -= {.Hidden} }
	t.damage_off = popup_holds(t, n) // a popup's surface presents whole
	damage_add(t, d.abs)
	t.damage_off = false
	mark_paint_dirty(t, n)      // its own layer holds nothing while it is hidden: fill it again when it is shown
	mark_host_layer_dirty(t, n) // …and a layer of its own is drawn by the one that holds it, which must hear too
	// Hiding is the parent's arrangement: only the parent can give the
	// child room again. Marking a child that is its own relayout boundary
	// (a scroll) would re-lay it inside the zero size it was left with, and
	// it would never come back.
	mark_layout_dirty(t, d.parent if d.parent != NODE_NONE else n)
}

// set_hit_children makes a container's own space let the pointer through,
// so only its children are hit: for a control centred by ordinary layout
// over something that takes the pointer itself (a toolbar over a canvas),
// where the row holding it would otherwise take every press across its
// width. Unlike `Hit_Transparent` and `inert`, the children stay hittable;
// it is how the overlay root behaves. Hit-testing only: the node still lays
// out, draws and is in the accessibility tree, and a child's events still
// bubble through it, so an `on_click` on it would fire from a child's
// click. It stays until changed: pass it every build.
set_hit_children :: proc(t: ^Tree, n: Node, on: bool) {
	d := node_get(t, n)
	if d == nil do return
	if on { d.flags += {.Hit_Children} } else { d.flags -= {.Hit_Children} }
}

// set_invalid marks a form control's value as wrong, until changed: a field
// draws its frame in the theme's danger colour, and Linux and Windows readers
// are told (AT-SPI's invalid entry, UIA's IsDataValidForForm). macOS's
// accessibility protocol has no such property, so say why with
// `set_describe` as well, which every reader speaks with the field. On a
// field built of parts (a number field, a search field, a rich editor) it
// reaches the part that edits, where a reader lands.
set_invalid :: proc(t: ^Tree, n: Node, invalid: bool) {
	form_state(t, n, .Invalid, invalid)
}

// set_required marks a form control as one that must be filled in, until
// changed: readers on all three platforms are told. It reaches a field's
// editing part as set_invalid does, and changes nothing drawn: say so in the
// label too.
set_required :: proc(t: ^Tree, n: Node, required: bool) {
	form_state(t, n, .Required, required)
}

@(private)
form_state :: proc(t: ^Tree, n: Node, st: A11y_State, on: bool) {
	apply :: proc(t: ^Tree, m: Node, st: A11y_State, on: bool) {
		d := node_get(t, m)
		if d == nil do return
		if on { d.access.states += {st} } else { d.access.states -= {st} }
		mark_paint_dirty(t, m)
	}
	apply(t, n, st, on)
	if n in t.inputs || n in t.areas do return
	// a field built of parts: its editing part, a level or two in
	d := node_get(t, n)
	if d == nil do return
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if c in t.inputs || c in t.areas {
			apply(t, c, st, on)
			return
		}
		for g := node_get(t, c).first; g != NODE_NONE; g = node_get(t, g).next {
			if g in t.inputs || g in t.areas {
				apply(t, g, st, on)
				return
			}
		}
	}
}

// set_tab_stop takes a focusable `n` out of the Tab order (stop = false)
// or puts it back: a press still focuses it and a screen reader still reaches
// it, as Qt's click focus and HTML's tabindex=-1 do. For a form whose
// keyboard path is its fields alone. It stays until changed.
set_tab_stop :: proc(t: ^Tree, n: Node, stop: bool) {
	d := node_get(t, n)
	if d == nil do return
	if stop { d.flags -= {.Pointer_Only_Focus} } else { d.flags += {.Pointer_Only_Focus} }
}

// set_inert makes `n`'s subtree draw as usual but take no part in
// interaction, as HTML's `inert` does: hit testing passes through it to the
// nearest ancestor that isn't inert, so hover, press, click, right-click,
// the wheel and tooltips go there; Tab skips its controls and assistive
// technology doesn't see them. Focus inside it moves to the nearest
// focusable ancestor, or goes. For a shell's edit mode, which shows
// applets as they look and picks each up whole. It stays until changed:
// pass it every build. Another program's applet in an `applet_slot` inside
// it still takes the pointer: the applet protocol cannot pass it on.
set_inert :: proc(t: ^Tree, n: Node, inert: bool) {
	for r, i in t.roll_inert do if r == n { // the app says now, not a rolled-up window
		unordered_remove(&t.roll_inert, i)
		break
	}
	d := node_get(t, n)
	if d == nil || (.Inert in d.flags) == inert do return
	if inert { d.flags += {.Inert} } else { d.flags -= {.Inert} }
	if !inert || t.focus == NODE_NONE do return
	within := false
	for cur := t.focus; cur != NODE_NONE && !within; {
		cd := node_get(t, cur)
		if cd == nil do break
		within = cur == n
		cur = cd.parent
	}
	if !within do return
	to := NODE_NONE
	for cur := d.parent; cur != NODE_NONE; {
		cd := node_get(t, cur)
		if cd == nil do break
		if focusable(t, cur) {
			to = cur
			break
		}
		cur = cd.parent
	}
	set_focus(t, to, t.focus_visible)
}

set_style :: proc(t: ^Tree, n: Node, s: Style) {
	d := node_get(t, n)
	if d == nil || d.style == s do return
	d.style = s
	mark_paint_dirty(t, n)
}

set_layout :: proc(t: ^Tree, n: Node, l: Layout_Props) {
	d := node_get(t, n)
	if d == nil || d.layout == l do return
	d.layout = l
	mark_layout_dirty(t, n)
}

// set_layer turns a node into (or back from) a layer with its own cached
// draw list.
set_layer :: proc(t: ^Tree, n: Node, layer: bool) {
	d := node_get(t, n)
	if d == nil || (.Layer in d.flags) == layer do return
	if layer {
		d.flags += {.Layer}
		t.layers[n] = Layer{cmds = make([dynamic]Draw_Cmd, t.allocator)}
	} else {
		d.flags -= {.Layer}
		if l, ok := t.layers[n]; ok { delete(l.cmds); delete_key(&t.layers, n) }
	}
	mark_paint_dirty(t, n)
	if d.parent != NODE_NONE do mark_paint_dirty(t, d.parent)
}

// Clipboard is the text clipboard hook the platform installs on the tree so
// widgets (text input) can copy and paste without knowing the backend.
Clipboard :: struct {
	user:     rawptr,
	get:      proc(user: rawptr, allocator := context.allocator) -> (string, bool),
	set:      proc(user: rawptr, text: string) -> bool,
	types:    proc(user: rawptr, allocator := context.allocator) -> []string,                     // optional: what is offered now
	get_data: proc(user: rawptr, mime: string, allocator := context.allocator) -> ([]u8, bool), // optional: one form of it
	set_data: proc(user: rawptr, items: []Clip_Item) -> bool,                                    // optional: several forms at once
	primary_get: proc(user: rawptr, allocator := context.allocator) -> (string, bool),          // optional: the primary selection (a middle click's paste)
	primary_set: proc(user: rawptr, text: string) -> bool,                                      // optional
}

// Timer is a pending wake-up: repaint `node` (or just wake) at `at_ms`.
// `blink`: every ask it holds is a caret's blink, so only the caret repaints.
Timer :: struct {
	at_ms: f64,
	node:  Node,
	blink: bool,
}

// tree_wake_at asks for a wake-up at `at_ms` on the tree clock and, when it
// fires (in anim_tick), a repaint of `node`. Duplicate requests for the same
// node keep the earlier time.
tree_wake_at :: proc(t: ^Tree, at_ms: f64, node: Node = NODE_NONE) {
	wake_at(t, at_ms, node, false)
}

// wake_at is tree_wake_at, saying whether the ask is a caret's blink. A
// node has one timer, so one non-blink ask makes its next firing a whole
// repaint.
@(private)
wake_at :: proc(t: ^Tree, at_ms: f64, node: Node, blink: bool) {
	for &tm in t.timers {
		if tm.node == node {
			if at_ms < tm.at_ms do tm.at_ms = at_ms
			tm.blink = tm.blink && blink
			t.wake_at_ms = min(t.wake_at_ms, at_ms) if t.wake_at_ms > 0 else at_ms
			return
		}
	}
	append(&t.timers, Timer{at_ms = at_ms, node = node, blink = blink})
	if t.wake_at_ms == 0 || at_ms < t.wake_at_ms do t.wake_at_ms = at_ms
}

// fire_timers runs every timer due at `now_ms`: the node that asked is
// paint-dirtied. Returns true if any fired. Called by anim_tick.
@(private)
fire_timers :: proc(t: ^Tree, now_ms: f64) -> (fired: bool) {
	next: f64 = 0
	for i := 0; i < len(t.timers); {
		tm := t.timers[i]
		if tm.at_ms <= now_ms {
			if tm.node != NODE_NONE {
				if tm.blink { mark_blink_dirty(t, tm.node) } else { mark_paint_dirty(t, tm.node) }
			}
			unordered_remove(&t.timers, i)
			fired = true
			continue
		}
		if next == 0 || tm.at_ms < next do next = tm.at_ms
		i += 1
	}
	t.wake_at_ms = next
	return
}

@(private)
diag :: proc(t: ^Tree, loc: runtime.Source_Code_Location, msg: string) {
	append(&t.diags, Diag{msg = strings.clone(msg, t.allocator), loc = loc})
}
