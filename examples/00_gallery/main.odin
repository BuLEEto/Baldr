// 00_gallery — the Baldr gallery. Its first page puts most of the widgets on
// one screen; the tabs after it give the larger ones room (the table, the
// explorer, the editors), and the themes switch from its header.
//
//   ./build.sh example 00_gallery run
package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "baldr:baldr"

// "System" is first: it follows the desktop, which is what an app's
// appearance setting offers beside Light and Dark.
THEMES := []string{"System", "Dark", "Dim", "Light", "Contrast dark", "Contrast light", "Teal", "Violet", "Rose", "Solstice", "Paper"}
PAGES  := []string{"Overview", "Controls", "Inputs", "Overlays", "Lists", "Table", "Motion", "Explorer", "Editor", "Rich text"}
KINDS  := []string{"Text", "Image", "Folder", "Archive", "Audio", "Video", "Code"}
KIND_ICONS := []baldr.Icon{.File_Text, .File_Image, .Folder, .File_Archive, .File_Music, .File_Video_Camera, .File_Code}
FILE_COLS := []baldr.Column{
	{title = "Name", sortable = true},
	{title = "Kind", width = 110, sortable = true},
	{title = "Size", width = 100, numeric = true, sortable = true},
	{title = "Modified", width = 160},
}
FRUIT  := []string{"Apple", "Banana", "Cherry", "Dragon fruit", "Elderberry"}

State :: struct {
	page, theme: int,
	applied:     int, // the theme choice already given to the tree (-1: none yet)
	remember, notify: bool,
	volume, size: f32,
	search, secret, filter: baldr.Text,
	notes:  baldr.Document, // multiline, edited in place by the text area
	source: baldr.Document, // Editor page: the code editor's document
	rich:   baldr.Document, // Rich text page: blocks and runs
	rich_src: baldr.Document, // Rich text page: the markdown source while in source mode
	reply:  baldr.Markdown_Doc, // Rich text page: the same markdown, read-only, as a reply
	rich_mode: int,           // 0 rich, 1 markdown source, 2 live preview, 3 read-only reply
	last_link: string,        // Rich text page: the link last followed (owned)
	code_lang: int,         // Editor page: 0 Odin, 1 C, 2 JSON, 3 SQL, 4 plain
	code_wrap: bool,
	code_ws:   bool,
	avatar, photo: baldr.Image, // decoded once, drawn by image nodes
	searches: int,
	fruit: int,
	menu, confirm: bool,
	deleted: int,
	last: string,
	toast: bool,
	spring: bool,
	order: [6]int, // chips, shuffled by the Motion page
	picked: int,
	wide_rows: bool, // the Lists page: rows wider than the list, panned sideways
	sel:    baldr.Selection, // table rows, edited in place by the table
	sort:   baldr.Sort,
	opened: string,
	grid:   bool, // Files page: icon view instead of the table
	ctx_open: bool,
	ctx_item: int, // -1 = the folder background
	pinned:   bool, // Overlays page: the Actions menu's check item
	paste_note: string, // Files page: what the last paste brought (owned)
	zoom:     f32,      // Files page: tile / row scale, 1 = default
	editing:  baldr.Cell_Ref, // Files page: the cell being edited in place, row -1 none
	renames:  map[int]string, // Files page: names changed in place, by data index (owned)
	sizes:    map[int]string, // Files page: sizes changed in place, by data index (owned)
	tree_editing: int,        // Explorer page: the entry being renamed, -1 none
	// Explorer page: a project tree in a split pane
	sidebar_w: f32,
	expanded:  map[int]bool, // PROJECT index → open
	tree_sel:  int,          // PROJECT index, -1 none
	tree_open: string,       // last activated (double-click / Enter)
	detail_dismissed: bool,  // phone width: Back was pressed since the last pick, so the tree shows instead of the details
	proj: [dynamic]Proj_Entry, // the project as a tree (entries keep PROJECT's indices; moves re-parent them)
	density:  int,      // Controls page: segmented control
	filters:  [4]bool,  // Controls page: filter chips
	tags:     [dynamic]string, // Controls page: removable chips
	advanced: bool,     // Controls page: expander
	toasts:   [dynamic]Toast_Item, // Overlays page: toasts on screen
	next_toast: int,
	count:    f32,      // Inputs page: number input
	date:     baldr.Date, // Inputs page: date picker
	accent:   baldr.Color, // Controls page: colour picker
	alarm:    baldr.Time_Of_Day, // Inputs page: time picker
	clock:    baldr.Clock,       // Inputs page: locale / 24 h / 12 h
	seconds:  bool,              // Inputs page: show seconds
	files:    [dynamic]string, // Inputs page: what the last file dialog returned (owned)
	files_note: string,        // why the last dialog gave no file, or "" (static strings)
	name:     baldr.Text, // Overview: a filled-in field
	plan:     int,        // Overview: a horizontal radio group
	marks:    [3]bool,    // Overview: bold / italic / underline icon toggles
}
Toast_Item :: struct { id: int, text: string }

Msg :: union {
	Set_Page, Set_Theme, Set_Remember, Set_Pinned, Set_Notify, Set_Volume, Set_Size,
	Search, Set_Fruit, Menu, Confirm, Delete, Act, Toast, Pick, Reset_Picked, Wide_Rows, Noop,
	Select_Row, Open_Row, Sort_By, View_Mode, Context, Ctx_Close, Select_All, Spring_Toast, Shuffle, Copy_Sel, Paste_Ask, Paste_Got, Zoom, Dropped_In,
	Edit_Cell, Edit_Tile, Renamed, Resized, Edit_Done, Tree_Edit, Tree_Renamed,
	Set_Sidebar, Tree_Open, Tree_Pick, Tree_Act, Detail_Back, Reorder, Tree_Move,
	Set_Density, Set_Filter, Remove_Tag, Set_Advanced, Show_Toast, Toast_Done, Set_Count, Crumb, Set_Date, Set_Accent,
	Ask_Files, Got_Files, Set_Alarm, Set_Clock, Set_Seconds, Set_Code_Lang, Set_Code_Wrap, Set_Code_Ws, Code_Edited,
	Set_Rich_Mode, Follow_Link, Set_Plan, Set_Mark,
}
Set_Plan :: struct { i: int }
Set_Mark :: struct { i: int, on: bool }
Set_Rich_Mode :: struct { mode: int }
Follow_Link   :: struct { href: string }
Set_Code_Lang :: struct { i: int }
Set_Code_Wrap :: struct { on: bool }
Set_Code_Ws   :: struct { on: bool }
Code_Edited   :: struct { version: int }
Set_Alarm :: struct { tm: baldr.Time_Of_Day }
Set_Clock :: struct { clock: baldr.Clock }
Set_Seconds :: struct { on: bool }
Ask_Files :: struct { kind: enum { Open, Folder, Save } }
Got_Files :: struct { files: baldr.Files }
Set_Accent :: struct { c: baldr.Color }
Set_Date :: struct { d: baldr.Date }
Show_Toast :: struct {}
Toast_Done :: struct { id: int }
Set_Count  :: struct { v: f32 }
Crumb      :: struct { depth: int } // Explorer breadcrumbs: pick the ancestor at this depth
Set_Density  :: struct { i: int }
Set_Filter   :: struct { i: int, on: bool }
Remove_Tag   :: struct { i: int }
Set_Advanced :: struct { on: bool }
Reorder   :: struct { from, to: int, before: bool } // Motion page chips: drop `from` before / after `to`
Tree_Move :: struct { item, folder: int }           // Explorer: drop an entry into a folder
Detail_Back :: struct {}
Set_Sidebar :: struct { w: f32 }
Tree_Open   :: struct { i: int, on: bool }
Tree_Pick   :: struct { i: int }
Tree_Act    :: struct { i: int }
Spring_Toast :: struct { on: bool }
Shuffle      :: struct {}
View_Mode  :: struct { grid: bool }
Context    :: struct { item: int }
Ctx_Close  :: struct {}
Select_All :: struct {}
Copy_Sel   :: struct {}                       // Files: the selected rows go on the clipboard as files
Paste_Ask  :: struct {}                       // Files: read the clipboard
Paste_Got  :: struct { n: int, first, text: string } // …what was on it (first path / text cloned)
Zoom       :: struct { by: f32 }              // Files: Ctrl+wheel travel or ±48 from the keys
Dropped_In :: struct { n: int, first: string, onto: int } // Files: files dropped from another app (first cloned), onto a row or -1
Edit_Cell  :: struct { ref: baldr.Cell_Ref } // Files: the table asked to edit a cell (F2, slow click, Tab)
Edit_Tile  :: struct { i: int }              // Files: the icon view asked to edit a tile's name
Renamed    :: struct { row: int, name: string } // Files: a name committed (cloned)
Resized    :: struct { row: int, size: string } // Files: a size cell committed (cloned)
Edit_Done  :: struct {}                      // Files / Explorer: an edit ended without a commit
Tree_Edit  :: struct { i: int }              // Explorer: F2 or a slow click on the selected entry
Tree_Renamed :: struct { i: int, name: string } // Explorer: a name committed (cloned)
Select_Row :: struct { i: int }
Open_Row   :: struct { i: int }
Sort_By    :: struct { col: int }
Set_Page     :: struct { i: int }
Set_Theme    :: struct { i: int }
Set_Remember :: struct { on: bool }
Set_Pinned   :: struct { on: bool }
Set_Notify   :: struct { on: bool }
Set_Volume   :: struct { v: f32 }
Set_Size     :: struct { v: f32 }
Search       :: struct {}
Set_Fruit    :: struct { i: int }
Menu         :: struct { open: bool }
Confirm      :: struct { open: bool }
Delete       :: struct {}
Act          :: struct { what: string }
Toast        :: struct { on: bool }
Pick         :: struct {}
Reset_Picked :: struct {}
Wide_Rows    :: struct {}
Noop         :: struct {}

START_PAGE := 0
START_GRID := false
START_PICK := -1 // --pick N: start the Explorer page with PROJECT entry N selected (testing the phone-width details page)
START_THEME := 0

AVATAR_PNG := #load("../../assets/sample/avatar.png")
PHOTO_PNG  := #load("../../assets/sample/photo.png")

init :: proc() -> State {
	avatar, _ := baldr.image_load(AVATAR_PNG)
	photo, _ := baldr.image_load(PHOTO_PNG)
	return {page = START_PAGE, avatar = avatar, photo = photo, grid = START_GRID, theme = START_THEME, applied = -1, order = {0, 1, 2, 3, 4, 5}, volume = 0.4, size = 15, fruit = 2, sel = baldr.selection_make(multi = true), sort = {column = -1},
		sidebar_w = 240, expanded = project_open(), tree_sel = START_PICK, proj = project_tree(), editing = {-1, -1}, tree_editing = -1,
		density = 1, filters = {true, false, true, false}, tags = starting_tags(), count = 3, date = baldr.today(), accent = baldr.BALDR_BLUE, alarm = {hour = 7, minute = 30},
		name = baldr.text_make("Ada Lovelace"), plan = 1, marks = {true, false, false},
		source = baldr.document_make(ODIN_SAMPLE),
		rich = rich_sample(),
		rich_src = baldr.document_make(""),
		notes = baldr.document_make("Baldr's text area edits a Document in place.\nParagraphs wrap to the width, the box grows with its lines, and Ctrl+Z undoes a word at a time. And teh marks API lets a spell checker recieve squiggles.")}
}

