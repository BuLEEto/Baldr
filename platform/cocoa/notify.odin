#+build darwin
package cocoa

// Desktop notifications on macOS, through UNUserNotificationCenter.
//
// It needs a bundle: `currentNotificationCenter` raises when the process has
// no bundle identifier, and an ObjC exception out of a Baldr frame aborts
// the process. So a bare binary is answered `Failed`, with a reason. The
// code-signing identifier must also match CFBundleIdentifier, or the app is
// refused with no prompt and nothing logged; a linker's ad-hoc signature is
// named after the executable, so a dev bundle needs `codesign --force
// --sign - --identifier <bundle id>`.
//
// Permission is asked once, at init, and answered on another thread. A
// notification sent before the answer goes to the system anyway, which
// holds or drops it by its own rules; once a refusal is known `notify`
// answers `Failed` at once.
//
// Action buttons are not supported, as on Windows: they need a
// UNNotificationCategory registered beforehand. A click arrives as
// `Activated` with an empty action, but may never be delivered, so a
// notification should be informative on its own.
//
// Not in the Odin bindings, so built by hand: the UN classes, looked up by
// name; the delegate, a class made at runtime as in view.odin; and one ObjC
// block for the authorization answer. A global block is the one shape safe
// to write from Odin: `Block_copy` leaves it alone, so what it captures stays
// valid and nothing has to be freed.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "core:dynlib"
import "core:fmt"
import "core:strconv"
import "core:sync"
import "baldr:platform"

@(private) @(objc_class = "NSBundle")
Bundle :: struct {using _: NS.Object}

// ------------------------------------------- talking to a late framework
//
// A compiled-in class reference is bound when the binary loads, so
// `@(objc_class = "UNUserNotificationCenter")` and `objc_find_class` stay
// nil in a process that loads UserNotifications afterwards, as every Baldr
// app does. So these classes are looked up by name at run time and their
// messages sent through `objc_msgSend` cast to each call's signature.

@(private = "file") Id :: rawptr

// Objc is the two runtime entry points this file needs, looked up through
// core:dynlib. `base:runtime` already declares `objc_msgSend` as variadic
// and Odin keeps one type per link name, so it cannot be redeclared per call
// shape; its address is cast per shape at the point of use instead.
@(private)
Objc :: struct {
	lookup: proc "c" (name: cstring) -> Id,
	send:   rawptr,
}

@(private = "file")
objc_open :: proc(o: ^Objc) -> bool {
	if o.send != nil do return true
	lib, ok := dynlib.load_library("/usr/lib/libobjc.A.dylib")
	if !ok do return false
	look, lok := dynlib.symbol_address(lib, "objc_lookUpClass")
	send, sok := dynlib.symbol_address(lib, "objc_msgSend")
	if !lok || !sok do return false
	o.lookup = cast(proc "c" (name: cstring) -> Id)(look)
	o.send = send
	return true
}

@(private = "file")
cls :: proc(o: Objc, name: cstring) -> Id {
	return o.lookup(name) if o.lookup != nil else nil
}

@(private = "file")
m0 :: proc(o: Objc, self: Id, op: cstring) -> Id {
	if self == nil || o.send == nil do return nil
	f := cast(proc "c" (self: Id, op: ObjC.SEL) -> Id)(o.send)
	return f(self, ObjC.sel_registerName(op))
}

@(private = "file")
m0_cstr :: proc(o: Objc, self: Id, op: cstring) -> cstring {
	if self == nil || o.send == nil do return nil
	f := cast(proc "c" (self: Id, op: ObjC.SEL) -> cstring)(o.send)
	return f(self, ObjC.sel_registerName(op))
}

@(private = "file")
m1 :: proc(o: Objc, self: Id, op: cstring, a: Id) -> Id {
	if self == nil || o.send == nil do return nil
	f := cast(proc "c" (self: Id, op: ObjC.SEL, a: Id) -> Id)(o.send)
	return f(self, ObjC.sel_registerName(op), a)
}

@(private = "file")
m3 :: proc(o: Objc, self: Id, op: cstring, a, b, c: Id) -> Id {
	if self == nil || o.send == nil do return nil
	f := cast(proc "c" (self: Id, op: ObjC.SEL, a, b, c: Id) -> Id)(o.send)
	return f(self, ObjC.sel_registerName(op), a, b, c)
}

// requestAuthorizationWithOptions:completionHandler: — an integer and a
// block, which no other call here takes.
@(private = "file")
m_auth :: proc(o: Objc, self: Id, options: NS.UInteger, block: rawptr) {
	if self == nil || o.send == nil do return
	f := cast(proc "c" (self: Id, op: ObjC.SEL, options: NS.UInteger, block: rawptr))(o.send)
	f(self, ObjC.sel_registerName("requestAuthorizationWithOptions:completionHandler:"), options, block)
}

