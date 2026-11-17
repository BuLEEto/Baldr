package cocoa

// The menu bar's table, tested on every machine. Which chords the menu owns
// decides which ones the pump must keep its hands off, and getting that
// wrong is silent either way: too few and Cmd-Q types a q again, too many
// and an app's own shortcut stops firing for no visible reason.

@(require) import "baldr:platform"
@(require) import "core:strings"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
the_menu_owns_the_chords_a_mac_user_expects :: proc(t: ^testing.T) {
	cmd :: platform.Mods{.Super}
	want := [?]struct { key: platform.Key, mods: platform.Mods, what: string } {
		{.Q, cmd, "Quit"},
		{.W, cmd, "Close"},
		{.M, cmd, "Minimize"},
		{.H, cmd, "Hide"},
		{.H, {.Super, .Alt}, "Hide Others"},
		{.Z, cmd, "Undo"},
		{.Z, {.Super, .Shift}, "Redo"},
		{.X, cmd, "Cut"},
		{.C, cmd, "Copy"},
		{.V, cmd, "Paste"},
		{.A, cmd, "Select All"},
	}
	for w in want {
		testing.expectf(t, menu_owns_chord(w.key, w.mods),
			"%s is a menu item, so the menu should own %v+%v", w.what, w.mods, w.key)
	}
}

@(test)
a_chord_the_menu_has_no_item_for_stays_the_apps :: proc(t: ^testing.T) {
	cmd :: platform.Mods{.Super}
	// Each of these belongs to a widget or an app shortcut, not the menu.
	testing.expect(t, !menu_owns_chord(.C, {}), "a plain c is text, not a chord")
	testing.expect(t, !menu_owns_chord(.C, {.Ctrl}), "Ctrl+C is the toolkit's own, not the menu's")
	testing.expect(t, !menu_owns_chord(.N, cmd), "Cmd+N is an app's to bind: the menu has no New")
	testing.expect(t, !menu_owns_chord(.S, cmd), "Cmd+S likewise")
	testing.expect(t, !menu_owns_chord(.Tab, {.Ctrl}), "Ctrl+Tab stays Ctrl+Tab on macOS")
	// The modifiers have to match exactly, or one item swallows its
	// neighbour's chord: Cmd-H hides and Opt-Cmd-H hides the others.
	testing.expect(t, !menu_owns_chord(.H, {.Super, .Shift}), "Shift+Cmd+H is nobody's")
	testing.expect(t, !menu_owns_chord(.C, {.Super, .Shift}), "Shift+Cmd+C belongs to an app that binds it")
	testing.expect(t, !menu_owns_chord(.Q, {.Super, .Alt}), "Opt+Cmd+Q is not Quit")
}

@(test)
every_menu_item_with_a_chord_names_its_key :: proc(t: ^testing.T) {
	// `equiv` is what AppKit matches and `key` is what the pump compares
	// against. An item with one and not the other works in the bar and is
	// still delivered as a keystroke too.
	for tbl in ([][]Menu_Item_Desc{MENU_APP[:], MENU_EDIT[:], MENU_WINDOW[:]}) {
		for d in tbl {
			if d.equiv == "" do continue
			testing.expectf(t, d.key != .Unknown, "%q has the chord %q and no key", d.title, d.equiv)
			testing.expectf(t, len(d.equiv) == 1, "%q: a key equivalent is one character, got %q", d.title, d.equiv)
			testing.expectf(t, strings.to_lower(d.equiv, context.temp_allocator) == d.equiv,
				"%q: a key equivalent is lower case (Shift is the mask's job), got %q", d.title, d.equiv)
		}
	}
}

@(test)
every_menu_item_can_act :: proc(t: ^testing.T) {
	for tbl in ([][]Menu_Item_Desc{MENU_APP[:], MENU_EDIT[:], MENU_WINDOW[:]}) {
		for d in tbl {
			switch d.act {
			case .Separator:
				testing.expect(t, d.title == "" && d.equiv == "", "a separator has no title and no chord")
			case .Native:
				// Sent to whoever in the responder chain implements it, so a
				// missing colon is a selector that exists nowhere.
				testing.expectf(t, strings.has_suffix(d.sel, ":"), "%q: %q is not a selector", d.title, d.sel)
			case .Chord:
				// Without a chord it delivers a bare key: Cmd-C would arrive
				// as a plain "c" keystroke.
				testing.expectf(t, d.chord != {}, "%q delivers no chord", d.title)
				testing.expectf(t, d.key != .Unknown, "%q delivers no key", d.title)
			case .Quit, .Close, .Minimize, .Zoom, .Services:
				testing.expectf(t, d.sel == "", "%q answers itself, so it needs no selector", d.title)
				testing.expectf(t, d.title != "", "an item a person chooses has a title")
			}
		}
	}
}

@(test)
the_application_menu_is_named_after_the_application :: proc(t: ^testing.T) {
	// "Quit Gallery", not "Quit": the three items a Mac user looks for by
	// the app's own name. %s is where menu.odin puts it.
	named := 0
	for d in MENU_APP {
		if strings.contains(d.title, "%s") do named += 1
	}
	testing.expect_value(t, named, 3) // About, Hide, Quit
	for tbl in ([][]Menu_Item_Desc{MENU_EDIT[:], MENU_WINDOW[:]}) {
		for d in tbl {
			testing.expectf(t, !strings.contains(d.title, "%s"),
				"%q: only the application menu carries the app's name", d.title)
		}
	}
}

}
