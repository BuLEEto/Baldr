#+build linux
package atspi

// org.a11y.atspi.Cache: the whole tree in one call.
//
// A reader connecting to an application asks for this first; without it, it
// walks the tree object by object, hundreds of calls for an ordinary window.
// The answer is one array with an entry per object: the object, its
// application, parent, children, interfaces, name, role, description and
// states — the facts Accessible serves one at a time.

import "baldr:dbus"

IFACE_CACHE :: "org.a11y.atspi.Cache"
CACHE_PATH  :: "/org/a11y/atspi/cache"

// CACHE_MAX bounds one reply. A window is tens or hundreds of objects
// (virtualised views build only what is on screen), and a reader that hits
// this ceiling walks the rest itself.
CACHE_MAX :: 4096

// cache answers the Cache interface. GetItems walks from the application
// down; the tree is whatever the provider says it is at this moment.
@(private)
cache :: proc(b: ^Bridge, call: ^dbus.Message) -> bool {
	switch call.member {
	case "GetItems":
		dbus.reply(b.conn, call, {dbus.Array{sig = CACHE_ITEM_SIG, items = cache_items(b)}})
	case:
		return false
	}
	return true
}

// cache_items is the tree as one array, walked from the application down,
// breadth first — so a reader that stops reading early still has the top of
// the tree, which is the part it needs first.
@(private)
cache_items :: proc(b: ^Bridge) -> []dbus.Value {
	items := make([dynamic]dbus.Value, context.temp_allocator)
	queue := make([dynamic]u64, context.temp_allocator)
	append(&queue, APP_ID)
	for i := 0; i < len(queue) && len(items) < CACHE_MAX; i += 1 {
		id := queue[i]
		n := node_of(b, id)
		if .Defunct in n.states do continue // gone since the walk began
		kids := make([dynamic]u64, context.temp_allocator)
		if b.provider.child != nil {
			for k in 0 ..< n.child_count {
				cid, have := b.provider.child(b.provider.user, id, k)
				if !have do break
				append(&kids, cid)
				if len(queue) < CACHE_MAX do append(&queue, cid)
			}
		}
		append(&items, cache_item(b, id, n, kids[:]))
	}
	return items[:]
}

// CACHE_ITEM_SIG is one cache entry: object, application, parent, children,
// interfaces, name, role, description, states.
CACHE_ITEM_SIG :: "((so)(so)(so)a(so)assusau)"

@(private)
cache_item :: proc(b: ^Bridge, id: u64, n: Node, kids: []u64) -> dbus.Value {
	children := make([]dbus.Value, len(kids), context.temp_allocator)
	for k, i in kids do children[i] = ref(b, k)
	fields := make([]dbus.Value, 9, context.temp_allocator)
	fields[0] = ref(b, id)
	fields[1] = ref(b, APP_ID)
	fields[2] = parent_ref(b, id, n)
	fields[3] = dbus.Array{sig = "(so)", items = children}
	fields[4] = interfaces_of(id, n)
	fields[5] = n.name
	fields[6] = u32(n.role)
	fields[7] = n.describe
	fields[8] = state_words(n.states)
	return dbus.Struct{fields = fields}
}