// file_row is the demo's data: 100 000 files generated from the index, in
// the current sort order (the app owns sorting; here it is arithmetic).
file_row :: proc(s: ^State, row: int) -> (name, kind, size, modified: string, i: int) {
	i = row
	if s.sort.column >= 0 {
		if s.sort.descending do i = 99_999 - row
		if s.sort.column == 1 do i = (row * 7919) % 100_000 // "by kind": a stable shuffle stands in for a real sort
	}
	kind = KINDS[i % len(KINDS)]
	name = fmt.tprintf("%s-%05d.%s", kind, i, "txt" if kind == "Text" else "bin")
	if renamed, has := s.renames[i]; has do name = renamed
	size = fmt.tprintf("%d KB", (i * 37) % 4096 + 1)
	if resized, has := s.sizes[i]; has do size = resized
	modified = fmt.tprintf("2026-09-%02d %02d:%02d", i % 28 + 1, i % 24, (i * 13) % 60)
	return
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Set_Page:     s.page = v.i
	case Set_Plan:     s.plan = v.i
	case Set_Mark:     s.marks[v.i] = v.on
	case Set_Sidebar:  s.sidebar_w = v.w
	case Tree_Open:    s.expanded[v.i] = v.on
	case Tree_Pick:    s.tree_sel = v.i; if !PROJECT[v.i].folder do s.detail_dismissed = false // a tap on a file shows it at phone width
	case Tree_Act:     s.tree_sel = v.i; s.tree_open = project_path(s, v.i); s.detail_dismissed = false
	case Detail_Back:  s.detail_dismissed = true
	case Reorder:
		if v.from != v.to {
			from_i, to_i := -1, -1
			for x, i in s.order { if x == v.from do from_i = i; if x == v.to do to_i = i }
			if from_i >= 0 && to_i >= 0 {
				moved := s.order[from_i]
				for i in from_i ..< 5 do s.order[i] = s.order[i + 1] // take it out
				if to_i > from_i do to_i -= 1
				at := to_i if v.before else to_i + 1
				for i := 5; i > at; i -= 1 do s.order[i] = s.order[i - 1] // make room
				s.order[at] = moved
			}
		}
	case Tree_Move:    project_move(s, v.item, v.folder)
	case Set_Density:  s.density = v.i
	case Set_Filter:   s.filters[v.i] = v.on
	case Remove_Tag:   if v.i < len(s.tags) do ordered_remove(&s.tags, v.i)
	case Set_Advanced: s.advanced = v.on
	case Show_Toast:
		s.next_toast += 1
		append(&s.toasts, Toast_Item{id = s.next_toast, text = fmt.aprintf("Message %d sent", s.next_toast)})
	case Toast_Done:
		for tst, i in s.toasts do if tst.id == v.id { delete(tst.text); ordered_remove(&s.toasts, i); break }
	case Set_Count:    s.count = v.v
	case Set_Date:     s.date = v.d
	case Set_Accent:   s.accent = v.c
	case Set_Alarm:    s.alarm = v.tm
	case Set_Clock:    s.clock = v.clock
	case Set_Seconds:  s.seconds = v.on
	case Set_Code_Lang: s.code_lang = v.i
	case Set_Code_Wrap: s.code_wrap = v.on
	case Set_Code_Ws:   s.code_ws = v.on
	case Code_Edited:   // the document is already edited in place; a real app would mark it dirty
	case Set_Rich_Mode:
		if v.mode != s.rich_mode {
			// 0 rich (blocks and runs), 1 markdown source, 2 live preview — the last two share the source document
			if s.rich_mode == 0 { // leaving the rich view: print the markdown into the source document
				md := baldr.document_markdown(&s.rich, context.temp_allocator)
				baldr.document_set_text(&s.rich_src, md)
			}
			if v.mode == 0 { // back to the rich view: parse the source
				md := baldr.document_text(&s.rich_src, context.temp_allocator)
				baldr.document_set_markdown(&s.rich, md)
			}
			if v.mode == 3 { // the reply view reads the source as it stands
				baldr.md_set(&s.reply, baldr.document_text(&s.rich_src, context.temp_allocator))
			}
			s.rich_mode = v.mode
		}
	case Follow_Link:
		delete(s.last_link)
		s.last_link = strings.clone(v.href)
	case Ask_Files:
		on_done :: proc(e: baldr.Ev(baldr.Files)) -> Msg { return Got_Files{e.value} }
		switch v.kind {
		case .Open:   return baldr.open_files(Msg, on_done, title = "Choose files", multiple = true, filters = {{name = "Images", patterns = {"*.png", "*.jpg"}}, {name = "Everything", patterns = {"*"}}})
		case .Folder: return baldr.open_files(Msg, on_done, title = "Choose a folder", directory = true)
		case .Save:   return baldr.save_file(Msg, on_done, title = "Save the notes", name = "notes.md", filters = {{name = "Markdown", patterns = {"*.md"}}})
		}
	case Got_Files:
		for f in s.files do delete(f)
		clear(&s.files)
		// `why` says which of the empty answers this is: only one is a person's choice
		switch v.files.why {
		case .Chosen:
			for p in v.files.paths do append(&s.files, strings.clone(p)) // the paths live only during this update
			s.files_note = ""
		case .Cancelled: s.files_note = "Cancelled."
		case .Not_Shown: s.files_note = "This desktop's file dialog did not open."
		case .Unusable:  s.files_note = "What was chosen is not a file on this computer."
		}
	case Crumb:
		if s.tree_sel >= 0 {
			trail := make([dynamic]int, context.temp_allocator)
			for j := s.tree_sel; j >= 0; j = s.proj[j].parent do append(&trail, j)
			k := len(trail) - 1 - v.depth
			if k >= 0 && k < len(trail) do s.tree_sel = trail[k]
		}
	case Set_Theme:    s.theme = v.i
	case Set_Remember: s.remember = v.on
	case Set_Notify:   s.notify = v.on
	case Set_Volume:   s.volume = v.v
	case Set_Size:     s.size = v.v
	case Search:       s.searches += 1
	case Set_Fruit:    s.fruit = v.i
	case Menu:         s.menu = v.open
	case Confirm:      s.confirm = v.open; s.menu = false
	case Delete:       s.deleted += 1; s.confirm = false
	case Act:       s.last = v.what; s.menu = false; s.ctx_open = false
	case Toast:        s.toast = v.on
	case Spring_Toast: s.spring = v.on
	case Shuffle:
		first := s.order[0]
		for i in 0 ..< 5 do s.order[i] = s.order[i + 1]
		s.order[5] = first
	case Pick:         s.picked += 1
	case Reset_Picked: s.picked = 0
	case Wide_Rows:    s.wide_rows = !s.wide_rows
	case Select_Row:
	case Open_Row:    _, _, _, _, _ = file_row(s, v.i); s.opened = fmt.aprintf("file %d", v.i)
	case Sort_By:
		if s.sort.column == v.col { s.sort.descending = !s.sort.descending } else { s.sort = {column = v.col} }
		baldr.selection_clear(&s.sel)
	case View_Mode: s.grid = v.grid
	case Context:   s.ctx_item = v.item; s.ctx_open = true
	case Ctx_Close: s.ctx_open = false
	case Set_Pinned: s.pinned = v.on; s.menu = false
	case Select_All: baldr.selection_all(&s.sel, 100_000); s.ctx_open = false
	case Copy_Sel:
		s.ctx_open = false
		paths := make([dynamic]string, context.temp_allocator)
		for row in s.sel.rows {
			if len(paths) >= 1000 do break
			name, _, _, _, _ := file_row(s, row)
			append(&paths, fmt.tprintf("/home/user/Files/%s", name))
		}
		return baldr.copy_files(Msg, paths[:])
	case Paste_Ask:
		s.ctx_open = false
		return baldr.paste(Msg, proc(e: baldr.Ev(baldr.Pasted)) -> Msg {
			p := e.value
			return Paste_Got{n = len(p.files), first = strings.clone(p.files[0]) if len(p.files) > 0 else "", text = strings.clone(p.text) if len(p.files) == 0 else ""}
		})
	case Paste_Got:
		delete(s.paste_note)
		switch {
		case v.n > 1:  s.paste_note = fmt.aprintf("pasted %d files, first %s", v.n, v.first)
		case v.n == 1: s.paste_note = fmt.aprintf("pasted %s", v.first)
		case len(v.text) > 0: s.paste_note = fmt.aprintf("pasted text %q", v.text)
		case: s.paste_note = strings.clone("nothing to paste")
		}
		delete(v.first)
		delete(v.text)
	case Zoom: s.zoom = clamp((s.zoom if s.zoom > 0 else 1) * math.pow(1.1, v.by / 48), 0.5, 3)
	case Dropped_In:
		delete(s.paste_note)
		s.paste_note = fmt.aprintf("dropped %d file%s here, first %s", v.n, "" if v.n == 1 else "s", v.first)
		delete(v.first)
	case Edit_Cell: s.editing = v.ref
	case Edit_Tile: s.editing = {v.i, 0}
	case Renamed:
		_, _, _, _, i := file_row(s, v.row)
		if old, had := s.renames[i]; had do delete(old)
		s.renames[i] = v.name
		s.editing = {-1, -1}
	case Resized:
		_, _, _, _, i := file_row(s, v.row)
		if old, had := s.sizes[i]; had do delete(old)
		s.sizes[i] = v.size
		s.editing = {-1, -1}
	case Edit_Done: s.editing = {-1, -1}; s.tree_editing = -1
	case Tree_Edit: s.tree_editing = v.i
	case Tree_Renamed: s.proj[v.i].name = v.name; s.tree_editing = -1
	case Noop:
	}
	return {}
}

theme_for :: proc(i: int) -> baldr.Theme {
	switch i {
	case 2:  return baldr.theme_dim()
	case 3:  return baldr.theme_light()
	case 4:  return baldr.theme_high_contrast(.Dark)
	case 5:  return baldr.theme_high_contrast(.Light)
	case 6:  return baldr.theme_from_seed(baldr.oklch(0.6, 0.15, 190), .Dark, name = "Teal")
	case 7:  return baldr.theme_from_seed(baldr.oklch(0.6, 0.20, 300), .Dim, name = "Violet")
	case 8:  return baldr.theme_from_seed(baldr.oklch(0.6, 0.18, 350), .Light, name = "Rose")
	case 9:  return solstice()
	case 10: return paper()
	}
	return baldr.theme_dark() // 1, and anything unexpected
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	// System hands the window back to the desktop; anything else pins one.
	// Applied on the change rather than every build, or following the desktop
	// would re-theme the tree for ever.
	if s.applied != s.theme {
		s.applied = s.theme
		if s.theme == 0 {
			baldr.follow_system_theme(&ui.tree)
		} else {
			baldr.set_theme(&ui.tree, theme_for(s.theme))
		}
	}
	// the gallery's own themes are generated from a seed too, so they follow every rule
	th := ui.theme
	baldr.column(ui, flex = 1, align = .Stretch); defer baldr.end(ui)

	// header: name, page tabs, theme picker. When they do not fit on one line
	// (below Expanded width, or ten tabs beside the title and the picker on a
	// window under about 1160 px) the tabs move under the title.
	sc := baldr.size_class(ui)
	stacked := sc != .Expanded || baldr.viewport(ui).x < 1160
	baldr.column(ui, bg = th.color.surface_variant); {
		defer baldr.end(ui)
		baldr.row(ui, align = .Center, gap = .lg, padding = .md if sc == .Compact else .lg); {
			defer baldr.end(ui)
			baldr.text(ui, "Baldr gallery", role = .Title, nowrap = true)
			if !stacked do baldr.tab_bar(ui, s.page, PAGES, proc(e: baldr.Ev(int)) -> Msg { return Set_Page{e.value} })
			baldr.spacer(ui)
			if sc != .Compact do baldr.text(ui, "Theme", muted = true, role = .Label, nowrap = true)
			baldr.select(ui, s.theme, THEMES, proc(e: baldr.Ev(int)) -> Msg { return Set_Theme{e.value} }, label = "Theme", width = 130 if sc == .Compact else 150)
		}
		if stacked {
			baldr.row(ui, padding = .xs); {
				defer baldr.end(ui)
				baldr.tab_bar(ui, s.page, PAGES, proc(e: baldr.Ev(int)) -> Msg { return Set_Page{e.value} })
			}
		}
	}

	if baldr.tab_panel(ui, s.page == 0, 1, padding = .xl, gap = .lg, scroll = true) { defer baldr.end(ui); page_overview(s, ui) }
	if baldr.tab_panel(ui, s.page == 1, 2, padding = .xl, gap = .lg, scroll = true) { defer baldr.end(ui); page_controls(s, ui) }
	if baldr.tab_panel(ui, s.page == 2, 3, padding = .xl, gap = .lg, scroll = true) { defer baldr.end(ui); page_inputs(s, ui) }
	if baldr.tab_panel(ui, s.page == 3, 4, padding = .xl, gap = .lg, scroll = true) { defer baldr.end(ui); page_overlays(s, ui) }
	if baldr.tab_panel(ui, s.page == 4, 5, padding = .xl, gap = .lg) { defer baldr.end(ui); page_lists(s, ui) }
	if baldr.tab_panel(ui, s.page == 5, 6, padding = .xl, gap = .lg) { defer baldr.end(ui); page_table(s, ui) }
	if baldr.tab_panel(ui, s.page == 6, 7, padding = .xl, gap = .lg, scroll = true) { defer baldr.end(ui); page_motion(s, ui) }
	if baldr.tab_panel(ui, s.page == 7, 8, padding = .xl, gap = .lg) { defer baldr.end(ui); page_explorer(s, ui) }
	if baldr.tab_panel(ui, s.page == 8, 9, padding = .xl, gap = .lg) { defer baldr.end(ui); page_editor(s, ui) }
	if baldr.tab_panel(ui, s.page == 9, 10, padding = .xl, gap = .lg) { defer baldr.end(ui); page_rich(s, ui) }
	for tst in s.toasts do baldr.toast(ui, tst.text, Msg(Toast_Done{tst.id}), action = "Undo", on_action = Msg(Act{"Undo"}), key = u64(tst.id))
	// The dialog belongs to the window rather than to a page: the Overview
	// and the Overlays page both open it.
	if baldr.dialog(ui, s.confirm, Msg(Confirm{false}), title = "Delete this file?") {
		defer baldr.end(ui)
		baldr.text(ui, "The file is moved to the bin. You can restore it from there for 30 days.")
		baldr.row(ui, gap = .sm, justify = .End); {
			defer baldr.end(ui)
			baldr.button(ui, "Cancel", Msg(Confirm{false}), variant = .Outline)
			baldr.button(ui, "Delete", Msg(Delete{}), variant = .Danger)
		}
	}
}

