#+build darwin
package cocoa

// The menu bar, built from the tables in menu_items.odin.
//
// Not a Backend proc and not asked for by the app: a Mac app has a menu bar
// the way it has a close button, and the standard chords live in it, so the
// backend installs one in `init`.
//
// About, Hide, Hide Others and Show All are NSApplication's own and go to
// the responder chain with no target. Quit, Close, Minimize and Zoom have
// our own target, because the app may answer them: `terminate:` and
// `performClose:` would act behind its back, where an Ev_Close lets an
// `on_close` refuse (the reason windowShouldClose: in view.odin says NO).
//
// The Edit items deliver the toolkit's chords, not the Mac's (MENU_EDIT).
// The app's own menus are not mirrored here: a `menu_bar` widget still draws
// in its window.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "baldr:platform"

// menu_install builds the menu bar and hands it to NSApp. Called once, from
// init, after finishLaunching.
@(private)
menu_install :: proc(c: ^Cocoa) {
	if c.app == nil do return
	c.menu_titles = make([dynamic]string, c.allocator)
	name := menu_keep(c, app_display_name(c))

	main := menu_new(c, "")
	if main == nil do return

	// AppKit takes the first item of the main menu as the app menu whatever
	// it is called; the name is for the AX tree.
	if app_menu := menu_build(c, name, MENU_APP[:], name); app_menu != nil {
		menu_mount(c, main, name, app_menu)
	}
	if edit := menu_build(c, "Edit", MENU_EDIT[:], name); edit != nil {
		menu_mount(c, main, "Edit", edit)
	}
	if win := menu_build(c, "Window", MENU_WINDOW[:], name); win != nil {
		menu_mount(c, main, "Window", win)
		// AppKit adds "Bring All to Front" and keeps the window list in here.
		intrinsics.objc_send(nil, c.app, "setWindowsMenu:", win)
	}

	intrinsics.objc_send(nil, c.app, "setMainMenu:", main)
	c.menu = main
	if c.debug_files {
		got := intrinsics.objc_send(^NS.Object, c.app, "mainMenu")
		n := 0
		if got != nil do n = int(intrinsics.objc_send(NS.Integer, got, "numberOfItems"))
		fmt.eprintfln("baldr/cocoa: menu bar for %q installed (%d titles, mainMenu %v)", name, n, got != nil)
	}
}

// menu_shutdown drops the bar. The titles go last: every NSString in the
// menu is initWithBytesNoCopy over bytes this owns.
@(private)
menu_shutdown :: proc(c: ^Cocoa) {
	if c.app != nil do intrinsics.objc_send(nil, c.app, "setMainMenu:", ObjC.id(nil))
	if c.menu != nil {
		intrinsics.objc_send(nil, c.menu, "release")
		c.menu = nil
	}
	if c.menu_target != nil {
		intrinsics.objc_send(nil, c.menu_target, "release")
		c.menu_target = nil
	}
	for t in c.menu_titles do delete(t, c.allocator)
	delete(c.menu_titles)
}

// app_display_name is what the menu calls this application: the bundle's
// CFBundleName, or the process name for a bare binary with no .app.
@(private = "file")
app_display_name :: proc(c: ^Cocoa) -> string {
	if main := intrinsics.objc_send(^Bundle, Bundle, "mainBundle"); main != nil {
		key := ns_str("CFBundleName")
		if key != nil {
			defer key->release()
			if v := intrinsics.objc_send(^NS.String, main, "objectForInfoDictionaryKey:", key); v != nil {
				if s := string(v->odinString()); s != "" do return s
			}
		}
	}
	if pi := NS.ProcessInfo.processInfo(); pi != nil {
		if v := intrinsics.objc_send(^NS.String, pi, "processName"); v != nil {
			if s := string(v->odinString()); s != "" do return s
		}
	}
	return "Application"
}

// menu_keep owns a string for as long as the menu exists. `ns_str` is
// initWithBytesNoCopy, so the bytes behind a title must outlive its NSString.
@(private = "file")
menu_keep :: proc(c: ^Cocoa, s: string) -> string {
	out, err := strings.clone(s, c.allocator)
	if err != nil do return ""
	append(&c.menu_titles, out)
	return out
}

@(private = "file")
menu_new :: proc(c: ^Cocoa, title: string) -> ^NS.Object {
	t := ns_str(menu_keep(c, title))
	if t == nil do return nil
	defer t->release()
	m := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^Menu, Menu, "alloc"), "initWithTitle:", t)
	return m
}

