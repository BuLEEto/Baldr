package baldr

import "core:strings"

import "base:runtime"
import "core:fmt"
import "core:hash"
import "baldr:platform"

// Scoped builders. A view proc calls builders in order; containers open a
// scope that `end` closes. Each call reconciles against the current parent's
// child cursor — reuse the node in place if kind (and key) match, move a
// keyed node into position, or create — so a view re-run touches only what
// changed and never allocates a description tree.

// Ev is what a payload handler receives: the new value, the emitting node,
// and the app-supplied tag (how a row says which item it was).
Ev :: struct($T: typeid) {
	value: T,
	tag:   u64,
	node:  Node,
}

// Handler is either a plain message or a proc that builds one from an Ev.
// One builder per widget; both forms go through the same parameter.
//
// `on_x = msg if cond else nil` means no handler. Odin brings both arms of
// a ternary to one type, so that `nil` is a nil procedure inside the union,
// not an empty union, and `h == nil` is false. Ask `handler_live(h)`
// instead of comparing to nil: it treats both as "nothing was given".
Handler :: union($Msg, $T: typeid) {
	Msg,
	proc(Ev(T)) -> Msg,
}

// Space_Token is the theme's spacing scale, from `none` to `xxxl`: the sizes
// gaps, padding and margins come in, resolved through `Theme.space` so one
// theme sets the rhythm of every widget.
Space_Token :: enum u8 { none, xxs, xs, sm, md, lg, xl, xxl, xxxl }
// Space is a gap, padding or margin: either a token from the theme's spacing
// scale or a raw number of logical pixels. Prefer the token — `gap = .md`
// stays right when the theme or its density changes, `gap = f32(7)` does not.
Space :: union { Space_Token, f32 }

space_px :: proc "contextless" (th: ^Theme, s: Space) -> f32 {
	switch v in s {
	case Space_Token: return th.space[v]
	case f32:         return v
	}
	return 0
}

@(private)
Scope :: struct {
	node:       Node,
	cursor:     Node, // next child expected at this position
	loc:        runtime.Source_Code_Location,
	redirect:   bool, // a temporary scope on the overlay root: closing it removes nothing
	extra_pops: u8,   // scopes to close along with this one (overlay builders open several)
	list:       bool, // a virtual list: end emits the tail spacer; rows must be keyed
	theme_pop:  bool, // a glass popup's scope: closing it gives the tree its theme back (glass.odin)
	theme_area: bool, // …and this one is an app's own theme (theme_area), which a popup inside it steps back out of
}

// Ui is the per-app builder state: the tree plus message plumbing. `Msg` is
// the app's message type; layout/paint/a11y live on the embedded Tree and are
// compiled once.
Ui :: struct($Msg: typeid) {
	using tree: Tree,
	msgs:       [dynamic]Msg,
	clicks:     map[Node]Msg,
	on_bool:    map[Node]Handler(Msg, bool), // checkbox / toggle
	on_f32:     map[Node]Handler(Msg, f32),  // slider
	slider_commit: map[Node]Handler(Msg, f32), // slider: the value let go of, or stepped to by a key (on_commit)
	on_int:     map[Node]Handler(Msg, int),  // tabs, segmented, select — value = the node's tag
	dismiss:    map[Node]Dismiss_Rule(Msg),  // open overlays → how an outside press / Escape closes them
	open:       map[Node]bool,               // internal open state of self-managed popups (select)
	closes:     map[Node]Node,               // option row → the select it closes when activated
	needs_rebuild: bool,                     // internal state changed (a select opened): re-run view
	// build_pending: `update` ran and a view build follows this batch. Until
	// it does, a node may still point at app memory the app has since freed
	// (a Document), so `ime_sync`, `rich_tick` and `primary_sync` wait;
	// the syncs run after the build (ui_after_build).
	build_pending: bool,
	rebuild_from:  runtime.Source_Code_Location, // what first asked for it since the last build (ask_rebuild; BALDR_DEBUG_EVENTS says)
	focus_before_modal: Node,                // restored when the modal dialog closes
	pending_focus: Node,                     // focus the first focusable inside this node after the view finishes
	// The `focus` command's ask: the reconciliation key of the widget
	// `update` wants the keyboard in, and how many builds have looked for
	// it. Kept for a few builds because the command usually causes the
	// screen holding the widget to be built.
	focus_want:  u64,
	focus_tries: int,
	// The `reveal_key` / `reveal_index` and `hold` commands' asks, until the
	// views they name take them (reveal_cmd.odin). A set, not a slot: two
	// reveals in one update are two asks. Each carries its own age.
	reveal_asks:  [dynamic]Reveal_Ask,
	hold_asks:    [dynamic]Hold_Ask,
	view_inner:   int, // >0 while the toolkit builds a view of its own, so an app's ask cannot land in it
	entered_keyboard: bool,                  // the keyboard just arrived at a panel with nothing focused: land on its first control, ring showing
	release_keyboard: bool,                  // Escape in a bar or applet: the run loop asks the compositor to take the keyboard back (panel_escape)
	pointer_took_focus: bool,                // a press decided focus this batch: the keyboard arriving with it must not land on anything
	themes_saved: [dynamic]Theme,            // the themes glass popups' scopes replaced while they build
	theme_areas_open: int,                   // theme_area scopes open right now, so a popup knows it is inside one
	theme_outside:    Theme,                 // …and what the window's own theme is, to build that popup with
	lists:      map[Node]List_State,         // virtual lists: which rows are built
	// emoji_picker's state and its parts' wiring. The cells and strips are
	// plain nodes, so what each one means is kept here, not in their tag.
	emoji:       map[Node]Emoji_Picker_State, // the picker itself
	emoji_cells: map[Node]Emoji_Cell_Ref,     // a cell -> its picker and index
	emoji_grids: map[Node]Node,               // the grid -> its picker
	emoji_jumps: map[Node]Emoji_Jump_Ref,     // a group button -> its picker and group
	emoji_tones: map[Node]Emoji_Tone_Ref(Msg),// a tone swatch -> what to send
	emoji_picks: map[Node]Handler(Msg, string), // the grid -> the app's on_pick
	emoji_fields: map[Node]Node,              // the search field -> its picker
	search_clears: map[Node]Search_Clear_Ref(Msg), // a search_field's cross -> the field it empties
	rows:       map[Node]Row_Ref,            // table row node → table + index
	on_activate: map[Node]Handler(Msg, int), // tables: Enter / double-click on a row
	on_row_click: map[Node]Handler(Msg, int), // tables, icon views: a plain primary click on a row
	col_resize: Col_Resize,                  // header divider being dragged
	col_move:   Col_Move,                    // header cell being dragged to a new slot
	col_hover:  Col_Ref,                     // header divider under the pointer (cursor + guide)
	menu_bars:  map[Node]Menu_Bar_State,     // menu bars: titles and which menu is open
	marquee:    Node,                        // table or icon view whose rubber band is being dragged
	band_pending: Band_Pending,              // a press on a row's blank part: becomes a band if it moves, a click if not
	on_context: map[Node]Handler(Msg, int),  // tables / icon views: right-click or Menu key (item index, -1 = background)
	context_pos: [2]f32,                     // where the latest context request happened (context_menu opens there)
	context_clicks: map[Node]Msg,            // buttons: what a right-click or the Menu key sends (context_pos recorded first)
	editor_contexts: map[Node]Handler(Msg, Editor_Context), // editors (by area): a right-click or the Menu key in the text
	complete_asks:   map[Node]Handler(Msg, Complete_Ask),   // editors (by area) whose completion answers later (editor_complete.odin)
	word_clicks:     map[Node]Handler(Msg, Pos),            // code editors (by area): Ctrl+click on a word
	menu_leads:      [dynamic]Menu_Lead,                    // this build's menu rows, lined up at its end (menu_leads_settle)
	menu_slot:       map[Node]bool,                         // menus (by popup) whose rows keep a leading slot
	paste_others:    map[Node]Handler(Msg, Paste_Other),    // editors and fields: a paste that brought no text, but a picture or files
	md_links:        map[Node]Handler(Msg, string),         // markdown views: a link the person pressed, by its target
	md_images:       map[Node]Handler(Msg, string),         // …and a picture in a reply, by its src: the app opens it its own way
	on_scroll:  map[Node]Scroll_Use(Msg),    // buttons: a wheel or touchpad scroll over them, with the part of a step left over
	button_opts: map[Node]Button_Opts,       // buttons: what button_options set
	slots:      map[Node]Slot_Use(Msg),      // applet slots: what they report goes to (applet_slot.odin)
	tips:       map[Node]struct{},           // nodes with a tooltip (text lives in Access.describe)
	tip_anchor: Node,                        // tooltip currently shown for this node (NONE = none)
	tip_hover:  Node,                        // hover candidate being timed
	tip_mark:   int,                         // the mark (index in its area's marks) the tooltip is for; -1 = a node's
	tip_mark_hover: int,                     // the mark being timed
	tip_since:  f64,                         // when tip_hover started
	tip_block:  Node,                        // no tooltip for this node until hover/focus changes (a press hid it)
	tip_focus:  Node,                        // last focus seen by tooltip_tick
	built_class: Size_Class,                 // size class the latest view was built for
	read_viewport: bool,                     // the latest view asked viewport(): a resize builds it again
	finger:     Touch_State,                 // the touch sequence being tracked (touch.odin); Tree.touch says a touchscreen exists
	comp_rev:   map[Node]u64,
	input_handlers: map[Node]Text_Handlers(Msg), // text_input hook: on_change / on_submit per field
	split_change: map[Node]Handler(Msg, f32), // split panes: on_change per split (size of the sized pane)
	split_close: map[Node]Msg,                // split panes: on_close (Back / Escape leaves a collapsed split's detail pane)
	drags:      map[Node]Drag_Source,         // drag sources (dnd.odin)
	grid_drags: map[Node]Grid_Drag,           // tables / icon views whose rows drag and take drops
	chip_close: map[Node]Msg,                 // removable chips: the message Backspace / Delete sends
	toast_close: map[Node]Msg,                // toasts: the message the timer / × sends
	toast_deadline: map[Node]f64,             // toasts: when each closes on its own (tree clock)
	toast_count: int,                         // toasts built this view (stacking)
	on_number:  map[Node]Handler(Msg, f32),   // number inputs: on_change per outer node
	spin_step:  map[Node]Spin_Step,           // number inputs' − / + buttons
	spin_focused: Node,                       // number field that had focus last (commit on blur)
	on_date:    map[Node]Handler(Msg, Date),  // date pickers: on_change
	cal_nav:    map[Node]Cal_Nav,             // date pickers' ‹ › buttons
	on_color:   map[Node]Handler(Msg, Color), // colour pickers: on_change
	on_time:    map[Node]Handler(Msg, Time_Of_Day), // time pickers: on_change
	on_link:    map[Node]Handler(Msg, string),      // rich text: a link followed (Ctrl+click)
	time_scrub: Time_Scrub,                   // a time segment being dragged
	picker_focused: Node,                     // colour picker hex field that had focus last (commit on blur)
	on_drop:    map[Node]Handler(Msg, Drop),  // drop targets' handlers
	drag:       Drag_State,                   // the drag in progress
	split_hover: Node,                       // split whose divider zone is under the pointer
	split_drag:  Node,                       // split whose divider is being dragged
	shortcuts:  [dynamic]Shortcut(Msg),      // the latest view's window-level key bindings (shortcut.odin)
	capture:    Key_Capture(Msg),            // the latest view's key capture, and whether it asked for the desktop's shortcuts to be held off (key_capture.odin)
	keep_awake: bool,                        // …and whether it asked for the screen to stay on (keep_awake.odin)
	submenus:   map[Node]Node,               // submenu rows → the popup while open, NODE_NONE closed (overlay.odin)
	zooms:      map[Node]Handler(Msg, f32),  // nodes that take Ctrl + wheel (zoom.odin)
	chart_select: map[Node]Handler(Msg, Chart_Hit), // charts: the point the reader picked (widget_chart.odin)
	graph_event:  map[Node]Handler(Msg, Graph_Event), // node graphs: what the reader did to one (widget_graph.odin)
	chrome_close: map[Node]Msg,              // a title bar whose close the app wants to hear about (widget_chrome.odin)
	on_place:     map[Node]Handler(Msg, Place_Drop), // a placed icon view: where a drag put its items (widget_icon_view.odin)
	hovers:     map[Node]Handler(Msg, bool), // nodes that hear the pointer resting on them (hoverable, hover.odin)
	hovering:   [dynamic]Node,               // …the ones it rests on now, outermost first
	tracks:     map[Node]Track(Msg),         // nodes that hear where the pointer is over them (pointer_track.odin)
	on_focus:   map[Node]Handler(Msg, Focus_At), // nodes that hear the keyboard arrive and leave (focus_track, focus.odin)
	focus_sent: Node,                        // which node `on_focus` was last reported for, so a move is reported once
	pointer_areas: map[Node]Pointer_Area(Msg), // plain nodes that take the wheel, a double-click and a cursor (pointer_area.odin)
	sample_areas: map[Node]Sample_Area(Msg), // nodes that hear every pointer and pen sample (pointer_samples.odin)
	term_handlers: map[Node]Term_Handlers(Msg), // terminals: what their keys, text and size go to (widget_terminal.odin)
	term_pending: Term_Pending,             // a key a terminal hears once its text (if any) has come
	key_holds:  map[Node]Key_Hold_Area(Msg), // nodes that hear chosen keys held and let go (key_hold.odin)
	custom_keys: map[Node]Custom_Keys(Msg), // custom widgets' keys while focused (widget_custom.odin)
	option_of:  map[Node]Node,               // a select's option → the select: a pick is sent from there, with its tag
	dnd:        Dnd_Hook,                    // the platform's cross-app drag hooks; zero in headless tests
	edits:      map[Node]Edit_Handlers(Msg), // editors standing in for labels (widget_inline_edit.odin)
	edit_docs:  map[Node]^Document,          // …the documents the wrapping ones hold, by their card (inline_edit_over), the toolkit's to free
	on_edit_cell: map[Node]Handler(Msg, Cell_Ref), // tables: F2 / a slow click asks for a cell to edit
	on_edit:    map[Node]Handler(Msg, int),  // icon views (index) and trees (tag): the same
	edit_pending: Edit_Pending,              // a slow second click being timed
	on_drag_out: map[Node]Handler(Msg, Drop), // drag sources (and views, for their rows): a drag that left the window was dropped elsewhere
	drag_out:   Handler(Msg, Drop),          // the drag in progress's on_drag_out
	crumbs:     map[Node]f32,                // breadcrumbs: the room each was built for (a change rebuilds)
	middle_clicks: map[Node]Msg,             // nodes a middle-click reaches (tree items, buttons)
	double_clicks: map[Node]Msg,             // clickables that answer a double-click as well
	on_drag_over:  map[Node]Handler(Msg, Drag_Over), // drop targets that want telling where a drag is over them
	on_drag_rest:  map[Node]Handler(Msg, Drag_Rest), // nodes that want telling a drag has rested on them
	click_pairs:   map[Node]Click_Pair,      // …and when and where each last took one
	type_ahead: Type_Ahead,                  // what was typed into a focused table / icon view (type_ahead.odin)
	sub_hover:  Node,                        // menu row the pointer rests on, being timed
	sub_since:  f64,
	sub_acted:  Node,                        // the row sub_hover already opened / closed siblings for
	sub_kbd:    Node,                        // submenu row opened from the keyboard: focus goes into its popup
	scopes:     [dynamic]Scope,
	top_closed: [2]runtime.Source_Code_Location, // the last outermost scope an end closed: its opener, that end
	epoch:      u32,
	building:   bool,
	pointer:    Pointer,
	surface:    Surface_Info,                // which surface this tree is (tag, kind, glass); set by run
}

