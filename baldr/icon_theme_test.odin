package baldr

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// icon_test_tree writes a small world of themes under a fresh directory:
// Child inherits Parent, which inherits hicolor; Cached has a GTK
// icon-theme.cache; plus pixmaps and an extra directory. Returns the root;
// the caller removes it.
@(private = "file")
icon_test_tree :: proc(t: ^testing.T, tag: string) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	root := fmt.tprintf("%s/baldr-icons-%s-%d", tmp, tag, t.seed)
	_ = os.remove_all(root)
	files := [][2]string{
		{"icons/Child/index.theme", `[Icon Theme]
Name=Child
# a comment
Inherits=Parent
Directories=16x16/apps,scalable/apps

[16x16/apps]
Size=16
Type=Fixed

[scalable/apps]
Size=48
MinSize=8
MaxSize=512
Type=Scalable

[32x32/apps]
Size=32
Type=Fixed
`},
		{"icons/Child/16x16/apps/editor.png", ""},
		{"icons/Child/scalable/apps/viewer.svg", ""},
		{"icons/Child/32x32/apps/hidden.png", ""}, // not in Directories
		{"icons/Parent/index.theme", `[Icon Theme]
Name=Parent
Inherits=hicolor
Directories=22x22/apps,48x48/apps,symbolic/status
ScaledDirectories=22x22@2x/apps

[22x22/apps]
Size=22
Type=Fixed

[22x22@2x/apps]
Size=22
Scale=2
Type=Fixed

[48x48/apps]
Size=48
Threshold=4

[symbolic/status]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
`},
		{"icons/Parent/22x22/apps/editor.png", ""},
		{"icons/Parent/22x22/apps/mail-send.png", ""},
		{"icons/Parent/22x22/apps/clock.png", ""},
		{"icons/Parent/22x22@2x/apps/clock.png", ""},
		{"icons/Parent/22x22/apps/gauge.png", ""},
		{"icons/Parent/48x48/apps/gauge.png", ""},
		{"icons/Parent/22x22/apps/app.png", ""},
		{"icons/Parent/22x22/apps/network-wireless.png", ""},
		{"icons/Parent/symbolic/status/network-wireless-symbolic.svg", ""},
		{"icons/hicolor/index.theme", "[Icon Theme]\nName=Hicolor\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Threshold\n"},
		{"icons/hicolor/48x48/apps/only-hicolor.png", ""},
		{"icons/hicolor/48x48/apps/app-symbolic.svg", ""},
		{"icons/hicolor/48x48/apps/tray-symbolic.svg", ""},
		{"icons/Cached/index.theme", "[Icon Theme]\nName=Cached\nDirectories=16x16/apps,24x24/apps,32x32/apps\n\n[16x16/apps]\nSize=16\nType=Fixed\n\n[24x24/apps]\nSize=24\nType=Fixed\n\n[32x32/apps]\nSize=32\nType=Fixed\n"},
		{"icons/Cached/16x16/apps/cached-a.png", ""},
		{"icons/Cached/16x16/apps/cached-both.png", ""},
		{"icons/Cached/16x16/apps/uncached.png", ""}, // on disk, not in the cache
		{"icons/Cached/24x24/apps/cached-b.svg", ""},
		{"icons/Cached/24x24/apps/cached-both.svg", ""},
		{"icons/Cached/24x24/apps/ícone.svg", ""},
		{"icons/Cached/32x32/apps/thirty.png", ""}, // a directory the cache doesn't know
		{"pixmaps/legacy.xpm", ""},
		{"pixmaps/old.png", ""},
		{"extra/loose.png", ""},
		{"extra/hicolor/48x48/apps/extra-app.png", ""},
	}
	for f in files {
		path := fmt.tprintf("%s/%s", root, f[0])
		_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
		err := os.write_entire_file(path, transmute([]u8)f[1])
		testing.expectf(t, err == nil, "wrote %s: %v", path, err)
	}
	Entry :: struct { name: string, dir, flags: int }
	cache := icon_test_cache({"16x16/apps", "24x24/apps"}, {
		{"cached-a", 0, ICON_CACHE_PNG}, {"cached-b", 1, ICON_CACHE_SVG},
		{"cached-both", 0, ICON_CACHE_PNG}, {"cached-both", 1, ICON_CACHE_SVG},
		{"ícone", 1, ICON_CACHE_SVG},
	}, 3)
	err := os.write_entire_file(fmt.tprintf("%s/icons/Cached/icon-theme.cache", root), cache)
	testing.expectf(t, err == nil, "wrote the cache: %v", err)
	return root
}