// ------------------------------------------------------------- Overview

// The Overview puts most of the widgets on one screen, in cards that flow into
// three columns on a wide window, two on a narrower one and one on a phone.
// Every value on it is the state the other pages edit, so a slider moved here
// has moved there too.
Section :: enum { Buttons, Inputs, Choices, Pickers, Project, Labels, Glass, Files, Overlays }

OVERVIEW_3 := [][]Section{{.Buttons, .Inputs, .Overlays}, {.Choices, .Pickers, .Project}, {.Labels, .Glass, .Files}}
OVERVIEW_2 := [][]Section{{.Buttons, .Inputs, .Pickers, .Overlays}, {.Choices, .Labels, .Glass, .Project, .Files}}
OVERVIEW_1 := [][]Section{{.Buttons, .Inputs, .Choices, .Pickers, .Labels, .Glass, .Files, .Project, .Overlays}}

PLANS := []string{"Free", "Pro", "Team"}
MARK_ICONS := [3]baldr.Icon{.Bold, .Italic, .Underline}
MARK_NAMES := [3]string{"Bold", "Italic", "Underline"}
OVERVIEW_COLS := []baldr.Column{
	{title = "Name"},
	{title = "Kind", width = 84},
	{title = "Size", width = 80, numeric = true},
}

page_overview :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	vw := baldr.viewport(ui).x
	layout := OVERVIEW_3 if vw >= 1180 else OVERVIEW_2 if vw >= 760 else OVERVIEW_1
	baldr.row(ui, gap = .lg, align = .Start); defer baldr.end(ui)
	for col, ci in layout {
		baldr.column(ui, flex = 1, gap = .lg, key = u64(ci + 1)); defer baldr.end(ui)
		for sec in col do overview_section(s, ui, sec)
	}
}

// field_label opens a row with a label in a fixed-width column, so a card's
// controls line up; the caller puts the control in it and ends it.
field_label :: proc(ui: ^baldr.Ui(Msg), label: string, loc := #caller_location) {
	baldr.row(ui, align = .Center, gap = .md, loc = loc)
	baldr.row(ui, width = 92); { defer baldr.end(ui); baldr.text(ui, label, muted = true, nowrap = true) }
}

overview_section :: proc(s: ^State, ui: ^baldr.Ui(Msg), sec: Section) {
	th := ui.theme
	baldr.card(ui, gap = .md, key = u64(sec) + 1); defer baldr.end(ui)
	switch sec {
	case .Buttons:
		baldr.text(ui, "Buttons", role = .Title)
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.button(ui, "Primary", Msg(Noop{}))
			baldr.button(ui, "Secondary", Msg(Noop{}), variant = .Secondary)
			baldr.button(ui, "Outline", Msg(Noop{}), variant = .Outline)
			baldr.button(ui, "Ghost", Msg(Noop{}), variant = .Ghost)
			baldr.button(ui, "Danger", Msg(Noop{}), variant = .Danger)
		}
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.button(ui, "Save", Msg(Noop{}), icon = .Save)
			baldr.button(ui, "Share", Msg(Noop{}), icon = .External_Link, variant = .Outline)
			baldr.button(ui, "Profile", Msg(Noop{}), image = &s.avatar, variant = .Secondary)
			baldr.button(ui, "Settings", Msg(Noop{}), icon = .Settings, icon_only = true, variant = .Outline)
			baldr.button(ui, "Disabled", Msg(Noop{}), disabled = true)
		}
		baldr.row(ui, gap = .xs, align = .Center); {
			defer baldr.end(ui)
			for i in 0 ..< 3 {
				baldr.icon_toggle(ui, MARK_ICONS[i], s.marks[i], MARK_NAMES[i],
					proc(e: baldr.Ev(bool)) -> Msg { return Set_Mark{int(e.tag), e.value} }, tag = u64(i), key = u64(i + 1))
			}
			baldr.box(ui, width = 12)
			// progress as a ring round an icon-only button: one following the
			// Volume slider below, one busy with no known end
			drive := baldr.button(ui, "Backup", Msg(Noop{}), icon = .Hard_Drive, icon_only = true, variant = .Ghost)
			baldr.button_options(ui, drive, progress = s.volume, progress_style = .Ring)
			sync := baldr.button(ui, "Syncing", Msg(Noop{}), icon = .Refresh_Cw, icon_only = true, variant = .Ghost)
			baldr.button_options(ui, sync, progress_style = .Ring, indeterminate = true)
		}
	case .Inputs:
		baldr.text(ui, "Inputs", role = .Title)
		field_label(ui, "Name"); { defer baldr.end(ui); baldr.text_input(ui, &s.name, label = "Name", flex = 1) }
		field_label(ui, "Password"); {
			defer baldr.end(ui)
			baldr.text_input(ui, &s.secret, placeholder = "Password", label = "Password", password = true, flex = 1)
		}
		field_label(ui, "Search"); {
			defer baldr.end(ui)
			baldr.search_field(ui, &s.filter, placeholder = "Filter", label = "Search", on_submit = Msg(Search{}), flex = 1)
		}
		field_label(ui, "Copies"); {
			defer baldr.end(ui)
			baldr.number_input(ui, s.count, proc(e: baldr.Ev(f32)) -> Msg { return Set_Count{e.value} }, min = 0, max = 99, label = "Copies")
		}
		field_label(ui, "Volume"); {
			defer baldr.end(ui)
			baldr.slider(ui, s.volume, flex = 1, label = "Volume", on_change = proc(e: baldr.Ev(f32)) -> Msg { return Set_Volume{e.value} })
		}
		field_label(ui, "Progress"); {
			defer baldr.end(ui)
			baldr.progress(ui, s.volume, label = "Progress", flex = 1)
			baldr.spinner(ui, label = "Working")
		}
		baldr.checkbox(ui, s.remember, "Remember me on this device", proc(e: baldr.Ev(bool)) -> Msg { return Set_Remember{e.value} })
		baldr.toggle(ui, s.notify, "Notifications", proc(e: baldr.Ev(bool)) -> Msg { return Set_Notify{e.value} })
	case .Choices:
		baldr.text(ui, "Choices", role = .Title)
		field_label(ui, "Fruit"); {
			defer baldr.end(ui)
			baldr.select(ui, s.fruit, FRUIT, proc(e: baldr.Ev(int)) -> Msg { return Set_Fruit{e.value} }, label = "Favourite fruit", width = 200)
		}
		field_label(ui, "Plan"); {
			defer baldr.end(ui)
			baldr.radio(ui, s.plan, PLANS, proc(e: baldr.Ev(int)) -> Msg { return Set_Plan{e.value} }, label = "Plan", horizontal = true)
		}
		field_label(ui, "Density"); {
			defer baldr.end(ui)
			baldr.segmented(ui, s.density, {"Compact", "Comfortable", "Spacious"}, proc(e: baldr.Ev(int)) -> Msg { return Set_Density{e.value} }, label = "Density")
		}
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			names := [4]string{"Wayland", "X11", "Windows", "macOS"}
			for name, i in names do baldr.chip(ui, name, selected = s.filters[i], tag = u64(i), key = u64(i + 1),
				on_change = proc(e: baldr.Ev(bool)) -> Msg { return Set_Filter{int(e.tag), e.value} })
		}
	case .Pickers:
		baldr.text(ui, "Date, time and colour", role = .Title)
		field_label(ui, "Due date"); {
			defer baldr.end(ui)
			baldr.date_field(ui, s.date, proc(e: baldr.Ev(baldr.Date)) -> Msg { return Set_Date{e.value} }, label = "Due date", min = {2026, 1, 1}, max = {2027, 12, 31})
		}
		field_label(ui, "Alarm"); {
			defer baldr.end(ui)
			baldr.time_field(ui, s.alarm, proc(e: baldr.Ev(baldr.Time_Of_Day)) -> Msg { return Set_Alarm{e.value} }, label = "Alarm", clock = s.clock, seconds = s.seconds)
		}
		field_label(ui, "Accent"); {
			defer baldr.end(ui)
			baldr.color_field(ui, s.accent, proc(e: baldr.Ev(baldr.Color)) -> Msg { return Set_Accent{e.value} }, label = "Accent")
			baldr.box(ui, width = 34, height = 34, bg = s.accent, radius = th.radius.md)
		}
		baldr.text(ui, fmt.tprintf("Due %s at %s, in the desktop's own format.", baldr.date_text(&ui.tree, s.date), baldr.time_text(&ui.tree, s.alarm, s.seconds, s.clock)), role = .Caption, muted = true)
	case .Project:
		baldr.text(ui, "Project", role = .Title)
		baldr.breadcrumbs(ui, {"baldr", "examples", "00_gallery"})
		explorer_tree(s, ui)
	case .Labels:
		baldr.text(ui, "Badges, avatars and tags", role = .Title)
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.badge(ui, "Neutral")
			baldr.badge(ui, "12 new", tone = .Primary)
			baldr.badge(ui, "Passing", tone = .Success)
			baldr.badge(ui, "Slow", tone = .Warning)
			baldr.badge(ui, "Failed", tone = .Danger)
		}
		baldr.row(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.image(ui, &s.avatar, width = 40, radius = 20, label = "Avatar")
			// Initials in white, on fills dark enough to keep it above 4.5:1.
			people := [3]struct { initials: string, fill: u32 }{{"AL", 0x2563EB}, {"JS", 0x7C3AED}, {"MK", 0xBE123C}}
			for p, i in people {
				baldr.row(ui, width = 40, height = 40, radius = 20, bg = baldr.rgb(p.fill), align = .Center, justify = .Center, key = u64(i + 1)); {
					defer baldr.end(ui)
					baldr.text(ui, p.initials, role = .Label, color = {1, 1, 1, 1})
				}
			}
		}
		baldr.wrap(ui, gap = .sm, align = .Center, animate = true); {
			defer baldr.end(ui)
			for tag, i in s.tags do baldr.chip(ui, tag, icon = .Star, on_close = Msg(Remove_Tag{i}), key = u64(i + 1))
			if len(s.tags) == 0 do baldr.text(ui, "All tags removed.", muted = true)
		}
		if baldr.expander(ui, "What these are for", s.advanced, on_change = proc(e: baldr.Ev(bool)) -> Msg { return Set_Advanced{e.value} }) {
			defer baldr.end(ui)
			baldr.text(ui, "Badges carry a count or a state, avatars a person, and a tag's × removes it (Backspace does on a focused one).", muted = true)
		}
	case .Glass:
		baldr.text(ui, "Frosted glass", role = .Title)
		baldr.stack(ui, height = 132); {
			defer baldr.end(ui)
			baldr.row(ui, gap = .sm, height = 132, align = .Stretch); {
				defer baldr.end(ui)
				tiles := [?]u32{0xE5484D, 0xF2B544, 0x22C55E, 0x3B82F6, 0x8B5CF6, 0xEC4899}
				for c, i in tiles do baldr.box(ui, flex = 1, bg = baldr.rgb(c), radius = th.radius.md, key = u64(i + 1))
			}
			baldr.card(ui, glass = true, offset = {18, 22}, width = 260, elevation = .High, gap = .xs); {
				defer baldr.end(ui)
				baldr.text(ui, "Blurred by the renderer", role = .Label)
				baldr.text(ui, "Tinted by the theme, and opaque when the desktop asks for less transparency.", role = .Caption, muted = true)
			}
		}
	case .Files:
		baldr.text(ui, "Files", role = .Title)
		first, last := baldr.table(ui, OVERVIEW_COLS, 100_000, &s.sel,
			on_select = proc(e: baldr.Ev(int)) -> Msg { return Select_Row{e.value} },
			on_activate = proc(e: baldr.Ev(int)) -> Msg { return Open_Row{e.value} },
			sort = s.sort, on_sort = proc(e: baldr.Ev(int)) -> Msg { return Sort_By{e.value} },
			row_height = 32, rows = 6, flex = 0, label = "Files"); {
			defer baldr.end(ui)
			for row in first ..< last {
				name, kind, size, _, i := file_row(s, row)
				baldr.table_row(ui, row); {
					defer baldr.end(ui)
					baldr.cell_text(ui, name, icon = KIND_ICONS[i % len(KIND_ICONS)])
					baldr.cell_text(ui, kind, muted = true)
					baldr.cell_text(ui, size, tabular = true)
				}
			}
		}
		n := baldr.selection_count(&s.sel)
		baldr.text(ui, "100 000 rows, built as they scroll into view" if n == 0 else fmt.tprintf("%d of 100 000 selected", n), role = .Caption, muted = true)
	case .Overlays:
		baldr.text(ui, "Menus, tooltips and dialogs", role = .Title)
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			more := baldr.button(ui, "Actions…", Msg(Menu{true}), variant = .Outline, icon = .Ellipsis)
			baldr.tooltip(ui, more, "Rename, duplicate or delete the file")
			baldr.button(ui, "Show a toast", Msg(Show_Toast{}), variant = .Secondary, icon = .Bell)
			del := baldr.button(ui, "Delete…", Msg(Confirm{true}), variant = .Danger, icon = .Trash)
			baldr.tooltip(ui, del, "Asks first: nothing is deleted without confirming")
			if baldr.menu(ui, more, s.menu, Msg(Menu{false})) {
				defer baldr.end(ui)
				baldr.menu_item(ui, "Rename", Msg(Act{"Rename"}), shortcut = "F2", icon = .Pencil)
				baldr.menu_item(ui, "Duplicate", Msg(Act{"Duplicate"}), shortcut = "Ctrl+D", icon = .Copy)
				baldr.menu_item(ui, "Pinned", Msg(Set_Pinned{!s.pinned}), checked = s.pinned)
				baldr.separator(ui)
				baldr.menu_item(ui, "Delete…", Msg(Confirm{true}), shortcut = "Del", icon = .Trash)
			}
		}
		status := "Nothing chosen yet." if s.last == "" else fmt.tprintf("Last: %s", s.last)
		if s.deleted > 0 do status = fmt.tprintf("%s · deleted %d", status, s.deleted)
		baldr.text(ui, status, role = .Caption, muted = true)
	}
}

