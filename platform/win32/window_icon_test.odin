#+build windows
package win32

@(require) import "core:testing"
@(require) import win "core:sys/windows"
@(require) import "baldr:platform"

// Runs on Windows: `odin test platform/win32`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A window opened with the app's icon carries it: Windows hands it back for
// the taskbar and Alt+Tab (big) and for the title bar (small). And a window
// declared with a parent is owned by it, so Windows keeps it above that
// window and minimises it along with it. One backend for both: two at once
// would register the same window class.
@(test)
a_window_carries_the_apps_icon_and_its_parent :: proc(t: ^testing.T) {
	b := backend()
	if ok, why := init(b); !ok {
		testing.fail_now(t, why)
	}
	defer shutdown(b)
	argb := make([]u32, 32 * 32, context.temp_allocator)
	for &p in argb do p = 0xFF2266EE
	main_id, ok := surface_create(b, platform.Surface_Desc{kind = .Window, title = "icon", size = {200, 100}, icon = {w = 32, h = 32, argb = argb}})
	if !testing.expect(t, ok, "the window opened") do return
	s := get_surface(data(b), main_id)
	if !testing.expect(t, s != nil && s.icon != nil, "an icon was made from the pixels") do return
	big := win.HICON(rawptr(uintptr(win.SendMessageW(s.hwnd, win.WM_GETICON, 1, 0))))
	small := win.HICON(rawptr(uintptr(win.SendMessageW(s.hwnd, win.WM_GETICON, 0, 0))))
	testing.expect(t, big == s.icon, "the big icon is the app's")
	testing.expect(t, small == s.icon, "so is the small one")

	prefs_id, pok := surface_create(b, platform.Surface_Desc{kind = .Window, title = "prefs", size = {200, 100}, parent = main_id})
	if !testing.expect(t, pok, "the second window opened") do return
	prefs := get_surface(data(b), prefs_id)
	testing.expect(t, win.GetWindow(prefs.hwnd, win.GW_OWNER) == s.hwnd, "the main window owns it")
	testing.expect(t, win.GetWindow(s.hwnd, win.GW_OWNER) == nil, "the main window has no owner")
	surface_destroy(b, prefs_id)
	surface_destroy(b, main_id)
}
}
