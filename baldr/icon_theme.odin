package baldr

// Freedesktop icon themes (the Icon Theme Specification): the file for an
// icon name at a size and scale. The theme asked for is searched, then what
// it inherits, then hicolor, then the pixmaps directories; a name found
// nowhere tries its more generic forms, a dash-part at a time. A symbolic
// name looks for symbolic icons through all of that before settling for a
// full-colour one (and a full-colour name for full colour first), so a bar
// asking for a recolourable icon gets one wherever it lives.
//
// A theme's icon-theme.cache (GTK's index of which directories hold which
// names) answers when it is at least as new as the theme, mapped rather
// than read; a theme without one has its directories listed once. At most
// every ICON_THEME_RECHECK_MS a lookup looks again at what it read and
// starts afresh when something changed (a new theme, an icon added, folders
// recoloured). One Icon_Themes belongs to one thread.

import "base:runtime"
import "core:encoding/ini"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
// @(require): every use sits inside a `when ODIN_OS == .Linux`, so on macOS
// and Windows the import is dead and `-vet` would reject it.
@(require) import "core:sys/linux"

ICON_THEME_RECHECK_MS :: 2000

// Icon_Themes is the lookup state: where themes live, which one is asked
// for, and the caches.
Icon_Themes :: struct {
	allocator: runtime.Allocator,
	bases:     []string, // where themes live, searched in order
	pixmaps:   []string, // unthemed icons
	theme:     string, // the theme asked for; "" searches hicolor alone
	arena:     virtual.Arena, // the caches below, dropped whole when something changed
	themes:    map[string]^Icon_Theme_Info, // by extra base and name; nil: no such theme
	listings:  map[string]^Icon_Listing, // by directory
	found:     map[string]string, // by name, size, scale and extra base; "" not found
	stamps:    map[string]Icon_Stamp, // every directory, index and cache read
	maps:      [dynamic][]u8, // mapped icon-theme.cache files
	checked:   time.Tick,
}

@(private)
Icon_Stamp :: struct {
	mtime, taken: time.Time, // the file's mtime, and when it was read
}

@(private)
Icon_Theme_Info :: struct {
	parents: []string,
	dirs:    []Icon_Dir,
	caches:  [][]u8, // per root: its icon-theme.cache, or nil to list directories
}

@(private)
Icon_Dir_Type :: enum u8 { Threshold, Fixed, Scalable }

@(private)
Icon_Dir :: struct {
	paths:                           []string, // the directory under each root (each base that has the theme)
	cached:                          []int, // per root with a cache: the directory's index in it, -1 when absent
	size, scale, min_size, max_size: int,
	threshold:                       int,
	type:                            Icon_Dir_Type,
}

@(private)
Icon_Ext :: enum u8 { Png, Svg, Xpm }

@(private)
Icon_Listing :: struct {
	names: map[string]bit_set[Icon_Ext; u8],
}

// icon_themes_init prepares a lookup over `bases` and `pixmaps`, or by
// default the XDG data directories' `icons` (with ~/.icons) and `pixmaps`.
// It searches hicolor until icon_themes_use names a theme.
icon_themes_init :: proc(it: ^Icon_Themes, bases: []string = nil, pixmaps: []string = nil, allocator := context.allocator) {
	it^ = {allocator = allocator}
	context.allocator = allocator
	it.maps = make([dynamic][]u8)
	if bases != nil && pixmaps != nil {
		it.bases = make([]string, len(bases))
		for b, i in bases do it.bases[i] = strings.clone(b)
		it.pixmaps = make([]string, len(pixmaps))
		for p, i in pixmaps do it.pixmaps[i] = strings.clone(p)
	} else {
		found_bases, found_pixmaps := make([dynamic]string), make([dynamic]string)
		home := os.get_env("HOME", context.temp_allocator)
		data_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if data_home == "" && home != "" do data_home = strings.concatenate({home, "/.local/share"}, context.temp_allocator)
		if data_home != "" do append(&found_bases, strings.concatenate({data_home, "/icons"}))
		if home != "" do append(&found_bases, strings.concatenate({home, "/.icons"}))
		dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
		if dirs == "" do dirs = "/usr/local/share:/usr/share"
		for dir in strings.split_iterator(&dirs, ":") {
			if dir == "" do continue
			append(&found_bases, strings.concatenate({dir, "/icons"}))
			append(&found_pixmaps, strings.concatenate({dir, "/pixmaps"}))
		}
		it.bases, it.pixmaps = found_bases[:], found_pixmaps[:]
	}
	icon_themes_reset(it)
}