// addNotificationRequest:withCompletionHandler: — an object and a block
// that may be nil (the one place a nil handler is allowed, and taken).
@(private = "file")
m_add :: proc(o: Objc, self: Id, req: Id) {
	if self == nil || o.send == nil do return
	f := cast(proc "c" (self: Id, op: ObjC.SEL, req: Id, block: rawptr))(o.send)
	f(self, ObjC.sel_registerName("addNotificationRequest:withCompletionHandler:"), req, nil)
}

// UNAuthorizationOptionAlert | UNAuthorizationOptionSound. Badge is left
// out: a tray app's count belongs in its own icon, not on a Dock tile.
@(private = "file") AUTH_ALERT_SOUND :: NS.UInteger(1 << 2 | 1 << 1)
// UNNotificationPresentationOptionBanner | …Sound, for a notification that
// arrives while the app is in front; without them the system shows nothing.
@(private = "file") PRESENT_BANNER_SOUND :: NS.UInteger(1 << 4 | 1 << 1)

@(private = "file") ACTION_DEFAULT :: "com.apple.UNNotificationDefaultActionIdentifier"
@(private = "file") ACTION_DISMISS :: "com.apple.UNNotificationDismissActionIdentifier"

// ---------------------------------------------------------------- blocks

@(private = "file")
Block_Descriptor :: struct {
	reserved: u64,
	size:     u64,
}

// The layout every ObjC block starts with. BLOCK_IS_GLOBAL in `flags` marks
// it static, so copying it hands back the same pointer; that is what makes a
// block written in Odin safe to hand to a framework.
@(private = "file")
Block_Literal :: struct {
	isa:        rawptr,
	flags:      i32,
	reserved:   i32,
	invoke:     rawptr,
	descriptor: ^Block_Descriptor,
}

@(private = "file") BLOCK_IS_GLOBAL :: i32(1 << 28)

// Auth_Block is the block the authorization answer comes back through,
// with the backend it belongs to captured on the end of it. One per
// backend, living in the Cocoa struct, so there is no global state here
// and nothing to free.
@(private = "file")
Auth_Block :: struct {
	using base: Block_Literal,
	c:          ^Cocoa,
}

// `_NSConcreteGlobalBlock` is the class every static block points at; only
// its address is used. `base:runtime` declares it without exporting it, so
// it is declared here from the same library with the same type, or the link
// conflicts.
foreign import libSystem "system:System"

@(default_calling_convention = "c")
foreign libSystem {
	_NSConcreteGlobalBlock: intrinsics.objc_class
}

// ------------------------------------------------------------ the state

// Notify_State is what the notification centre needs to remember. The
// answers arrive on threads of the system's choosing, so everything here is
// behind the mutex and the events are staged until a pump drains them on
// the thread that owns the queue.
@(private)
Notify_State :: struct {
	mu:      sync.Mutex,
	pending: [dynamic]platform.Ev_Notify,
	auth:    Auth_Block,
	asked:    bool, // authorization has been requested
	answered: bool, // …the system has said one way or the other
	refused:  bool, // …and the answer was no
	delegate: ^NS.Object,
	lib:      dynlib.Library, // UserNotifications.framework, loaded on demand
	objc:     Objc,           // …and the runtime's two entry points
}

// notify_framework loads UserNotifications.framework, which nothing links:
// a class reached by name is not there until its framework is loaded. False
// on a macOS without it.
@(private = "file")
notify_framework :: proc(c: ^Cocoa) -> bool {
	if !objc_open(&c.notify.objc) do return false
	if c.notify.lib == nil {
		lib, ok := dynlib.load_library("/System/Library/Frameworks/UserNotifications.framework/UserNotifications")
		if !ok do return false
		c.notify.lib = lib
	}
	return cls(c.notify.objc, "UNUserNotificationCenter") != nil
}

@(private)
notify_init :: proc(c: ^Cocoa) {
	if !bundled() do return // without a bundle there is nothing to ask for
	c.notify.pending = make([dynamic]platform.Ev_Notify, c.allocator)
	if !notify_framework(c) do return
	center := notify_center(c.notify.objc)
	if center == nil do return

	c.notify.auth = Auth_Block{
		base = {isa = rawptr(&_NSConcreteGlobalBlock), flags = BLOCK_IS_GLOBAL, invoke = rawptr(auth_answered)},
		c = c,
	}
	c.notify.auth.descriptor = &auth_descriptor
	c.notify.asked = true
	m_auth(c.notify.objc, center, AUTH_ALERT_SOUND, &c.notify.auth)

	if d := notify_delegate_make(c); d != nil {
		c.notify.delegate = d
		m1(c.notify.objc, center, "setDelegate:", rawptr(d))
	}
}