ui_init :: proc(ui: ^Ui($Msg), allocator := context.allocator) {
	tree_init(&ui.tree, allocator)
	ui.msgs = make([dynamic]Msg, allocator)
	ui.shortcuts = make([dynamic]Shortcut(Msg), allocator)
	ui.submenus = make(map[Node]Node, allocator)
	ui.zooms = make(map[Node]Handler(Msg, f32), allocator)
	ui.hovers = make(map[Node]Handler(Msg, bool), allocator)
	ui.hovering = make([dynamic]Node, allocator)
	ui.tracks = make(map[Node]Track(Msg), allocator)
	ui.on_focus = make(map[Node]Handler(Msg, Focus_At), allocator)
	ui.pointer_areas = make(map[Node]Pointer_Area(Msg), allocator)
	ui.sample_areas = make(map[Node]Sample_Area(Msg), allocator)
	ui.term_handlers = make(map[Node]Term_Handlers(Msg), allocator)
	ui.key_holds = make(map[Node]Key_Hold_Area(Msg), allocator)
	ui.custom_keys = make(map[Node]Custom_Keys(Msg), allocator)
	ui.option_of = make(map[Node]Node, allocator)
	ui.edits = make(map[Node]Edit_Handlers(Msg), allocator)
	ui.edit_docs = make(map[Node]^Document, allocator)
	ui.on_edit_cell = make(map[Node]Handler(Msg, Cell_Ref), allocator)
	ui.on_edit = make(map[Node]Handler(Msg, int), allocator)
	ui.on_drag_out = make(map[Node]Handler(Msg, Drop), allocator)
	ui.crumbs = make(map[Node]f32, allocator)
	ui.middle_clicks = make(map[Node]Msg, allocator)
	ui.sub_hover, ui.sub_acted, ui.sub_kbd = NODE_NONE, NODE_NONE, NODE_NONE
	ui.clicks = make(map[Node]Msg, allocator)
	ui.on_bool = make(map[Node]Handler(Msg, bool), allocator)
	ui.on_f32 = make(map[Node]Handler(Msg, f32), allocator)
	ui.slider_commit = make(map[Node]Handler(Msg, f32), allocator)
	ui.on_int = make(map[Node]Handler(Msg, int), allocator)
	ui.dismiss = make(map[Node]Dismiss_Rule(Msg), allocator)
	ui.open = make(map[Node]bool, allocator)
	ui.closes = make(map[Node]Node, allocator)
	ui.tip_mark, ui.tip_mark_hover = -1, -1
	ui.tips = make(map[Node]struct{}, allocator)
	ui.lists = make(map[Node]List_State, allocator)
	ui.rows = make(map[Node]Row_Ref, allocator)
	ui.on_activate = make(map[Node]Handler(Msg, int), allocator)
	ui.on_row_click = make(map[Node]Handler(Msg, int), allocator)
	ui.on_context = make(map[Node]Handler(Msg, int), allocator)
	ui.context_clicks = make(map[Node]Msg, allocator)
	ui.editor_contexts = make(map[Node]Handler(Msg, Editor_Context), allocator)
	ui.complete_asks = make(map[Node]Handler(Msg, Complete_Ask), allocator)
	ui.word_clicks = make(map[Node]Handler(Msg, Pos), allocator)
	ui.menu_leads = make([dynamic]Menu_Lead, allocator)
	ui.menu_slot = make(map[Node]bool, allocator)
	ui.paste_others = make(map[Node]Handler(Msg, Paste_Other), allocator)
	ui.md_links = make(map[Node]Handler(Msg, string), allocator)
	ui.md_images = make(map[Node]Handler(Msg, string), allocator)
	ui.on_scroll = make(map[Node]Scroll_Use(Msg), allocator)
	ui.button_opts = make(map[Node]Button_Opts, allocator)
	ui.slots = make(map[Node]Slot_Use(Msg), allocator)
	ui.menu_bars = make(map[Node]Menu_Bar_State, allocator)
	ui.comp_rev = make(map[Node]u64, allocator)
	ui.input_handlers = make(map[Node]Text_Handlers(Msg), allocator) // text_input hook
	ui.split_change = make(map[Node]Handler(Msg, f32), allocator)
	ui.split_close = make(map[Node]Msg, allocator)
	ui.drags = make(map[Node]Drag_Source, allocator)
	ui.grid_drags = make(map[Node]Grid_Drag, allocator)
	ui.chip_close = make(map[Node]Msg, allocator)
	ui.toast_close = make(map[Node]Msg, allocator)
	ui.toast_deadline = make(map[Node]f64, allocator)
	ui.on_number = make(map[Node]Handler(Msg, f32), allocator)
	ui.spin_step = make(map[Node]Spin_Step, allocator)
	ui.on_date = make(map[Node]Handler(Msg, Date), allocator)
	ui.cal_nav = make(map[Node]Cal_Nav, allocator)
	ui.on_color = make(map[Node]Handler(Msg, Color), allocator)
	ui.on_time = make(map[Node]Handler(Msg, Time_Of_Day), allocator)
	ui.on_link = make(map[Node]Handler(Msg, string), allocator)
	ui.on_drop = make(map[Node]Handler(Msg, Drop), allocator)
	ui.scopes = make([dynamic]Scope, allocator)
}

ui_destroy :: proc(ui: ^Ui($Msg)) {
	delete(ui.msgs)
	delete(ui.shortcuts)
	delete(ui.submenus)
	delete(ui.zooms)
	delete(ui.chart_select)
	delete(ui.graph_event)
	delete(ui.chrome_close)
	delete(ui.on_place)
	delete(ui.hovers)
	delete(ui.hovering)
	delete(ui.tracks)
	delete(ui.on_focus)
	delete(ui.pointer_areas)
	for _, &a in ui.sample_areas {
		delete(a.samples)
		delete(a.sent)
	}
	delete(ui.sample_areas)
	delete(ui.term_handlers)
	for _, &a in ui.key_holds {
		delete(a.keys)
		delete(a.held)
	}
	delete(ui.key_holds)
	for _, &ck in ui.custom_keys do delete(ck.keys)
	delete(ui.custom_keys)
	delete(ui.option_of)
	for _, doc in ui.edit_docs do inline_doc_free(&ui.tree, doc)
	delete(ui.edit_docs)
	delete(ui.edits)
	delete(ui.on_edit_cell)
	delete(ui.on_edit)
	delete(ui.on_drag_out)
	delete(ui.crumbs)
	delete(ui.middle_clicks)
	delete(ui.double_clicks)
	delete(ui.on_drag_over)
	delete(ui.on_drag_rest)
	delete(ui.click_pairs)
	delete(ui.clicks)
	delete(ui.on_bool)
	delete(ui.on_f32)
	delete(ui.slider_commit)
	delete(ui.on_int)
	delete(ui.dismiss)
	delete(ui.open)
	delete(ui.closes)
	delete(ui.tips)
	for _, &ls in ui.lists do list_state_destroy(&ls)
	delete(ui.lists)
	for _, &es in ui.emoji do emoji_state_destroy(&ui.tree, &es)
	delete(ui.emoji)
	delete(ui.emoji_cells)
	delete(ui.emoji_grids)
	delete(ui.emoji_jumps)
	delete(ui.emoji_tones)
	delete(ui.emoji_picks)
	delete(ui.emoji_fields)
	delete(ui.search_clears)
	delete(ui.rows)
	delete(ui.on_activate)
	delete(ui.on_row_click)
	delete(ui.on_context)
	delete(ui.context_clicks)
	delete(ui.editor_contexts)
	delete(ui.complete_asks)
	delete(ui.word_clicks)
	delete(ui.menu_leads)
	delete(ui.menu_slot)
	delete(ui.paste_others)
	delete(ui.md_links)
	delete(ui.md_images)
	delete(ui.on_scroll)
	delete(ui.button_opts)
	delete(ui.slots)
	for _, &mb in ui.menu_bars do delete(mb.titles)
	delete(ui.menu_bars)
	delete(ui.comp_rev)
	delete(ui.input_handlers) // text_input hook
	delete(ui.split_change)
	delete(ui.split_close)
	for _, &ds in ui.drags do drag_source_destroy(&ui.tree, &ds)
	delete(ui.drags)
	for _, &gd in ui.grid_drags do grid_drag_destroy(&ui.tree, &gd)
	delete(ui.grid_drags)
	delete(ui.chip_close)
	delete(ui.toast_close)
	delete(ui.toast_deadline)
	delete(ui.on_number)
	delete(ui.spin_step)
	delete(ui.on_date)
	delete(ui.cal_nav)
	delete(ui.on_color)
	delete(ui.on_time)
	delete(ui.on_link)
	delete(ui.on_drop)
	drag_clear_strings(ui)
	delete(ui.scopes)
	delete(ui.themes_saved)
	delete(ui.reveal_asks)
	delete(ui.hold_asks)
	tree_destroy(&ui.tree)
}