icon_themes_destroy :: proc(it: ^Icon_Themes) {
	icon_themes_unmap(it)
	context.allocator = it.allocator
	for b in it.bases do delete(b)
	for p in it.pixmaps do delete(p)
	delete(it.bases)
	delete(it.pixmaps)
	delete(it.theme)
	delete(it.maps)
	virtual.arena_destroy(&it.arena)
	it^ = {}
}

// icon_themes_use makes `theme` the one searched first ("" for hicolor).
icon_themes_use :: proc(it: ^Icon_Themes, theme: string) {
	if theme == it.theme do return
	delete(it.theme, it.allocator)
	it.theme = strings.clone(theme, it.allocator)
	clear(&it.found)
}

// icon_theme_lookup is the file for icon `name` at `size` logical px and
// integer `scale`, or ok = false. `extra` is one more place a theme or
// loose icons may be (a tray item's IconThemePath). An absolute path is
// its own answer when the file exists. The path stays valid until a lookup
// notices a change.
icon_theme_lookup :: proc(it: ^Icon_Themes, name: string, size: int, scale := 1, extra := "") -> (path: string, ok: bool) {
	if name == "" || size <= 0 do return
	if strings.has_prefix(name, "/") do return name, os.is_file(name)
	icon_themes_recheck(it)
	buf: [32]u8
	key := strings.concatenate({name, "\x00", strconv.write_int(buf[:], i64(size * 64 + max(scale, 1)), 10), "\x00", extra}, context.temp_allocator)
	if p, seen := it.found[key]; seen do return p, p != ""
	context.allocator = virtual.arena_allocator(&it.arena)
	chain := make([dynamic]^Icon_Theme_Info, 0, 8)
	icon_theme_chain(it, it.theme if it.theme != "" else "hicolor", extra, &chain)
	icon_theme_chain(it, "hicolor", extra, &chain)
	variants := icon_name_variants(name)
	unthemed := make([dynamic]string, 0, len(it.pixmaps) + 1)
	if extra != "" do append(&unthemed, extra)
	append(&unthemed, ..it.pixmaps)
	result := ""
	search: for names in variants {
		for info in chain {
			for n in names {
				if result = icon_theme_find(it, info, n, size, max(scale, 1)); result != "" do break search
			}
		}
		for n in names {
			for dir in unthemed {
				if exts := icon_listing(it, dir).names[n]; exts != {} {
					result = strings.concatenate({dir, "/", n, icon_ext_name(exts)})
					break search
				}
			}
		}
	}
	it.found[strings.clone(key)] = result
	return result, result != ""
}

// icon_themes_recheck looks again at everything the caches read, at most
// every ICON_THEME_RECHECK_MS (always with `force`); when one changed (or
// had changed so shortly before it was read that a change in the same
// clock tick would not show) the caches start afresh and it returns true.
icon_themes_recheck :: proc(it: ^Icon_Themes, force := false) -> (changed: bool) {
	if !force && time.duration_milliseconds(time.tick_since(it.checked)) < ICON_THEME_RECHECK_MS do return false
	it.checked = time.tick_now()
	for path, stamp in it.stamps {
		if icon_mtime(path) != stamp.mtime || (stamp.mtime != {} && time.diff(stamp.mtime, stamp.taken) < 100 * time.Millisecond) {
			changed = true
			break
		}
	}
	if changed do icon_themes_reset(it)
	return
}