// ---------------------------------------------------------- the delegate
//
// What the person did with a notification arrives through a
// UNUserNotificationCenterDelegate: a class made at runtime, its instance
// carrying the backend in its indexed ivars, as in view.odin. Both methods
// are handed a completion block the system waits on; calling one is calling
// the `invoke` pointer in its layout.

@(private = "file")
delegate_owner :: proc "contextless" (self: ObjC.id) -> ^Cocoa {
	slot := (^^Cocoa)(ObjC.object_getIndexedIvars(self))
	return slot^ if slot != nil else nil
}

@(private = "file")
call_block :: proc "contextless" (block: rawptr, arg: NS.UInteger, with_arg: bool) {
	if block == nil do return
	b := (^Block_Literal)(block)
	if b.invoke == nil do return
	if with_arg {
		f := (proc "c" (block: rawptr, options: NS.UInteger))(b.invoke)
		f(block, arg)
		return
	}
	f := (proc "c" (block: rawptr))(b.invoke)
	f(block)
}

// A notification that arrives while the app is in front shows nothing
// unless this asks for it.
@(private = "file")
d_will_present :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, center: rawptr, notification: rawptr, completion: rawptr) {
	if c := delegate_owner(self); c != nil && c.debug_files {
		context = c.ctx
		fmt.eprintln("baldr/cocoa: a notification arrived while this app is in front; asking for it to be shown anyway")
	}
	call_block(completion, PRESENT_BANNER_SOUND, true)
}

@(private = "file")
d_did_receive :: proc "c" (self: ObjC.id, cmd: ObjC.SEL, center: rawptr, response: rawptr, completion: rawptr) {
	defer call_block(completion, 0, false) // the system waits for this
	c := delegate_owner(self)
	if c == nil || response == nil do return
	context = c.ctx
	o := c.notify.objc
	req := m0(o, m0(o, response, "notification"), "request")
	if req == nil do return
	tag, ok := notify_tag(o, m0(o, req, "identifier"))
	if !ok do return // not one of ours
	action := ""
	if cs := m0_cstr(o, m0(o, response, "actionIdentifier"), "UTF8String"); cs != nil do action = string(cs)
	// Dismissed is not chosen: an app that treats both as "they want this"
	// interrupts the person twice (platform.odin, Notify_Close_Reason).
	if action == ACTION_DISMISS {
		notify_stage(c, platform.Ev_Notify{tag = tag, event = .Closed, reason = .Dismissed})
		return
	}
	notify_stage(c, platform.Ev_Notify{tag = tag, event = .Activated})
}

@(private = "file")
notify_delegate_make :: proc(c: ^Cocoa) -> ^NS.Object {
	if c.notify_class == nil {
		super := intrinsics.objc_find_class("NSObject")
		if super == nil do return nil
		cls := ObjC.objc_allocateClassPair(super, "BaldrNotifyDelegate", size_of(rawptr))
		if cls == nil do return nil
		// sel_registerName, not the intrinsic: it needs a compile-time
		// literal, so it cannot be used from a helper (view.odin).
		ObjC.class_addMethod(cls, ObjC.sel_registerName("userNotificationCenter:willPresentNotification:withCompletionHandler:"),
			auto_cast d_will_present, "v@:@@@")
		ObjC.class_addMethod(cls, ObjC.sel_registerName("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"),
			auto_cast d_did_receive, "v@:@@@")
		ObjC.objc_registerClassPair(cls)
		c.notify_class = cls
	}
	obj := ObjC.class_createInstance(c.notify_class, size_of(rawptr))
	if obj == nil do return nil
	if slot := (^^Cocoa)(ObjC.object_getIndexedIvars(obj)); slot != nil do slot^ = c
	return cast(^NS.Object)obj
}

@(private = "file")
auth_descriptor := Block_Descriptor{size = u64(size_of(Auth_Block))}

@(private = "file")
auth_answered :: proc "c" (block: rawptr, granted: NS.BOOL, err: rawptr) {
	b := (^Auth_Block)(block)
	if b == nil || b.c == nil do return
	context = b.c.ctx
	sync.mutex_lock(&b.c.notify.mu)
	b.c.notify.refused = !bool(granted)
	b.c.notify.answered = true
	sync.mutex_unlock(&b.c.notify.mu)
	// Logged because, from inside the app, never answered and refused look
	// the same.
	if b.c.debug_files {
		fmt.eprintfln("baldr/cocoa: notifications were %s", "allowed" if bool(granted) else "refused")
	}
}

@(private)
notify_shutdown :: proc(c: ^Cocoa) {
	if center := notify_center(c.notify.objc); center != nil && c.notify.delegate != nil {
		m1(c.notify.objc, center, "setDelegate:", nil)
	}
	delete(c.notify.pending)
}

