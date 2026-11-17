#+build linux
package atspi

// A reader asks for the whole tree at the door. What it gets back has to be
// the same tree the Accessible interface serves one object at a time —
// every object once, with its parent, its children and its states.

@(require) import "core:testing"
@(require) import "baldr:dbus"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Cache_Fake :: struct {
	names:  []string,
	kids:   [][]u64, // by id: 0 is the application, then one per object
}

@(private = "file")
cache_fake_node :: proc(user: rawptr, id: u64) -> (Node, bool) {
	f := (^Cache_Fake)(user)
	i := 0 if id == APP_ID else int(id)
	if i >= len(f.names) do return {}, false
	parent := u64(0)
	index := -1
	for kids, p in f.kids {
		for k, at in kids do if k == id {
			parent = APP_ID if p == 0 else u64(p)
			index = at
		}
	}
	return Node{
		id = id, parent = parent, index = index, role = .Application if id == APP_ID else .Button,
		name = f.names[i], child_count = len(f.kids[i]), states = {.Enabled, .Sensitive, .Showing},
	}, true
}

@(private = "file")
cache_fake_child :: proc(user: rawptr, id: u64, index: int) -> (u64, bool) {
	f := (^Cache_Fake)(user)
	i := 0 if id == APP_ID else int(id)
	if i >= len(f.kids) || index < 0 || index >= len(f.kids[i]) do return 0, false
	return f.kids[i][index], true
}

@(test)
atspi_cache_hands_over_the_whole_tree :: proc(t: ^testing.T) {
	// the application, a window, and two buttons in it
	fake := Cache_Fake{
		names = {"Test App", "Notes", "Save", "Close"},
		kids  = {{1}, {2, 3}, {}, {}},
	}
	b := Bridge{provider = Provider{user = &fake, node = cache_fake_node, child = cache_fake_child}}
	items := cache_items(&b)
	testing.expect_value(t, len(items), 4) // every object once, application included

	names := make([dynamic]string, context.temp_allocator)
	for it in items {
		s, is_struct := it.(dbus.Struct)
		testing.expect(t, is_struct && len(s.fields) == 9, "nine fields, as the signature says")
		if !is_struct do continue
		name, _ := s.fields[5].(string)
		append(&names, name)
	}
	testing.expect_value(t, names[0], "Test App") // breadth first: the top of the tree first
	testing.expect_value(t, names[1], "Notes")
	testing.expect_value(t, names[2], "Save")
	testing.expect_value(t, names[3], "Close")

	// the window's entry: its children are listed, its parent is the app
	win, _ := items[1].(dbus.Struct)
	kids, is_array := win.fields[3].(dbus.Array)
	testing.expect(t, is_array && len(kids.items) == 2, "the window lists both buttons")
	testing.expect_value(t, kids.sig, "(so)")
	role, _ := win.fields[6].(u32)
	testing.expect_value(t, role, u32(Role.Button))
	states, states_are_array := win.fields[8].(dbus.Array)
	testing.expect(t, states_are_array && len(states.items) == 2, "states are AT-SPI's two words")

	// a button has no children and says so
	save, _ := items[2].(dbus.Struct)
	save_kids, _ := save.fields[3].(dbus.Array)
	testing.expect_value(t, len(save_kids.items), 0)
	ifaces, has_ifaces := save.fields[4].(dbus.Array)
	testing.expect(t, has_ifaces && len(ifaces.items) >= 2, "Accessible and Component at least")
}

} // when ODIN_TEST
