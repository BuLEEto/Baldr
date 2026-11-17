#+build darwin
package cocoa

// The status item on macOS: `NSStatusItem` in the menu bar, with an
// `NSMenu` built from the same descriptor the other backends get.
//
// The icon is a template image, so the system draws it in whatever colour a
// light or dark menu bar needs. The toolkit's icons are coverage masks
// already, which is what a template wants.
//
// A status item with a menu set shows it on any click, so "left click opens
// the window, right click opens the menu" cannot just hand over an NSMenu.
// The button's action is taken instead, and the menu is popped up from it
// for a right click or a Control-click.
//
// The image is made through CoreGraphics (a bitmap context and
// `initWithCGImage:size:`): an NSBitmapImageRep from the same pixels is
// valid, sized and inked, and draws nothing in a status item. The button
// also needs `setImagePosition:`, or it draws its empty title instead.
//
// There is no attention state on macOS, so `.Attention` is the app's
// attention icon and nothing more.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:fmt"
import "baldr:platform"

@(private) @(objc_class = "NSStatusBar")
Status_Bar :: struct {using _: NS.Object}
@(private) @(objc_class = "NSMenu")
Menu :: struct {using _: NS.Object}
@(private) @(objc_class = "NSMenuItem")
Menu_Item :: struct {using _: NS.Object}

// CoreGraphics, for turning pixels into a picture (see the top of the file
// for why not NSBitmapImageRep).
foreign import CG "system:CoreGraphics.framework"

@(default_calling_convention = "c")
foreign CG {
	CGColorSpaceCreateDeviceRGB :: proc() -> rawptr ---
	CGColorSpaceRelease         :: proc(space: rawptr) ---
	CGBitmapContextCreate       :: proc(data: rawptr, width, height, bits_per_component, bytes_per_row: uint, space: rawptr, info: u32) -> rawptr ---
	CGBitmapContextCreateImage  :: proc(ctx: rawptr) -> rawptr ---
	CGContextRelease            :: proc(ctx: rawptr) ---
	CGImageRelease              :: proc(image: rawptr) ---
}

// kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little: ARGB words
// in memory, which is what the toolkit hands over.
@(private = "file") CG_ARGB_LITTLE :: u32(2 | (2 << 12))

@(private = "file") VARIABLE_LENGTH :: f64(-1)
@(private = "file") EVENT_RIGHT_UP  :: 4      // NSEventTypeRightMouseUp
@(private = "file") EVENT_RIGHT_DOWN :: 3
@(private = "file") CONTROL_KEY     :: 1 << 18 // NSEventModifierFlagControl
@(private = "file") STATE_ON        :: 1       // NSControlStateValueOn
@(private = "file") STATE_OFF       :: 0

// Tray_Entry is one status item. `pixels` holds the icon's bytes: the bitmap
// context draws into them in place and its image may share them rather than
// copy, so they live as long as the item shows that icon.
Tray_Entry :: struct {
	tag:    u64,
	item:   ^NS.Object, // NSStatusItem
	menu:   ^NS.Object, // NSMenu, rebuilt when the descriptor changes
	pixels: []u8,
	ids:    map[uintptr]u32, // NSMenuItem -> the toolkit's id
}

@(private)
tray_init :: proc(c: ^Cocoa) {
	c.tray_ids = make(map[uintptr]u32, c.allocator)
}

@(private)
tray_shutdown :: proc(c: ^Cocoa) {
	for &e in c.tray do tray_entry_free(c, &e)
	delete(c.tray)
	delete(c.tray_ids)
}

@(private = "file")
tray_entry_free :: proc(c: ^Cocoa, e: ^Tray_Entry) {
	if e.item != nil {
		bar := intrinsics.objc_send(^Status_Bar, Status_Bar, "systemStatusBar")
		if bar != nil do intrinsics.objc_send(nil, bar, "removeStatusItem:", e.item)
		intrinsics.objc_send(nil, e.item, "release")
	}
	if e.menu != nil do intrinsics.objc_send(nil, e.menu, "release")
	delete(e.pixels, c.allocator)
}

