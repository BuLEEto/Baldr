package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
copy_files_offers_uris_gnome_form_and_plain_paths :: proc(t: ^testing.T) {
	items := clip_files_items([]string{"/tmp/a b.txt", "/tmp/c"})
	testing.expect_value(t, len(items), 4)
	testing.expect_value(t, items[0].mime, MIME_URI_LIST)
	testing.expect_value(t, string(items[0].data), "file:///tmp/a%20b.txt\r\nfile:///tmp/c\r\n")
	testing.expect_value(t, items[1].mime, MIME_GNOME_FILES)
	testing.expect_value(t, string(items[1].data), "copy\nfile:///tmp/a%20b.txt\nfile:///tmp/c")
	testing.expect_value(t, string(items[2].data), "/tmp/a b.txt\n/tmp/c")
	testing.expect_value(t, items[3].mime, MIME_TEXT)
}

@(test)
copy_files_cut_says_so_to_gnome_and_kde :: proc(t: ^testing.T) {
	items := clip_files_items([]string{"/tmp/c"}, cut = true)
	testing.expect_value(t, len(items), 5)
	testing.expect_value(t, string(items[1].data), "cut\nfile:///tmp/c")
	testing.expect_value(t, items[2].mime, MIME_KDE_CUT)
	testing.expect_value(t, string(items[2].data), "1")
}

@(test)
paste_outcome_reads_files_and_whether_they_were_cut :: proc(t: ^testing.T) {
	p := paste_outcome({text = "hello", uri_list = transmute([]u8)string("file:///etc/hosts\r\n")})
	testing.expect_value(t, p.text, "hello")
	testing.expect_value(t, len(p.files), 1)
	testing.expect_value(t, p.files[0], "/etc/hosts")
	testing.expect(t, !p.cut, "a copy by default")

	nautilus := paste_outcome({uri_list = transmute([]u8)string("file:///a\r\n"), gnome = transmute([]u8)string("cut\nfile:///a")})
	testing.expect(t, nautilus.cut, "Nautilus's cut")
	testing.expect_value(t, nautilus.files[0], "/a")

	only_gnome := paste_outcome({gnome = transmute([]u8)string("copy\nfile:///x%20y\nfile:///z")})
	testing.expect(t, !only_gnome.cut && len(only_gnome.files) == 2 && only_gnome.files[0] == "/x y", "the GNOME form alone still gives the paths")

	dolphin := paste_outcome({uri_list = transmute([]u8)string("file:///d\r\n"), kde_cut = transmute([]u8)string("1")})
	testing.expect(t, dolphin.cut, "Dolphin's cut")

	empty := paste_outcome({})
	testing.expect(t, len(empty.files) == 0 && !empty.cut && empty.text == "")
}

} // when ODIN_TEST