// icon_theme_default is the desktop's icon theme when no settings portal
// says: GTK 4's then GTK 3's settings.ini, then KDE's kdeglobals; "" when
// none do. The string is the caller's to free.
icon_theme_default :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config == "" && home != "" do config = strings.concatenate({home, "/.config"}, context.temp_allocator)
	if config == "" do return ""
	Source :: struct { file, section, key: string }
	sources := [?]Source{
		{"/gtk-4.0/settings.ini", "Settings", "gtk-icon-theme-name"},
		{"/gtk-3.0/settings.ini", "Settings", "gtk-icon-theme-name"},
		{"/kdeglobals", "Icons", "Theme"},
	}
	for src in sources {
		data, err := os.read_entire_file_from_path(strings.concatenate({config, src.file}, context.temp_allocator), context.temp_allocator)
		if err != nil do continue
		iter := ini.iterator_from_string(string(data), {comment = "#"})
		for key, value in ini.iterate(&iter) {
			if iter.section == src.section && key == src.key && value != "" do return strings.clone(strings.trim(value, "\"'"), allocator)
		}
	}
	return ""
}

@(private)
icon_themes_reset :: proc(it: ^Icon_Themes) {
	icon_themes_unmap(it)
	virtual.arena_destroy(&it.arena)
	it.arena = {}
	_ = virtual.arena_init_growing(&it.arena)
	a := virtual.arena_allocator(&it.arena)
	it.themes = make(map[string]^Icon_Theme_Info, a)
	it.listings = make(map[string]^Icon_Listing, a)
	it.found = make(map[string]string, a)
	it.stamps = make(map[string]Icon_Stamp, a)
	it.checked = time.tick_now()
	for dir in it.bases do icon_stamp(it, dir) // a theme installed later shows here
	for dir in it.pixmaps do icon_stamp(it, dir)
}

@(private)
icon_themes_unmap :: proc(it: ^Icon_Themes) {
	// The `when` wraps the loop, not its body: with it inside, `m` is unused
	// everywhere but Linux and `-vet` rejects that too.
	when ODIN_OS == .Linux {
		for m in it.maps do linux.munmap(raw_data(m), uint(len(m)))
	}
	clear(&it.maps)
}

@(private)
icon_stamp :: proc(it: ^Icon_Themes, path: string) {
	it.stamps[strings.clone(path, virtual.arena_allocator(&it.arena))] = {icon_mtime(path), time.now()}
}

// icon_theme_chain appends `name` and what it inherits, depth first, each once.
@(private)
icon_theme_chain :: proc(it: ^Icon_Themes, name, extra: string, chain: ^[dynamic]^Icon_Theme_Info) {
	info := icon_theme_info(it, name, extra)
	if info == nil do return
	for c in chain do if c == info do return
	append(chain, info)
	for parent in info.parents do icon_theme_chain(it, parent, extra, chain)
}

@(private)
icon_theme_info :: proc(it: ^Icon_Themes, name, extra: string) -> ^Icon_Theme_Info {
	key := strings.concatenate({extra, "\x00", name}, context.temp_allocator)
	if info, seen := it.themes[key]; seen do return info
	context.allocator = virtual.arena_allocator(&it.arena)
	roots := make([dynamic]string, 0, 2)
	index: string
	if extra != "" do append(&roots, strings.concatenate({extra, "/", name}))
	for base in it.bases do append(&roots, strings.concatenate({base, "/", name}))
	for i := 0; i < len(roots); {
		if !os.is_dir(roots[i]) {
			ordered_remove(&roots, i)
			continue
		}
		if index == "" {
			path := strings.concatenate({roots[i], "/index.theme"})
			if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
				index = string(data)
				icon_stamp(it, path)
			}
		}
		i += 1
	}
	info: ^Icon_Theme_Info
	if index != "" {
		info = new(Icon_Theme_Info)
		info^ = icon_theme_parse(index, roots[:])
		info.caches = make([][]u8, len(roots))
		for root, r in roots {
			cache := icon_cache_open(it, root)
			if cache == nil do continue
			info.caches[r] = cache
			known := icon_cache_dirs(cache)
			for &dir in info.dirs do dir.cached[r] = known[dir.paths[r][len(root) + 1:]] or_else -1
		}
	}
	it.themes[strings.clone(key)] = info
	return info
}

