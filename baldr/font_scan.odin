package baldr

// The fonts installed on this machine: an app shows a document
// in a family the reader chose, and offers a list of what there is.
//
// The families are found by walking the standard font directories and
// reading each file's `name` table, in Odin — no fontconfig, no fc-list.
// That gives concrete installed families, which is what a font picker and an
// editor need; it does not give fontconfig's aliases ("Sans"), its user
// overrides or its per-language substitution. Missing glyphs are the
// toolkit's own fallback stack's job (text.odin), not the family's.
//
// A scan reads only each file's table directory and its `name`, `post` and
// `OS/2` tables — a few hundred small reads, tens of milliseconds on a
// normal machine — and the result is kept on the Text_Engine until
// `fonts_forget` throws it away.

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

// Installed_Font is one family this machine has: the name to pass to
// `editor_options(font = …)`, and whether it is fixed-width (the code face
// an editor wants).
Installed_Font :: struct {
	family: string,
	fixed:  bool,
}

// Installed_Face is one face of an installed family, for a type tool's
// weight menu: its weight, the range a variable face can be set to (its
// own weight twice for a fixed one), and its slant.
Installed_Face :: struct {
	weight:   int,
	weights:  [2]int,
	italic:   bool,
	variable: bool,
}

// FONT_EXTS are the file kinds a scan reads.
@(private)
FONT_EXTS :: [?]string{".ttf", ".otf", ".ttc", ".TTF", ".OTF", ".TTC"}

// FONT_SCAN_MAX_DIRS bounds a walk, so a machine with a strange symlink
// loop under its font directories cannot hang an app.
@(private)
FONT_SCAN_MAX_DIRS :: 512

// Font_Face_File is one file that holds one face of a family.
@(private)
Font_Face_File :: struct {
	path:   string, // owned by the index
	weight: int,    // OS/2 usWeightClass (400 regular, 700 bold), 0 unknown
	italic: bool,
	fixed:  bool,
	variable: bool, // has a wght axis: one file covers the weights
	weights:  [2]int, // the weights it can be set to: its wght axis's range, or its own weight twice
	face:   int,    // which face of a collection (.ttc) it is; 0 for a file of one
	width:  int,    // OS/2 usWidthClass: 5 normal, below it condensed (0 unknown)
	ranges: [4]u32, // OS/2 ulUnicodeRange1–4: the Unicode blocks it says it covers (the fallback search reads these)
	glyphs: int,    // maxp numGlyphs. The fallback ranks on this rather than on family names: a CJK
	                // text face has thousands, a symbols or kana-only face a few hundred, on every OS.
}

// Font_Index is what a scan found: the files of each family, and the
// directories it walked with their modification times, which say whether a
// cached index is still true (font_cache.odin).
@(private)
Font_Index :: struct {
	families: map[string][dynamic]Font_Face_File,
	names:    [dynamic]string, // families in the order they are listed (sorted)
	roots:    [dynamic]Font_Dir, // the font directories looked in, in order (-1: not there)
	dirs:     [dynamic]Font_Dir, // every directory walked below them
	built:    bool,
	allocator: runtime.Allocator,
}

// Font_Dir is a directory a scan walked and when it last changed (Unix
// nanoseconds; -1 when it was not there).
@(private)
Font_Dir :: struct {
	path:  string,
	mtime: i64,
}

// installed_fonts lists the families this machine has, sorted by name, with
// `fixed` set for the fixed-width ones. The list belongs to the caller
// (`allocator`); the scan behind it is done once and kept, so asking again
// is cheap. `ok` is false when there is no text engine (a headless test),
// or while the list is still being read off the UI thread (the views are
// built again when it arrives) — "ask again later", where ok with an empty
// list means "there are none".
installed_fonts :: proc(t: ^Tree, allocator := context.allocator) -> (fonts: []Installed_Font, ok: bool) {
	te := t.text
	if te == nil do return {}, false
	idx := font_index(te)
	if !idx.built do return {}, false
	out := make([dynamic]Installed_Font, 0, len(idx.names), allocator)
	for name in idx.names {
		files := idx.families[name]
		fixed := len(files) > 0
		for f in files do if !f.fixed do fixed = false
		append(&out, Installed_Font{family = strings.clone(name, allocator), fixed = fixed})
	}
	return out[:], true
}

