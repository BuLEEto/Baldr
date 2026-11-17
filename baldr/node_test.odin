package baldr

@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
node_handles_are_generational :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)

	a := node_new(&tr, Box_Kind{})
	node_append(&tr, tr.root, a)
	testing.expect(t, node_valid(&tr, a))

	node_destroy(&tr, a)
	testing.expect(t, !node_valid(&tr, a), "destroyed handle must be stale")
	testing.expect(t, node_get(&tr, a) == nil)

	b := node_new(&tr, Box_Kind{})
	testing.expect(t, node_index(b) == node_index(a), "slot is reused")
	testing.expect(t, b != a, "…with a new generation")
	testing.expect(t, node_get(&tr, a) == nil, "old handle still stale after reuse")
}

@(private = "file")
children :: proc(tr: ^Tree, p: Node, allocator := context.temp_allocator) -> []Node {
	out := make([dynamic]Node, allocator)
	for c := node_first(tr, p); c != NODE_NONE; c = node_next(tr, c) do append(&out, c)
	return out[:]
}

@(test)
node_tree_ops_keep_sibling_order :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)

	a := node_new(&tr, Box_Kind{})
	b := node_new(&tr, Box_Kind{})
	c := node_new(&tr, Box_Kind{})
	node_append(&tr, tr.root, a)
	node_append(&tr, tr.root, c)
	node_insert_before(&tr, tr.root, b, c)
	got := children(&tr, tr.root)
	testing.expect(t, len(got) == 3 && got[0] == a && got[1] == b && got[2] == c, "a b c")

	node_insert_before(&tr, tr.root, c, a) // move c to the front
	got = children(&tr, tr.root)
	testing.expect(t, len(got) == 3 && got[0] == c && got[1] == a && got[2] == b, "c a b after move")

	node_destroy(&tr, a)
	got = children(&tr, tr.root)
	testing.expect(t, len(got) == 2 && got[0] == c && got[1] == b, "c b after destroy")
	testing.expect(t, node_child_count(&tr, tr.root) == 2)
}

@(test)
node_destroy_frees_subtree :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)

	p := node_new(&tr, Box_Kind{})
	k := node_new(&tr, Text_Kind{str = "kid", size = 16})
	node_append(&tr, tr.root, p)
	node_append(&tr, p, k)
	node_destroy(&tr, p)
	testing.expect(t, !node_valid(&tr, p) && !node_valid(&tr, k), "child freed with parent")
	testing.expect(t, len(tr.free) == 2, "both slots returned to the free list")
}

} // when ODIN_TEST