// Locale is how the desktop writes dates, times and numbers (see
// platform.Locale). run reads it from the desktop; set_locale overrides it
// for an app that carries its own, and re-runs the view.
Locale :: platform.Locale
LOCALE_EN :: platform.LOCALE_EN

set_locale :: proc(ui: ^Ui($Msg), l: Locale) {
	ui.tree.locale = l
	ask_rebuild(ui)
}

// begin_view starts a build: the root becomes the open scope. The run loop
// calls this before the app's `view`, and end_view after.
begin_view :: proc(ui: ^Ui($Msg), loc := #caller_location) {
	ui.epoch += 1
	ui.building = true
	ui.built_class = size_class(ui)
	ui.read_viewport = false
	clear(&ui.scopes)
	ui.top_closed = {}
	if len(ui.themes_saved) > 0 do ui.tree.theme = ui.themes_saved[0] // a build that stopped inside a popup
	clear(&ui.themes_saved)
	ui.theme_areas_open = 0 // …and one that stopped inside a theme_area
	clear(&ui.shortcuts)
	ui.capture = {} // declared again by every build that is still listening
	ui.keep_awake = false // …as is the screen staying on
	ui.toast_count = 0
	node_get(&ui.tree, ui.root).epoch = ui.epoch
	append(&ui.scopes, Scope{node = ui.root, cursor = node_first(&ui.tree, ui.root), loc = loc})
}

// end_view finishes a build. Scopes the view forgot to close are reported
// (with the opener's location) and closed; unvisited children are removed.
end_view :: proc(ui: ^Ui($Msg), loc := #caller_location) -> Error {
	err: Error
	for len(ui.scopes) > 1 {
		s := ui.scopes[len(ui.scopes) - 1]
		if !s.redirect {
			diag(&ui.tree, s.loc, fmt.tprintf("scope opened here was never closed; add baldr.end(ui) before the view returns (view ended at %s:%d)", loc.file_path, loc.line))
			err = .Unbalanced_Scope
		}
		close_scope(ui)
	}
	close_scope(ui)
	reveals_sweep(&ui.tree) // a node built without reveal_within again is always shown
	drag_preview_reapply(ui) // the rebuild restored the app's order; relink the reorder preview
	drag_ghost_build(ui, loc)
	sweep_overlay(ui)
	menu_leads_settle(ui)
	focus_sweep(ui) // the `focus` command's ask, if the widget it names is built
	// The fence is reset at the end of every view: a widget that returned
	// between `view_inner_begin` and its `end` would otherwise leave it
	// raised, and every later app ask would be refused in silence.
	if ui.view_inner != 0 {
		fmt.eprintfln("baldr: a widget left %d view(s) of its own open; the reveal fence is reset", ui.view_inner)
		ui.view_inner = 0
	}
	reveal_sweep(ui) // the `reveal` command's ask, dropped if no view took it
	hold_sweep(ui)   // …as is a `hold` nobody claimed
	if ui.pending_focus != NODE_NONE {
		focus_initial(&ui.tree, ui.pending_focus) // a dialog's default button, else its first control
		ui.pending_focus = NODE_NONE
		// Focus placed deliberately answers the landing too: left pending it
		// would fire on the next build and pull focus out of a menu that had
		// just opened.
		ui.entered_keyboard = false
	} else if ui.entered_keyboard {
		// A panel the keyboard has just been given lands on its first
		// control, ring showing: set only for a surface with nothing focused
		// and not just pressed (keyboard_info.odin), so a panel returned to
		// keeps its focus and a click on a bar's empty space focuses
		// nothing. The ring is required: the keyboard arriving without a
		// pointer means someone came by keyboard and needs to see where
		// they are.
		focus_first(&ui.tree, ui.tree.root, true)
		ui.entered_keyboard = false
	} else if ui.tree.modal != NODE_NONE && ui.tree.focus == NODE_NONE {
		focus_initial(&ui.tree, ui.tree.modal) // the focused control in a dialog went away: focus stays inside
	}
	ui.pointer_took_focus = false // the press that set it has been built; the next keyboard arrival is on its own
	ui.building = false
	return err
}

// end closes the innermost open container scope (and the helper scopes an
// overlay builder opened along with it).
end :: proc(ui: ^Ui($Msg), loc := #caller_location) {
	if len(ui.scopes) <= 1 {
		// the end too many is earlier than this one: name where the outermost
		// scope was closed, which is it or comes after it
		if opener, closer := ui.top_closed[0], ui.top_closed[1]; closer.line != 0 {
			diag(&ui.tree, loc, fmt.tprintf("baldr.end(ui) called with no open scope: the scope opened at %s:%d was already closed by the end at %s:%d, so an end at or before that one closes a scope too many (a leaf such as box, text or spacer takes no end)",
				opener.file_path, opener.line, closer.file_path, closer.line))
		} else {
			diag(&ui.tree, loc, "baldr.end(ui) called with no open scope")
		}
		return
	}
	pops := 1 + int(ui.scopes[len(ui.scopes) - 1].extra_pops)
	for _ in 0 ..< pops {
		if len(ui.scopes) <= 1 do break
		s := ui.scopes[len(ui.scopes) - 1]
		if s.list do list_tail(ui, s.node, loc) // a virtual list closed through here still gets its tail
		close_scope(ui)
		if len(ui.scopes) == 1 do ui.top_closed = {s.loc, loc}
	}
}

@(private)
close_scope :: proc(ui: ^Ui($Msg)) {
	s := pop(&ui.scopes)
	if s.theme_pop && len(ui.themes_saved) > 0 do ui.tree.theme = pop(&ui.themes_saved)
	if s.theme_area do ui.theme_areas_open -= 1
	if s.redirect do return // overlay children are swept once per build, in end_view
	t := &ui.tree
	c := s.cursor
	for c != NODE_NONE {
		next := node_next(t, c)
		d := node_get(t, c)
		if d != nil && d.epoch != ui.epoch && .Overlay not_in d.flags {
			switch {
			case .Exiting in d.flags:
				// still playing its exit; sweep_exited removes it when done
			case .Keep in d.flags:
				// Parked: it draws nothing until built again, so it must
				// hold none of the app's Images, which the app may now free.
				pictures_release(t, c)
				set_hidden(t, c, true)
			case d.style.exit.kind != .None && !t.theme.motion.reduce:
				begin_exit(t, c)
			case:
				forget_subtree(ui, c)
				node_destroy(t, c)
			}
		}
		c = next
	}
}

// begin_exit flags a node (and, for hit-testing, its subtree) as leaving and
// starts its exit tween; paint fades it out from its current progress.
@(private)
begin_exit :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil do return
	d.flags += {.Exiting}
	if t.focus == n do set_focus(t, NODE_NONE, false)
	pictures_release(t, n) // the app may free those Images now
	append(&t.exiting, n)
	mark_paint_dirty(t, n)
	dur := d.style.exit.duration if d.style.exit.duration > 0 else t.theme.motion.base
	anim_target(t, n, .Enter, 0, dur)
}

// sweep_exited destroys exiting nodes whose fade has finished.
@(private)
sweep_exited :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for i := 0; i < len(t.exiting); {
		n := t.exiting[i]
		d := node_get(t, n)
		if d == nil {
			unordered_remove(&t.exiting, i)
			continue
		}
		if .Exiting not_in d.flags { // resurrected
			unordered_remove(&t.exiting, i)
			continue
		}
		if anim_value(t, n, .Enter) <= 0.002 && !anim_running(t, n, .Enter) {
			forget_subtree(ui, n)
			node_destroy(t, n)
			unordered_remove(&t.exiting, i)
			continue
		}
		i += 1
	}
}

// ui_tick advances animations, fires timers, and removes nodes whose exit
// transition finished. Call once per wake-up (the run loop does). Returns
// true while anything is still animating.
ui_tick :: proc(ui: ^Ui($Msg), now_ms: f64) -> bool {
	active := anim_tick(&ui.tree, now_ms)
	if len(ui.tree.exiting) > 0 do sweep_exited(ui)
	ui_after_events(ui, now_ms)
	return active
}

// ui_after_events runs the checks that depend on what the latest input did:
// tooltip timing and virtual-list ranges. The run loop calls it after
// dispatching a batch of events (ui_tick calls it too).
ui_after_events :: proc(ui: ^Ui($Msg), now_ms: f64) {
	inert_hover_tick(ui) // before the tooltip: none for a node that just turned inert
	track_tick(ui) // where the pointer went over the nodes that track it, once a frame
	samples_tick(ui) // …and every sample, for the nodes that hear them all
	tooltip_tick(ui, now_ms)
	submenu_tick(ui, now_ms)
	inline_tick(ui, now_ms)
	toast_tick(ui, now_ms)
	number_tick(ui)
	picker_tick(ui)
	time_tick(ui)
	code_tick(ui)
	complete_tick(ui) // a completion list the keyboard has left closes (editor_complete.odin)
	if !ui.build_pending do rich_tick(ui) // reads an editor's Document, which update may have freed: the build answers it anyway
	md_view_tick(ui, now_ms) // a reply's "Copied" tick goes back to the copy icon
	sel_drag_tick(ui, now_ms) // a selection dragged to the edge of a scroll keeps going
	touch_tick(ui, now_ms)
	drag_after_events(ui, now_ms)
	list_tick(ui)
	table_tick(ui)
	breadcrumbs_tick(ui)
	terminal_tick(ui) // the grid a terminal holds after the latest layout
	focus_tick(ui) // the nodes that asked to hear the keyboard arrive or leave
	if !ui.build_pending {
		ime_sync(ui)     // what the focused field tells an input method, when it changed
		primary_sync(ui) // what the person selected, for a middle click anywhere
	} // …else after the build (ui_after_build), against the tree the new view made
	if size_class(ui) != ui.built_class do ask_rebuild(ui) // the window crossed a breakpoint
}

// ui_after_build runs what waited for a view build because `update` had run
// (`build_pending`): what the focused field tells an input method, and the
// primary selection. The run loop calls it once the build is done.
@(private)
ui_after_build :: proc(ui: ^Ui($Msg)) {
	if !ui.build_pending do return
	ui.build_pending = false
	ime_sync(ui)
	primary_sync(ui)
}

// Click_Pair is when and where a clickable was last clicked, for pairing a
// double-click. A pointer area cannot do this for a control: its press
// handler stops at the hovered node, which for a control is the area itself.
Click_Pair :: struct {
	ms: f64,
	at: [2]f32,
}

// transition sets how `n` appears and leaves. Call right after the builder
// that created it: `c := card(ui); transition(ui, c, .Fade_Up, .Fade)`.
// A node that leaves keeps its layout slot while fading, then is removed.
// Under reduce-motion both are instant. Its fill, border, shadow and glass
// fade with it; an overlay (a popover, menu, select's list or dialog) keeps
// them whole instead and fades only what is on it, so the controls it opens
// over never show through it (Transition.whole).
transition :: proc(ui: ^Ui($Msg), n: Node, enter: Transition_Kind, exit: Transition_Kind = .None, duration_ms: f32 = 0, easing: Easing = .Ease_Out) {
	d := node_get(&ui.tree, n)
	if d == nil do return
	d.style.enter = {kind = enter, duration = duration_ms, easing = easing}
	d.style.exit = {kind = exit, duration = duration_ms}
}

// input_area marks `n` as part of where its surface takes the pointer, for
// a surface that declares `input = .Marked`: the region is the union of the
// marked nodes' rects (and any popover open on the surface) and follows
// layout.
input_area :: proc(ui: ^Ui($Msg), n: Node, on := true) {
	d := node_get(&ui.tree, n)
	if d == nil do return
	if on { d.flags += {.Input_Area} } else { d.flags -= {.Input_Area} }
}