// font_faces lists the faces of an installed family (named as
// installed_fonts names it, case ignored): regular ones first, each by
// weight. Faces the text engine cannot draw (CID-keyed CFF) are left out.
// The slice is the caller's (`allocator`). `ok` is false when there is
// nothing to scan with or the list is still being read, as for
// installed_fonts; a family this machine does not have gives none.
font_faces :: proc(t: ^Tree, family: string, allocator := context.allocator) -> (faces: []Installed_Face, ok: bool) {
	te := t.text
	if te == nil do return {}, false
	idx := font_index(te)
	if !idx.built do return {}, false
	out := make([dynamic]Installed_Face, allocator)
	for name, files in idx.families do if strings.equal_fold(name, family) {
		next: for f in files {
			face := Installed_Face{weight = f.weight, weights = f.weights, italic = f.italic, variable = f.variable}
			for g in out do if g == face do continue next // the same face in two formats, or two folders
			append(&out, face)
		}
		break
	}
	slice.sort_by(out[:], proc(a, b: Installed_Face) -> bool {
		if a.italic != b.italic do return !a.italic
		if a.weight != b.weight do return a.weight < b.weight
		return !a.variable && b.variable
	})
	return out[:], true
}

// fonts_forget throws away what the last scan found, so the next ask walks
// the directories again: for an app that has just installed a font. In an
// app the new scan runs off the UI thread, the old list standing until it
// is done; headless, the next ask walks them there and then.
fonts_forget :: proc(t: ^Tree) {
	te := t.text
	if te == nil do return
	if te.font_scanner.wake != nil {
		font_scan_start(te, check = false)
		return
	}
	font_index_destroy(&te.font_index)
	fallback_forget(te) // what was looked for is looked for again, among what is there now
}

// fonts_ready says whether the list of installed fonts is there: false
// while it is still being read off the UI thread, when a family asked for
// may not have been found yet (editor_font says it is installed meanwhile)
// and text is drawn in the theme's face. Asking starts the reading.
fonts_ready :: proc(t: ^Tree) -> bool {
	return t.text != nil && font_index(t.text).built
}

// font_index is the fonts this machine has. Headless (no scanner started)
// the directories are walked now, once. In an app (fonts_start) the index
// kept on disk is read the first time (one file), and its directories are
// checked for changes on a worker, which walks them again if they changed
// or there was none; until then the index is not built and callers draw
// with the theme's fonts.
@(private)
font_index :: proc(te: ^Text_Engine) -> ^Font_Index {
	idx := &te.font_index
	if idx.built do return idx
	sc := &te.font_scanner
	if sc.wake == nil {
		font_index_build(idx, te.allocator, nil)
		return idx
	}
	if !sc.asked {
		sc.asked = true
		cached := font_cache_read(idx, sc.cache_path, te.allocator)
		font_scan_start(te, check = cached)
	}
	return idx
}

// font_index_build walks the font directories into `idx` (in
// `allocator`), recording each directory's modification time. `quit`,
// when set, stops it early (the index is then not built).
@(private)
font_index_build :: proc(idx: ^Font_Index, allocator: runtime.Allocator, quit: ^bool) {
	idx.allocator = allocator
	idx.families = make(map[string][dynamic]Font_Face_File, allocator)
	idx.names = make([dynamic]string, allocator)
	idx.roots = make([dynamic]Font_Dir, allocator)
	idx.dirs = make([dynamic]Font_Dir, allocator)
	dirs := font_dirs(context.temp_allocator)
	seen := 0
	for dir in dirs {
		append(&idx.roots, Font_Dir{strings.clone(dir, allocator), font_dir_mtime(dir)})
		font_scan_dir(idx, dir, &seen, quit)
	}
	if quit != nil && sync.atomic_load(quit) do return
	for name in idx.families do append(&idx.names, name)
	slice.sort(idx.names[:])
	idx.built = true
}

@(private)
font_index_destroy :: proc(idx: ^Font_Index) {
	if idx.allocator.procedure == nil do return
	for name, files in idx.families {
		for f in files do delete(f.path, idx.allocator)
		delete(files)
		delete(name, idx.allocator)
	}
	for d in idx.roots do delete(d.path, idx.allocator)
	for d in idx.dirs do delete(d.path, idx.allocator)
	delete(idx.families)
	delete(idx.names)
	delete(idx.roots)
	delete(idx.dirs)
	idx^ = {}
}