@(private)
b_tray_set :: proc(b: ^platform.Backend, d: platform.Tray_Desc) -> bool {
	c := self(b)
	i := -1
	for e, j in c.tray do if e.tag == d.tag do i = j
	if i < 0 {
		bar := intrinsics.objc_send(^Status_Bar, Status_Bar, "systemStatusBar")
		if bar == nil do return false
		item := intrinsics.objc_send(^NS.Object, bar, "statusItemWithLength:", VARIABLE_LENGTH)
		if item == nil do return false
		intrinsics.objc_send(nil, item, "retain") // the bar's array is not ours to trust
		append(&c.tray, Tray_Entry{tag = d.tag, item = item})
		i = len(c.tray) - 1
		// The menu bar is always there, so an item added is an item hosted.
		append(&c.queue, platform.Ev_Tray{tag = d.tag, kind = .Hosted})
	}
	e := &c.tray[i]

	button := intrinsics.objc_send(^NS.Object, e.item, "button")
	if button != nil {
		if img := tray_image(c, e, d.icon); img != nil {
			intrinsics.objc_send(nil, button, "setImage:", img)
			// NSImageOnly: the button otherwise draws its empty title and the
			// icon is never seen.
			intrinsics.objc_send(nil, button, "setImagePosition:", NS.UInteger(1))
			if c.debug_files {
				// For an icon that does not show: is the item in the bar, how
				// big is the picture, and does it have any ink.
				vis := intrinsics.objc_send(NS.BOOL, e.item, "isVisible")
				size := intrinsics.objc_send(NS.Size, img, "size")
				ink := 0
				for a := 3; a < len(e.pixels); a += 4 do if e.pixels[a] > 32 do ink += 1
				fmt.eprintfln("baldr/cocoa: tray visible=%v image %.0fx%.0f, %d of %d pixels inked",
					bool(vis), size.width, size.height, ink, len(e.pixels) / 4)
			}
		}
		tip := ns_str(d.tooltip if len(d.tooltip) > 0 else d.title)
		if tip != nil {
			intrinsics.objc_send(nil, button, "setToolTip:", tip)
			tip->release()
		}
		// The button's own action, so a left click is not swallowed by the
		// menu. `sendActionOn:` asks for the up events; without it only a
		// left down arrives.
		if del := tray_delegate(c); del != nil {
			intrinsics.objc_send(nil, button, "setTarget:", del)
			intrinsics.objc_send(nil, button, "setAction:", ObjC.sel_registerName("baldrTrayClick:"))
			mask := NS.UInteger((1 << 2) | (1 << 4)) // LeftMouseUp | RightMouseUp
			intrinsics.objc_send(NS.Integer, button, "sendActionOn:", mask)
		}
	}

	if e.menu != nil {
		intrinsics.objc_send(nil, e.menu, "release")
		e.menu = nil
	}
	e.menu = tray_menu(c, d.menu)
	return true
}

@(private)
b_tray_remove :: proc(b: ^platform.Backend, tag: u64) {
	c := self(b)
	for &e, i in c.tray {
		if e.tag != tag do continue
		tray_entry_free(c, &e)
		ordered_remove(&c.tray, i)
		return
	}
}

// tray_image turns the toolkit's pixmaps into a template NSImage at the
// 18 points Apple asks for; the 32 px pixmap gives two pixels per point on a
// retina screen.
@(private = "file")
tray_image :: proc(c: ^Cocoa, e: ^Tray_Entry, sizes: []platform.Tray_Pixmap) -> ^NS.Image {
	if len(sizes) == 0 do return nil
	best := sizes[0]
	for p in sizes do if p.w >= 32 && p.w < best.w || best.w < 32 && p.w > best.w do best = p

	// Kept on the entry: the context uses these bytes in place, and the
	// image it makes may share them rather than copy.
	delete(e.pixels, c.allocator)
	e.pixels = make([]u8, len(best.argb) * 4, c.allocator)
	for v, i in best.argb {
		e.pixels[i * 4 + 0] = u8(v)       // B
		e.pixels[i * 4 + 1] = u8(v >> 8)  // G
		e.pixels[i * 4 + 2] = u8(v >> 16) // R
		e.pixels[i * 4 + 3] = u8(v >> 24) // A
	}
	space := CGColorSpaceCreateDeviceRGB()
	if space == nil do return nil
	defer CGColorSpaceRelease(space)
	ctx := CGBitmapContextCreate(raw_data(e.pixels), uint(best.w), uint(best.h), 8, uint(best.w * 4), space, CG_ARGB_LITTLE)
	if ctx == nil do return nil
	defer CGContextRelease(ctx)
	cg := CGBitmapContextCreateImage(ctx)
	if cg == nil do return nil
	defer CGImageRelease(cg)
	// 18 points, from a 32 px picture: two pixels a point on retina.
	img := intrinsics.objc_send(^NS.Image, NS.Image, "alloc")
	if img == nil do return nil
	img = intrinsics.objc_send(^NS.Image, img, "initWithCGImage:size:", cg, NS.Size{18, 18})
	if img == nil do return nil
	// A template image is drawn in whatever colour the menu bar needs,
	// which is how it follows light and dark.
	intrinsics.objc_send(nil, img, "setTemplate:", NS.BOOL(true))
	return img
}

