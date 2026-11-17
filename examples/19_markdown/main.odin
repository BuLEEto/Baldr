// 19_markdown — the live-preview markdown editor with a toolbar of the
// app's own: every button is rich_apply, which edits the markdown source
// the way the editor's shortcuts do, and Cut / Copy / Paste come from
// editor_action, greyed by editor_actions. The row under it is how the
// document is *shown* rather than what is in it: a family from
// installed_fonts, a size, and a line spacing.
//
//   ./build.sh example 19_markdown run
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	doc:     baldr.Document,
	pending: Maybe(baldr.Rich_Action),   // what the toolbar chose, done once the editor is built
	clip:    Maybe(baldr.Editor_Action), // …and what the clipboard buttons chose
	menu:    bool,
	at:      baldr.Pos, // where the right-click menu was asked for
	fonts:   []baldr.Installed_Font, // what this machine has, listed once
	fonts_known: bool,               // …once the list is there (read off the UI thread)
	names:   []string,
	font:    int, // an index into `names`; 0 = the theme's own font
	size:    int, // an index into SIZES
	spacing: int, // …and into SPACINGS
}

SIZES    :: [?]f32{0, 14, 16, 18, 22}
SPACINGS :: [?]f32{1, 1.15, 1.5, 2}
Msg :: union { Edited, Format, Clip, Menu, Menu_Closed, Set_Font, Set_Size, Set_Spacing }
Edited      :: struct { version: int }
Format      :: struct { action: baldr.Rich_Action }
Clip        :: struct { action: baldr.Editor_Action }
Menu        :: struct { at: baldr.Pos }
Menu_Closed :: struct {}
Set_Font    :: struct { i: int }
Set_Size    :: struct { i: int }
Set_Spacing :: struct { i: int }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Edited:
	case Format:      s.pending = v.action
	case Clip:        s.clip = v.action
	case Menu:        s.menu, s.at = true, v.at
	case Menu_Closed: s.menu = false
	case Set_Font:    s.font = v.i
	case Set_Size:    s.size = v.i
	case Set_Spacing: s.spacing = v.i
	}
	return {}
}