// font_dirs is where fonts live: the user's own first, then the system's,
// following XDG_DATA_HOME and XDG_DATA_DIRS as the icon theme does — and
// on Windows and macOS their own font folders, where the scripts a
// fallback needs are (Yu Gothic, Malgun Gothic, Hiragino, …).
@(private)
font_dirs :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	when ODIN_OS == .Windows {
		if local := os.get_env("LOCALAPPDATA", allocator); local != "" do append(&out, strings.concatenate({local, "\\Microsoft\\Windows\\Fonts"}, allocator))
		windir := os.get_env("WINDIR", allocator)
		if windir == "" do windir = "C:\\Windows"
		append(&out, strings.concatenate({windir, "\\Fonts"}, allocator))
		return out[:]
	}
	when ODIN_OS == .Darwin {
		if home := os.get_env("HOME", allocator); home != "" do append(&out, strings.concatenate({home, "/Library/Fonts"}, allocator))
		append(&out, "/Library/Fonts", "/System/Library/Fonts", "/System/Library/Fonts/Supplemental")
		return out[:]
	}
	home := os.get_env("HOME", allocator)
	data_home := os.get_env("XDG_DATA_HOME", allocator)
	if data_home == "" && home != "" do data_home = strings.concatenate({home, "/.local/share"}, allocator)
	if data_home != "" do append(&out, strings.concatenate({data_home, "/fonts"}, allocator))
	if home != "" do append(&out, strings.concatenate({home, "/.fonts"}, allocator)) // where people still drop them
	dirs := os.get_env("XDG_DATA_DIRS", allocator)
	if dirs == "" do dirs = "/usr/local/share:/usr/share"
	for dir in strings.split_iterator(&dirs, ":") {
		if dir == "" do continue
		append(&out, strings.concatenate({dir, "/fonts"}, allocator))
	}
	return out[:]
}

// font_scan_dir walks `dir` and its subdirectories, reading what each font
// file says it is.
@(private)
font_scan_dir :: proc(idx: ^Font_Index, dir: string, seen: ^int, quit: ^bool) {
	if seen^ >= FONT_SCAN_MAX_DIRS do return
	if quit != nil && sync.atomic_load(quit) do return
	seen^ += 1
	f, err := os.open(dir)
	if err != nil do return
	defer os.close(f)
	append(&idx.dirs, Font_Dir{strings.clone(dir, idx.allocator), font_dir_mtime(dir)})
	subs := make([dynamic]string, context.temp_allocator)
	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {
		path := strings.concatenate({dir, "/", fi.name}, context.temp_allocator)
		if fi.type == .Directory {
			append(&subs, path)
			continue
		}
		if !font_file_name(fi.name) do continue
		if quit != nil && sync.atomic_load(quit) do return
		font_scan_file(idx, path)
	}
	for sub in subs do font_scan_dir(idx, sub, seen, quit)
}

@(private)
font_file_name :: proc(name: string) -> bool {
	for ext in FONT_EXTS do if strings.has_suffix(name, ext) do return true
	return false
}

// font_scan_file reads one file's family and face and files it under that
// family. Only the table directory and the three tables that say what the
// file is are read, not the outlines, so a directory of 20 MB fonts costs
// tens of milliseconds. Anything it cannot read is skipped, never fatal.
@(private)
font_scan_file :: proc(idx: ^Font_Index, path: string) {
	fd, oerr := os.open(path)
	if oerr != nil do return
	defer os.close(fd)
	for i in 0 ..< font_face_count(fd) { // every face of a collection: Noto Sans CJK's languages are faces of one file
		face, ok := font_face_read(fd, i)
		if !ok || len(face.family) == 0 do continue
		files, has := &idx.families[face.family]
		if !has {
			name := strings.clone(face.family, idx.allocator)
			idx.families[name] = make([dynamic]Font_Face_File, idx.allocator)
			files = &idx.families[name]
		}
		f := face.file
		f.path = strings.clone(path, idx.allocator)
		f.face = i
		append(files, f)
	}
}