// icon_theme_parse reads an index.theme: Inherits, and the size data of
// each directory in Directories and ScaledDirectories.
@(private)
icon_theme_parse :: proc(src: string, roots: []string) -> (info: Icon_Theme_Info) {
	Keys :: struct {
		size, scale, min_size, max_size, threshold: int,
		has_min, has_max:                            bool,
		type:                                        Icon_Dir_Type,
	}
	sections := make(map[string]Keys)
	listed := make([dynamic]string)
	parents := make([dynamic]string)
	iter := ini.iterator_from_string(src, {comment = "#"})
	for key, value in ini.iterate(&iter) {
		if iter.section == "Icon Theme" {
			switch key {
			case "Inherits":
				rest := value
				for p in strings.split_iterator(&rest, ",") do if name := strings.trim_space(p); name != "" do append(&parents, name)
			case "Directories", "ScaledDirectories":
				rest := value
				for d in strings.split_iterator(&rest, ",") do if dir := strings.trim_space(d); dir != "" do append(&listed, dir)
			}
			continue
		}
		k, seen := sections[iter.section]
		if !seen do k = {scale = 1, threshold = 2}
		n, is_int := strconv.parse_int(value)
		switch key {
		case "Size":      if is_int do k.size = n
		case "Scale":     if is_int do k.scale = n
		case "MinSize":   if is_int { k.min_size = n; k.has_min = true }
		case "MaxSize":   if is_int { k.max_size = n; k.has_max = true }
		case "Threshold": if is_int do k.threshold = n
		case "Type":
			switch value {
			case "Fixed":     k.type = .Fixed
			case "Scalable":  k.type = .Scalable
			case "Threshold": k.type = .Threshold
			}
		}
		sections[iter.section] = k
	}
	dirs := make([dynamic]Icon_Dir, 0, len(listed))
	for path in listed {
		k, seen := sections[path]
		if !seen || k.size <= 0 do continue
		paths := make([]string, len(roots))
		for root, i in roots do paths[i] = strings.concatenate({root, "/", path})
		append(&dirs, Icon_Dir{
			paths = paths, cached = make([]int, len(roots)), size = k.size, scale = max(k.scale, 1),
			min_size = k.min_size if k.has_min else k.size, max_size = k.max_size if k.has_max else k.size,
			threshold = k.threshold, type = k.type,
		})
	}
	return {parents = parents[:], dirs = dirs[:]}
}

// icon_theme_find is the spec's LookupIcon: the first directory whose size
// matches, else the closest.
@(private)
icon_theme_find :: proc(it: ^Icon_Themes, info: ^Icon_Theme_Info, name: string, size, scale: int) -> string {
	Hit :: struct { at, count: int, looked: bool }
	hits := make([]Hit, len(info.caches), context.temp_allocator)
	best := ""
	best_distance := max(int)
	for &dir in info.dirs {
		for path, r in dir.paths {
			exts: bit_set[Icon_Ext; u8]
			if cache := info.caches[r]; cache != nil {
				if dir.cached[r] < 0 do continue
				if !hits[r].looked {
					at, count := icon_cache_images(cache, name)
					hits[r] = {at, count, true}
				}
				exts = icon_cache_exts(cache, hits[r].at, hits[r].count, dir.cached[r])
			} else {
				exts = icon_listing(it, path).names[name]
			}
			if exts == {} do continue
			if icon_dir_matches(dir, size, scale) do return strings.concatenate({path, "/", name, icon_ext_name(exts)})
			if distance := icon_dir_distance(dir, size, scale); distance < best_distance {
				best_distance = distance
				best = strings.concatenate({path, "/", name, icon_ext_name(exts)})
			}
		}
	}
	return best
}

@(private)
icon_dir_matches :: proc(d: Icon_Dir, size, scale: int) -> bool {
	if d.scale != scale do return false
	switch d.type {
	case .Fixed:     return d.size == size
	case .Scalable:  return d.min_size <= size && size <= d.max_size
	case .Threshold: return d.size - d.threshold <= size && size <= d.size + d.threshold
	}
	return false
}