page_controls :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.text(ui, "Controls", role = .Headline)
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Buttons", role = .Title)
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.button(ui, "Primary", Msg(Noop{}))
			baldr.button(ui, "Secondary", Msg(Noop{}), variant = .Secondary)
			baldr.button(ui, "Outline", Msg(Noop{}), variant = .Outline)
			baldr.button(ui, "Ghost", Msg(Noop{}), variant = .Ghost)
			baldr.button(ui, "Danger", Msg(Noop{}), variant = .Danger)
			baldr.button(ui, "Disabled", Msg(Noop{}), disabled = true)
		}
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.button(ui, "Save", Msg(Noop{}), icon = .Save)
			baldr.button(ui, "Download", Msg(Noop{}), icon = .Download, variant = .Secondary)
			baldr.button(ui, "Share", Msg(Noop{}), icon = .External_Link, variant = .Outline)
			baldr.button(ui, "Settings", Msg(Noop{}), icon = .Settings, icon_only = true, variant = .Outline)
			baldr.button(ui, "Search", Msg(Noop{}), icon = .Search, icon_only = true, variant = .Ghost)
			baldr.button(ui, "Delete", Msg(Noop{}), icon = .Trash, icon_only = true, variant = .Danger)
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Images", role = .Title)
		baldr.text(ui, "PNGs decoded by Odin's core decoder, uploaded to the atlas once, drawn with rounded corners; buttons take a picture as well as an icon.", muted = true)
		baldr.wrap(ui, gap = .md, align = .Center); { // a wrap, not a row: these flow onto more lines when narrow
			defer baldr.end(ui)
			baldr.image(ui, &s.photo, height = 72, radius = 8, label = "Sample photo")
			baldr.image(ui, &s.avatar, width = 56, radius = 28, label = "Avatar")
			baldr.image(ui, &s.avatar, width = 32, radius = 6)
			baldr.button(ui, "Profile", Msg(Noop{}), image = &s.avatar, variant = .Outline)
			baldr.button(ui, "Open photo", Msg(Noop{}), image = &s.photo, variant = .Secondary)
			baldr.button(ui, "Account", Msg(Noop{}), image = &s.avatar, icon_only = true, variant = .Ghost)
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Icons", role = .Title)
		baldr.text(ui, fmt.tprintf("%d Lucide icons vendored, drawn from their SVG paths at any size; hover for the name.", len(baldr.Icon) - 1), muted = true)
		baldr.wrap(ui, gap = .sm); {
			defer baldr.end(ui)
			for ic in baldr.Icon {
				if ic == .None do continue
				n := baldr.icon(ui, ic, size = 20, key = u64(ic) + 1)
				baldr.tooltip(ui, n, baldr.ICON_NAMES[ic])
			}
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Choices", role = .Title)
		baldr.checkbox(ui, s.remember, "Remember me on this device", proc(e: baldr.Ev(bool)) -> Msg { return Set_Remember{e.value} })
		baldr.toggle(ui, s.notify, "Notifications", proc(e: baldr.Ev(bool)) -> Msg { return Set_Notify{e.value} })
		baldr.checkbox(ui, false, "Two-factor (managed by your organisation)", nil, disabled = true)
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "One of a few", role = .Title)
		baldr.text(ui, "A radio group and a segmented control are one Tab stop each: the arrow keys move the pick.", muted = true)
		baldr.row(ui, gap = .xl, vertical = baldr.size_class(ui) == .Compact); {
			defer baldr.end(ui)
			baldr.radio(ui, s.fruit, FRUIT, proc(e: baldr.Ev(int)) -> Msg { return Set_Fruit{e.value} }, label = "Favourite fruit")
			baldr.column(ui, gap = .sm, align = .Start); {
				defer baldr.end(ui)
				baldr.text(ui, "Density", role = .Label, muted = true)
				baldr.segmented(ui, s.density, {"Compact", "Comfortable", "Spacious"}, proc(e: baldr.Ev(int)) -> Msg { return Set_Density{e.value} }, label = "Density")
			}
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Chips and badges", role = .Title)
		baldr.text(ui, "Filter chips flip; tag chips have a × (Backspace removes a focused one). Badges are small pills for counts and states.", muted = true)
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			names := [4]string{"Wayland", "Win32", "macOS", "X11"}
			for name, i in names do baldr.chip(ui, name, selected = s.filters[i], tag = u64(i), key = u64(i + 1),
				on_change = proc(e: baldr.Ev(bool)) -> Msg { return Set_Filter{int(e.tag), e.value} })
		}
		baldr.wrap(ui, gap = .sm, align = .Center, animate = true); {
			defer baldr.end(ui)
			for tag, i in s.tags do baldr.chip(ui, tag, icon = .Star, on_close = Msg(Remove_Tag{i}), key = u64(i + 1))
			if len(s.tags) == 0 do baldr.text(ui, "All tags removed.", muted = true)
		}
		baldr.wrap(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.badge(ui, "Neutral")
			baldr.badge(ui, "12 new", tone = .Primary)
			baldr.badge(ui, "Passing", tone = .Success)
			baldr.badge(ui, "Slow", tone = .Warning)
			baldr.badge(ui, "Failed", tone = .Danger)
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Progress", role = .Title)
		baldr.row(ui, gap = .md, align = .Center); {
			defer baldr.end(ui)
			baldr.text(ui, "Volume", muted = true, nowrap = true)
			baldr.progress(ui, s.volume, label = "Volume", flex = 1)
			baldr.text(ui, fmt.tprintf("%d%%", int(s.volume * 100 + 0.5)), role = .Caption, muted = true, nowrap = true)
		}
		baldr.row(ui, gap = .md, align = .Center); {
			defer baldr.end(ui)
			baldr.text(ui, "Working", muted = true, nowrap = true)
			baldr.progress(ui, 0, label = "Working", flex = 1, indeterminate = true)
			baldr.spinner(ui, label = "Working")
		}
		if baldr.expander(ui, "About these", s.advanced, on_change = proc(e: baldr.Ev(bool)) -> Msg { return Set_Advanced{e.value} }) {
			defer baldr.end(ui)
			baldr.text(ui, "The bar eases to a new value; the indeterminate band and the spinner keep moving on their own and hold still under reduce-motion. This expander's content fades up when opened.", muted = true)
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Colour", role = .Title)
		baldr.text(ui, "The field opens the picker: hue, chroma and lightness in OKLCH — the space the themes are built in — so every step is an even one and the tracks show what they select. The same picker sits inline as color_picker.", muted = true)
		baldr.row(ui, gap = .lg, align = .Center, vertical = baldr.size_class(ui) == .Compact); {
			defer baldr.end(ui)
			baldr.color_field(ui, s.accent, proc(e: baldr.Ev(baldr.Color)) -> Msg { return Set_Accent{e.value} }, label = "Accent")
			baldr.box(ui, width = 120, height = 34, bg = s.accent, radius = ui.theme.radius.md)
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Sliders", role = .Title)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			baldr.text(ui, "Text size", muted = true)
			baldr.slider(ui, s.size, min = 12, max = 24, step = 1, flex = 1, label = "Text size", on_change = proc(e: baldr.Ev(f32)) -> Msg { return Set_Size{e.value} })
			baldr.row(ui, width = 52, justify = .End); { defer baldr.end(ui); baldr.text(ui, fmt.tprintf("%.0f px", s.size), role = .Label) }
		}
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			baldr.text(ui, "Volume", muted = true)
			baldr.slider(ui, s.volume, flex = 1, label = "Volume", on_change = proc(e: baldr.Ev(f32)) -> Msg { return Set_Volume{e.value} })
			baldr.row(ui, width = 52, justify = .End); { defer baldr.end(ui); baldr.text(ui, fmt.tprintf("%d%%", int(s.volume * 100)), role = .Label) }
		}
	}
}

