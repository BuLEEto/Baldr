#+build linux
package dbus

@(require) import "core:testing"
@(require) import "core:mem"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Any process on the session bus can send us a message. A valid one, then
// thousands of corrupt copies of it (bytes flipped, lengths made huge, cut
// short) must each decode or be refused, never crash or run away.
@(test)
a_corrupt_message_is_refused_not_trusted :: proc(t: ^testing.T) {
	inner := make([]Value, 2, context.temp_allocator)
	inner[0], inner[1] = u32(7), "seven"
	entries := make([]Dict_Entry, 2, context.temp_allocator)
	entries[0] = {key = "a", value = variant(i32(-1), context.temp_allocator)}
	entries[1] = {key = "b", value = variant(Struct{fields = inner}, context.temp_allocator)}
	items := make([]Value, 3, context.temp_allocator)
	items[0], items[1], items[2] = "x", "yy", "zzz"
	body := make([]Value, 3, context.temp_allocator)
	body[0] = Dict{key_sig = "s", value_sig = "v", entries = entries}
	body[1] = Array{sig = "s", items = items}
	body[2] = Object_Path{"/org/example/thing"}
	m := method_call(":1.2", "/org/example", "org.example.Iface", "Call", body)
	m.serial = 9
	good, err := encode_message(&m, context.temp_allocator)
	if !testing.expect_value(t, err, Error.None) do return
	_, derr := decode_message(good, context.temp_allocator)
	testing.expect_value(t, derr, Error.None)

	r := u64(0x9E3779B97F4A7C15)
	next :: proc(r: ^u64, n: int) -> int {
		r^ ~= r^ << 13
		r^ ~= r^ >> 7
		r^ ~= r^ << 17
		return int(r^ % u64(max(n, 1)))
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	bad := make([]u8, len(good), context.temp_allocator)
	for round in 0 ..< 4000 {
		copy(bad, good)
		n := len(bad)
		switch round % 4 {
		case 0: // a few bytes anywhere
			for _ in 0 ..< 1 + next(&r, 4) do bad[next(&r, n)] = u8(next(&r, 256))
		case 1: // a length or count made huge
			at := next(&r, n - 4)
			bad[at], bad[at + 1], bad[at + 2], bad[at + 3] = 0xFF, 0xFF, 0xFF, u8(next(&r, 256))
		case 2: // cut short
			n = next(&r, n)
		case 3: // a signature byte turned into a container opener
			openers := "(a{v"
			bad[next(&r, n)] = openers[next(&r, 4)]
		}
		_, _ = decode_message(bad[:n], mem.dynamic_arena_allocator(&arena))
		mem.dynamic_arena_free_all(&arena)
	}
}

}