// notify_drain moves what the system's threads reported into the queue the
// pump hands back. Called from the pump, on the thread that owns it.
@(private)
notify_drain :: proc(c: ^Cocoa) {
	sync.mutex_lock(&c.notify.mu)
	defer sync.mutex_unlock(&c.notify.mu)
	for e in c.notify.pending do append(&c.queue, e)
	clear(&c.notify.pending)
}

@(private = "file")
notify_stage :: proc(c: ^Cocoa, e: platform.Ev_Notify) {
	sync.mutex_lock(&c.notify.mu)
	append(&c.notify.pending, e)
	sync.mutex_unlock(&c.notify.mu)
	if c.backend.wake != nil do c.backend.wake(&c.backend) // it may have arrived while the pump waits
}

// ------------------------------------------------------------- the calls

@(private = "file")
notify_center :: proc(o: Objc) -> Id {
	return m0(o, cls(o, "UNUserNotificationCenter"), "currentNotificationCenter")
}

// bundled says whether this process has a bundle identifier. Without one,
// asking for the notification centre raises, which aborts the process.
@(private = "file")
bundled :: proc "contextless" () -> bool {
	main := intrinsics.objc_send(^Bundle, Bundle, "mainBundle")
	if main == nil do return false
	return intrinsics.objc_send(^NS.String, main, "bundleIdentifier") != nil
}

@(private)
b_notify :: proc(b: ^platform.Backend, d: platform.Notify_Desc) -> bool {
	c := self(b)
	if !bundled() {
		notify_stage(c, platform.Ev_Notify{tag = d.tag, event = .Failed,
			error = "macOS shows notifications for a bundled app; this one has no bundle identifier"})
		return true
	}
	sync.mutex_lock(&c.notify.mu)
	refused, answered := c.notify.refused, c.notify.answered
	sync.mutex_unlock(&c.notify.mu)
	if refused {
		notify_stage(c, platform.Ev_Notify{tag = d.tag, event = .Failed,
			error = "notifications are turned off for this app in System Settings"})
		return true
	}
	// Not refused is not allowed: until the prompt is answered the system
	// holds what it is sent. Shown means only that the system took it
	// (platform.odin).
	if c.debug_files && !answered {
		fmt.eprintln("baldr/cocoa: notifications have not been allowed yet; the system is holding this one")
	}
	if !notify_framework(c) do return false
	o := c.notify.objc
	center := notify_center(o)
	if center == nil do return false

	content := m0(o, m0(o, cls(o, "UNMutableNotificationContent"), "alloc"), "init")
	if content == nil do return false
	defer m0(o, content, "release")
	title, body := ns_str(d.title), ns_str(d.body)
	defer if title != nil do title->release()
	defer if body != nil do body->release()
	if title != nil do m1(o, content, "setTitle:", rawptr(title))
	if body != nil do m1(o, content, "setBody:", rawptr(body))

	ident := notify_ident(d.tag)
	defer if ident != nil do ident->release()
	// The tag is the identifier, and the system replaces a request whose
	// identifier it already has, so a second notify on a tag replaces the
	// first.
	req := m3(o, cls(o, "UNNotificationRequest"), "requestWithIdentifier:content:trigger:",
		rawptr(ident), content, nil)
	if req == nil do return false
	m_add(o, center, req)
	notify_stage(c, platform.Ev_Notify{tag = d.tag, event = .Shown})
	return true
}

@(private)
b_notify_close :: proc(b: ^platform.Backend, tag: u64) {
	c := self(b)
	if !bundled() || !notify_framework(c) do return
	o := c.notify.objc
	center := notify_center(o)
	if center == nil do return
	ident := notify_ident(tag)
	if ident == nil do return
	defer ident->release()
	objs := [1]^NS.Object{(^NS.Object)(ident)}
	list := (^NS.Array)(NS.Array.alloc()->initWithObjects((^ObjC.id)(raw_data(objs[:])), 1))
	if list == nil do return
	defer list->release()
	m1(o, center, "removeDeliveredNotificationsWithIdentifiers:", rawptr(list))
	notify_stage(c, platform.Ev_Notify{tag = tag, event = .Closed, reason = .By_App})
}

// The tag as the notification's identifier, and back again.
@(private = "file")
notify_ident :: proc(tag: u64) -> ^NS.String {
	buf: [24]u8
	return ns_str(strconv.write_uint(buf[:], tag, 10))
}

@(private = "file")
notify_tag :: proc(o: Objc, s: Id) -> (u64, bool) {
	cs := m0_cstr(o, s, "UTF8String")
	if cs == nil do return 0, false
	return strconv.parse_u64_of_base(string(cs), 10)
}