// menu_mount hangs a submenu off the main bar under `title`.
@(private = "file")
menu_mount :: proc(c: ^Cocoa, bar: ^NS.Object, title: string, sub: ^NS.Object) {
	t := ns_str(menu_keep(c, title))
	if t == nil do return
	defer t->release()
	empty := ns_str("")
	if empty == nil do return
	defer empty->release()
	mi := intrinsics.objc_send(^NS.Object, Menu_Item, "alloc")
	mi = intrinsics.objc_send(^NS.Object, mi, "initWithTitle:action:keyEquivalent:", t, ObjC.SEL(nil), empty)
	if mi == nil do return
	intrinsics.objc_send(nil, mi, "setSubmenu:", sub)
	intrinsics.objc_send(nil, bar, "addItem:", mi)
	intrinsics.objc_send(nil, mi, "release") // the bar owns it now
	intrinsics.objc_send(nil, sub, "release") // …and the item owns the submenu
}

// menu_build makes one menu from its table.
@(private = "file")
menu_build :: proc(c: ^Cocoa, title: string, items: []Menu_Item_Desc, app_name: string) -> ^NS.Object {
	m := menu_new(c, title)
	if m == nil do return nil
	for d, i in items {
		if d.act == .Separator {
			if sep := intrinsics.objc_send(^NS.Object, Menu_Item, "separatorItem"); sep != nil {
				intrinsics.objc_send(nil, m, "addItem:", sep)
			}
			continue
		}
		text := d.title
		if strings.contains(d.title, "%s") do text = fmt.tprintf(d.title, app_name)
		t := ns_str(menu_keep(c, text))
		if t == nil do continue
		defer t->release()
		eq := ns_str(menu_keep(c, d.equiv))
		if eq == nil do continue
		defer eq->release()

		sel: ObjC.SEL
		switch d.act {
		case .Native:   sel = ObjC.sel_registerName(strings.clone_to_cstring(d.sel, context.temp_allocator))
		case .Quit:     sel = ObjC.sel_registerName("baldrMenuQuit:")
		case .Close:    sel = ObjC.sel_registerName("baldrMenuClose:")
		case .Minimize: sel = ObjC.sel_registerName("baldrMenuMinimize:")
		case .Zoom:     sel = ObjC.sel_registerName("baldrMenuZoom:")
		case .Chord:    sel = ObjC.sel_registerName("baldrMenuChord:")
		case .Services, .Separator: // no action of their own
		}

		mi := intrinsics.objc_send(^NS.Object, Menu_Item, "alloc")
		mi = intrinsics.objc_send(^NS.Object, mi, "initWithTitle:action:keyEquivalent:", t, sel, eq)
		if mi == nil do continue
		if d.equiv != "" {
			mask := FLAG_SUPER
			if d.shift do mask |= FLAG_SHIFT
			if d.option do mask |= FLAG_ALT
			intrinsics.objc_send(nil, mi, "setKeyEquivalentModifierMask:", NS.UInteger(mask))
		}
		switch d.act {
		case .Quit, .Close, .Minimize, .Zoom, .Chord:
			// A nil target would send these down the responder chain, where
			// nothing implements them and the item greys out.
			if tgt := menu_target(c); tgt != nil do intrinsics.objc_send(nil, mi, "setTarget:", tgt)
			// Which item this is, for the one action that serves several.
			intrinsics.objc_send(nil, mi, "setTag:", NS.Integer(i + 1))
		case .Services:
			if sub := menu_new(c, text); sub != nil {
				intrinsics.objc_send(nil, mi, "setSubmenu:", sub)
				intrinsics.objc_send(nil, c.app, "setServicesMenu:", sub)
				intrinsics.objc_send(nil, sub, "release")
			}
		case .Native, .Separator: // AppKit's own: the responder chain finds it
		}
		intrinsics.objc_send(nil, m, "addItem:", mi)
		intrinsics.objc_send(nil, mi, "release") // the menu owns it now
	}
	return m
}

// ------------------------------------------------------- what was chosen

@(private = "file")
menu_owner :: proc "contextless" (self: ObjC.id) -> ^Cocoa {
	slot := (^^Cocoa)(ObjC.object_getIndexedIvars(self))
	return slot^ if slot != nil else nil
}

// menu_key_surface is the window a menu item acts on: the key or main
// window, else the only window. With several windows and none key there is
// no right answer, so nil.
@(private = "file")
menu_key_surface :: proc(c: ^Cocoa) -> ^Surface {
	if c.app == nil do return nil
	win := intrinsics.objc_send(^NS.Window, c.app, "keyWindow")
	if win == nil do win = intrinsics.objc_send(^NS.Window, c.app, "mainWindow")
	if win != nil {
		for s in c.surfaces do if s != nil && !s.closing && s.win == win do return s
	}
	only: ^Surface
	n := 0
	for s in c.surfaces do if s != nil && !s.closing {
		only = s
		n += 1
	}
	return only if n == 1 else nil
}

