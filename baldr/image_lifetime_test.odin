package baldr

@(require) import "core:testing"

// When an app frees an Image in update, the previous tree still holds
// `rawptr(^Image)` on its image nodes until the next view build. These pin
// when that pointer is let go, and how an app frees one safely at once.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ilt_Msg :: union { int }

@(private = "file")
ilt_user_of :: proc(t: ^Tree, n: Node) -> rawptr {
	ck, ok := node_get(t, n).kind.(Custom_Kind)
	return ck.user if ok else nil
}

// A build that stops showing a picture lets go of it, but a `component`
// whose revision has not changed is not built at all, so its image node
// keeps pointing at whatever the app had, and paint dereferences it.
@(test)
a_skipped_component_keeps_pointing_at_its_image :: proc(t: ^testing.T) {
	img, _ := image_from_rgba(2, 2, []u8{1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16})
	defer image_destroy(&img)
	ui: Ui(Ilt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Ilt_Msg), img: ^Image, rev: u64, show: bool) -> Node {
		n := NODE_NONE
		set_viewport(&ui.tree, {200, 200})
		begin_view(ui)
		column(ui, padding = .none)
		if component(ui, "pic", rev) {
			defer end(ui)
			if show do n = image(ui, img, width = 20, height = 20, key = 1)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {200, 200})
		return n
	}

	n := build(&ui, &img, 1, true)
	testing.expect(t, n != NODE_NONE, "the picture was built")
	testing.expect_value(t, ilt_user_of(&ui.tree, n), rawptr(&img))

	// the app drops the picture from its own map and bumps nothing: the
	// component is skipped, so the node still points at the Image
	build(&ui, &img, 1, false)
	testing.expectf(t, ilt_user_of(&ui.tree, n) == rawptr(&img),
		"a skipped component still points at the Image — freeing it here is a dangling pointer")

	// image_forget is the way out: it lets every node showing it go, so the
	// app may free it at once whatever its components are doing
	image_forget(&ui, &img)
	testing.expect_value(t, ilt_user_of(&ui.tree, n), nil)
	testing.expect(t, ui.tree.pictures[n].released, "and the node draws the atlas's copy until it is rebuilt")
}

// A build that *does* stop showing the picture already lets go of it, which
// is the documented contract: free it once your view stops showing it.
@(test)
a_rebuilt_view_that_drops_a_picture_lets_go_of_it :: proc(t: ^testing.T) {
	img, _ := image_from_rgba(2, 2, []u8{1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16})
	defer image_destroy(&img)
	ui: Ui(Ilt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Ilt_Msg), img: ^Image, show: bool) -> Node {
		n := NODE_NONE
		set_viewport(&ui.tree, {200, 200})
		begin_view(ui)
		column(ui, padding = .none)
		if show do n = image(ui, img, width = 20, height = 20, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {200, 200})
		return n
	}

	n := build(&ui, &img, true)
	testing.expect_value(t, ilt_user_of(&ui.tree, n), rawptr(&img))
	build(&ui, &img, false)
	testing.expect(t, !node_valid(&ui.tree, n) || ilt_user_of(&ui.tree, n) == nil,
		"the node is gone, or holds nothing")
}

// Forgetting an Image nothing shows is harmless, and so is forgetting nil.
@(test)
forgetting_an_image_nothing_shows_is_harmless :: proc(t: ^testing.T) {
	img, _ := image_from_rgba(1, 1, []u8{1,2,3,4})
	defer image_destroy(&img)
	ui: Ui(Ilt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	image_forget(&ui, &img)
	image_forget(&ui, nil)
}

}