// icon_test_cache builds a GTK icon-theme.cache: `dirs`, and per entry an
// icon name, its directory's index and its file flags, hashed into
// `buckets` chains.
@(private = "file")
icon_test_cache :: proc(dirs: []string, entries: []struct { name: string, dir, flags: int }, buckets: int) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	put16 :: proc(out: ^[dynamic]u8, v: int) { append(out, u8(v >> 8), u8(v)) }
	put32 :: proc(out: ^[dynamic]u8, v: int) { append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }
	patch :: proc(out: ^[dynamic]u8, at, v: int) { out[at], out[at + 1], out[at + 2], out[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v) }
	text :: proc(out: ^[dynamic]u8, s: string) {
		append(out, ..transmute([]u8)s)
		append(out, 0)
		for len(out) % 4 != 0 do append(out, 0)
	}
	put16(&out, 1)
	put16(&out, 0)
	put32(&out, 0) // the hash, patched
	put32(&out, 0) // the directory list, patched
	patch(&out, 8, len(out))
	put32(&out, len(dirs))
	slots := len(out)
	for _ in dirs do put32(&out, 0)
	for d, i in dirs {
		patch(&out, slots + i * 4, len(out))
		text(&out, d)
	}
	patch(&out, 4, len(out))
	put32(&out, buckets)
	bucket_slots := len(out)
	for _ in 0 ..< buckets do put32(&out, 0xffffffff)
	done := make(map[string]bool, context.temp_allocator)
	for e in entries {
		if e.name in done do continue
		done[e.name] = true
		icon := len(out)
		put32(&out, 0xffffffff)
		put32(&out, icon + 12)
		put32(&out, 0) // the image list, patched
		text(&out, e.name)
		patch(&out, icon + 8, len(out))
		n := 0
		for o in entries do if o.name == e.name do n += 1
		put32(&out, n)
		for o in entries {
			if o.name != e.name do continue
			put16(&out, o.dir)
			put16(&out, o.flags)
			put32(&out, 0)
		}
		h := u32(i32(i8(e.name[0])))
		for ch in transmute([]u8)e.name[1:] do h = (h << 5) - h + u32(i32(i8(ch)))
		slot := bucket_slots + int(h % u32(buckets)) * 4
		prev := int(out[slot]) << 24 | int(out[slot + 1]) << 16 | int(out[slot + 2]) << 8 | int(out[slot + 3])
		patch(&out, icon, prev) // chained in front of the bucket's first
		patch(&out, slot, icon)
	}
	return out[:]
}

@(private = "file")
icon_test_init :: proc(it: ^Icon_Themes, root: string, theme: string) {
	bases := [1]string{fmt.tprintf("%s/icons", root)}
	pixmaps := [1]string{fmt.tprintf("%s/pixmaps", root)}
	icon_themes_init(it, bases[:], pixmaps[:])
	icon_themes_use(it, theme)
}

@(private = "file")
icon_test_expect :: proc(t: ^testing.T, it: ^Icon_Themes, root, name: string, size, scale: int, want: string, extra := "", loc := #caller_location) {
	path, ok := icon_theme_lookup(it, name, size, scale, extra)
	if want == "" {
		testing.expectf(t, !ok, "%s at %d@%d: found %s, want nothing", name, size, scale, path, loc = loc)
		return
	}
	full := fmt.tprintf("%s/%s", root, want)
	testing.expectf(t, ok && path == full, "%s at %d@%d: %s, want %s", name, size, scale, path, full, loc = loc)
}

@(test)
icon_theme_lookup_follows_the_spec :: proc(t: ^testing.T) {
	root := icon_test_tree(t, "spec")
	defer os.remove_all(root)
	it: Icon_Themes
	icon_test_init(&it, root, "Child")
	defer icon_themes_destroy(&it)
	icon_test_expect(t, &it, root, "editor", 16, 1, "icons/Child/16x16/apps/editor.png")
	icon_test_expect(t, &it, root, "editor", 22, 1, "icons/Child/16x16/apps/editor.png") // the theme's closest beats a parent's exact
	icon_test_expect(t, &it, root, "viewer", 64, 1, "icons/Child/scalable/apps/viewer.svg")
	icon_test_expect(t, &it, root, "mail-send", 22, 1, "icons/Parent/22x22/apps/mail-send.png") // inherited
	icon_test_expect(t, &it, root, "clock", 22, 1, "icons/Parent/22x22/apps/clock.png")
	icon_test_expect(t, &it, root, "clock", 22, 2, "icons/Parent/22x22@2x/apps/clock.png") // the scale's own directory
	icon_test_expect(t, &it, root, "gauge", 50, 1, "icons/Parent/48x48/apps/gauge.png") // within the threshold
	icon_test_expect(t, &it, root, "gauge", 30, 1, "icons/Parent/22x22/apps/gauge.png") // nearer 22 than 44
	icon_test_expect(t, &it, root, "only-hicolor", 48, 1, "icons/hicolor/48x48/apps/only-hicolor.png")
	icon_test_expect(t, &it, root, "legacy", 48, 1, "pixmaps/legacy.xpm")
	icon_test_expect(t, &it, root, "old", 48, 1, "pixmaps/old.png")
	icon_test_expect(t, &it, root, "hidden", 32, 1, "") // not listed in Directories
	icon_test_expect(t, &it, root, "nothing-like-it", 16, 1, "")
}