@(private = "file")
menu_wake :: proc(c: ^Cocoa) {
	if c.backend.wake != nil do c.backend.wake(&c.backend)
}

// m_quit asks every window to close rather than calling [NSApp terminate:],
// which would end the process without letting an `on_close` refuse. An app
// with no on_close ends on the first one (app.odin's close_event); an app
// with no windows gets Ev_Quit.
@(private = "file")
m_quit :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := menu_owner(self)
	if c == nil do return
	context = c.ctx
	n := 0
	for s in c.surfaces do if s != nil && !s.closing {
		append(&c.queue, platform.Ev_Close{surface = s.id, reason = .User})
		n += 1
	}
	if n == 0 do append(&c.queue, platform.Ev_Quit{})
	if c.debug_files do fmt.eprintfln("baldr/cocoa: menu Quit -> %d close(s)%s", n, ", and Ev_Quit" if n == 0 else "")
	menu_wake(c)
}

@(private = "file")
m_close :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := menu_owner(self)
	if c == nil do return
	context = c.ctx
	s := menu_key_surface(c)
	if c.debug_files do fmt.eprintfln("baldr/cocoa: menu Close -> surface %v", s.id if s != nil else 0)
	if s == nil do return
	append(&c.queue, platform.Ev_Close{surface = s.id, reason = .User})
	menu_wake(c)
}

// Minimise and zoom are nothing for the app to refuse, so they go straight
// to the window. `miniaturize:` and not `performMiniaturize:`, which beeps
// at a window without the title-bar button, and a window drawing its own
// frame is the normal case.
@(private = "file")
m_minimize :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := menu_owner(self)
	if c == nil do return
	context = c.ctx
	s := menu_key_surface(c)
	if c.debug_files do fmt.eprintfln("baldr/cocoa: menu Minimize -> surface %v", s.id if s != nil else 0)
	if s != nil && s.win != nil do intrinsics.objc_send(nil, s.win, "miniaturize:", ObjC.id(nil))
}

@(private = "file")
m_zoom :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := menu_owner(self)
	if c == nil do return
	context = c.ctx
	s := menu_key_surface(c)
	if c.debug_files do fmt.eprintfln("baldr/cocoa: menu Zoom -> surface %v", s.id if s != nil else 0)
	if s != nil && s.win != nil do intrinsics.objc_send(nil, s.win, "zoom:", ObjC.id(nil))
}

// m_chord delivers the toolkit chord this Edit item stands for, as the press
// and release the pump would append for a real key. `native` is 0 because no
// physical key was pressed; a made-up code would be printed by `key_name`.
@(private = "file")
m_chord :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := menu_owner(self)
	if c == nil do return
	context = c.ctx
	i := int(intrinsics.objc_send(NS.Integer, cast(^NS.Object)sender, "tag")) - 1
	if i < 0 || i >= len(MENU_EDIT) do return
	d := MENU_EDIT[i]
	if d.act != .Chord do return
	s := menu_key_surface(c)
	if c.debug_files {
		fmt.eprintfln("baldr/cocoa: menu %q -> %v on surface %v", d.title, d.key, s.id if s != nil else 0)
	}
	if s == nil do return
	append(&c.queue, platform.Ev_Key{surface = s.id, key = d.key, pressed = true, mods = d.chord})
	append(&c.queue, platform.Ev_Key{surface = s.id, key = d.key, pressed = false, mods = d.chord})
	menu_wake(c)
}

@(private = "file")
menu_target :: proc(c: ^Cocoa) -> ^NS.Object {
	if c.menu_target != nil do return c.menu_target
	if c.menu_class == nil {
		super := intrinsics.objc_find_class("NSObject")
		if super == nil do return nil
		cls := ObjC.objc_allocateClassPair(super, "BaldrMenuTarget", size_of(rawptr))
		if cls == nil do return nil
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrMenuQuit:"), auto_cast m_quit, "v@:@")
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrMenuClose:"), auto_cast m_close, "v@:@")
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrMenuMinimize:"), auto_cast m_minimize, "v@:@")
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrMenuZoom:"), auto_cast m_zoom, "v@:@")
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrMenuChord:"), auto_cast m_chord, "v@:@")
		ObjC.objc_registerClassPair(cls)
		c.menu_class = cls
	}
	obj := ObjC.class_createInstance(c.menu_class, size_of(rawptr))
	if obj == nil do return nil
	if slot := (^^Cocoa)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = c
	c.menu_target = cast(^NS.Object)obj
	return c.menu_target
}