// backdrop_area marks `n` as part of where its surface is blurred behind,
// for a surface that declares `backdrop_region = .Marked`: the region is the
// union of the marked nodes' rounded rects where they are drawn, following
// layout, slides and glides, and the surface is clear elsewhere. Each marked
// node gives itself its glass (`card(glass = true)`): separate toast cards
// on one surface. A node on its way out leaves the region as its fade
// starts. Its corners round by its radius, square ones included. On a
// surface that adapts only its marked nodes, the children built inside `n`
// after this call get the glass theme, solved for the wallpaper, while the
// rest of the window keeps the app's colours; the scope gives the theme
// back when it closes. A pane that paints its own ground must read
// `ui.theme` after this call, or it paints with the unsolved theme under
// solved text (`card(glass = true)` does this itself).
backdrop_area :: proc(ui: ^Ui($Msg), n: Node, on := true) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return
	if on { d.flags += {.Backdrop_Area} } else { d.flags -= {.Backdrop_Area} }
	if !on || !t.glass_theme_ok do return
	if len(ui.scopes) == 0 || ui.scopes[len(ui.scopes) - 1].node != n do return // not the open scope: only paint can scope it
	s := &ui.scopes[len(ui.scopes) - 1]
	if s.theme_pop do return // already swapped (a glass popup that is also marked)
	append(&ui.themes_saved, t.theme)
	t.theme = t.glass_theme
	s.theme_pop = true
}

// theme_area builds container `n` and everything inside it in a theme of
// the app's own: a reader's Sepia page, a photo editor's dark canvas, a
// terminal pane in its own palette. Call it on the container whose scope is
// open, as with `backdrop_area`; the tree's theme comes back when the scope
// closes. The subtree is painted with the theme as well as built with it,
// so hovers, focus rings and washes follow it; `theme_on_ground` derives a
// whole theme from a ground, an ink and an accent, keeping the desktop's
// accessibility preferences and the contrast text needs. A popup opened from
// inside (a select's list, a menu, a tooltip) keeps the window's theme,
// since it sits over the whole window; give its content a `theme_area` of
// its own to match the page. Layout, hit-testing and accessibility are
// untouched.
theme_area :: proc(ui: ^Ui($Msg), n: Node, theme: Theme) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return
	if len(ui.scopes) == 0 || ui.scopes[len(ui.scopes) - 1].node != n do return // not the open scope: only its own scope can theme it
	s := &ui.scopes[len(ui.scopes) - 1]
	if s.theme_pop do return // already swapped (a glass popup, or this called twice)
	if old, had := t.theme_areas[n]; !had || old.color != theme.color || old.state != theme.state {
		mark_paint_dirty(t, n) // the subtree is painted with it, so a new one is a repaint
	}
	t.theme_areas[n] = theme
	d.flags += {.Theme_Area}
	if ui.theme_areas_open == 0 do ui.theme_outside = t.theme // what a popup inside it steps back to
	ui.theme_areas_open += 1
	append(&ui.themes_saved, t.theme)
	t.theme = theme
	s.theme_pop = true
	s.theme_area = true
}

// context_area gives container `n` (a bar, a panel's background) a menu of
// its own without making it a control: a right-click on it, or on anything
// inside it without a menu of its own, sends `on_context`, as does the Menu
// key on a focused control inside it without one. It takes no focus, role,
// hover or press. Open the menu with `context_menu`. nil removes it.
context_area :: proc(ui: ^Ui($Msg), n: Node, on_context: Maybe(Msg)) {
	if node_get(&ui.tree, n) == nil do return
	if m, has := on_context.?; has { ui.context_clicks[n] = m } else { delete_key(&ui.context_clicks, n) }
}

// square_corners leaves `corners` of `n`'s `radius` square, the others
// rounded: a bar's content following the bar's shape, or a tab joined to
// its panel. It stays until changed; {} rounds all four again.
// Its fill, border, shadow, glass and focus ring all take the shape.
square_corners :: proc(ui: ^Ui($Msg), n: Node, corners: Corners) {
	d := node_get(&ui.tree, n)
	if d == nil || d.style.square == corners do return
	d.style.square = corners
	mark_paint_dirty(&ui.tree, n)
}

// animate_moves makes a container's children glide to their new positions
// when a rebuild reorders or reflows them (a toast pushing content down, a
// sorted list, chips wrapping). Layout is never touched: the glide is a
// paint-time shift over the theme's base duration, instant under
// reduce-motion, and skipped for window resizes.
animate_moves :: proc(ui: ^Ui($Msg), container: Node, on := true) {
	d := node_get(&ui.tree, container)
	if d == nil do return
	if on { d.flags += {.Animate_Moves} } else { d.flags -= {.Animate_Moves} }
}

@(private)
forget_subtree :: proc(ui: ^Ui($Msg), n: Node) {
	for c := node_first(&ui.tree, n); c != NODE_NONE; c = node_next(&ui.tree, c) {
		forget_subtree(ui, c)
	}
	delete_key(&ui.clicks, n)
	delete_key(&ui.on_bool, n)
	delete_key(&ui.on_f32, n)
	delete_key(&ui.slider_commit, n)
	delete_key(&ui.on_int, n)
	delete_key(&ui.dismiss, n)
	delete_key(&ui.open, n)
	delete_key(&ui.closes, n)
	delete_key(&ui.submenus, n)
	delete_key(&ui.zooms, n)
	hover_forget(ui, n)
	track_forget(ui, n)
	samples_forget(ui, n)
	delete_key(&ui.term_handlers, n)
	if ui.term_pending.node == n do ui.term_pending = {}
	key_holds_forget(ui, n)
	custom_keys_forget(ui, n)
	delete_key(&ui.option_of, n)
	delete_key(&ui.edits, n)
	if doc, has := ui.edit_docs[n]; has { // the card of a wrapping editor: its document goes with it
		inline_doc_free(&ui.tree, doc)
		delete_key(&ui.edit_docs, n)
	}
	delete_key(&ui.on_edit_cell, n)
	delete_key(&ui.on_edit, n)
	delete_key(&ui.on_drag_out, n)
	delete_key(&ui.crumbs, n)
	delete_key(&ui.middle_clicks, n)
	delete_key(&ui.tips, n)
	if ds, has_drag := &ui.drags[n]; has_drag {
		drag_source_destroy(&ui.tree, ds)
		delete_key(&ui.drags, n)
	}
	if gd, has_grid := &ui.grid_drags[n]; has_grid {
		grid_drag_destroy(&ui.tree, gd)
		delete_key(&ui.grid_drags, n)
	}
	delete_key(&ui.on_drop, n)
	delete_key(&ui.chip_close, n)
	delete_key(&ui.toast_close, n)
	delete_key(&ui.toast_deadline, n)
	delete_key(&ui.on_number, n)
	delete_key(&ui.spin_step, n)
	delete_key(&ui.on_date, n)
	delete_key(&ui.cal_nav, n)
	delete_key(&ui.on_color, n)
	delete_key(&ui.on_time, n)
	delete_key(&ui.on_link, n)
	if ui.picker_focused == n do ui.picker_focused = NODE_NONE
	if ui.spin_focused == n do ui.spin_focused = NODE_NONE
	// A drag outlives both: a target that goes away is no longer the
	// target, and a source is where the drag started, not what it carries
	// (dnd.odin).
	if ui.drag.target == n do drag_set_target(ui, NODE_NONE, .On)
	if ui.drag.source == n do drag_source_gone(ui)
	if ls := &ui.lists[n]; ls != nil do list_state_destroy(ls)
	delete_key(&ui.lists, n)
	if es := &ui.emoji[n]; es != nil do emoji_state_destroy(&ui.tree, es)
	delete_key(&ui.emoji, n)
	delete_key(&ui.emoji_cells, n)
	delete_key(&ui.emoji_grids, n)
	delete_key(&ui.emoji_jumps, n)
	delete_key(&ui.emoji_tones, n)
	delete_key(&ui.emoji_picks, n)
	delete_key(&ui.emoji_fields, n)
	delete_key(&ui.search_clears, n)
	delete_key(&ui.rows, n)
	delete_key(&ui.on_activate, n)
	delete_key(&ui.on_row_click, n)
	delete_key(&ui.on_context, n)
	delete_key(&ui.context_clicks, n)
	delete_key(&ui.editor_contexts, n)
	delete_key(&ui.complete_asks, n)
	delete_key(&ui.word_clicks, n)
	delete_key(&ui.menu_slot, n)
	delete_key(&ui.paste_others, n)
	delete_key(&ui.md_links, n)
	delete_key(&ui.md_images, n)
	delete_key(&ui.on_scroll, n)
	delete_key(&ui.pointer_areas, n)
	delete_key(&ui.on_focus, n)
	if ui.focus_sent == n do ui.focus_sent = NODE_NONE // a recycled id must not look like the node that had the keyboard
	if ui.pointer.area_held == n do ui.pointer.area_held = NODE_NONE
	delete_key(&ui.button_opts, n)
	delete_key(&ui.slots, n)
	if mb, ok := &ui.menu_bars[n]; ok {
		delete(mb.titles)
		delete_key(&ui.menu_bars, n)
	}
	delete_key(&ui.comp_rev, n)
	delete_key(&ui.input_handlers, n) // text_input hook
}

// handler_live says whether a handler would send anything: for a widget
// deciding whether to show a control at all. `h == nil` cannot answer it,
// because `x if cond else nil` gives a nil procedure inside the union
// rather than an empty union (see Handler).
handler_live :: proc(h: Handler($Msg, $T)) -> bool {
	switch v in h {
	case Msg:                return true
	case proc(Ev(T)) -> Msg: return v != nil
	}
	return false
}

// handler_send delivers a Handler: a plain message is queued as-is; a proc
// receives Ev{value, tag, node} and its result is queued. An empty union or
// a nil proc sends nothing. True when a message was queued.
handler_send :: proc(ui: ^Ui($Msg), h: Handler(Msg, $T), value: T, node: Node) -> bool {
	switch v in h {
	case Msg:
		append(&ui.msgs, v)
		return true
	case proc(Ev(T)) -> Msg:
		if v == nil do return false
		tag: u64
		if d := node_get(&ui.tree, node); d != nil do tag = d.tag
		append(&ui.msgs, v(Ev(T){value = value, tag = tag, node = node}))
		return true
	}
	return false
}

// RECONCILE_LOOKAHEAD is how many siblings an unkeyed call searches for its
// own node before making a new one.
RECONCILE_LOOKAHEAD :: 32

// reconcile_child finds the node this builder call means, or makes one, and
// advances the cursor past it.
//
// Identity is the builder, the key and the position, not the key alone:
// `box`, `column`, `row`, `button` and `card` share `Kind_Tag.Box`, and a
// node reused across builders skips the setup its builder does only on
// creation. `builder` defaults at the call site inside each builder, so it
// names the builder with nothing passed. Changing which builder sits at a
// key therefore discards that node's state (focus, scroll, a half-typed
// value), as type-plus-key identity does in other toolkits.
@(private)
reconcile_child :: proc(ui: ^Ui($Msg), kt: Kind_Tag, key: u64, loc: runtime.Source_Code_Location, builder := #caller_location) -> (n: Node, created: bool) {
	t := &ui.tree
	s := &ui.scopes[len(ui.scopes) - 1]
	if s.list && key == 0 do list_unkeyed_row(ui, s.node, loc)
	// Exiting nodes and the overlay root are not candidates for positional
	// reuse; skip past them.
	for s.cursor != NODE_NONE {
		cd := node_get(t, s.cursor)
		if cd == nil do break
		if .Overlay in cd.flags || (.Exiting in cd.flags && key == 0) {
			s.cursor = node_next(t, s.cursor)
			continue
		}
		break
	}
	cur := s.cursor
	if key != 0 {
		for c := cur; c != NODE_NONE; c = node_next(t, c) {
			d := node_get(t, c)
			if d.key == key && kind_tag(d.kind) == kt && d.builder == builder.procedure {
				// The call site is not compared: a keyed widget may move
				// between two branches at two sites.
				if c != cur do node_insert_before(t, s.node, c, cur)
				n = c
				if .Exiting in d.flags {
					// Came back while leaving: cancel the exit, fade back in.
					d.flags -= {.Exiting}
					mark_paint_dirty(t, n)
				}
				break
			}
		}
		if n == NODE_NONE {
			n = node_new_kind(t, kt, loc)
			created = true
			node_get(t, n).key = key
			node_insert_before(t, s.node, n, cur)
		}
	} else {
		// Positional reuse is only safe between builds of the same call
		// site: a spacer's node must never become a tab bar's because both
		// are boxes at one position. Looking a little way ahead means a
		// branch above that changed shape does not cost every later sibling
		// its node, and with it focus, scroll and editing state.
		for c, i := cur, 0; c != NODE_NONE && i < RECONCILE_LOOKAHEAD; c, i = node_next(t, c), i + 1 {
			d := node_get(t, c)
			if .Overlay in d.flags || .Exiting in d.flags || d.epoch == ui.epoch do continue
			if d.key == 0 && kind_tag(d.kind) == kt && same_site(d.loc, loc) && d.builder == builder.procedure {
				if c != cur do node_insert_before(t, s.node, c, cur)
				n = c
				break
			}
		}
		if n == NODE_NONE {
			n = node_new_kind(t, kt, loc)
			created = true
			node_insert_before(t, s.node, n, cur)
		}
	}
	d := node_get(t, n)
	d.epoch = ui.epoch
	d.loc = loc
	d.builder = builder.procedure
	s.cursor = node_next(t, n)
	if .Keep in d.flags && .Hidden in d.flags {
		set_hidden(t, n, false)
		d.flags += {.Revealed}
	}
	return
}