page_inputs :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.text(ui, "Inputs", role = .Headline)
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Text", role = .Title)
		baldr.row(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.text_input(ui, &s.search, placeholder = "Search everything…", label = "Search", on_submit = Msg(Search{}), flex = 1)
			baldr.button(ui, "Search", Msg(Search{}), variant = .Secondary)
		}
		baldr.text_input(ui, &s.secret, placeholder = "Password", label = "Password", password = true, width = 260)
		// A search box is its own control, not a field with decorations:
		// the cross appears with the text, Escape clears it before it
		// closes anything, Enter runs the search at once.
		baldr.search_field(ui, &s.filter, placeholder = "Filter these controls",
			on_submit = Msg(Search{}), width = 260)
		baldr.row(ui, gap = .md, align = .Center); {
			defer baldr.end(ui)
			baldr.text(ui, "Copies", muted = true, nowrap = true)
			baldr.number_input(ui, s.count, proc(e: baldr.Ev(f32)) -> Msg { return Set_Count{e.value} }, min = 0, max = 99, label = "Copies")
			baldr.text(ui, "Up / Down step, Shift for ten; Enter or leaving the field commits what you typed.", muted = true, role = .Caption)
		}
		if s.searches > 0 do baldr.text(ui, fmt.tprintf("Searched for “%s” (%d so far)", baldr.str(s.search), s.searches), muted = true)
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Files", role = .Title)
		baldr.text(ui, "The desktop's own dialog, asked for by a command from update; the outcome comes back as a message.", muted = true)
		baldr.wrap(ui, gap = .sm); {
			defer baldr.end(ui)
			baldr.button(ui, "Open files…", Msg(Ask_Files{.Open}), icon = .Folder_Open, variant = .Secondary)
			baldr.button(ui, "Choose a folder…", Msg(Ask_Files{.Folder}), icon = .Folder, variant = .Secondary)
			baldr.button(ui, "Save as…", Msg(Ask_Files{.Save}), icon = .Save, variant = .Secondary)
		}
		for f in s.files do baldr.text(ui, f, role = .Caption, nowrap = true, ellipsis = .Middle)
		if s.files_note != "" do baldr.text(ui, s.files_note, muted = true, role = .Caption)
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Date and time", role = .Title)
		baldr.text(ui, fmt.tprintf("Names, the first weekday, date order, the clock style and the decimal mark follow the desktop's locale (%s here). The fields open their pickers; the same widgets sit inline as date_picker and time_picker.", ui.locale.tag), muted = true)
		baldr.row(ui, gap = .lg, align = .Center, vertical = baldr.size_class(ui) == .Compact); {
			defer baldr.end(ui)
			baldr.date_field(ui, s.date, proc(e: baldr.Ev(baldr.Date)) -> Msg { return Set_Date{e.value} }, label = "Due date", min = {2026, 1, 1}, max = {2027, 12, 31})
			baldr.time_field(ui, s.alarm, proc(e: baldr.Ev(baldr.Time_Of_Day)) -> Msg { return Set_Alarm{e.value} }, label = "Alarm", clock = s.clock, seconds = s.seconds)
			baldr.text(ui, fmt.tprintf("Due %s at %s", baldr.date_text(&ui.tree, s.date), baldr.time_text(&ui.tree, s.alarm, s.seconds, s.clock)), muted = true)
		}
		// The time field's `clock` follows the locale unless forced; `seconds`
		// adds the third segment. The same widget sits inline as `time_picker`.
		baldr.row(ui, gap = .lg, align = .Center, vertical = baldr.size_class(ui) == .Compact); {
			defer baldr.end(ui)
			baldr.segmented(ui, int(s.clock), {"Locale", "24 h", "12 h"}, proc(e: baldr.Ev(int)) -> Msg { return Set_Clock{baldr.Clock(e.value)} }, label = "Clock")
			baldr.checkbox(ui, s.seconds, "Seconds", proc(e: baldr.Ev(bool)) -> Msg { return Set_Seconds{e.value} })
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Text area", role = .Title)
		// A toy spell checker: squiggle a few common misspellings. A real one is
		// a dictionary package producing the same marks.
		marks := make([dynamic]baldr.Mark, context.temp_allocator)
		for b in 0 ..< baldr.block_count(&s.notes) {
			line := baldr.block_str(&s.notes, b)
			for word in ([]string{"teh", "recieve", "seperate", "definately"}) {
				at := 0
				for {
					i := strings.index(line[at:], word)
					if i < 0 do break
					append(&marks, baldr.Mark{from = {b, at + i}, to = {b, at + i + len(word)}, kind = .Error, message = "Did you mean “the”?" if word == "teh" else "Did you mean “receive”?"})
					at += i + len(word)
				}
			}
		}
		notes := baldr.text_area(ui, &s.notes, placeholder = "Notes…", label = "Notes")
		baldr.editor_options(ui, notes, min_lines = 3, max_lines = 8, max_length = 400)
		baldr.editor_marks(ui, notes, marks[:])
		baldr.text(ui, fmt.tprintf("%d paragraphs · %d/400 characters · misspell “teh” or “recieve” for a squiggle", baldr.block_count(&s.notes), baldr.document_rune_count(&s.notes)), role = .Label, muted = true)
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Select", role = .Title)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			baldr.text(ui, "Favourite fruit", muted = true)
			baldr.select(ui, s.fruit, FRUIT, proc(e: baldr.Ev(int)) -> Msg { return Set_Fruit{e.value} }, label = "Favourite fruit", width = 220)
		}
		baldr.text(ui, fmt.tprintf("You picked %s.", FRUIT[s.fruit]), role = .Label, muted = true)
	}
}

page_overlays :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.text(ui, "Overlays", role = .Headline)
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Menu bar", role = .Title)
		baldr.text(ui, "Click a title or press F10; Left and Right move across, hovering switches an open menu, Escape closes.", muted = true)
		baldr.menu_bar(ui); {
			defer baldr.end(ui)
			if baldr.menu_bar_menu(ui, "File") {
				defer baldr.end(ui)
				baldr.menu_item(ui, "New", Msg(Act{"New"}), shortcut = "Ctrl+N", icon = .File_Plus)
				baldr.menu_item(ui, "Open…", Msg(Act{"Open"}), shortcut = "Ctrl+O", icon = .Folder_Open)
				baldr.menu_item(ui, "Save", Msg(Act{"Save"}), shortcut = "Ctrl+S", icon = .Save)
				baldr.separator(ui)
				baldr.menu_item(ui, "Quit", Msg(Act{"Quit"}), shortcut = "Ctrl+Q")
			}
			if baldr.menu_bar_menu(ui, "Edit") {
				defer baldr.end(ui)
				baldr.menu_item(ui, "Undo", Msg(Act{"Undo"}), shortcut = "Ctrl+Z", icon = .Undo_2)
				baldr.menu_item(ui, "Redo", Msg(Act{"Redo"}), shortcut = "Ctrl+Y", icon = .Redo_2)
				baldr.separator(ui)
				baldr.menu_item(ui, "Cut", Msg(Act{"Cut"}), shortcut = "Ctrl+X", icon = .Scissors)
				baldr.menu_item(ui, "Copy", Msg(Act{"Copy"}), shortcut = "Ctrl+C", icon = .Copy)
				baldr.menu_item(ui, "Paste", Msg(Act{"Paste"}), shortcut = "Ctrl+V", icon = .Clipboard)
			}
			if baldr.menu_bar_menu(ui, "View") {
				defer baldr.end(ui)
				baldr.menu_item(ui, "Zoom in", Msg(Act{"Zoom in"}), shortcut = "Ctrl++", icon = .Zoom_In)
				baldr.menu_item(ui, "Zoom out", Msg(Act{"Zoom out"}), shortcut = "Ctrl+-", icon = .Zoom_Out)
			}
			if baldr.menu_bar_menu(ui, "Help") {
				defer baldr.end(ui)
				baldr.menu_item(ui, "About the gallery", Msg(Act{"About"}), icon = .Info)
			}
		}
		if s.last != "" do baldr.text(ui, fmt.tprintf("Last: %s", s.last), role = .Label, muted = true)
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Menu and tooltip", role = .Title)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			more := baldr.button(ui, "Actions…", Msg(Menu{true}), variant = .Outline)
			baldr.tooltip(ui, more, "Rename, duplicate or delete the file")
			baldr.shortcut(ui, "F2", Msg(Act{"Rename"}))     // the menu shows the hint; this makes the key work
			baldr.shortcut(ui, "Ctrl+D", Msg(Act{"Duplicate"}))
			baldr.text(ui, s.last == "" ? "Nothing chosen yet." : fmt.tprintf("Last: %s", s.last), muted = true)
			if baldr.menu(ui, more, s.menu, Msg(Menu{false})) {
				defer baldr.end(ui)
				baldr.menu_item(ui, "Rename", Msg(Act{"Rename"}), shortcut = "F2", icon = .Pencil)
				baldr.menu_item(ui, "Duplicate", Msg(Act{"Duplicate"}), shortcut = "Ctrl+D", icon = .Copy)
				if baldr.submenu(ui, "Move to", icon = .Folder) { // a submenu; "More…" inside it nests another
					defer baldr.end(ui)
					baldr.menu_item(ui, "Documents", Msg(Act{"Move to Documents"}))
					baldr.menu_item(ui, "Pictures", Msg(Act{"Move to Pictures"}))
					if baldr.submenu(ui, "More…") {
						defer baldr.end(ui)
						baldr.menu_item(ui, "Desktop", Msg(Act{"Move to Desktop"}))
						baldr.menu_item(ui, "Downloads", Msg(Act{"Move to Downloads"}))
					}
				}
				baldr.menu_item(ui, "Pinned", Msg(Set_Pinned{!s.pinned}), checked = s.pinned) // a check item
				baldr.separator(ui)
				baldr.menu_item(ui, "Delete…", Msg(Confirm{true}), shortcut = "Del", icon = .Trash)
			}
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Toasts", role = .Title)
		baldr.text(ui, "A brief message at the bottom that goes away by itself (it waits while the pointer rests on it); several stack.", muted = true)
		baldr.row(ui); {
			defer baldr.end(ui)
			baldr.button(ui, "Send a message", Msg(Show_Toast{}), icon = .Check)
		}
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Dialog", role = .Title)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			del := baldr.button(ui, "Delete file…", Msg(Confirm{true}), variant = .Danger, icon = .Trash)
			baldr.tooltip(ui, del, "Asks first — nothing is deleted without confirming")
			baldr.text(ui, fmt.tprintf("Deleted %d file(s).", s.deleted), muted = true)
		}
	}
}

