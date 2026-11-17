package baldr

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The font index, kept on disk and built off the UI thread.


@(private = "file")
scratch_dir :: proc(t: ^testing.T, name: string) -> string {
	base, err := os.temp_directory(context.temp_allocator)
	if err != nil do testing.fail_now(t, "no temp directory")
	dir := fmt.tprintf("%s/baldr-%s-%d", base, name, time.to_unix_nanoseconds(time.now()))
	os.make_directory_all(dir)
	return dir
}

// What is written is what is read: families and faces with their weights,
// coverage and flags, names and paths with tabs and backslashes in them,
// and the directories with their times.
@(test)
the_font_cache_reads_back_what_was_written :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "fontcache")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/fonts.idx", dir)
	idx: Font_Index
	idx.allocator = context.allocator
	idx.families = make(map[string][dynamic]Font_Face_File)
	idx.names = make([dynamic]string)
	idx.roots = make([dynamic]Font_Dir)
	idx.dirs = make([dynamic]Font_Dir)
	odd := "Odd\tName \\ Sans"
	idx.families[clone_string(odd)] = make([dynamic]Font_Face_File)
	append(&idx.families[odd], Font_Face_File{path = clone_string("/fonts/odd\\one.ttc"), face = 2, weight = 350, weights = {100, 900}, variable = true, italic = true, width = 3, ranges = {1, 2, 0xFFFFFFFF, 4}, glyphs = 20339})
	append(&idx.names, odd)
	append(&idx.roots, Font_Dir{clone_string("/fonts"), 1234567890123}, Font_Dir{clone_string("/missing"), -1})
	append(&idx.dirs, Font_Dir{clone_string("/fonts/sub"), 42})
	idx.built = true
	defer font_index_destroy(&idx)
	font_cache_write(&idx, path)

	back: Font_Index
	testing.expect(t, font_cache_read(&back, path, context.allocator), "read")
	defer font_index_destroy(&back)
	files, has := back.families[odd]
	testing.expect(t, has && len(files) == 1 && len(back.names) == 1, "the family, by its odd name")
	if has && len(files) == 1 {
		f := files[0]
		testing.expect(t, f.path == "/fonts/odd\\one.ttc" && f.face == 2 && f.weight == 350 && f.weights == {100, 900}, "path, face, weights")
		testing.expect(t, f.variable && f.italic && !f.fixed && f.width == 3 && f.glyphs == 20339 && f.ranges == {1, 2, 0xFFFFFFFF, 4}, "flags, glyph count and coverage")
	}
	testing.expect(t, len(back.roots) == 2 && back.roots[0].mtime == 1234567890123 && back.roots[1].mtime == -1 && back.roots[1].path == "/missing", "roots")
	testing.expect(t, len(back.dirs) == 1 && back.dirs[0].path == "/fonts/sub" && back.dirs[0].mtime == 42, "dirs")

	_ = os.write_entire_file_from_bytes(path, transmute([]u8)string("baldr-fonts\t999\n"))
	other: Font_Index
	testing.expect(t, !font_cache_read(&other, path, context.allocator), "another version is not read")
}

// A directory the index was built from that has changed since (a font
// added) makes it stale; one untouched keeps it true.
@(test)
a_changed_font_directory_makes_the_cache_stale :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "fontdirs")
	defer os.remove_all(dir)
	idx: Font_Index
	idx.allocator = context.allocator
	idx.roots = make([dynamic]Font_Dir)
	idx.dirs = make([dynamic]Font_Dir)
	for d in font_dirs(context.temp_allocator) do append(&idx.roots, Font_Dir{clone_string(d), font_dir_mtime(d)})
	append(&idx.dirs, Font_Dir{clone_string(dir), font_dir_mtime(dir)})
	defer font_index_destroy(&idx)
	testing.expect(t, font_dirs_unchanged(&idx), "untouched")
	time.sleep(20 * time.Millisecond) // a coarse clock must see the change
	_ = os.write_entire_file_from_bytes(fmt.tprintf("%s/new.ttf", dir), {0})
	testing.expect(t, !font_dirs_unchanged(&idx), "a file added")
}

// In an app the list comes off the UI thread: a family asked for before it
// arrives is pending (not reported missing), and found with an id of its
// own when it does; the next start reads the cache the first walk wrote, at
// once.
@(test)
the_font_list_arrives_from_a_worker_and_then_from_the_cache :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "fontlist")
	defer os.remove_all(dir)
	start :: proc(te: ^Text_Engine, dir: string) {
		fonts_start(te, proc(user: rawptr) {}, nil)
		delete(te.font_scanner.cache_path, te.allocator)
		te.font_scanner.cache_path = clone_string(fmt.tprintf("%s/fonts.idx", dir), te.allocator)
	}
	wait :: proc(te: ^Text_Engine) -> bool {
		for _ in 0 ..< 3000 {
			if fonts_take(te) do return true
			time.sleep(10 * time.Millisecond)
		}
		return false
	}
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	start(&te, dir)
	testing.expect(t, !font_index(&te).built, "not there yet: nothing waited for")
	testing.expect(t, wait(&te), "it arrives")
	testing.expect(t, te.font_index.built, "built")
	family := ""
	for name in te.font_index.names do if e := family_of(&te, text_family(&te, name)); e != nil && e.ok { // one this machine can draw
		family = name
		break
	}
	if family == "" do return // a machine without usable fonts: nothing more to see

	fresh: Text_Engine // a second start: the cache the first one wrote
	if !text_engine_init(&fresh) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&fresh)
	start(&fresh, dir)
	testing.expect(t, font_index(&fresh).built, "read from the cache at once")
	_, has := fresh.font_index.families[family]
	testing.expect(t, has, "with the same families")

	late: Text_Engine // a family asked for before the list is there
	if !text_engine_init(&late) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&late)
	start(&late, fmt.tprintf("%s/none", dir)) // no cache here: a walk
	id := text_family(&late, family)
	testing.expect(t, text_family_ok(&late, id) && text_family_name(&late, id) == family, "pending: not called missing")
	testing.expect(t, wait(&late), "the list arrives")
	now := text_family(&late, family)
	testing.expect(t, now != id && text_family_ok(&late, now) && family_of(&late, now).ok, "found, with an id of its own")
}

} // when ODIN_TEST