@(private)
icon_dir_distance :: proc(d: Icon_Dir, size, scale: int) -> int {
	want := size * scale
	lo, hi := d.size, d.size
	switch d.type {
	case .Fixed:
	case .Scalable:  lo, hi = d.min_size, d.max_size
	case .Threshold: lo, hi = d.size - d.threshold, d.size + d.threshold
	}
	if want < lo * d.scale do return lo * d.scale - want
	if want > hi * d.scale do return want - hi * d.scale
	return 0
}

// icon_listing is which icon files a directory holds, read once.
@(private)
icon_listing :: proc(it: ^Icon_Themes, dir: string) -> ^Icon_Listing {
	if l, seen := it.listings[dir]; seen do return l
	context.allocator = virtual.arena_allocator(&it.arena)
	l := new(Icon_Listing)
	l.names = make(map[string]bit_set[Icon_Ext; u8])
	when ODIN_OS == .Linux { // names only: the portable iterator stats every entry
		if fd, errno := linux.open(strings.clone_to_cstring(dir, context.temp_allocator), {.DIRECTORY, .CLOEXEC}); errno == .NONE {
			buf: [16384]u8
			for {
				n, err := linux.getdents(fd, buf[:])
				if err != .NONE || n <= 0 do break
				offset := 0
				for entry in linux.dirent_iterate_buf(buf[:n], &offset) do icon_listing_add(l, linux.dirent_name(entry))
			}
			linux.close(fd)
		}
	} else {
		if f, err := os.open(dir); err == nil {
			entries := os.read_directory_iterator_create(f)
			for fi in os.read_directory_iterator(&entries) do icon_listing_add(l, fi.name)
			os.read_directory_iterator_destroy(&entries)
			os.close(f)
		}
	}
	it.listings[strings.clone(dir)] = l
	icon_stamp(it, dir)
	return l
}

@(private)
icon_listing_add :: proc(l: ^Icon_Listing, file: string) {
	ext: Icon_Ext
	switch {
	case strings.has_suffix(file, ".png"): ext = .Png
	case strings.has_suffix(file, ".svg"): ext = .Svg
	case strings.has_suffix(file, ".xpm"): ext = .Xpm
	case:                                  return
	}
	stem := file[:len(file) - 4]
	if exts, has := l.names[stem]; has {
		l.names[stem] = exts + {ext}
	} else {
		l.names[strings.clone(stem)] = {ext}
	}
}

// icon_ext_name picks the file the spec prefers: PNG, then SVG, then XPM.
@(private)
icon_ext_name :: proc(exts: bit_set[Icon_Ext; u8]) -> string {
	if .Png in exts do return ".png"
	if .Svg in exts do return ".svg"
	return ".xpm"
}

// icon_name_variants is the name and its more generic forms, then the same
// with -symbolic swapped: the symbolic kind asked for is looked for first.
@(private)
icon_name_variants :: proc(name: string) -> (lists: [2][]string) {
	symbolic := strings.has_suffix(name, "-symbolic")
	stem := name[:len(name) - len("-symbolic")] if symbolic else name
	same, other := make([dynamic]string), make([dynamic]string)
	for s := stem; s != ""; {
		with := strings.concatenate({s, "-symbolic"})
		append(&same, with if symbolic else s)
		append(&other, s if symbolic else with)
		dash := strings.last_index_byte(s, '-')
		if dash <= 0 do break
		s = s[:dash]
	}
	return {same[:], other[:]}
}

@(private)
icon_mtime :: proc(path: string) -> time.Time {
	fi, err := os.stat(path, context.temp_allocator)
	return fi.modification_time if err == nil else {}
}

// GTK's icon-theme.cache: big-endian; a header (version 1.0, the hash's
// offset, the directory list's offset), the directory names, and a hash of
// icon names whose entries list (directory index, PNG/XPM/SVG flags).

@(private)
ICON_CACHE_XPM :: 1
@(private)
ICON_CACHE_SVG :: 2
@(private)
ICON_CACHE_PNG :: 4

