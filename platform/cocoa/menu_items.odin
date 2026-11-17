package cocoa

// What is in the menu bar, as data, read twice: to build the NSMenus
// (menu.odin, darwin only) and to decide which chords the menu owns and the
// pump must not also deliver as keys. One table, so the two cannot disagree.
//
// No build tag, so the Linux gate type-checks it and menu_test.odin runs
// everywhere. Nothing here touches AppKit.
//
// The menu bar is not cosmetic: on macOS the standard chords belong to it,
// and without one Cmd-V, Cmd-W, Cmd-Q and Cmd-M reach the focused widget as
// the text "v", "w", "q" and "m".

import "baldr:platform"

// Menu_Act is what choosing an item does. `Native` hands the selector to the
// responder chain (About, Hide, Show All: NSApplication's own). The rest are
// the toolkit's: a close or quit an app may refuse, or a chord a widget
// handles.
Menu_Act :: enum u8 {
	Separator,
	Native,
	Services, // the submenu AppKit fills, handed over with setServicesMenu:
	Quit,
	Close,
	Minimize,
	Zoom,
	Chord, // delivered to the surface with the keyboard as the toolkit's own chord
}

// Menu_Item_Desc is one line of a menu. `title` may carry a single %s for
// the application's name ("Quit Gallery"). `equiv` is the key equivalent
// AppKit matches, lower case, with Command implied and `shift` / `option`
// added. `key` is the same key in the toolkit's vocabulary, so
// `menu_owns_chord` can recognise an event before the pump translates it; an
// item with no `equiv` needs no `key`.
Menu_Item_Desc :: struct {
	title:  string,
	act:    Menu_Act,
	sel:    string, // Native only: the Objective-C selector, with its colon
	equiv:  string, // "" = no chord
	shift:  bool,
	option: bool,
	key:    platform.Key, // which key `equiv` is
	chord:  platform.Mods, // Chord only: what the toolkit calls this chord
}

// The application menu. Apple's order, which people read without looking.
@(private, rodata)
MENU_APP := [9]Menu_Item_Desc{
	{title = "About %s", act = .Native, sel = "orderFrontStandardAboutPanel:"},
	{act = .Separator},
	{title = "Services", act = .Services},
	{act = .Separator},
	{title = "Hide %s", act = .Native, sel = "hide:", equiv = "h", key = .H},
	{title = "Hide Others", act = .Native, sel = "hideOtherApplications:", equiv = "h", option = true, key = .H},
	{title = "Show All", act = .Native, sel = "unhideAllApplications:"},
	{act = .Separator},
	{title = "Quit %s", act = .Quit, equiv = "q", key = .Q},
}

// Edit. Baldr's widgets handle Ctrl+C, Ctrl+V, Ctrl+Z and so on
// (docs/guide.md, Keyboard conventions), so each item takes the Mac's Command chord and
// delivers the Ctrl chord the widgets understand. `chord` is the one place
// that mapping lives.
@(private, rodata)
MENU_EDIT := [7]Menu_Item_Desc{
	{title = "Undo", act = .Chord, equiv = "z", key = .Z, chord = {.Ctrl}},
	{title = "Redo", act = .Chord, equiv = "z", shift = true, key = .Z, chord = {.Ctrl, .Shift}},
	{act = .Separator},
	{title = "Cut", act = .Chord, equiv = "x", key = .X, chord = {.Ctrl}},
	{title = "Copy", act = .Chord, equiv = "c", key = .C, chord = {.Ctrl}},
	{title = "Paste", act = .Chord, equiv = "v", key = .V, chord = {.Ctrl}},
	{title = "Select All", act = .Chord, equiv = "a", key = .A, chord = {.Ctrl}},
}

// Window. AppKit appends "Bring All to Front" and the window list itself
// once the menu is handed over with setWindowsMenu:.
@(private, rodata)
MENU_WINDOW := [4]Menu_Item_Desc{
	{title = "Minimize", act = .Minimize, equiv = "m", key = .M},
	{title = "Zoom", act = .Zoom},
	{act = .Separator},
	{title = "Close", act = .Close, equiv = "w", key = .W},
}

// menu_owns_chord says whether the menu bar's key equivalents claim this
// chord. The pump asks before translating a key, because AppKit will act on
// it, and delivering it as a key too would fire an app's
// `shortcut(ui, "Cmd+W", …)` beside the menu's close. Command (`.Super`) is
// required, and Shift and Option must match exactly: Cmd-H and Opt-Cmd-H are
// different items.
@(private)
menu_owns_chord :: proc(key: platform.Key, mods: platform.Mods) -> bool {
	if .Super not_in mods do return false
	return menu_claims(MENU_APP[:], key, mods) ||
		menu_claims(MENU_EDIT[:], key, mods) ||
		menu_claims(MENU_WINDOW[:], key, mods)
}

@(private)
menu_claims :: proc(items: []Menu_Item_Desc, key: platform.Key, mods: platform.Mods) -> bool {
	for d in items {
		if d.equiv == "" || d.key != key do continue
		if (.Shift in mods) != d.shift do continue
		if (.Alt in mods) != d.option do continue
		return true
	}
	return false
}