@(test)
icon_theme_lookup_falls_back_by_name_and_kind :: proc(t: ^testing.T) {
	root := icon_test_tree(t, "fallback")
	defer os.remove_all(root)
	it: Icon_Themes
	icon_test_init(&it, root, "Child")
	defer icon_themes_destroy(&it)
	icon_test_expect(t, &it, root, "mail-send-receive", 22, 1, "icons/Parent/22x22/apps/mail-send.png") // more generic
	icon_test_expect(t, &it, root, "app-symbolic", 16, 1, "icons/hicolor/48x48/apps/app-symbolic.svg") // symbolic anywhere before full colour
	icon_test_expect(t, &it, root, "network-wireless-symbolic", 22, 1, "icons/Parent/symbolic/status/network-wireless-symbolic.svg")
	icon_test_expect(t, &it, root, "network-wireless", 22, 1, "icons/Parent/22x22/apps/network-wireless.png")
	icon_test_expect(t, &it, root, "tray", 16, 1, "icons/hicolor/48x48/apps/tray-symbolic.svg") // only a symbolic one exists
	icon_test_expect(t, &it, root, "loose", 22, 1, "extra/loose.png", extra = fmt.tprintf("%s/extra", root))
	icon_test_expect(t, &it, root, "extra-app", 48, 1, "extra/hicolor/48x48/apps/extra-app.png", extra = fmt.tprintf("%s/extra", root))
	icon_test_expect(t, &it, root, "loose", 22, 1, "") // not without the extra directory
	abs_path := fmt.tprintf("%s/pixmaps/old.png", root)
	path, ok := icon_theme_lookup(&it, abs_path, 48)
	testing.expect(t, ok && path == abs_path, "an absolute path is its own answer")
	_, missing := icon_theme_lookup(&it, "/no/such/icon.png", 48)
	testing.expect(t, !missing, "a missing absolute path is not found")
}

@(test)
icon_theme_lookup_reads_gtk_caches :: proc(t: ^testing.T) {
	root := icon_test_tree(t, "cache")
	defer os.remove_all(root)
	it: Icon_Themes
	icon_test_init(&it, root, "Cached")
	defer icon_themes_destroy(&it)
	icon_test_expect(t, &it, root, "cached-a", 16, 1, "icons/Cached/16x16/apps/cached-a.png")
	icon_test_expect(t, &it, root, "cached-b", 24, 1, "icons/Cached/24x24/apps/cached-b.svg")
	icon_test_expect(t, &it, root, "cached-both", 16, 1, "icons/Cached/16x16/apps/cached-both.png")
	icon_test_expect(t, &it, root, "cached-both", 24, 1, "icons/Cached/24x24/apps/cached-both.svg")
	icon_test_expect(t, &it, root, "ícone", 24, 1, "icons/Cached/24x24/apps/ícone.svg") // hashed over signed bytes
	icon_test_expect(t, &it, root, "uncached", 16, 1, "") // the cache answers, not the directory
	icon_test_expect(t, &it, root, "thirty", 32, 1, "")
	// a cache older than its theme is not trusted
	old := time.time_add(time.now(), -time.Hour)
	testing.expect(t, os.change_times(fmt.tprintf("%s/icons/Cached/icon-theme.cache", root), old, old) == nil, "aged the cache")
	stale: Icon_Themes
	icon_test_init(&stale, root, "Cached")
	defer icon_themes_destroy(&stale)
	icon_test_expect(t, &stale, root, "uncached", 16, 1, "icons/Cached/16x16/apps/uncached.png")
}

@(test)
icon_theme_lookup_notices_changes_and_theme_switches :: proc(t: ^testing.T) {
	root := icon_test_tree(t, "changes")
	defer os.remove_all(root)
	time.sleep(150 * time.Millisecond) // past the window in which a fresh directory counts as possibly changed
	it: Icon_Themes
	icon_test_init(&it, root, "Child")
	defer icon_themes_destroy(&it)
	icon_test_expect(t, &it, root, "fresh", 22, 1, "")
	testing.expect(t, !icon_themes_recheck(&it, force = true), "nothing changed yet")
	time.sleep(30 * time.Millisecond) // a later tick of the file system's clock
	err := os.write_entire_file(fmt.tprintf("%s/icons/Parent/22x22/apps/fresh.png", root), []u8{})
	testing.expect(t, err == nil, "added an icon")
	testing.expect(t, icon_themes_recheck(&it, force = true), "the new icon changed its directory")
	icon_test_expect(t, &it, root, "fresh", 22, 1, "icons/Parent/22x22/apps/fresh.png")
	icon_themes_use(&it, "Parent")
	icon_test_expect(t, &it, root, "editor", 16, 1, "icons/Parent/22x22/apps/editor.png")
	icon_themes_use(&it, "No-Such-Theme")
	icon_test_expect(t, &it, root, "only-hicolor", 48, 1, "icons/hicolor/48x48/apps/only-hicolor.png") // hicolor still answers
	icon_test_expect(t, &it, root, "editor", 16, 1, "")
}

} // when ODIN_TEST