// tray_menu builds an NSMenu. Auto-enabling is off: left on, the menu asks
// each item's target and ignores `setEnabled:`, so a disabled line would be
// clickable.
@(private = "file")
tray_menu :: proc(c: ^Cocoa, items: []platform.Tray_Item) -> ^NS.Object {
	menu := intrinsics.objc_send(^NS.Object, intrinsics.objc_send(^Menu, Menu, "alloc"), "init")
	if menu == nil do return nil
	intrinsics.objc_send(nil, menu, "setAutoenablesItems:", NS.BOOL(false))
	del := tray_delegate(c)
	for it in items {
		if it.separator {
			sep := intrinsics.objc_send(^NS.Object, Menu_Item, "separatorItem")
			if sep != nil do intrinsics.objc_send(nil, menu, "addItem:", sep)
			continue
		}
		title := ns_str(it.label)
		if title == nil do continue
		defer title->release()
		empty := ns_str("")
		defer if empty != nil do empty->release()
		mi := intrinsics.objc_send(^NS.Object, Menu_Item, "alloc")
		mi = intrinsics.objc_send(^NS.Object, mi, "initWithTitle:action:keyEquivalent:",
			title, ObjC.sel_registerName("baldrTrayItem:"), empty)
		if mi == nil do continue
		intrinsics.objc_send(nil, mi, "setTarget:", del)
		intrinsics.objc_send(nil, mi, "setEnabled:", NS.BOOL(!it.disabled))
		if on, has := it.checked.?; has {
			intrinsics.objc_send(nil, mi, "setState:", NS.Integer(STATE_ON if on else STATE_OFF))
		}
		// The id travels in the item's tag and in a table; the table keeps a
		// stale item from a rebuilt menu harmless.
		intrinsics.objc_send(nil, mi, "setTag:", NS.Integer(it.id))
		c.tray_ids[uintptr(rawptr(mi))] = it.id
		if len(it.children) > 0 {
			if sub := tray_menu(c, it.children); sub != nil {
				intrinsics.objc_send(nil, mi, "setSubmenu:", sub)
			}
		}
		intrinsics.objc_send(nil, menu, "addItem:", mi)
		intrinsics.objc_send(nil, mi, "release") // the menu owns it now
	}
	return menu
}

// ------------------------------------------------------- what was clicked

@(private = "file")
tray_owner :: proc "contextless" (self: ObjC.id) -> ^Cocoa {
	slot := (^^Cocoa)(ObjC.object_getIndexedIvars(self))
	return slot^ if slot != nil else nil
}

@(private = "file")
t_click :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := tray_owner(self)
	if c == nil || len(c.tray) == 0 do return
	context = c.ctx
	e := &c.tray[0]
	right := false
	if c.app != nil {
		if ev := intrinsics.objc_send(^NS.Object, c.app, "currentEvent"); ev != nil {
			kind := intrinsics.objc_send(NS.UInteger, ev, "type")
			mods := intrinsics.objc_send(NS.UInteger, ev, "modifierFlags")
			right = kind == EVENT_RIGHT_UP || kind == EVENT_RIGHT_DOWN || (mods & CONTROL_KEY) != 0
		}
	}
	if right && e.menu != nil {
		// The menu is set for this click only: left set, it would swallow the
		// next left click too.
		intrinsics.objc_send(nil, e.item, "setMenu:", e.menu)
		if button := intrinsics.objc_send(^NS.Object, e.item, "button"); button != nil {
			intrinsics.objc_send(nil, button, "performClick:", ObjC.id(nil))
		}
		intrinsics.objc_send(nil, e.item, "setMenu:", ObjC.id(nil))
		return
	}
	append(&c.queue, platform.Ev_Tray{tag = e.tag, kind = .Clicked})
	if c.backend.wake != nil do c.backend.wake(&c.backend)
}

@(private = "file")
t_item :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, sender: ObjC.id) {
	c := tray_owner(self)
	if c == nil || len(c.tray) == 0 do return
	context = c.ctx
	id, found := c.tray_ids[uintptr(rawptr(sender))]
	if !found {
		tag := intrinsics.objc_send(NS.Integer, cast(^NS.Object)sender, "tag")
		if tag <= 0 do return
		id = u32(tag)
	}
	append(&c.queue, platform.Ev_Tray{tag = c.tray[0].tag, kind = .Chosen, id = id})
	if c.backend.wake != nil do c.backend.wake(&c.backend)
}

@(private = "file")
tray_delegate :: proc(c: ^Cocoa) -> ^NS.Object {
	if c.tray_target != nil do return c.tray_target
	if c.tray_class == nil {
		super := intrinsics.objc_find_class("NSObject")
		if super == nil do return nil
		cls := ObjC.objc_allocateClassPair(super, "BaldrTrayTarget", size_of(rawptr))
		if cls == nil do return nil
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrTrayClick:"), auto_cast t_click, "v@:@")
		ObjC.class_addMethod(cls, ObjC.sel_registerName("baldrTrayItem:"), auto_cast t_item, "v@:@")
		ObjC.objc_registerClassPair(cls)
		c.tray_class = cls
	}
	obj := ObjC.class_createInstance(c.tray_class, size_of(rawptr))
	if obj == nil do return nil
	if slot := (^^Cocoa)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = c
	c.tray_target = cast(^NS.Object)obj
	return c.tray_target
}