TOOLS :: [?]struct { icon: baldr.Icon, name: string, action: baldr.Rich_Action, gap: bool } {
	{.Bold, "Bold", .Bold, false},
	{.Italic, "Italic", .Italic, false},
	{.Strikethrough, "Strikethrough", .Strike, false},
	{.Code, "Inline code", .Code, false},
	{.Highlighter, "Highlight", .Highlight, false},
	{.Link, "Link", .Link, false},
	{.Heading_1, "Heading 1", .H1, true},
	{.Heading_2, "Heading 2", .H2, false},
	{.Pilcrow, "Paragraph", .Paragraph, false},
	{.List, "Bullet list", .Bullet, true},
	{.List_Ordered, "Numbered list", .Numbered, false},
	{.List_Todo, "Task list", .Task, false},
	{.Text_Quote, "Quote", .Quote, false},
	{.File_Code, "Code block", .Code_Block, false},
	{.Minus, "Horizontal rule", .Rule, false},
	{.Table, "Table", .Table, false},
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Notes.md", role = .Title)

	ed: baldr.Node
	baldr.wrap(ui, gap = .xxs); { // the format bar: what the editor's own shortcuts do
		defer baldr.end(ui)
		for tool, i in TOOLS {
			if tool.gap do baldr.spacer(ui, size = 8)
			b := baldr.button(ui, tool.name, Msg(Format{tool.action}), icon = tool.icon, icon_only = true, variant = .Ghost, size = .Small, key = u64(i + 1))
			baldr.tooltip(ui, b, tool.name)
		}
	}
	ed = baldr.markdown_editor(ui, &s.doc, proc(e: baldr.Ev(int)) -> Msg { return Edited{e.value} }, label = "Notes", flex = 1,
		on_context = proc(e: baldr.Ev(baldr.Editor_Context)) -> Msg { return Menu{e.value.pos} })
	if !s.fonts_known { // the families this machine has, listed once: "Theme's own" first
		fonts, known := baldr.installed_fonts(&ui.tree) // not yet while the list is read off the UI thread: asked again when the view is built again
		if known || s.names == nil {
			s.fonts, s.fonts_known = fonts, known
			names := make([dynamic]string, 0, len(fonts) + 1)
			append(&names, "Theme's own")
			for f in fonts do append(&names, f.family)
			delete(s.names)
			s.names = names[:]
		}
	}
	sizes := SIZES
	spacings := SPACINGS
	baldr.editor_options(ui, ed,
		font = "" if s.font == 0 else s.names[s.font],
		size = sizes[s.size],
		line_spacing = spacings[s.spacing])
	if a, ok := s.pending.?; ok {
		baldr.rich_apply(ui, ed, a)
		s.pending = nil
	}
	if a, ok := s.clip.?; ok {
		baldr.editor_action(ui, ed, a)
		s.clip = nil
	}
	can := baldr.editor_actions(&ui.tree, ed)

	baldr.row(ui, align = .Center, gap = .sm); { // how it is shown, not what is in it
		defer baldr.end(ui)
		baldr.wrap(ui, gap = .sm); { // they flow onto another line when the window is narrow, or the desktop's text is large
			defer baldr.end(ui)
			baldr.select(ui, s.font, s.names, proc(e: baldr.Ev(int)) -> Msg { return Set_Font{e.value} }, width = 0, label = "Font")
			baldr.select(ui, s.size, {"Default", "14", "16", "18", "22"}, proc(e: baldr.Ev(int)) -> Msg { return Set_Size{e.value} }, width = 0, label = "Size")
			baldr.select(ui, s.spacing, {"Single", "1.15", "1.5", "Double"}, proc(e: baldr.Ev(int)) -> Msg { return Set_Spacing{e.value} }, width = 0, label = "Line spacing")
		}
		baldr.spacer(ui)
		if name, installed := baldr.editor_font(&ui.tree, ed); s.font > 0 && !installed {
			baldr.text(ui, fmt.tprintf("%s isn't installed", s.names[s.font]), role = .Caption, color = ui.tree.theme.color.danger)
		} else if s.font > 0 {
			baldr.text(ui, name, role = .Caption, muted = true)
		}
	}

	baldr.row(ui, align = .Center, gap = .sm); {
		defer baldr.end(ui)
		baldr.button(ui, "Undo", Msg(Format{.Undo}), icon = .Undo_2, variant = .Ghost, disabled = .Undo not_in can)
		baldr.button(ui, "Redo", Msg(Format{.Redo}), icon = .Redo_2, variant = .Ghost, disabled = .Redo not_in can)
		baldr.spacer(ui)
		baldr.text(ui, fmt.tprintf("%d lines — Ctrl+B, Ctrl+I, Ctrl+E, Ctrl+Shift+H highlight, Ctrl+K link", baldr.block_count(&s.doc)), role = .Caption, muted = true)
	}

	if baldr.context_menu(ui, s.menu, Msg(Menu_Closed{})) {
		defer baldr.end(ui)
		baldr.menu_item(ui, "Cut", Msg(Clip{.Cut}), shortcut = "Ctrl+X", icon = .Scissors, disabled = .Cut not_in can)
		baldr.menu_item(ui, "Copy", Msg(Clip{.Copy}), shortcut = "Ctrl+C", icon = .Copy, disabled = .Copy not_in can)
		baldr.menu_item(ui, "Paste", Msg(Clip{.Paste}), shortcut = "Ctrl+V", icon = .Clipboard, disabled = .Paste not_in can)
		baldr.separator(ui)
		baldr.menu_item(ui, "Highlight", Msg(Format{.Highlight}), shortcut = "Ctrl+Shift+H", icon = .Highlighter)
		baldr.menu_item(ui, fmt.tprintf("Line %d, column %d", s.at.block + 1, s.at.off + 1), Msg(Menu_Closed{}), disabled = true)
	}
}

SAMPLE :: `# Notes

The toolbar writes **markdown** into the source: ==highlights==, ` + "`code`" + `, [links](https://example.org).

- [x] Ship the editor
- [ ] Write it up

> Everything here is the text as it is saved.
`

init :: proc() -> State { return State{doc = baldr.document_make(SAMPLE)} }

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){title = "Markdown", app_id = "baldr.markdown", size = {760, 620}, init = init, update = update, view = view})
	if err != .None do fmt.eprintln("exit:", err)
}
