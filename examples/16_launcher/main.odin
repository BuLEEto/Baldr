package main

// A desktop shell's search launcher: a search field over results in tiles, walked
// with Up and Down while the field keeps focus, the pointer resting on a row making it current, over a blurred and
// dimmed desktop. Enter takes the current row, a right-click or the Menu key asks for its menu, Escape closes;
// Ctrl+P pins the current row and Shift+Delete removes it. --light for the light theme.

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:baldr"

Found :: struct {
	title, detail, theme_icon, glyph, hint: string,
	icon:    baldr.Icon,
	variant: baldr.Row_Variant,
	size:    baldr.Row_Size,
}

ALL := [?]Found{
	{title = "Files", detail = "Application", theme_icon = "org.gnome.Nautilus", hint = "↵ open", variant = .Tile},
	{title = "Terminal", detail = "Application", theme_icon = "utilities-terminal", hint = "↵ open", variant = .Tile},
	{title = "Notes", detail = "Application", theme_icon = "com.example.Notes", icon = .Layout_Grid, hint = "↵ open", variant = .Tile}, // an Icon= no theme provides: the icon stands in
	{title = "Settings", detail = "System", icon = .Settings, hint = "↵ open", variant = .Tile},
	{title = "Documents", detail = "Folder in your home", icon = .Folder, hint = "↵ open", variant = .Tile},
	{title = "Grinning face", detail = "Emoji", glyph = "😀", hint = "↵ copy", variant = .Tile},
	{title = "42", detail = "6 × 7", glyph = "=", hint = "↵ copy", variant = .Accent, size = .Large},
}

State :: struct {
	query:   baldr.Text,
	current: int,
	note:    string,
	removed: [len(ALL)]bool, // Shift+Delete took these out of the results
}

Typed :: struct {}
Walk :: struct { press: baldr.Key_Press }
Rest :: struct { i: int, on: bool }
Take :: struct { i: int }
Menu :: struct { i: int }
Close :: struct {}
Msg :: union { Typed, Walk, Rest, Take, Menu, Close }

// matches: every word of the query in a result's title or detail, ignoring case.
matches :: proc(s: ^State) -> []Found {
	out := make([dynamic]Found, context.temp_allocator)
	words := strings.fields(strings.to_lower(baldr.str(s.query), context.temp_allocator), context.temp_allocator)
	for f, i in ALL {
		if s.removed[i] do continue
		text := strings.to_lower(fmt.tprintf("%s %s", f.title, f.detail), context.temp_allocator)
		all := true
		for w in words do if !strings.contains(text, w) { all = false; break }
		if all do append(&out, f)
	}
	return out[:]
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Layer, title = "Launcher",
		layer = {level = .Overlay, anchor = {.Top, .Bottom, .Left, .Right}, keyboard = .Exclusive},
		transparent = true, backdrop = .Blur,
		clear = baldr.Color{0.03, 0.04, 0.06, 0.45}, // the desktop blurred, dimmed by this rather than tinted as a panel
		on_close = Msg(Close{}),
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, align = .Center); defer baldr.end(ui)
	baldr.spacer(ui, 94) // the card's top 13 % down the screen
	baldr.card(ui, width = 660, padding = .sm, gap = .xs, glass = true); {
		defer baldr.end(ui)
		field := baldr.text_input(ui, &s.query, placeholder = "Search apps, files, actions…", label = "Search",
			on_change = Msg(Typed{}), on_submit = Msg(Take{s.current}), on_cancel = Msg(Close{}), on_key = walk, focus = true)
		found := matches(s)
		current := baldr.NODE_NONE
		for f, i in found {
			r := baldr.list_row(ui, f.title, Msg(Take{i}), icon = f.icon, theme_icon = f.theme_icon, glyph = f.glyph, detail = f.detail,
				selected = i == s.current, hint = f.hint, variant = f.variant, size = f.size, on_context = Msg(Menu{i}), tag = u64(i), key = u64(i + 1))
			baldr.hoverable(ui, r, proc(e: baldr.Ev(bool)) -> Msg { return Rest{int(e.tag), e.value} })
			if i == s.current do current = r
		}
		baldr.set_active_item(&ui.tree, field, current) // the row Up, Down and Enter act on, for assistive technology
		if len(found) == 0 do baldr.text(ui, "No results", muted = true)
		baldr.text(ui, s.note if s.note != "" else fmt.tprintf("%d result%s · ↑ ↓ navigate · ↵ open · esc close", len(found), "" if len(found) == 1 else "s"), role = .Caption, muted = true)
	}
}

walk :: proc(e: baldr.Ev(baldr.Key_Press)) -> Msg { return Walk{e.value} }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	found := matches(s)
	switch v in m {
	case Typed:
		s.current = 0
	case Walk:
		#partial switch v.press.key {
		case .Up:        s.current -= 1
		case .Down:      s.current += 1
		case .Page_Up:   s.current -= 5
		case .Page_Down: s.current += 5
		case .P: // Ctrl+P
			if .Ctrl in v.press.mods && s.current < len(found) do note(s, fmt.tprintf("Pinned %s to the taskbar", found[s.current].title))
		case .Delete: // Shift+Delete
			if s.current < len(found) {
				gone := found[s.current].title
				for f, i in ALL do if f.title == gone do s.removed[i] = true
				note(s, fmt.tprintf("Removed %s", gone))
				found = matches(s)
			}
		}
		s.current = clamp(s.current, 0, max(len(found) - 1, 0))
	case Rest:
		if v.on do s.current = v.i // the pointer resting on a row makes it current
	case Take:
		if v.i < len(found) do note(s, fmt.tprintf("Took %s", found[v.i].title))
	case Menu:
		if v.i < len(found) do note(s, fmt.tprintf("The menu for %s: Launch, Pin to taskbar, Add to desktop", found[v.i].title))
	case Close:
		return baldr.quit(Msg)
	}
	return {}
}

note :: proc(s: ^State, text: string) {
	delete(s.note)
	s.note = strings.clone(text)
}

main :: proc() {
	light := len(os.args) > 1 && os.args[1] == "--light"
	err := baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.launcher", theme = baldr.theme_light() if light else baldr.theme_dark(),
		init = proc() -> State { return {} },
		update = update, view = view, surfaces = surfaces,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