@(private)
same_site :: proc "contextless" (a, b: runtime.Source_Code_Location) -> bool {
	return a.line == b.line && a.column == b.column && a.file_path == b.file_path
}

@(private)
node_new_kind :: proc(t: ^Tree, kt: Kind_Tag, loc: runtime.Source_Code_Location) -> Node {
	switch kt {
	case .Text:       return node_new(t, Text_Kind{size = 16}, loc)
	case .Custom:     return node_new(t, Custom_Kind{}, loc)
	case .Text_Input: return node_new(t, Text_Input_Kind{}, loc) // text_input hook
	case .Box, .None: return node_new(t, Box_Kind{}, loc)
	}
	return node_new(t, Box_Kind{}, loc)
}

@(private)
open_scope :: proc(ui: ^Ui($Msg), n: Node, loc: runtime.Source_Code_Location) {
	append(&ui.scopes, Scope{node = n, cursor = node_first(&ui.tree, n), loc = loc})
}

// ---------------------------------------------------------------- builders

// column opens a vertical container. Children stack top to bottom. `offset`
// moves it inside a `stack` parent and is ignored anywhere else. Close with end.
// `border` outlines it: a line of that colour, `border_width` px wide (1
// unless said), just inside its edge and round its `radius`, taking no
// room; a zero colour is none.
column :: proc(ui: ^Ui($Msg), gap: Space = Space_Token.none, padding: Space = Space_Token.none,
	align: Align = .Stretch, justify: Justify = .Start, width: f32 = 0, height: f32 = 0, flex: f32 = 0,
	max_width: f32 = 0, max_height: f32 = 0,
	bg: Color = {}, radius: f32 = 0, border: Color = {}, border_width: f32 = 1, material: Material = {}, offset: [2]f32 = {}, animate := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n := container(ui, .Column, gap, padding, align, justify, width, height, flex, bg, radius, border, border_width, material, offset, max_width, max_height, key, loc)
	animate_moves(ui, n, animate)
	set_tag(ui, n, tag)
	return n
}

// stack opens a container whose children overlap, each placed at the
// container's padding origin plus the child's `offset`. The building block
// for overlays, floating panels, and glass over content. Close with end.
// `border` outlines it: a line of that colour, `border_width` px wide (1
// unless said), just inside its edge and round its `radius`, taking no
// room; a zero colour is none.
stack :: proc(ui: ^Ui($Msg), padding: Space = Space_Token.none, align: Align = .Start,
	width: f32 = 0, height: f32 = 0, flex: f32 = 0, max_width: f32 = 0, max_height: f32 = 0,
	bg: Color = {}, radius: f32 = 0, border: Color = {}, border_width: f32 = 1, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n := container(ui, .Stack, Space_Token.none, padding, align, .Start, width, height, flex, bg, radius, border, border_width, {}, {}, max_width, max_height, key, loc)
	set_tag(ui, n, tag)
	return n
}

// row opens a horizontal container. Children run left to right. Close with end.
// `vertical = true` stacks them top to bottom instead, stretched across: the
// one switch a header, a form row or a card's action row needs at phone
// width, `baldr.row(ui, gap = .md, vertical = baldr.size_class(ui) == .Compact)`.
// `offset` moves it inside a `stack` parent and is ignored anywhere else.
// `border` outlines it: a line of that colour, `border_width` px wide (1
// unless said), just inside its edge and round its `radius`, taking no
// room; a zero colour is none.
row :: proc(ui: ^Ui($Msg), gap: Space = Space_Token.none, padding: Space = Space_Token.none,
	align: Align = .Start, justify: Justify = .Start, width: f32 = 0, height: f32 = 0, flex: f32 = 0,
	max_width: f32 = 0, max_height: f32 = 0,
	bg: Color = {}, radius: f32 = 0, border: Color = {}, border_width: f32 = 1, material: Material = {}, offset: [2]f32 = {}, animate := false,
	vertical := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n := container(ui, .Column if vertical else .Row, gap, padding, .Stretch if vertical else align, justify, width, height, flex, bg, radius, border, border_width, material, offset, max_width, max_height, key, loc)
	animate_moves(ui, n, animate)
	set_tag(ui, n, tag)
	return n
}

@(private)
container :: proc(ui: ^Ui($Msg), axis: Axis, gap, padding: Space, align: Align, justify: Justify,
	width, height, flex: f32, bg: Color, radius: f32, border: Color, border_width: f32, material: Material, offset: [2]f32, max_width, max_height: f32, key: u64, loc: runtime.Source_Code_Location) -> Node {
	n, _ := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	set_layout(t, n, Layout_Props{
		axis = axis, gap = space_px(&t.theme, gap), padding = pad4(space_px(&t.theme, padding)),
		align = align, justify = justify, width = width, height = height, flex = flex, offset = offset,
		max_w = max_width, max_h = max_height,
	})
	d := node_get(t, n)
	st := d.style
	st.bg, st.radius, st.material = bg, radius, material
	style_border(&st, border, border_width)
	set_style(t, n, st)
	open_scope(ui, n, loc)
	return n
}

// style_border puts a container's `border` on its style: a line of that
// colour, `width` px wide (1 unless said), drawn just inside its edge and
// following its `radius`. It takes no room, so it can come and go without
// moving anything — a card whose outline says it is the selected one.
// Children draw over it where they reach the edge, so a
// container whose children are flush with it wants `padding` as wide as
// the line. A zero colour is no border.
@(private)
style_border :: proc(st: ^Style, border: Color, width: f32) {
	if border.a > 0 && width > 0 {
		st.border, st.border_w = border, width
	} else {
		st.border, st.border_w = {}, 0
	}
}

// set_tag records the `tag` a plain container was built with, for handlers
// that read `Ev.tag` (a `pointer_track` learns which row it tracks this
// way). 0 leaves what is there, as `clickable` and `draggable` do, so a tag
// one of those modifiers put on the same node stands.
@(private)
set_tag :: proc(ui: ^Ui($Msg), n: Node, tag: u64) {
	if tag == 0 do return
	if d := node_get(&ui.tree, n); d != nil do d.tag = tag
}

// box is a leaf rectangle: spacing, dividers, colour swatches, a frame.
// `border` outlines it: a line of that colour, `border_width` px wide (1
// unless said), just inside its edge and round its `radius`, taking no
// room; a zero colour is none.
box :: proc(ui: ^Ui($Msg), width: f32 = 0, height: f32 = 0, flex: f32 = 0, bg: Color = {}, radius: f32 = 0,
	border: Color = {}, border_width: f32 = 1, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, _ := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	set_layout(t, n, Layout_Props{width = width, height = height, flex = flex})
	d := node_get(t, n)
	st := d.style
	st.bg, st.radius = bg, radius
	style_border(&st, border, border_width)
	set_style(t, n, st)
	set_tag(ui, n, tag)
	return n
}

// text is a run of text. `role` picks the size and weight from the theme's
// type scale (`size` and `weight`, Regular, Medium or Semibold, override
// them); zero `color` means the theme's on_surface. Its accessible name is
// its content. It is sized as any leaf is: a fixed `width`,
// `min_width` / `max_width`, or `flex` for a share of a row's free space;
// it wraps at the width it ends up with, and `align` places its lines in
// it. A label column and the values beside it are two texts in a row:
//
//	baldr.row(ui, gap = .md); {
//		defer baldr.end(ui)
//		baldr.text(ui, "Licence", muted = true, width = 170)
//		baldr.text(ui, licence, flex = 1)
//	}
//
// `mono` sets it in the code face the editors use, for a run of text that
// is machinery rather than prose — a tool step under a reply, a hash, a
// path — so the words around it lead. `family` draws it in a family of its
// own instead: one this machine has (`text_family`) or one the app carries
// (`text_family_bytes`), such as a wordmark's face. `italic` sets it in the
// face's italic: a title, a term being defined, a tab that is only a
// preview. It is a look and nothing more; a screen reader is not told.
text :: proc(ui: ^Ui($Msg), s: string, role: Text_Role = .Body, size: f32 = 0, color: Color = {},
	muted := false, nowrap := false, ellipsis: Ellipsis = .None, max_lines := 0, align: Text_Align = .Start,
	weight: Maybe(Font_Weight) = nil, mono := false, family: Family_Id = 0, tabular := false, italic := false,
	sensitive := false,
	width: f32 = 0, min_width: f32 = 0, max_width: f32 = 0, flex: f32 = 0,
	key: u64 = 0, loc := #caller_location) -> Node {
	n, _ := reconcile_child(ui, .Text, key, loc)
	t := &ui.tree
	// Before `set_text`, so the first string is already known to be a
	// secret and is scrubbed when it is replaced.
	set_sensitive(t, n, sensitive)
	set_text(t, n, s)
	set_layout(t, n, Layout_Props{width = width, min_w = min_width, max_w = max_width, flex = flex})
	d := node_get(t, n)
	st := text_style(&t.theme, role)
	px := size * tree_text_scale(t) if size > 0 else st.size // a size the app set follows the text scale too, the desktop's and the app's own, as the roles do
	wt := weight.? or_else st.weight
	family := family
	if family == 0 && !mono do family = role_family(&t.theme, role) // the family the theme sets this step in, if it names one
	if tk, ok := d.kind.(Text_Kind); ok && (tk.size != px || tk.weight != wt || tk.nowrap != nowrap || tk.ellipsis != ellipsis || tk.max_lines != max_lines || tk.align != align || tk.mono != mono || tk.family != family || tk.tabular != tabular || tk.italic != italic) {
		tk.size = px
		tk.weight = wt
		tk.nowrap = nowrap
		tk.ellipsis = ellipsis
		tk.max_lines = max_lines
		tk.align = align
		tk.mono = mono
		tk.family = family
		tk.tabular = tabular
		tk.italic = italic
		d.kind = tk
		mark_layout_dirty(t, n)
	}
	fg := color
	if fg == {} do fg = t.theme.color.on_surface_muted if muted else t.theme.color.on_surface
	if d.style.fg != fg {
		d.style.fg = fg
		mark_paint_dirty(t, n)
	}
	// A secret is not published as the accessible name: anything on the
	// session bus can read a name. A screen reader cannot speak it either;
	// a Copy button beside it is the accessible path.
	set_name(t, n, "Secret, shown on screen" if sensitive else s)
	// a text cut with "…" shows the whole of it on hover, but never a secret: the tooltip is a name readers can see
	if !sensitive && ui.tip_anchor == n && text_trimmed(t, n) do tooltip_show(ui, n, s, loc)
	return n
}

// Button_Variant picks the colour roles a button uses.
Button_Variant :: enum u8 {
	Primary,   // filled with the primary colour — the main action
	Secondary, // tonal: primary container
	Outline,   // transparent with an outline
	Ghost,     // transparent, text only
	Danger,    // filled with the danger colour
}