// icon_cache_open maps a theme root's cache when it is as new as the root
// (by the second, as GTK compares) and well formed; nil otherwise.
@(private)
icon_cache_open :: proc(it: ^Icon_Themes, root: string) -> []u8 {
	path := strings.concatenate({root, "/icon-theme.cache"}, context.temp_allocator)
	cache_time, root_time := icon_mtime(path), icon_mtime(root)
	if cache_time == {} || time.to_unix_seconds(cache_time) < time.to_unix_seconds(root_time) do return nil
	data: []u8
	when ODIN_OS == .Linux {
		fd, errno := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC})
		if errno != .NONE do return nil
		defer linux.close(fd)
		st: linux.Stat
		if linux.fstat(fd, &st) != .NONE || int(st.size) < 12 do return nil
		ptr, map_err := linux.mmap(0, uint(st.size), {.READ}, {.PRIVATE}, fd, 0)
		if map_err != .NONE do return nil
		data = ([^]u8)(ptr)[:int(st.size)]
		append(&it.maps, data)
	} else {
		read, err := os.read_entire_file_from_path(path, virtual.arena_allocator(&it.arena))
		if err != nil do return nil
		data = read
	}
	icon_stamp(it, path)
	icon_stamp(it, root)
	if icon_be16(data, 0) != 1 || icon_be32(data, 4) < 0 || icon_be32(data, 8) < 0 do return nil
	return data
}

// icon_cache_dirs maps each directory the cache knows to its index.
@(private)
icon_cache_dirs :: proc(c: []u8) -> map[string]int {
	known := make(map[string]int)
	list := icon_be32(c, 8)
	n := icon_be32(c, list)
	for i in 0 ..< clamp(n, 0, 65536) {
		if name := icon_cstring(c, icon_be32(c, list + 4 + i * 4)); name != "" do known[name] = i
	}
	return known
}

// icon_cache_images finds `name` in the cache's hash: its image list's
// first entry and how many there are.
@(private)
icon_cache_images :: proc(c: []u8, name: string) -> (at, count: int) {
	hash := icon_be32(c, 4)
	buckets := icon_be32(c, hash)
	if buckets <= 0 || name == "" do return
	h := u32(i32(i8(name[0]))) // GLib's hash, over signed chars
	for ch in transmute([]u8)name[1:] do h = (h << 5) - h + u32(i32(i8(ch)))
	icon := icon_be32(c, hash + 4 + int(h % u32(buckets)) * 4)
	for steps := 0; icon >= 0 && steps < 1 << 16; steps += 1 {
		if icon_cstring(c, icon_be32(c, icon + 4)) == name {
			list := icon_be32(c, icon + 8)
			return list + 4, clamp(icon_be32(c, list), 0, (len(c) - list) / 8)
		}
		icon = icon_be32(c, icon)
	}
	return
}

// icon_cache_exts is which files an image list says directory `dir` holds.
@(private)
icon_cache_exts :: proc(c: []u8, at, count, dir: int) -> (exts: bit_set[Icon_Ext; u8]) {
	for i in 0 ..< count {
		entry := at + i * 8
		if icon_be16(c, entry) != dir do continue
		flags := icon_be16(c, entry + 2)
		if flags & ICON_CACHE_PNG != 0 do exts += {.Png}
		if flags & ICON_CACHE_SVG != 0 do exts += {.Svg}
		if flags & ICON_CACHE_XPM != 0 do exts += {.Xpm}
		return
	}
	return
}

// icon_be16 and icon_be32 read big-endian values, -1 past the end (so a
// malformed or truncated cache ends a walk instead of reading beyond it).
@(private)
icon_be16 :: proc "contextless" (c: []u8, at: int) -> int {
	if at < 0 || at + 2 > len(c) do return -1
	return int(c[at]) << 8 | int(c[at + 1])
}

@(private)
icon_be32 :: proc "contextless" (c: []u8, at: int) -> int {
	if at < 0 || at + 4 > len(c) do return -1
	v := int(c[at]) << 24 | int(c[at + 1]) << 16 | int(c[at + 2]) << 8 | int(c[at + 3])
	return -1 if v == 0xffffffff else v // the end of a hash chain
}

@(private)
icon_cstring :: proc "contextless" (c: []u8, at: int) -> string {
	if at < 0 || at >= len(c) do return ""
	for i in at ..< len(c) do if c[i] == 0 do return string(c[at:i])
	return ""
}