page_lists :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	compact := baldr.size_class(ui) == .Compact
	// The header stacks at phone width: the title on its own line, the
	// count and the button under it.
	baldr.row(ui, align = .Center, gap = .md, vertical = compact); {
		defer baldr.end(ui)
		baldr.text(ui, "Inbox", role = .Headline)
		if !compact do baldr.spacer(ui)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			baldr.text(ui, fmt.tprintf("100 000 messages · %d picked", s.picked), muted = true, nowrap = true, ellipsis = .End)
			baldr.spacer(ui)
			baldr.button(ui, "Wide rows", Msg(Wide_Rows{}), variant = .Outline, pressed = s.wide_rows)
			baldr.button(ui, "Clear", Msg(Reset_Picked{}), variant = .Outline, disabled = s.picked == 0)
		}
	}
	// A virtualised list: 100 000 rows, only the visible ones exist as nodes.
	// At phone width a row is taller and its preview wraps to two lines, like
	// a mail app; wider, one line each.
	row_h: f32 = 100 if compact else 76
	// "Wide rows": rows wider than the list (a log's long lines, pages zoomed
	// past fit width). `content_width` lays them out that wide instead of
	// squeezing them into the viewport, and the list scrolls both ways: a bar
	// along its bottom, the vertical one still at its right edge, panned by
	// the wheel's x, Shift+wheel, a touchpad or Shift+Page.
	first, last := baldr.list(ui, 100_000, row_height = row_h, gap = .sm, label = "Inbox",
		content_width = 1800 if s.wide_rows else 0); defer baldr.end(ui)
	for i in first ..< last {
		baldr.card(ui, elevation = .Low, gap = .xs, padding = .md, key = u64(i + 1)); {
			defer baldr.end(ui)
			baldr.row(ui, align = .Center, gap = .md); {
				defer baldr.end(ui)
				baldr.box(ui, width = 10, height = 10, radius = 5, bg = ui.theme.color.primary if i % 3 == 0 else ui.theme.color.outline)
				baldr.text(ui, fmt.tprintf("Message %d — build finished", i + 1), role = .Title, nowrap = true, ellipsis = .End)
				baldr.spacer(ui)
				baldr.button(ui, "Pick", Msg(Pick{}), variant = .Ghost)
			}
			if s.wide_rows {
				// No ellipsis: the line runs past the list, which is the point — pan to its end.
				baldr.text(ui, "2026-10-20 09:14:22.118  worker-7  INFO   build finished in 4.812 s · 1 240 files · cache 97 % · peak 1.6 GB · artefacts/baldr-0.9.3-linux-amd64.tar.zst · sha256 9f2c…a41d · uploaded to releases/nightly · notified 3 watchers",
					muted = true, nowrap = true)
			} else {
				baldr.text(ui, "Wheel, Page Up/Down, Home/End, drag the thumb or click the track. Rows are built on demand.",
					muted = true, nowrap = !compact, ellipsis = .End, max_lines = 2 if compact else 0)
			}
		}
	}
}

page_table :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, align = .Center, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Files", role = .Headline)
		baldr.spacer(ui)
		baldr.button(ui, "List view", Msg(View_Mode{false}), icon = .List, icon_only = true, variant = .Secondary if !s.grid else .Ghost)
		baldr.button(ui, "Icon view", Msg(View_Mode{true}), icon = .Layout_Grid, icon_only = true, variant = .Secondary if s.grid else .Ghost)
		n := baldr.selection_count(&s.sel)
		status := "100 000 files" if n == 0 else fmt.tprintf("%d of 100 000 selected", n)
		if s.opened != "" do status = fmt.tprintf("%s · opened %s", status, s.opened)
		if s.paste_note != "" do status = fmt.tprintf("%s · %s", status, s.paste_note)
		baldr.text(ui, status, muted = true)
	}
	baldr.shortcut(ui, "Ctrl+C", Msg(Copy_Sel{}))   // the context menu shows the hints; these make the keys work
	baldr.shortcut(ui, "Ctrl+V", Msg(Paste_Ask{}))
	baldr.shortcut(ui, "Ctrl++", Msg(Zoom{48}))
	baldr.shortcut(ui, "Ctrl+-", Msg(Zoom{-48}))
	zoom := s.zoom if s.zoom > 0 else 1
	if s.grid {
		baldr.text(ui, "Click, Ctrl-click and Shift-click select, or drag a band over empty space; arrows move across the grid, Space, Ctrl+A and Enter work with the keyboard.", muted = true)
		first, last := baldr.icon_view(ui, 100_000, &s.sel,
			on_select = proc(e: baldr.Ev(int)) -> Msg { return Select_Row{e.value} },
			on_activate = proc(e: baldr.Ev(int)) -> Msg { return Open_Row{e.value} },
			on_context = proc(e: baldr.Ev(int)) -> Msg { return Context{e.value} },
			on_zoom = proc(e: baldr.Ev(f32)) -> Msg { return Zoom{e.value} }, // Ctrl+wheel: bigger or smaller tiles
			on_edit = proc(e: baldr.Ev(int)) -> Msg { return Edit_Tile{e.value} }, // F2 / a slow click: rename in place
			drag = "file", drag_files = files_of_rows, drag_user = s, // tiles drag out to other apps as files…
			on_drop = files_dropped, accepts = "files",              // …and files from other apps drop in
			tile = baldr.icon_view_look(&ui.tree.theme).tile * zoom, label = "Files"); { // scaled from the theme's, so a theme's tile still applies
			defer baldr.end(ui)
			for row in first ..< last {
				name, _, _, _, i := file_row(s, row)
				if s.editing.row == row {
					baldr.icon_item(ui, row, KIND_ICONS[i % len(KIND_ICONS)], name, on_submit = renamed, on_cancel = Msg(Edit_Done{}))
				} else {
					baldr.icon_item(ui, row, KIND_ICONS[i % len(KIND_ICONS)], name)
				}
			}
			files_context_menu(s, ui)
			return
		}
	}
	baldr.text(ui, "Click, Ctrl-click and Shift-click select; arrows, Space, Ctrl+A and Enter work with the keyboard. Drag a header divider to resize, drag a header to reorder (Shift or Ctrl + arrows do the same), click a header to sort.", muted = true)
	first, last := baldr.table(ui, FILE_COLS, 100_000, &s.sel,
		on_select = proc(e: baldr.Ev(int)) -> Msg { return Select_Row{e.value} },
		on_activate = proc(e: baldr.Ev(int)) -> Msg { return Open_Row{e.value} },
		on_context = proc(e: baldr.Ev(int)) -> Msg { return Context{e.value} },
		sort = s.sort, on_sort = proc(e: baldr.Ev(int)) -> Msg { return Sort_By{e.value} },
		on_zoom = proc(e: baldr.Ev(f32)) -> Msg { return Zoom{e.value} }, // Ctrl+wheel: row density
		on_edit = proc(e: baldr.Ev(baldr.Cell_Ref)) -> Msg { return Edit_Cell{e.value} }, // F2 / a slow click / Tab: edit a cell in place
		drag = "file", drag_files = files_of_rows, drag_user = s, // rows drag out to other apps as files…
		on_drop = files_dropped, accepts = "files",              // …and files from other apps drop in
		row_height = baldr.table_look(&ui.tree.theme).row_height * zoom, label = "Files"); { // the theme's and its density, zoomed
		defer baldr.end(ui)
		files_context_menu(s, ui)
		for row in first ..< last {
			name, kind, size, modified, i := file_row(s, row)
			baldr.table_row(ui, row); {
				defer baldr.end(ui)
				if s.editing == (baldr.Cell_Ref{row, 0}) { // the name, selected up to its extension
					baldr.cell_edit(ui, name, renamed, on_cancel = Msg(Edit_Done{}))
				} else {
					baldr.cell_text(ui, name, icon = KIND_ICONS[i % len(KIND_ICONS)])
				}
				baldr.cell_text(ui, kind, muted = true)
				if s.editing == (baldr.Cell_Ref{row, 2}) { // a data cell: all of it selected
					baldr.cell_edit(ui, size, proc(e: baldr.Ev(string)) -> Msg { return Resized{int(e.tag), strings.clone(e.value)} }, on_cancel = Msg(Edit_Done{}), select_stem = false)
				} else {
					baldr.cell_text(ui, size)
				}
				baldr.cell_text(ui, modified, muted = true)
			}
		}
	}
}

// renamed: a name committed in place (the table's or the icon view's editor).
renamed :: proc(e: baldr.Ev(string)) -> Msg { return Renamed{int(e.tag), strings.clone(e.value)} }

// files_of_rows: the paths a drag carries once it leaves the window — the
// selection when the dragged row is part of it, else that row.
files_of_rows :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> []string {
	s := (^State)(user)
	out := make([dynamic]string, allocator)
	if count > 1 {
		for row in s.sel.rows {
			if len(out) >= 1000 do break
			name, _, _, _, _ := file_row(s, row)
			append(&out, fmt.aprintf("/home/user/Files/%s", name, allocator = allocator))
		}
	} else {
		name, _, _, _, _ := file_row(s, int(tag))
		append(&out, fmt.aprintf("/home/user/Files/%s", name, allocator = allocator))
	}
	return out[:]
}

// files_dropped: files from another app landed on the view (Ev.tag = the
// row they landed on).
files_dropped :: proc(e: baldr.Ev(baldr.Drop)) -> Msg {
	if e.value.kind != "files" do return nil
	return Dropped_In{n = len(e.value.files), first = strings.clone(e.value.files[0]) if len(e.value.files) > 0 else "", onto = int(e.tag)}
}

// files_context_menu: right-click (or the Menu key) on a file or on the
// folder background. The app decides what the menu holds.
files_context_menu :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	// A builder that answers whether it opened at all is opened by an `if`,
	// and the whole proc is its scope — so the defer goes here rather than
	// into a block of its own.
	if !baldr.context_menu(ui, s.ctx_open, Msg(Ctx_Close{})) do return
	defer baldr.end(ui)
	if s.ctx_item >= 0 {
		n := baldr.selection_count(&s.sel)
		baldr.menu_item(ui, "Open" if n <= 1 else fmt.tprintf("Open %d items", n), Msg(Open_Row{s.ctx_item}), icon = .Eye)
		baldr.menu_item(ui, "Rename", Msg(Act{"Rename"}), shortcut = "F2", icon = .Pencil)
		baldr.menu_item(ui, "Copy", Msg(Copy_Sel{}), shortcut = "Ctrl+C", icon = .Copy)
		baldr.separator(ui)
		baldr.menu_item(ui, "Delete", Msg(Confirm{true}), shortcut = "Del", icon = .Trash)
	} else {
		baldr.menu_item(ui, "New folder", Msg(Act{"New folder"}), shortcut = "Ctrl+Shift+N", icon = .Folder_Plus)
		baldr.menu_item(ui, "Paste", Msg(Paste_Ask{}), shortcut = "Ctrl+V", icon = .Clipboard)
		baldr.separator(ui)
		if baldr.submenu(ui, "Sort by", icon = .Arrow_Up_Down) { // a submenu of radio items: the table's sort
			defer baldr.end(ui)
			for c, col in FILE_COLS do baldr.menu_item(ui, c.title, Msg(Sort_By{col}), checked = s.sort.column == col, radio = true)
		}
		baldr.menu_item(ui, "Icon view", Msg(View_Mode{!s.grid}), checked = s.grid) // a check item
		baldr.separator(ui)
		baldr.menu_item(ui, "Select all", Msg(Select_All{}), shortcut = "Ctrl+A", icon = .Square_Check)
	}
}