// button is a clickable control. `on_click` is queued when it is activated
// (pointer, Enter, Space, or an assistive-technology action).
// `default` marks the button Enter activates in a dialog: it takes the
// dialog's initial focus (unless the dialog starts with a text field) and is
// announced as the default. `pressed` makes it a toggle (show hidden files,
// the preview pane): a Toggle_Button, Pressed while true, drawn off in the
// variant's quiet form and on with its emphasis (the tonal fill for Ghost,
// Outline and Secondary). `on_context` is what a right-click, or the Menu
// key while it is focused, sends; `Ui.context_pos` is recorded first, so a
// `context_menu` opens there (under the button from the keyboard).
// `on_scroll` gets a wheel or touchpad scroll over it (a tray icon's
// Scroll, a volume applet) before any scroll view around it, and doesn't
// take focus. `icons` shows several icons side by side after `icon` (a bar
// button's Wi-Fi, sound and battery), decorative: say what they show in the
// button's description (`set_describe`). `theme_icon` is an icon from the
// desktop's icon theme by name
// (an app's Icon=), drawn where `icon` goes, as `theme_icon` draws it, in the
// label's colour. `size = .Small` makes it compact: by default 26 × 26 when
// `icon_only` (a tile's arrow), a 12 px label otherwise (Theme.button
// restyles both). Rarer settings (a
// width that cuts the label with "…", the icon's size and colour) are
// `button_options`.
button :: proc(ui: ^Ui($Msg), label: string, on_click: Msg, variant: Button_Variant = .Primary, disabled := false,
	icon: Icon = .None, icons: []Icon = nil, image: ^Image = nil, theme_icon := "", icon_only := false, size: Button_Size = .Regular, default := false, pressed: Maybe(bool) = nil, on_middle_click: Maybe(Msg) = nil,
	on_context: Maybe(Msg) = nil, on_scroll: Handler(Msg, Scroll) = nil, focus_on_click := true,
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	lk := button_look(th) // the theme in force here: a popup's, when it is built in one
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
		d.layout.axis = .Row
		d.layout.align = .Center
		d.layout.justify = .Center
		d.layout.padding = lk.sizes[.Regular].padding
		mark_layout_dirty(t, n)
	}
	focus_on_click_set(t, d, focus_on_click) // every build: a tools column says it on every button
	st := d.style
	st.radius = lk.radius
	vc := lk.colors[variant]
	on, toggle := pressed.?
	if toggle {
		switch {
		case on && (variant == .Primary || variant == .Danger): // the fill is the emphasis
		case on:
			vc = lk.pressed
		case variant == .Primary || variant == .Secondary || variant == .Danger: // off: quiet
			vc = lk.unpressed
		}
	}
	st.bg, st.bg2, st.shadow, st.border, st.border_w = vc.fill, vc.fill_bottom, vc.shadow, vc.border, vc.border_width
	fg := vc.ink
	st.fg = fg // its content's colour, which button_options' icon colour falls back to
	set_style(t, n, st)
	d = node_get(t, n)
	d.tag = tag
	set_name(t, n, label)
	d.access.role = .Toggle_Button if toggle else .Button
	if toggle && on { d.access.states += {.Pressed} } else { d.access.states -= {.Pressed} }
	// set_disabled repaints: the dimming happens at paint time, so setting
	// the flag alone would leave the old look on screen.
	set_disabled(t, n, disabled)
	if default { d.access.states += {.Default} } else { d.access.states -= {.Default} }
	ui.clicks[n] = on_click
	if m, has := on_middle_click.?; has { ui.middle_clicks[n] = m } else { delete_key(&ui.middle_clicks, n) } // open in a new window, a new tab
	if m, has := on_context.?; has { ui.context_clicks[n] = m } else { delete_key(&ui.context_clicks, n) } // its menu
	if handler_live(on_scroll) {
		use := ui.on_scroll[n] // the part of a step left over stays across builds
		use.handler = on_scroll
		ui.on_scroll[n] = use
	} else {
		delete_key(&ui.on_scroll, n)
	}
	// icon-only buttons are square; the label is still the accessible name
	sz := lk.sizes[size]
	pad := sz.icon_only_padding if icon_only else sz.padding
	if d.layout.padding != pad || d.layout.gap != lk.gap {
		d.layout.padding = pad
		d.layout.gap = lk.gap
		mark_layout_dirty(t, n)
	}
	open_scope(ui, n, loc)
	o := ui.button_opts[n]
	button_quiet_set(t, n, d, o.quiet) // what button_options set, kept across rebuilds
	icon_px := o.icon_size if o.icon_size > 0 else lk.icon_size
	icon_fg := o.icon_color if o.icon_color != {} else fg
	if image != nil do baldr_image(ui, image, o.icon_size if o.icon_size > 0 else lk.image_size, lk.image_radius, loc, key = u64(Control_Part.Image))
	if icon != .None && theme_icon == "" do baldr_icon(ui, icon, icon_px, icon_fg, loc, key = u64(Control_Part.Icon)) // with a theme icon, the icon stands in when no theme provides it
	for which, i in icons do if which != .None do baldr_icon(ui, which, icon_px, icon_fg, loc, key = control_part_icons(i))
	if theme_icon != "" do baldr_theme_icon(ui, theme_icon, icon_px, icon_fg, loc, key = u64(Control_Part.Theme_Icon), fallback = icon)
	if !icon_only {
		// a label never wraps: a row shrinks what can give instead; under a max_width it ends in "…" where cut
		tl := sz.text // size 0 and family "": the Label step's
		lbl := text(ui, label, role = .Label, size = tl.size, weight = tl.weight, family = look_family(t, tl.family), color = fg, nowrap = true,
			ellipsis = .End if o.max_width > 0 else .None, italic = o.italic, key = u64(Control_Part.Label), loc = loc)
		set_role(t, lbl, .None) // the button carries the name; its label is not a separate a11y node
	}
	close_scope(ui)
	return n
}

BUTTON_IMAGE_SIZE :: f32(20) // a picture inside a button: an avatar, a thumbnail

// Button_Size is how big a button is: Regular, or Small, compact.
Button_Size :: enum u8 { Regular, Small }

BUTTON_SMALL      :: f32(26) // a Small icon-only button's side
BUTTON_SMALL_TEXT :: f32(12) // a Small button's label size

// button_options sets a button's rarer settings, each kept until changed.
// `max_width` caps its width (0: none): its label then ends in "…" where it
// is cut, and a tight row shortens it further; the whole label stays its
// accessible name and shows on hover (a window's title on a taskbar).
// `icon_size` sizes its icon, theme icon or picture (0: their own size).
// `icon_color` colours its icon or theme icon ({}: the label's colour); a
// full-colour theme icon keeps its colours and fades with the alpha (a
// pinned app that isn't running). `mark` is drawn inside the button's edge
// and takes no room (a taskbar's running-app dot or bar, Button_Mark);
// `badge` sits on its icon's top end corner, taking no room either (a count,
// or a bell's dot: Button_Badge). `progress` draws a thin bar across the
// bottom of its icon, 0…1, taking no room and clear of the badge (a download
// on a taskbar entry): 0 is an empty track, a negative value takes the bar
// away, and the value eases as it changes. `quiet` takes the hover and press
// wash off, for a control that answers the pointer another way (a dock's
// icons grow, so the wash would say it twice): it still hovers, presses,
// takes the keyboard and shows its focus ring, mark, badge and tooltip, and
// reads the same to a screen reader — only the wash goes. `italic` sets the
// label in italics (a tab that is only a preview, which the next file opened
// replaces); say what it means in its tooltip or description too.
// An option left out keeps what the button had, so a mark, a badge or a bar
// goes only when you pass its empty value: a mark with `length = 0`, an
// empty `Button_Badge{}`, a negative `progress`.
// Anything but a button is left alone.
button_options :: proc(ui: ^Ui($Msg), n: Node, max_width: Maybe(f32) = nil, icon_size: Maybe(f32) = nil, icon_color: Maybe(Color) = nil,
	mark: Maybe(Button_Mark) = nil, badge: Maybe(Button_Badge) = nil, progress: Maybe(f32) = nil, quiet: Maybe(bool) = nil,
	focus_on_click: Maybe(bool) = nil, // focus_on_click is on `button` too: a tools column sets it on every one
	progress_style: Maybe(Progress_Style) = nil, indeterminate: Maybe(bool) = nil, italic: Maybe(bool) = nil) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil || (d.access.role != .Button && d.access.role != .Toggle_Button) do return
	o := ui.button_opts[n]
	if v, ok := max_width.?; ok do o.max_width = max(v, 0)
	if v, ok := icon_size.?; ok do o.icon_size = max(v, 0)
	if v, ok := icon_color.?; ok do o.icon_color = v
	if v, ok := mark.?; ok && v != o.mark {
		o.mark = v
		use := t.button_marks[n]
		use.mark = v
		t.button_marks[n] = use // kept with length 0 too, so the mark shrinks away
		mark_paint_dirty(t, n)
	}
	if v, ok := badge.?; ok do button_badge_set(t, n, d, v)
	if progress != nil || progress_style != nil || indeterminate != nil do button_progress_set(t, n, d, progress, progress_style, indeterminate)
	if v, ok := focus_on_click.?; ok do focus_on_click_set(t, d, v)
	if v, ok := italic.?; ok do o.italic = v
	if v, ok := quiet.?; ok && v != o.quiet {
		o.quiet = v
		button_quiet_set(t, n, d, v)
	}
	if o == {} { delete_key(&ui.button_opts, n) } else { ui.button_opts[n] = o }
	// the button was built already: what it shows follows now, not a build later
	if d.layout.max_w != o.max_width {
		d.layout.max_w = o.max_width
		mark_layout_dirty(t, n)
	}
	lk := button_look(&t.theme)
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		cd := node_get(t, ch)
		part := Control_Part(cd.key)
		if cd.key >= control_part_icons(0) do part = .Icon // one of `icons`: sized and coloured as the icon is
		#partial switch part {
		case .Label:
			if tk, ok := &cd.kind.(Text_Kind); ok && ((tk.ellipsis != .None) != (o.max_width > 0) || tk.italic != o.italic) {
				tk.ellipsis = .End if o.max_width > 0 else .None
				tk.italic = o.italic
				mark_layout_dirty(t, ch)
			}
		case .Image, .Icon, .Theme_Icon:
			ck, ok := &cd.kind.(Custom_Kind)
			if !ok do continue
			px := o.icon_size
			if px <= 0 do px = lk.image_size if part == .Image else lk.icon_size
			if ck.size != {px, px} {
				ck.size = {px, px}
				mark_layout_dirty(t, ch)
			}
			fg := o.icon_color if o.icon_color != {} else d.style.fg
			if part != .Image && cd.style.fg != fg {
				cd.style.fg = fg
				mark_paint_dirty(t, ch)
			}
		}
	}
}

// button_quiet_set turns a button's hover and press wash on or off. A quiet
// button keeps everything else: its focus ring, its keyboard, its mark,
// badge and progress, its tooltip and its place in the accessibility tree —
// it just stops answering the pointer with a wash, for a dock whose icons
// answer by growing.
@(private)
button_quiet_set :: proc(t: ^Tree, n: Node, d: ^Node_Data, quiet: bool) {
	if quiet == (.Quiet in d.flags) do return
	if quiet { d.flags += {.Quiet} } else { d.flags -= {.Quiet} }
	mark_paint_dirty(t, n)
}

// Button_Opts is what button_options set on a button.
@(private)
Button_Opts :: struct {
	max_width, icon_size: f32,
	icon_color:           Color,
	mark:                 Button_Mark,
	quiet:                bool,
	italic:               bool,
}

// Button_Mark is a mark a button draws inside its edge, taking no room: a
// taskbar's or dock's running-app dot, or a longer bar for the app in
// front. It sits on `side` (the edge facing the screen's
// edge), centred along it, `length` long (0: none) and `thickness` thick
// (0: the theme's), rounded, in `color` ({}: the button's content
// colour). A change of length or colour is animated (instant under reduce
// motion). `count` above 1 splits it into that many short marks with a gap
// between, in the same place and about the same length — two windows of one
// app, where a single mark could only say "running" (the caller caps it:
// three is plenty). It is drawn, not announced: say what it
// means in the button's description (`set_describe`), count included.
Button_Mark :: struct {
	side:      Edge,
	length:    f32,
	thickness: f32,
	color:     Color,
	count:     int, // 0 or 1: one mark; more: that many, side by side along the edge
}

