#+build windows
package win32

// The tray menu, read back from Windows itself.
//
// Whether the shell delivers a click on an icon in Windows 11's overflow
// flyout is Windows' business. What a descriptor turns into (the labels,
// the separator, the checkmark, the greyed-out status line, the submenu and
// the ids that come back) is ours, and `GetMenuState` and friends say
// exactly what was built.
@(require) import "core:testing"
@(require) import win "core:sys/windows"
@(require) import "baldr:platform"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// The querying half of the menu API, which core:sys/windows does not
// declare (it has only GetMenuItemInfoW, whose MENUITEMINFOW it also does
// not declare).
foreign import user32_menu "system:User32.lib"

@(default_calling_convention = "system")
foreign user32_menu {
	GetMenuItemCount :: proc(hMenu: win.HMENU) -> win.INT ---
	GetMenuState     :: proc(hMenu: win.HMENU, uId: win.UINT, uFlags: win.UINT) -> win.UINT ---
	GetMenuItemID    :: proc(hMenu: win.HMENU, nPos: win.INT) -> win.UINT ---
	GetSubMenu       :: proc(hMenu: win.HMENU, nPos: win.INT) -> win.HMENU ---
	GetMenuStringW   :: proc(hMenu: win.HMENU, uIDItem: win.UINT, lpString: win.LPWSTR, cchMax: win.INT, flags: win.UINT) -> win.INT ---
}

@(private = "file") MF_BYPOSITION :: 0x00000400

@(private = "file")
menu_label :: proc(menu: win.HMENU, pos: int) -> string {
	buf: [128]win.WCHAR
	n := GetMenuStringW(menu, win.UINT(pos), raw_data(buf[:]), win.INT(len(buf)), MF_BYPOSITION)
	if n <= 0 do return ""
	out, _ := win.wstring_to_utf8(win.wstring(raw_data(buf[:])), int(n), context.temp_allocator)
	return out
}

@(test)
a_tray_menu_is_built_as_the_descriptor_asked :: proc(t: ^testing.T) {
	sub := []platform.Tray_Item{
		{id = 5, label = "My files"},
		{id = 6, label = "Shared"},
	}
	items := []platform.Tray_Item{
		{id = 1, label = "Up to date", disabled = true}, // the status line
		{id = 2, separator = true},
		{id = 3, label = "Pause syncing", checked = true},
		{id = 4, label = "Open folder", children = sub},
	}
	menu := win.CreatePopupMenu()
	testing.expect(t, menu != nil, "a popup menu was made")
	if menu == nil do return
	defer win.DestroyMenu(menu)
	tray_fill(menu, items)

	testing.expect_value(t, int(GetMenuItemCount(menu)), 4)

	// The status line: its own label, greyed, and not a separator.
	state0 := GetMenuState(menu, 0, MF_BYPOSITION)
	testing.expectf(t, state0 & win.MF_GRAYED != 0, "the status line is greyed (state %x)", state0)
	testing.expectf(t, state0 & win.MF_SEPARATOR == 0, "…and is not a separator (state %x)", state0)
	testing.expect_value(t, menu_label(menu, 0), "Up to date")
	testing.expect_value(t, GetMenuItemID(menu, 0), win.UINT(1))

	// The separator.
	state1 := GetMenuState(menu, 1, MF_BYPOSITION)
	testing.expectf(t, state1 & win.MF_SEPARATOR != 0, "the separator is one (state %x)", state1)

	// The checkable item: ticked, enabled, and carrying its own id — the
	// id is what comes back from TrackPopupMenu and becomes the app's
	// message, so a wrong one sends the wrong thing.
	state2 := GetMenuState(menu, 2, MF_BYPOSITION)
	testing.expectf(t, state2 & win.MF_CHECKED != 0, "Pause syncing is ticked (state %x)", state2)
	testing.expectf(t, state2 & win.MF_GRAYED == 0, "…and is not greyed (state %x)", state2)
	testing.expect_value(t, menu_label(menu, 2), "Pause syncing")
	testing.expect_value(t, GetMenuItemID(menu, 2), win.UINT(3))

	// The submenu: Windows says an item with one is a popup, and its
	// children are there with their own ids.
	state3 := GetMenuState(menu, 3, MF_BYPOSITION)
	testing.expectf(t, state3 & win.MF_POPUP != 0, "Open folder is a submenu (state %x)", state3)
	testing.expect_value(t, menu_label(menu, 3), "Open folder")
	kids := GetSubMenu(menu, 3)
	testing.expect(t, kids != nil, "…and the submenu is there")
	if kids != nil {
		testing.expect_value(t, int(GetMenuItemCount(kids)), 2)
		testing.expect_value(t, menu_label(kids, 0), "My files")
		testing.expect_value(t, GetMenuItemID(kids, 1), win.UINT(6))
	}
}

// A checkbox that is off must not be ticked — the other half of the
// `Maybe(bool)` the toolkit carries, and the one a wrong default breaks.
@(test)
a_tray_checkbox_that_is_off_is_not_ticked :: proc(t: ^testing.T) {
	items := []platform.Tray_Item{
		{id = 1, label = "Pause syncing", checked = false},
		{id = 2, label = "Show window"},
	}
	menu := win.CreatePopupMenu()
	if menu == nil do return
	defer win.DestroyMenu(menu)
	tray_fill(menu, items)
	off := GetMenuState(menu, 0, MF_BYPOSITION)
	plain := GetMenuState(menu, 1, MF_BYPOSITION)
	testing.expectf(t, off & win.MF_CHECKED == 0, "an unchecked item is not ticked (state %x)", off)
	testing.expectf(t, plain & win.MF_CHECKED == 0, "…nor is one with no checkbox (state %x)", plain)
}

} // when ODIN_TEST