page_motion :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.text(ui, "Motion", role = .Headline)
	baldr.text(ui, "Hover, press and focus ease over the theme's fast duration. Enter and exit transitions are opt-in per node and instant under reduce-motion.", muted = true)
	baldr.row(ui, gap = .sm); {
		defer baldr.end(ui)
		baldr.button(ui, "Show toast" if !s.toast else "Hide toast", Msg(Toast{!s.toast}))
		baldr.button(ui, "Spring toast" if !s.spring else "Hide spring toast", Msg(Spring_Toast{!s.spring}), variant = .Secondary)
		baldr.button(ui, "Shuffle chips", Msg(Shuffle{}), variant = .Outline, icon = .Refresh_Cw)
	}
	// Everything below this row glides when the toasts push it (animate).
	baldr.column(ui, gap = .lg, animate = true); {
		defer baldr.end(ui)
		if s.toast {
			c := baldr.card(ui, width = 360, gap = .xs, elevation = .High, key = 1); {
				defer baldr.end(ui)
				baldr.transition(ui, c, .Fade_Up, .Fade)
				baldr.text(ui, "Saved", role = .Title)
				baldr.text(ui, "Your changes are safe. This card fades up when it appears and out when it leaves.", muted = true)
			}
		}
		if s.spring {
			c := baldr.card(ui, width = 360, gap = .xs, elevation = .High, key = 2); {
				defer baldr.end(ui)
				baldr.transition(ui, c, .Fade_Up, .Fade, easing = .Spring)
				baldr.text(ui, "Springy", role = .Title)
				baldr.text(ui, "Same transition with a spring: a small overshoot, then it settles.", muted = true)
			}
		}
		baldr.card(ui, gap = .md, key = 3); {
			defer baldr.end(ui)
			baldr.text(ui, "Animated moves", role = .Title)
			baldr.text(ui, "Chips are keyed; when the order changes they glide to their new slots instead of jumping. Drag one over another: the rest part to show where it will land, and dropping confirms it. Resizing the window never animates.", muted = true)
			baldr.wrap(ui, gap = .sm, animate = true); {
				defer baldr.end(ui)
				names := [6]string{"Wayland", "Win32", "Vulkan 1.3", "Retained", "Accessible", "Responsive"}
				for i in s.order {
					th := ui.theme
					chip := baldr.row(ui, padding = .xs, bg = th.color.surface_high, radius = th.radius.full, align = .Center, key = u64(i + 1)); {
						defer baldr.end(ui)
						baldr.box(ui, width = 6)
						baldr.text(ui, names[i], role = .Caption)
						baldr.box(ui, width = 6)
					}
					// drag a chip before or after another (Ctrl+X / Ctrl+V works too); the wrap glides them into place
					baldr.draggable(ui, chip, "chip", tag = u64(i + 1))
					baldr.drop_target(ui, chip, proc(e: baldr.Ev(baldr.Drop)) -> Msg { return Reorder{from = int(e.value.tag) - 1, to = int(e.tag) - 1, before = e.value.position == .Before} },
						accepts = "chip", positions = {.Before, .After}, tag = u64(i + 1))
				}
			}
		}
		baldr.card(ui, gap = .md, key = 4); {
			defer baldr.end(ui)
			baldr.text(ui, "Lines over a picture", role = .Title)
			baldr.text(ui, "An editor's overlays, which no box can be: marching ants round a selection with a hole, and a transform box rotated with its layer. The app raises dash_offset over time and the ants march — here they are still, so the gallery does not spin.", muted = true)
			baldr.stack(ui, width = 320, height = 160); {
				defer baldr.end(ui)
				// A mid grey stands in for a picture: the ants are black and white,
				// and both have to read against what is behind them.
				baldr.box(ui, width = 320, height = 160, bg = {0.42, 0.46, 0.53, 1}, radius = 4)
				sel  := [][2]f32{{20, 24}, {140, 24}, {140, 124}, {20, 124}}
				hole := [][2]f32{{60, 58}, {100, 58}, {100, 90}, {60, 90}}
				baldr.lines(ui, {{sel, true}, {hole, true}}, color = {0, 0, 0, 1}, outline = {1, 1, 1, 1},
					dashes = {4, 4}, width = 320, height = 160, label = "Selection")
				frame := [][2]f32{{192, 44}, {288, 30}, {300, 112}, {204, 126}}
				baldr.lines(ui, {{frame, true}}, thickness = 1.5, color = ui.theme.color.primary,
					width = 320, height = 160, label = "Free transform")
			}
		}
	}
}

solstice :: proc() -> baldr.Theme {
	th := baldr.theme_dark()
	th.name = "Solstice"
	c := &th.color
	c.bg = baldr.rgb(0x0F1115); c.surface = baldr.rgb(0x171A21); c.surface_variant = baldr.rgb(0x1C2028); c.surface_high = baldr.rgb(0x262B36)
	c.on_bg = baldr.rgb(0xF2EFE8); c.on_surface = baldr.rgb(0xF2EFE8); c.on_surface_muted = baldr.rgb(0x9A9890)
	c.primary = baldr.rgb(0xF2B544); c.on_primary = baldr.rgb(0x1A1300); c.primary_container = baldr.rgb(0x3A2E10); c.on_primary_container = baldr.rgb(0xFFE2A0)
	c.outline = baldr.rgb(0x2B303B); c.outline_variant = baldr.rgb(0x222630); c.focus_ring = baldr.rgb(0xF2B544)
	c.danger = baldr.rgb(0xE5484D); c.shadow = baldr.rgb(0x000000, 0.55)
	return th
}

paper :: proc() -> baldr.Theme {
	th := baldr.theme_light()
	th.name = "Paper"
	c := &th.color
	c.bg = baldr.rgb(0xF6F3EE); c.surface = baldr.rgb(0xFFFFFF); c.surface_variant = baldr.rgb(0xEEEAE2); c.surface_high = baldr.rgb(0xFFFFFF)
	c.on_bg = baldr.rgb(0x1C1B18); c.on_surface = baldr.rgb(0x1C1B18); c.on_surface_muted = baldr.rgb(0x6B665C)
	c.primary = baldr.rgb(0xD4901F); c.on_primary = baldr.rgb(0x201700); c.primary_container = baldr.rgb(0xFBE6B8); c.on_primary_container = baldr.rgb(0x4A3200)
	c.outline = baldr.rgb(0xD9D2C5); c.outline_variant = baldr.rgb(0xE8E2D6); c.focus_ring = baldr.rgb(0xB8741A)
	c.shadow = baldr.rgb(0x2A2010, 0.18)
	return th
}

// CORNERS is `--corners <px>`: every theme radius capped at that many pixels,
// as a desktop with a square style sets. It goes through App.adjust_theme, so
// it survives the Theme picker and light/dark. Pill shapes follow it; a
// switch, a slider's thumb, a radio and a dot stay round on purpose.
CORNERS: f32 = -1

corners_cap :: proc(th: ^baldr.Theme) {
	if CORNERS < 0 do return
	r := &th.radius
	r.xs, r.sm, r.md = min(r.xs, CORNERS), min(r.sm, CORNERS), min(r.md, CORNERS)
	r.lg, r.xl, r.full = min(r.lg, CORNERS), min(r.xl, CORNERS), min(r.full, CORNERS)
}

main :: proc() {
	size := [2]f32{960, 680}
	page := 0
	for a, i in os.args { // --size WxH: try a phone- or tablet-sized window; --page <name>: open on that page; --corners <px>: a square style
		if a == "--grid" do START_GRID = true
		if a == "--pick" && i + 1 < len(os.args) {
			if n, ok := strconv.parse_int(os.args[i + 1]); ok do START_PICK = clamp(n, -1, len(PROJECT) - 1)
		}
		if a == "--corners" && i + 1 < len(os.args) {
			if v, ok := strconv.parse_f32(os.args[i + 1]); ok do CORNERS = max(v, 0)
		}
		if a == "--theme" && i + 1 < len(os.args) {
			for name, ti in THEMES do if strings.equal_fold(name, os.args[i + 1]) do START_THEME = ti
		}
		if a == "--page" && i + 1 < len(os.args) {
			for name, pi in PAGES do if strings.equal_fold(name, os.args[i + 1]) do page = pi
		}
		if a == "--size" && i + 1 < len(os.args) {
			parts := strings.split(os.args[i + 1], "x", context.temp_allocator)
			if len(parts) == 2 {
				w, _ := strconv.parse_f32(parts[0])
				h, _ := strconv.parse_f32(parts[1])
				if w > 0 && h > 0 do size = {w, h}
			}
		}
	}
	START_PAGE = page
	icon := gallery_icon()
	defer baldr.image_destroy(&icon)
	err := baldr.run(baldr.App(State, Msg){
		title = "Baldr gallery", app_id = "dev.baldr.gallery", size = size, icon = &icon,
		theme = baldr.theme_dark(), adjust_theme = corners_cap, init = init, update = update, view = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}


// gallery_icon draws the window's icon: a rounded square in two blues.
// Windows and X11 show it; Wayland takes the icon from the .desktop file.
gallery_icon :: proc() -> baldr.Image {
	N :: 64
	px := make([]u8, N * N * 4)
	defer delete(px)
	for y in 0 ..< N {
		for x in 0 ..< N {
			// inside a square with corners of radius 14, softened over a pixel
			cx := f32(max(14 - x, x - (N - 1 - 14), 0))
			cy := f32(max(14 - y, y - (N - 1 - 14), 0))
			a := clamp(14.5 - math.sqrt(cx * cx + cy * cy), 0, 1)
			t := f32(x + y) / f32(2 * N)
			p := px[(y * N + x) * 4:]
			p[0], p[1], p[2], p[3] = u8(40 + 30 * t), u8(110 + 60 * t), u8(230), u8(a * 255)
		}
	}
	img, _ := baldr.image_from_rgba(N, N, px)
	return img
}

// ------------------------------------------------------------- Explorer

// A small project tree, pre-order with depths; folders' children follow them.
Proj_Node :: struct { name: string, depth: int, folder: bool, icon: baldr.Icon }
PROJECT := []Proj_Node{
	{"baldr", 0, true, .Folder},
	{"baldr", 1, true, .Folder},
	{"app.odin", 2, false, .File_Code}, {"layout.odin", 2, false, .File_Code}, {"paint.odin", 2, false, .File_Code},
	{"widget_split.odin", 2, false, .File_Code}, {"widget_tree.odin", 2, false, .File_Code},
	{"docs", 1, true, .Folder},
	{"guide.md", 2, false, .File_Text}, {"widgets.md", 2, false, .File_Text},
	{"examples", 1, true, .Folder},
	{"00_gallery", 2, true, .Folder},
	{"main.odin", 3, false, .File_Code},
	{"assets", 3, true, .Folder},
	{"avatar.png", 4, false, .File_Image}, {"photo.png", 4, false, .File_Image},
	{"06_panel", 2, true, .Folder},
	{"main.odin", 3, false, .File_Code},
	{"gpu", 1, true, .Folder},
	{"render.odin", 2, false, .File_Code}, {"blur.odin", 2, false, .File_Code},
	{"shaders", 2, true, .Folder},
	{"quad.vert", 3, false, .File_Code}, {"quad.frag", 3, false, .File_Code},
	{"README.md", 1, false, .File_Text},
	{"build.sh", 1, false, .Terminal},
}

project_open :: proc() -> (m: map[int]bool) {
	m = make(map[int]bool)
	m[0], m[10] = true, true // the project and its examples; the rest closed, so the tree fits the Overview
	return
}

// Proj_Entry is PROJECT as a tree the app owns: drops re-parent entries.
Proj_Entry :: struct {
	name:   string,
	icon:   baldr.Icon,
	folder: bool,
	parent: int,          // -1 for the root
	kids:   [dynamic]int, // in display order
}

project_tree :: proc() -> (out: [dynamic]Proj_Entry) {
	out = make([dynamic]Proj_Entry)
	stack := make([dynamic]int, context.temp_allocator) // open folders by depth
	for n, i in PROJECT {
		resize(&stack, n.depth)
		parent := stack[n.depth - 1] if n.depth > 0 else -1
		append(&out, Proj_Entry{name = n.name, icon = n.icon, folder = n.folder, parent = parent, kids = make([dynamic]int)})
		if parent >= 0 do append(&out[parent].kids, i)
		append(&stack, i)
	}
	return
}

// project_path joins an entry's ancestors: "baldr/examples/00_gallery/main.odin".
project_path :: proc(s: ^State, i: int) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for j := i; j >= 0; j = s.proj[j].parent do append(&parts, s.proj[j].name)
	for k in 0 ..< len(parts) / 2 do parts[k], parts[len(parts) - 1 - k] = parts[len(parts) - 1 - k], parts[k]
	return strings.join(parts[:], "/", context.temp_allocator)
}

// project_move re-parents `item` into `folder` — never into itself or a descendant.
project_move :: proc(s: ^State, item, folder: int) {
	if item == folder || !s.proj[folder].folder do return
	for j := folder; j >= 0; j = s.proj[j].parent do if j == item do return
	old := s.proj[item].parent
	if old == folder do return
	if old >= 0 {
		kids := &s.proj[old].kids
		for k, i in kids^ do if k == item { ordered_remove(kids, i); break }
	}
	append(&s.proj[folder].kids, item)
	s.proj[item].parent = folder
	s.expanded[folder] = true
}

// explorer_entry builds one entry and, for an open folder, its children.
// Entries are draggable; folders take drops (Ctrl+X / Ctrl+V work too).
explorer_entry :: proc(s: ^State, ui: ^baldr.Ui(Msg), i: int) {
	n := s.proj[i]
	on_drop :: proc(e: baldr.Ev(baldr.Drop)) -> Msg { return Tree_Move{item = int(e.value.tag), folder = int(e.tag)} }
	rename: baldr.Handler(Msg, string) // set while this entry is being renamed in place
	if s.tree_editing == i do rename = proc(e: baldr.Ev(string)) -> Msg { return Tree_Renamed{int(e.tag), strings.clone(e.value)} }
	if n.folder {
		open := baldr.tree_item(ui, n.name, Msg(Tree_Pick{i}), expanded = s.expanded[i], selected = s.tree_sel == i,
			icon = .Folder_Open if s.expanded[i] else .Folder, tag = u64(i), key = u64(i + 1),
			on_change = proc(e: baldr.Ev(bool)) -> Msg { return Tree_Open{int(e.tag), e.value} },
			drag = "entry" if i > 0 else "", on_drop = on_drop, accepts = "entry",
			on_submit = rename, on_cancel = Msg(Edit_Done{}))
		if open {
			defer baldr.end(ui)
			for k in n.kids do explorer_entry(s, ui, k)
		}
	} else {
		baldr.tree_item(ui, n.name, Msg(Tree_Pick{i}), selected = s.tree_sel == i, icon = n.icon, on_activate = Msg(Tree_Act{i}),
			tag = u64(i), key = u64(i + 1), drag = "entry", on_submit = rename, on_cancel = Msg(Edit_Done{}))
	}
}

explorer_tree :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.tree_view(ui, label = "Project", on_edit = proc(e: baldr.Ev(int)) -> Msg { return Tree_Edit{e.value} }); defer baldr.end(ui) // F2 / a slow click renames
	explorer_entry(s, ui, 0)
}