BUTTON_MARK_THICKNESS :: f32(3)

// Button_Mark_Use is a button's mark as painted: what it shows, and the
// colour it is changing from.
@(private)
Button_Mark_Use :: struct {
	mark:    Button_Mark,
	from:    Color, // the colour a change started from
	to:      Color, // the colour it is going to
	painted: bool,  // painted before: later changes animate
}

// Button_Badge is a small badge at the top end corner of a button's icon,
// over it and taking no room: a count or a word in a pill ("3", "99+"), or,
// with no text and `dot` set, a dot (a bell with notifications waiting).
// It is in `color` ({}: the accent), its text in a colour that
// reads on it; neither text nor dot is none. Coming and going it grows and
// shrinks over motion.fast (at once under reduce motion); on a button's
// first paint it shows as it is. It is drawn, not announced: say what it
// means in the button's description (`set_describe`).
Button_Badge :: struct {
	text:  string,
	dot:   bool,
	color: Color,
}

// Progress_Style is how a button shows its progress (`button_options`).
Progress_Style :: enum u8 {
	Bar,  // a thin bar across the bottom of the icon: for an app's picture in a taskbar or a dock
	Ring, // a ring just outside the icon, filling clockwise from twelve o'clock: for a line glyph, whose bottom stroke a bar would land on
}

// Button_Progress_Use is a button's progress as asked for: `value` 0…1, `on`
// false once it was taken away (so it shrinks away showing the value it
// had), how it is drawn, and whether it is busy with no known end.
@(private)
Button_Progress_Use :: struct {
	value: f32,
	on:    bool,
	style: Progress_Style,
	busy:  bool,
}

BUTTON_PROGRESS_THICKNESS   :: f32(3)    // how thick that bar is, logical px
BUTTON_PROGRESS_TRACK_ALPHA :: f32(0.25) // its track, in the content colour; a power of two, so applying it before the fade or after gives the same bits
BUTTON_RING_THICKNESS       :: f32(2)    // a ring's stroke, logical px
BUTTON_RING_GAP             :: f32(2)    // between the icon's box and the ring
BUTTON_RING_BUSY_ARC        :: f32(0.28) // the share of the ring a busy arc covers

// button_progress_set keeps a button's progress. A value 0…1 draws it, a
// negative one takes it away (busy or not); `busy` draws it with no known
// end, whatever the value; `style` says how, and is kept for when progress
// comes. The first progress on a button already on screen grows in. It is
// announced, not only drawn: the button carries the value (or Busy) as a
// progress bar does, so a reader says "Backups, button, 30 %".
@(private)
button_progress_set :: proc(t: ^Tree, n: Node, d: ^Node_Data, value: Maybe(f32), style: Maybe(Progress_Style), busy: Maybe(bool)) {
	was, has := t.button_progress[n]
	next := was
	if v, ok := value.?; ok {
		if v < 0 {
			next.on, next.busy = false, false
		} else {
			next.on, next.value = true, clamp(v, 0, 1)
		}
	}
	if s, ok := style.?; ok do next.style = s
	if b, ok := busy.?; ok {
		next.busy = b
		if b do next.on = true // busy is shown, value or not
	}
	if !has && !next.on && !next.busy && next.style == .Bar do return // nothing to keep
	if has && next == was do return
	if !has && next.on && d.abs != {} do anim_restart(t, n, .Progress_On, 0, 0, 0)
	t.button_progress[n] = next
	d.access.has_value = next.on && !next.busy
	if d.access.has_value do d.access.value, d.access.value_min, d.access.value_max = next.value, 0, 1
	if next.on && next.busy { d.access.states += {.Busy} } else { d.access.states -= {.Busy} }
	mark_paint_dirty(t, n)
}

// A badge's dot diameter; a pill's height, text size and the room each side of its text.
BUTTON_BADGE_DOT     :: f32(8)
BUTTON_BADGE_HEIGHT  :: f32(16)
BUTTON_BADGE_TEXT    :: f32(10)
BUTTON_BADGE_PADDING :: f32(4)

// Button_Badge_Use is a button's badge as asked for, and as last shown,
// which it draws while it shrinks away. Both texts are the tree's copies.
@(private)
Button_Badge_Use :: struct {
	badge: Button_Badge,
	shown: Button_Badge,
}

@(private)
button_badge_set :: proc(t: ^Tree, n: Node, d: ^Node_Data, b: Button_Badge) {
	on := b.dot || b.text != ""
	use, has := &t.button_badges[n]
	if has && use.badge.text == b.text && use.badge.dot == b.dot && use.badge.color == b.color do return
	if !has {
		if !on do return
		t.button_badges[n] = {}
		use = &t.button_badges[n]
		if d.abs != {} do anim_restart(t, n, .Badge, 0, 0, 0) // a button already on screen: its new badge grows in
	}
	delete(use.badge.text, t.allocator)
	use.badge = {text = strings.clone(b.text, t.allocator), dot = b.dot, color = b.color}
	if on { // what shows, and what shrinks away when it goes
		delete(use.shown.text, t.allocator)
		use.shown = {text = strings.clone(b.text, t.allocator), dot = b.dot, color = b.color}
	}
	mark_paint_dirty(t, n)
}

@(private)
baldr_image :: proc(ui: ^Ui($Msg), img: ^Image, size, radius: f32, loc: runtime.Source_Code_Location, key: u64 = 0) -> Node {
	return image(ui, img, width = size, height = size, radius = radius, key = key, loc = loc)
}

// baldr_icon is `icon` for use inside other builders (a distinct name so a
// parameter called `icon` does not shadow it).
@(private)
baldr_icon :: proc(ui: ^Ui($Msg), which: Icon, size: f32, color: Color, loc: runtime.Source_Code_Location, key: u64 = 0) -> Node {
	return icon(ui, which, size = size, color = color, key = key, loc = loc)
}

// baldr_theme_icon is `theme_icon` for builders with a `theme_icon` parameter.
@(private)
baldr_theme_icon :: proc(ui: ^Ui($Msg), name: string, size: f32, color: Color, loc: runtime.Source_Code_Location, key: u64 = 0, fallback: Icon = .None) -> Node {
	return theme_icon(ui, name, size = size, color = color, fallback = fallback, key = key, loc = loc)
}

// Control_Part keys the parts a control builds inside itself, so a picture,
// an icon and a theme icon never take over each other's node when one comes
// or goes.
@(private)
Control_Part :: enum u64 { None, Check, Image, Icon, Theme_Icon, Label, Value, End, Tile, Hint, Avatar }

// control_part_icons keys the `i`th of a control's `icons`, past the named parts.
@(private)
control_part_icons :: proc "contextless" (i: int) -> u64 {
	return u64(len(Control_Part)) + u64(i)
}

// How many builds the `focus` command looks for its widget before giving
// up. One is usually enough, but a field in a dialog that animates in, or
// behind a `component` whose revision has not caught up, can be a pass or
// two late. Bounded so an unrelated screen that reuses the key much later
// cannot claim it.
@(private) FOCUS_WAIT_BUILDS :: 3

// focus_sweep gives the keyboard to the widget the `focus` command named,
// once a build has made it. It looks for a focusable, enabled, visible
// node with that reconciliation key, in tree order.
@(private)
focus_sweep :: proc(ui: ^Ui($Msg)) {
	if ui.focus_want == 0 do return
	t := &ui.tree
	found := NODE_NONE
	walk :: proc(t: ^Tree, n: Node, key: u64, found: ^Node) {
		if found^ != NODE_NONE do return
		for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
			d := node_get(t, c)
			if d == nil do continue
			if d.key == key && focusable(t, c) {
				found^ = c
				return
			}
			walk(t, c, key, found)
			if found^ != NODE_NONE do return
		}
	}
	walk(t, t.root, ui.focus_want, &found)
	if found == NODE_NONE {
		walk(t, t.overlay, ui.focus_want, &found) // a dialog's field, a popover's search box
	}
	if found != NODE_NONE {
		set_focus(t, found, t.focus_visible)
		scroll_into_view(t, found) // a field below the fold is no use focused
		ui.focus_want, ui.focus_tries = 0, 0
		return
	}
	ui.focus_tries += 1
	if ui.focus_tries >= FOCUS_WAIT_BUILDS do ui.focus_want, ui.focus_tries = 0, 0
}

// component wraps a subtree that only needs rebuilding when `rev` changes.
// Returns false — and leaves the retained subtree untouched — when the
// revision matches the last build. Close with end when it returns true.
component :: proc(ui: ^Ui($Msg), key: string, rev: u64, loc := #caller_location) -> bool {
	k := hash.fnv64a(transmute([]byte)key)
	if k == 0 do k = 1
	n, created := reconcile_child(ui, .Box, k, loc)
	if !created {
		if old, ok := ui.comp_rev[n]; ok && old == rev do return false
	}
	ui.comp_rev[n] = rev
	open_scope(ui, n, loc)
	return true
}

// click activates a control (used by event dispatch and by tests): a button
// queues its message; a checkbox / toggle sends its flipped value.
click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	d := node_get(&ui.tree, n)
	if d == nil || .Disabled in d.flags do return false
	done := false
	if _, is_chrome := ui.tree.chrome_btn[n]; is_chrome do return chrome_click(ui, n) // a window's own minimise, maximise or close
	if ref, is_row := ui.rows[n]; is_row do return grid_item_click(ui, ref.table, ref.index)
	if _, is_tree_row := ui.tree.tree_rows[n]; is_tree_row do return tree_row_click(ui, n)
	if g, in_choice := ui.tree.choice_of[n]; in_choice do set_focus(&ui.tree, g, false) // the group is the Tab stop
	if _, is_group := ui.tree.choices[n]; is_group { // its track, its padding, the gap between items: focus, no pick
		set_focus(&ui.tree, n, false)
		return false
	}
	if _, is_time := ui.tree.time_seg_of[n]; is_time do return time_seg_click(ui, n)
	if _, is_ctl := ui.tree.editor_ctl_of[n]; is_ctl && (complete_click(ui, n) || code_bar_click(ui, n) || rich_ctl_click(ui, n)) do return true
	if _, is_copy := ui.tree.md_copy_of[n]; is_copy do return md_view_copy_click(ui, n) // a reply's "Copy code"
	if step, is_step := ui.spin_step[n]; is_step do return number_step(ui, step.outer, step.dir, 1)
	if nav, is_nav := ui.cal_nav[n]; is_nav do return calendar_nav(ui, nav.cal, nav.delta)
	if cal, is_day := ui.tree.cal_day_of[n]; is_day do return calendar_pick(ui, cal, i64(d.tag))
	if pop, is_sub := ui.submenus[n]; is_sub { // a submenu row opens (and stays open) on click
		if pop == NODE_NONE do submenu_open(ui, n, false)
		return true
	}
	if emoji_click(ui, n) do return true // a cell, a tone swatch or a group button in an emoji_picker
	if search_clear_click(ui, n) do return true // a search_field's cross
	if m, has_msg := ui.clicks[n]; has_msg {
		append(&ui.msgs, m)
		// …and the second of two close together is also a double-click. It
		// goes after the click, so an app that only wants the double still
		// hears the click first, as a file manager's icon does.
		if dm, wants := ui.double_clicks[n]; wants {
			now, at := ui.pointer.time_ms, ui.pointer.pos // the click's own time (events.odin)
			last, seen := ui.click_pairs[n]
			paired := seen && now >= last.ms && now - last.ms <= MULTI_CLICK_MS &&
				abs(at.x - last.at.x) <= MULTI_CLICK_PX && abs(at.y - last.at.y) <= MULTI_CLICK_PX
			// A refused pair looks exactly like a second click that never
			// arrived: say which it was, and by how much it missed.
			if ui.tree.debug_events {
				if !seen {
					fmt.eprintfln("baldr/events: node %d clicked at %.0f ms %v — the first of a possible pair", n, now, at)
				} else {
					fmt.eprintfln("baldr/events: node %d %s — %.0f ms and %.1f px from the click before it",
						n, "double-clicked" if paired else "NOT a double-click", now - last.ms,
						max(abs(at.x - last.at.x), abs(at.y - last.at.y)))
				}
			}
			if paired {
				append(&ui.msgs, dm)
				delete_key(&ui.click_pairs, n) // a third click starts a new pair, not a triple
			} else {
				ui.click_pairs[n] = {ms = now, at = at}
			}
		}
		done = true
	} else if h, has_bool := ui.on_bool[n]; has_bool {
		on := d.access.states & {.Checked, .Pressed, .Expanded} != {} // checkbox, toggle, chip, expander
		done = handler_send(ui, h, !on, n)
	} else if h, has_int := ui.on_int[n]; has_int {
		from := n // a pick comes from the control carrying the app's tag, as its keys send it: a choice's group, a select
		if g, in_choice := ui.tree.choice_of[n]; in_choice do from = g
		if s, is_option := ui.option_of[n]; is_option do from = s
		done = handler_send(ui, h, int(d.tag), from)
	} else if is_open, has_open := ui.open[n]; has_open {
		if ui.tree.debug_events do overlay_log(ui, n, "closed" if is_open else "opened", "a click on it")
		ui.open[n] = !is_open // a self-managed popup (select) toggles
		ask_rebuild(ui)
		mark_paint_dirty(&ui.tree, n)
		return true
	}
	if owner, closes := ui.closes[n]; closes { // menu items and options close their popup
		close_owner(ui, owner)
		done = true
	}
	return done
}

