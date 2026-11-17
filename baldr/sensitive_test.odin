package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Sensitive text and secret pictures, such as a private key revealed as text
// or as a QR code. A `sensitive` text is overwritten rather than just freed,
// and is never published as the node's accessible name, where anything on
// the session accessibility bus could read it; a secret picture's pixels are
// overwritten when it is destroyed.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sens_Msg :: union { int }

@(private = "file")
SECRET_KEY :: "sk-0000wearenotarealkeybutweareexactlythisshape0000"

@(private = "file")
sens_build :: proc(ui: ^Ui(Sens_Msg), s: string, sensitive: bool) -> Node {
	set_viewport(&ui.tree, {400, 200})
	begin_view(ui)
	column(ui, padding = .sm)
	n := text(ui, s, sensitive = sensitive, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	return n
}

// The accessibility bus must not be told the secret: a live reader on the
// session bus is a certain leak, not a page of heap that might be reused.
@(test)
a_sensitive_text_is_not_published_to_accessibility :: proc(t: ^testing.T) {
	ui: Ui(Sens_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	plain := sens_build(&ui, SECRET_KEY, false)
	testing.expect_value(t, node_get(&ui.tree, plain).access.name, SECRET_KEY) // an ordinary text is named by its words

	ui2: Ui(Sens_Msg)
	ui_init(&ui2)
	defer ui_destroy(&ui2)
	secret := sens_build(&ui2, SECRET_KEY, true)
	name := node_get(&ui2.tree, secret).access.name
	testing.expect(t, name != SECRET_KEY, "the key is not the node's name")
	testing.expect(t, !strings.contains(name, "sk-0000"), "nor any of it")
	testing.expectf(t, len(name) > 0, "but something is said, so a reader knows it is there: %q", name)

	// …and it is still drawn: the person asked to see it
	tk, ok := node_get(&ui2.tree, secret).kind.(Text_Kind)
	testing.expect(t, ok)
	testing.expect_value(t, tk.str, SECRET_KEY)
	testing.expect(t, tk.sensitive)
}

// Replacing it overwrites the old characters rather than handing them back
// to the allocator intact.
@(test)
replacing_a_sensitive_text_overwrites_the_old_one :: proc(t: ^testing.T) {
	ui: Ui(Sens_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := sens_build(&ui, SECRET_KEY, true)

	tk, _ := node_get(&ui.tree, n).kind.(Text_Kind)
	was := transmute([]u8)tk.str // the same memory, to read after the replace

	sens_build(&ui, "••••", true)

	zeroed := true
	for b in was do if b != 0 do zeroed = false
	testing.expect(t, zeroed, "the old key was overwritten before it was freed")
}

// An ordinary text is untouched: no scrub, and its words still reach a
// screen reader, which is the whole point of them.
@(test)
an_ordinary_text_is_unchanged :: proc(t: ^testing.T) {
	ui: Ui(Sens_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := sens_build(&ui, "Backup your key", false)
	testing.expect_value(t, node_get(&ui.tree, n).access.name, "Backup your key")
	tk, _ := node_get(&ui.tree, n).kind.(Text_Kind)
	testing.expect(t, !tk.sensitive)
}

// A secret picture's pixels are overwritten when it is destroyed.
@(test)
a_secret_image_is_overwritten_when_destroyed :: proc(t: ^testing.T) {
	px := make([]u8, 4 * 4 * 4, context.temp_allocator)
	for i in 0 ..< len(px) do px[i] = u8(i % 251 + 1) // nothing already zero

	img, ok := image_from_rgba(4, 4, px, secret = true)
	testing.expect(t, ok)
	seen := img.pixels // the same memory, to read after the destroy
	testing.expect(t, img.secret)
	image_destroy(&img)
	zeroed := true
	for b in seen do if b != 0 do zeroed = false
	testing.expect(t, zeroed, "a secret picture's pixels are overwritten before they are freed")

	// an ordinary picture is freed without the scrub, which is not free: a
	// chat full of avatars should not pay for it
	plain, _ := image_from_rgba(4, 4, px)
	testing.expect(t, !plain.secret)
	image_destroy(&plain)
	testing.expect(t, plain.pixels == nil)
}

// image_secret marks one made another way (image_load of a decrypted file).
@(test)
image_secret_marks_a_picture_made_another_way :: proc(t: ^testing.T) {
	px := make([]u8, 2 * 2 * 4, context.temp_allocator)
	for i in 0 ..< len(px) do px[i] = 0xAB
	img, _ := image_from_rgba(2, 2, px)
	image_secret(&img)
	seen := img.pixels
	image_destroy(&img)
	for b in seen do testing.expect_value(t, b, u8(0))
	image_secret(nil) // harmless
}

}
