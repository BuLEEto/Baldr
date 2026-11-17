#+build darwin
package cocoa

// Hearing when the desktop's preferences change: light or dark, reduce
// motion, reduce transparency, increase contrast, the accent. Followed live,
// as the Settings portal's signal is on Linux and `WM_SETTINGCHANGE` on
// Windows, so a setting turned on while an app runs takes effect at once.
//
// Three sources, because macOS keeps them apart:
//
//   - the accessibility display options on NSWorkspace's own notification
//     centre (`NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification`);
//   - the accent and other system colours on the default centre
//     (`NSSystemColorsDidChangeNotification`);
//   - light and dark on the distributed centre
//     (`AppleInterfaceThemeChangedNotification`). AppKit has no notification
//     of its own for the appearance, and this avoids observing
//     `effectiveAppearance` by KVO.
//
// All three set one flag, and the pump turns it into a single `Ev_Theme`,
// as Windows does with `theme_pending`: one appearance change posts several
// notifications in a row, and each would rebuild the app's whole tree.

import "base:intrinsics"
import "core:fmt"
import ObjC "core:sys/darwin/ObjectiveC"
import NS "vendor:darwin/AppKit"

@(private) @(objc_class = "NSDistributedNotificationCenter")
Dist_Centre :: struct {using _: NS.Object}

@(private) NOTE_A11Y_DISPLAY :: "NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification"
@(private) NOTE_SYSTEM_COLORS :: "NSSystemColorsDidChangeNotification"
@(private) NOTE_APPEARANCE :: "AppleInterfaceThemeChangedNotification"

// prefs_watch registers for all three. Called once at start, beside
// `outputs_watch`.
@(private)
prefs_watch :: proc(c: ^Cocoa) {
	if c.prefs_watch != nil do return
	super := intrinsics.objc_find_class("NSObject")
	if super == nil do return
	cls := ObjC.objc_allocateClassPair(super, "BaldrPrefsWatch", size_of(rawptr))
	if cls == nil do return
	ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrPrefsChanged:"), auto_cast m_prefs_changed, "v@:@")
	ObjC.objc_registerClassPair(cls)
	obj := ObjC.class_createInstance(cls, size_of(rawptr))
	if obj == nil do return
	if slot := (^^Cocoa)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = c
	c.prefs_watch = cast(^NS.Object)obj

	sel := ObjC.sel_registerName("baldrPrefsChanged:")
	// The accessibility options, on the workspace's own centre.
	if ws := shared_workspace(); ws != nil {
		if centre := intrinsics.objc_send(^NS.Object, ws, "notificationCenter"); centre != nil {
			prefs_add(centre, c.prefs_watch, sel, NOTE_A11Y_DISPLAY)
		}
	}
	// The system colours, on the default centre.
	if centre := intrinsics.objc_send(^NS.Object, Note_Centre, "defaultCenter"); centre != nil {
		prefs_add(centre, c.prefs_watch, sel, NOTE_SYSTEM_COLORS)
	}
	// Light and dark, on the distributed centre.
	if centre := intrinsics.objc_send(^NS.Object, Dist_Centre, "defaultCenter"); centre != nil {
		prefs_add(centre, c.prefs_watch, sel, NOTE_APPEARANCE)
	}
	if c.debug_files do fmt.eprintfln("baldr/cocoa: watching the desktop's preferences")
}

@(private = "file")
prefs_add :: proc(centre: ^NS.Object, who: ^NS.Object, sel: ObjC.SEL, name: string) {
	n := ns_str(name)
	if n == nil do return
	defer n->release()
	intrinsics.objc_send(nil, centre, "addObserver:selector:name:object:", who, sel, n, ObjC.id(nil))
}

@(private)
prefs_shutdown :: proc(c: ^Cocoa) {
	if c.prefs_watch == nil do return
	// Every centre it was added to: an observer left behind on a centre is a
	// crash the next time that notification fires.
	if ws := shared_workspace(); ws != nil {
		if centre := intrinsics.objc_send(^NS.Object, ws, "notificationCenter"); centre != nil {
			intrinsics.objc_send(nil, centre, "removeObserver:", c.prefs_watch)
		}
	}
	if centre := intrinsics.objc_send(^NS.Object, Note_Centre, "defaultCenter"); centre != nil {
		intrinsics.objc_send(nil, centre, "removeObserver:", c.prefs_watch)
	}
	if centre := intrinsics.objc_send(^NS.Object, Dist_Centre, "defaultCenter"); centre != nil {
		intrinsics.objc_send(nil, centre, "removeObserver:", c.prefs_watch)
	}
	intrinsics.objc_send(nil, c.prefs_watch, "release")
	c.prefs_watch = nil
}

// m_prefs_changed is all three notifications. It reads nothing: the pump
// asks `b_system_theme` for the whole picture when it flushes, so a change
// to one preference cannot report stale values for the others.
@(private = "file")
m_prefs_changed :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, note: ObjC.id) {
	slot := (^^Cocoa)(ObjC.object_getIndexedIvars(self))
	if slot == nil || slot^ == nil do return
	c := slot^
	context = c.ctx
	c.theme_pending = true
	if c.debug_files do fmt.eprintfln("baldr/cocoa: the desktop's preferences changed")
	b_wake(&c.backend)
}

// prefs_flush turns however many notifications arrived into one Ev_Theme.
// Called from the pump, the way win32's `flush_marks` does it.
@(private)
prefs_flush :: proc(c: ^Cocoa) {
	if !c.theme_pending do return
	c.theme_pending = false
	append(&c.queue, b_system_theme(&c.backend))
}