explorer_details :: proc(s: ^State, ui: ^baldr.Ui(Msg), split := true) -> baldr.Node {
	if s.tree_sel >= 0 {
		// the trail to the picked entry; each crumb picks that ancestor
		trail := make([dynamic]int, context.temp_allocator)
		for j := s.tree_sel; j >= 0; j = s.proj[j].parent do append(&trail, j)
		parts := make([dynamic]string, context.temp_allocator)
		for k := len(trail) - 1; k >= 0; k -= 1 do append(&parts, s.proj[trail[k]].name)
		crumbs := baldr.breadcrumbs(ui, parts[:], proc(e: baldr.Ev(int)) -> Msg { return Crumb{e.value} })
		_ = crumbs
	}
	card := baldr.card(ui, gap = .sm); defer baldr.end(ui)
	if s.tree_sel < 0 {
		baldr.text(ui, "Nothing picked", role = .Title)
		baldr.text(ui, "Pick an entry in the tree: click, or Tab to the tree and use the arrow keys. Right opens a folder, Left closes it or steps out. Double-click or Enter opens a file. Drag an entry onto a folder to move it.", muted = true)
	} else {
		n := s.proj[s.tree_sel]
		baldr.text(ui, n.name, role = .Title)
		baldr.text(ui, project_path(s, s.tree_sel), muted = true)
		baldr.text(ui, "Folder" if n.folder else "File")
		baldr.text(ui, "Drag an entry onto a folder to move it, or pick it, press Ctrl+X, move to a folder and press Ctrl+V.", muted = true, role = .Caption)
	}
	if s.tree_open != "" do baldr.text(ui, fmt.tprintf("Opened %s", s.tree_open))
	if split do baldr.text(ui, fmt.tprintf("Sidebar %.0f px — drag the divider, or Tab to it and press ← / → (Shift for bigger steps).", s.sidebar_w), role = .Caption, muted = true)
	return card
}

page_explorer :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	th := ui.theme
	compact := baldr.size_class(ui) == .Compact
	baldr.text(ui, "Explorer", role = .Headline)
	// One split for every width. At phone width it collapses to one pane at
	// a time: the tree until something is picked, then the details with a
	// Back button (and Escape) that sends Detail_Back — so shrinking the
	// window keeps what the split was showing.
	// The gutter keeps the panes apart; neither pane pads towards the
	// divider, so the details card's top lines up with the sidebar's.
	baldr.split(ui, s.sidebar_w, on_change = proc(e: baldr.Ev(f32)) -> Msg { return Set_Sidebar{e.value} }, min = 160, max = 480, gap = .lg,
		collapse = .Compact, detail = s.tree_sel >= 0 && !s.detail_dismissed, on_close = Msg(Detail_Back{}), back_label = "Project"); {
		defer baldr.end(ui)
		baldr.pane(ui, bg = th.color.surface if !compact else baldr.Color{}); {
			defer baldr.end(ui)
			baldr.scroll(ui, flex = 1, padding = .sm); {
				defer baldr.end(ui)
				explorer_tree(s, ui)
			}
		}
		baldr.pane(ui, gap = .md); {
			defer baldr.end(ui)
			explorer_details(s, ui, split = !compact)
		}
	}
}

starting_tags :: proc() -> (out: [dynamic]string) {
	out = make([dynamic]string)
	append(&out, "odin", "vulkan", "wayland", "retained")
	return
}

// The Editor page shows 01_hello's own source, read in at compile time, so
// the program on screen is one `./build.sh examples` builds every time.
ODIN_SAMPLE :: #load("../01_hello/main.odin", string)

page_editor :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.text(ui, "Editor", role = .Headline)
	baldr.text(ui, "A code editor on the same Document as the text area: line numbers, tab stops, syntax colour from a Language, the caret line washed, brackets matched. Tab / Shift+Tab indent, Enter keeps the indentation, Ctrl+/ comments, Alt+Up / Down move lines, Ctrl+F finds, Ctrl+H replaces, Ctrl+G goes to a line, Ctrl+Space (or just typing) completes, Ctrl+Tab leaves. Rest the pointer on the squiggle for the diagnostic.", muted = true)
	baldr.row(ui, gap = .lg, align = .Center, vertical = baldr.size_class(ui) == .Compact); {
		defer baldr.end(ui)
		baldr.segmented(ui, s.code_lang, {"Odin", "C", "JSON", "SQL", "Plain"}, proc(e: baldr.Ev(int)) -> Msg { return Set_Code_Lang{e.value} }, label = "Language")
		baldr.checkbox(ui, s.code_wrap, "Wrap", proc(e: baldr.Ev(bool)) -> Msg { return Set_Code_Wrap{e.value} })
		baldr.checkbox(ui, s.code_ws, "Whitespace", proc(e: baldr.Ev(bool)) -> Msg { return Set_Code_Ws{e.value} })
	}
	lang: ^baldr.Language
	switch s.code_lang {
	case 0: lang = &baldr.LANG_ODIN
	case 1: lang = &baldr.LANG_C
	case 2: lang = &baldr.LANG_JSON
	case 3: lang = &baldr.LANG_SQL
	case:   lang = &baldr.LANG_PLAIN
	}
	// a diagnostic from a "linter": the unused proc on the last line
	marks := make([dynamic]baldr.Mark, context.temp_allocator)
	for b in 0 ..< baldr.block_count(&s.source) {
		line := baldr.block_str(&s.source, b)
		if i := strings.index(line, "size   = {480, 320}"); i >= 0 {
			append(&marks, baldr.Mark{from = {b, i}, to = {b, i + 4}, kind = .Info, message = "The window's logical size; the backend scales it for the display"})
		}
	}
	ed := baldr.code_editor(ui, &s.source, lang, proc(e: baldr.Ev(int)) -> Msg { return Code_Edited{e.value} }, label = "Source", flex = 1)
	baldr.editor_options(ui, ed, wrap = s.code_wrap, whitespace = s.code_ws)
	baldr.editor_marks(ui, ed, marks[:])
	baldr.text(ui, fmt.tprintf("%d lines · version %d", baldr.block_count(&s.source), s.source.version), role = .Caption, muted = true)
}

rich_sample :: proc() -> baldr.Document {
	doc := baldr.document_make("")
	baldr.document_set_markdown(&doc, RICH_SAMPLE)
	return doc
}

RICH_SAMPLE :: `# Release notes

Baldr's **rich text** editor works on the *same* Document as the text area and the code editor: blocks with a kind, runs with attributes, one undo journal for all of it. Read the [design notes](https://example.org/design) for the reasoning.

## What is in

- Headings, paragraphs, quotes and rules
- Bullet, numbered and task lists
  - nested by Tab and Shift+Tab
- Inline ` + "`code`" + `, ~~strike~~ and <u>underline</u>

1. Type ` + "`# `" + `, ` + "`- `" + `, ` + "`1. `" + ` or ` + "`> `" + ` at the start of a line
2. Or use the toolbar, or Ctrl+B / I / U / E / K

- [x] Toolbar reflects the selection
- [x] Tables and images

> Everything round-trips through markdown: flip to the source view and back.

![The gallery's sample photo](photo)

| Editor | Document | Keys |
|---|---|---|
| Rich text | blocks and runs | Ctrl+B / I / U / E / K |
| Markdown | source lines | the code editor's |
| Live | source lines | Tab between cells, Shift+Enter out |

` + "```odin" + `
greet :: proc(name: string) { fmt.println("hello,", name) }
` + "```" + `

---

Ctrl+click a link to follow it.
`

page_rich :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	gallery_photo = &s.photo
	baldr.text(ui, "Rich text", role = .Headline)
	baldr.text(ui, "One Document, three editors and a reader. The rich view edits blocks and runs in place; the markdown view is the code editor over the source; the live view renders the source and shows the raw line under the caret; the reply is the read-only view an assistant's answer is shown in — select it, copy a code block, rest on a link. Switching converts between them.", muted = true)
	baldr.row(ui, gap = .lg, align = .Center, vertical = baldr.size_class(ui) == .Compact); {
		defer baldr.end(ui)
		baldr.segmented(ui, s.rich_mode, {"Rich", "Markdown", "Live", "Reply"}, proc(e: baldr.Ev(int)) -> Msg { return Set_Rich_Mode{e.value} }, label = "View")
		if len(s.last_link) > 0 do baldr.text(ui, fmt.tprintf("Followed %s", s.last_link), role = .Caption, muted = true)
	}
	if s.rich_mode == 0 {
		ed := baldr.rich_text(ui, &s.rich, proc(e: baldr.Ev(int)) -> Msg { return Code_Edited{e.value} }, label = "Notes", flex = 1,
			on_link = proc(e: baldr.Ev(string)) -> Msg { return Follow_Link{e.value} })
		baldr.editor_images(ui, ed, gallery_image)
	} else if s.rich_mode == 1 {
		src := baldr.code_editor(ui, &s.rich_src, &baldr.LANG_MARKDOWN, proc(e: baldr.Ev(int)) -> Msg { return Code_Edited{e.value} }, label = "Markdown", flex = 1, key = 2)
		baldr.editor_options(ui, src, wrap = true)
	} else if s.rich_mode == 2 {
		live := baldr.markdown_editor(ui, &s.rich_src, proc(e: baldr.Ev(int)) -> Msg { return Code_Edited{e.value} }, label = "Live", flex = 1, key = 3,
			on_link = proc(e: baldr.Ev(string)) -> Msg { return Follow_Link{e.value} })
		baldr.editor_images(ui, live, gallery_image)
	} else {
		baldr.scroll(ui, flex = 1, key = 5); {
			defer baldr.end(ui)
			n := baldr.markdown_view(ui, &s.reply, label = "Reply", flex = 1, key = 4)
			baldr.md_view_options(ui, n,
				on_link = proc(e: baldr.Ev(string)) -> Msg { return Follow_Link{e.value} },
				language = proc(name: string) -> ^baldr.Language {
					switch name {
					case "odin": return &baldr.LANG_ODIN
					case "sql":  return &baldr.LANG_SQL
					}
					return nil
				})
			baldr.md_view_image(ui, n, "photo", gallery_photo)
		}
	}
	baldr.text(ui, fmt.tprintf("%d blocks · version %d", baldr.block_count(&s.rich), s.rich.version), role = .Caption, muted = true)
}

// gallery_image resolves the sample document's image sources: "photo" is
// gallery_photo (a real app maps names to the files it loaded).
gallery_photo: ^baldr.Image
gallery_image :: proc(src: string) -> ^baldr.Image { return gallery_photo if src == "photo" else nil }