// Elevation_Level picks a shadow preset from the theme.
Elevation_Level :: enum u8 { None, Low, Mid, High }

// wrap is a row that breaks into new lines when its children do not fit the
// width (chips, tags, a toolbar, a card grid). Children with `flex` grow to
// fill their line. `align` positions children within a line; `justify`
// spreads a line's leftover. `vertical` runs it down instead, starting a new
// column to the right when the next child would not fit the height (a top
// bar's rows of applets): the wrap is as wide as its columns, `align` places
// children across a column's width and `justify` spreads a column's leftover
// height. `gap` is between children and between lines or columns. Close
// with end.
// `border` outlines it: a line of that colour, `border_width` px wide (1
// unless said), just inside its edge and round its `radius`, taking no
// room; a zero colour is none.
wrap :: proc(ui: ^Ui($Msg), gap: Space = Space_Token.none, padding: Space = Space_Token.none,
	align: Align = .Start, justify: Justify = .Start, width: f32 = 0, height: f32 = 0, flex: f32 = 0,
	max_width: f32 = 0, max_height: f32 = 0,
	vertical := false, bg: Color = {}, radius: f32 = 0, border: Color = {}, border_width: f32 = 1, animate := false, key: u64 = 0, loc := #caller_location) -> Node {
	n := container(ui, .Wrap_Column if vertical else .Wrap, gap, padding, align, justify, width, height, flex, bg, radius, border, border_width, {}, {}, max_width, max_height, key, loc)
	animate_moves(ui, n, animate)
	return n
}

// Size_Class buckets the window width so a view can choose a layout without
// inventing breakpoints (Material's window size classes): Compact is a phone
// or a narrow pane, Medium a tablet or split view, Expanded a desktop window.
// The run loop re-runs the view when the class changes; a view reads it
// through size_class and never a raw pixel width.
Size_Class :: enum u8 { Compact, Medium, Expanded }

SIZE_CLASS_MEDIUM   :: f32(600) // width from which the class is Medium
SIZE_CLASS_EXPANDED :: f32(840) // width from which the class is Expanded

size_class_of :: proc "contextless" (width: f32) -> Size_Class {
	switch {
	case width <= 0:                   return .Expanded // unknown yet (before the first configure)
	case width < SIZE_CLASS_MEDIUM:    return .Compact
	case width < SIZE_CLASS_EXPANDED:  return .Medium
	}
	return .Expanded
}

// size_class is the window's current size class (see Size_Class).
size_class :: proc(ui: ^Ui($Msg)) -> Size_Class {
	return size_class_of(ui.tree.viewport.x)
}

// viewport is the window's logical size (zero before the first configure).
// A view that asks for it is built again whenever it changes, so what it
// worked out from it (a viewer's visible part of a picture) never goes
// stale; a view that doesn't is only laid out again, as any resize is.
viewport :: proc(ui: ^Ui($Msg)) -> [2]f32 {
	if ui.building do ui.read_viewport = true
	return ui.tree.viewport
}

// device_scale is how many of the screen's pixels one logical pixel of this
// surface is (2 on a 2× screen, 1.25 at 125 %), from the same configure as
// `viewport`; 1 before the first. What a picture at 100 % needs: one of its
// pixels to one of the screen's is 1 / device_scale logical px. A move to a
// screen of another scale builds the view again.
device_scale :: proc(ui: ^Ui($Msg)) -> f32 {
	return ui.surface.scale if ui.surface.scale > 0 else 1
}

// spacer takes up room along the parent's main axis: `size` logical px, or
// all the remaining space when `size` is 0 (push siblings apart, right-align
// a row's tail). Invisible and not in the accessibility tree.
spacer :: proc(ui: ^Ui($Msg), size: f32 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, _ := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	parent := node_get(t, d.parent)
	vertical := parent == nil || parent.layout.axis != .Row
	lp: Layout_Props
	if size > 0 {
		if vertical { lp.height = size } else { lp.width = size }
	} else {
		lp.flex = 1
	}
	set_layout(t, n, lp)
	return n
}

// card opens a raised surface: background, rounded corners, hairline border,
// and a drop shadow. Children stack vertically. `gap`, `padding` and
// `elevation` left out are the theme's (Theme.card). `offset` moves it inside
// a `stack` parent and is ignored anywhere else. Close with end.
card :: proc(ui: ^Ui($Msg), gap: Space = nil, padding: Space = nil,
	align: Align = .Stretch, width: f32 = 0, height: f32 = 0, flex: f32 = 0, max_width: f32 = 0, max_height: f32 = 0,
	elevation: Maybe(Elevation_Level) = nil, glass := false, offset: [2]f32 = {}, key: u64 = 0, loc := #caller_location) -> Node {
	n, _ := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	lk := card_look(th)
	set_layout(t, n, Layout_Props{
		axis = .Column, gap = lk.gap if gap == nil else space_px(th, gap),
		padding = lk.padding if padding == nil else pad4(space_px(th, padding)),
		align = align, width = width, height = height, flex = flex, offset = offset,
		max_w = max_width, max_h = max_height,
	})
	d := node_get(t, n)
	st := d.style
	st.bg = lk.fill
	st.material = {}
	if m := th.material[th.glass].popover; glass && has_material(m) {
		// Glass: the material carries the colour; bg stays clear (Solid glass keeps the card opaque).
		st.material = glass_in_app(m)
		st.bg = {}
	}
	st.radius = lk.radius
	st.border_w = 0 if has_material(st.material) else lk.border_width // glass: its edge is the material's
	st.border = lk.border
	st.shadow = elevation_shadow(th, elevation.? or_else lk.elevation)
	set_style(t, n, st)
	if d.access.role == .None do d.access.role = .Group
	open_scope(ui, n, loc)
	return n
}

// scroll opens a scroll container: children stack along `axis` and may
// overflow it; the wheel, trackpad, and the overlay scrollbar move them.
// Give it a size — `height` (`width` along a row), or `flex = 1` inside a
// column — or let it take its content's size up to `max_height`
// (`max_width`) and scroll past that: a popover's list, which has no height
// to flex into. A scroll region that could grow forever would never need to
// scroll. Keyboard focus scrolls a control into view either way. Close with
// end.
//
// `content_width` makes a column scroll sideways as well: its children are
// laid out that wide, it pans with the wheel's x, Shift+wheel, a touchpad,
// Shift+Page / Home / End and `scroll_by` / `scroll_to`'s x, and it draws a
// bar along its bottom. Give the width the app knows (a document's widest
// page at the current zoom) rather than letting the widest child decide: in
// a virtualised view only built children are measured, so the extent would
// change as it scrolls. A child naturally wider keeps its width and the
// others are widened to match. Zero scrolls only down. It is read every
// build.
scroll :: proc(ui: ^Ui($Msg), axis: Axis = .Column, gap: Space = Space_Token.none, padding: Space = Space_Token.none,
	align: Align = .Stretch, width: f32 = 0, height: f32 = 0, flex: f32 = 0, bg: Color = {},
	max_width: f32 = 0, max_height: f32 = 0, follow_end := false, gutter := false, content_width: f32 = 0,
	key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	if created {
		d := node_get(t, n)
		d.flags += {.Clips}
		d.flags += {.Scroll_H} if axis == .Row else {.Scroll_V}
		d.access.role = .Scroll_Area
		set_layer(t, n, true)
		st := scroll_state_new()
		st.at_end = follow_end // a chat opens at its last message, not its first
		t.scrolls[n] = st
	}
	if st := &t.scrolls[n]; st != nil do st.follow_end = follow_end
	// `gutter` keeps the content clear of the overlay scrollbar. It is
	// always reserved, not only on overflow: reserving it on demand
	// oscillates, since narrowing the content wraps text, which can make it
	// overflow, which brings the gutter, and so on. A constant width is
	// stable; an app that wants the room passes nothing.
	pad := pad4(space_px(th, padding))
	if gutter && axis != .Row do pad[1] += scrollbar_look(th).gutter // the bar is drawn at the right; the horizontal one is along the bottom
	// Set every build: a zoom changes it.
	content_w := content_width if axis != .Row else 0
	// The clamp must see the width that is coming, not the last layout's: a
	// zoom widens the content and pans in the same build, and `scroll_clamp`
	// would hold the pan to the old width. Only raised here (as
	// `list_reveal_key` does for height); a width that shrank is layout's.
	if content_w > 0 {
		if sc := &t.scrolls[n]; sc != nil do sc.content.x = max(sc.content.x, content_w)
	}
	set_layout(t, n, Layout_Props{
		axis = .Row if axis == .Row else .Column, gap = space_px(th, gap), padding = pad,
		align = align, width = width, height = height, flex = flex, max_w = max_width, max_h = max_height,
		content_w = content_w,
	})
	d := node_get(t, n)
	if axis != .Row {
		if content_w > 0 { d.flags += {.Scroll_H} } else { d.flags -= {.Scroll_H} }
	}
	// Layout may stop at a scroll only when its size along its axis is fixed
	// from outside; one sized by its content grows and shrinks with it.
	if flex > 0 || (width > 0 if axis == .Row else height > 0) { d.flags += {.Relayout_Boundary} } else { d.flags -= {.Relayout_Boundary} }
	st := d.style
	st.bg = bg
	set_style(t, n, st)
	open_scope(ui, n, loc)
	return n
}

// ask_rebuild asks for the view to be built again after internal state
// changed (a select opened), remembering the first place that asked since
// the last build for BALDR_DEBUG_EVENTS.
@(private)
ask_rebuild :: proc(ui: ^Ui($Msg), loc := #caller_location) {
	if !ui.needs_rebuild do ui.rebuild_from = loc
	ui.needs_rebuild = true
}

// loc_text is a code location as a debug line prints it: the file's name and
// line, or the procedure field alone when there is no file (a cause with no
// place in the code, such as "messages").
@(private)
loc_text :: proc(loc: runtime.Source_Code_Location) -> string {
	if loc.file_path == "" do return loc.procedure
	name := loc.file_path
	if i := strings.last_index_byte(name, '/'); i >= 0 do name = name[i + 1:]
	return fmt.tprintf("%s:%d", name, loc.line)
}

// damage_log prints, under BALDR_DEBUG_DAMAGE, a node that damaged its
// surface: how (painted, moved, left behind), its kind, key and name, where
// it was built, and the rect.
@(private)
damage_log :: proc(t: ^Tree, n: Node, how: string, r: Rect) {
	d := node_get(t, n)
	if d == nil do return
	fmt.eprintfln("baldr/damage: %s %v key %x %q built at %s: %v", how, kind_tag(d.kind), d.key, d.access.name, loc_text(d.loc), r)
}
