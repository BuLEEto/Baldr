package baldr

// Showing text in a family this machine has: an editor set to "EB Garamond"
// draws its document in that family's regular, medium and bold faces and
// their italics, with the toolkit's own fonts behind it for anything the
// family lacks — emoji, CJK, symbols — so nothing falls out of the page.
//
// A family is found by the scan (font_scan.odin), loaded once per app, and
// named by a Family_Id that the text procs take. Id 0 means "whatever the
// theme's text is set in": a theme may name a family (`Theme.font_family`,
// `Theme.mono_family`) that every label, field, menu and tooltip follows,
// which family_now resolves; the embedded faces are what is left when the
// theme names nothing.

import "core:os"
import "core:strings"
import runa "baldr:third_party/runa"

// Family_Id names a loaded family; 0 is the theme's own fonts.
Family_Id :: distinct u16

// FAMILY_OF_ROLE + a Text_Role is the family the theme names for that step
// of its type scale (Text_Style.family): what `text` gives a node
// at a role whose step names one, resolved by family_now. Far above any id
// a family is loaded under.
@(private)
FAMILY_OF_ROLE :: Family_Id(0xFF00)

// Family_Face is the faces a family is drawn in: the weights the type
// scale asks for — regular, medium for labels, semibold for titles — and
// their italics. A family that has no cut for one of them is drawn in the
// nearest it has, and a variable family is set to the weight on its own
// axis (family_load).
Family_Face :: enum u8 { Regular, Medium, Bold, Italic, Medium_Italic, Bold_Italic }

// Font_Family is one loaded family: its faces, the stack each draws with
// (the face, then the toolkit's UI font and emoji), and the bytes they read.
@(private)
Font_Family :: struct {
	name:  string, // as the machine has it
	asked: string, // as the app asked for it
	pending: bool, // asked for before the font list was there: not known to be missing yet
	faces: [Family_Face]^runa.Font,
	stack: [Family_Face][3]^runa.Font,
	blobs: [dynamic][]u8,
	ok:    bool,
}

// text_family loads a family by name and returns the id to draw it with.
// The name is matched to what this machine has, ignoring case. Id 0 comes
// back for a family it does not have, and for an empty name: drawing then
// uses the theme's fonts. Loading happens once per family per app; asking
// again is a map lookup.
text_family :: proc(te: ^Text_Engine, family: string) -> Family_Id {
	if te == nil || !te.ok || len(family) == 0 do return 0
	key := strings.to_lower(family, context.temp_allocator)
	if id, has := te.family_ids[key]; has do return id
	entry := family_load(te, family)
	append(&te.families, entry)
	id := Family_Id(len(te.families))
	te.family_ids[strings.clone(key, te.allocator)] = id
	for f in entry.faces do if f != nil do face_id(te, f)
	return id
}

// text_family_bytes registers a family from font bytes the app carries and
// returns the id to draw it with. It is for the face a design asks for that
// a machine will not have — a wordmark, a brand face — where waiting for
// someone to install it is not an answer:
//
//	WORDMARK :: #load("fonts/AlegreyaSansSC-Bold.ttf")
//	s.brand = baldr.text_family_bytes(ui.tree.text, "acme wordmark", WORDMARK)
//	baldr.text(ui, "acme", family = s.brand, size = 20)
//
// `regular` is the one face that must be there; the others are drawn from
// it when not given, as for a family found on the machine. The bytes are
// copied, so `#load`ed data or a temporary buffer need not outlive the
// call. They must be SFNT
// (`.ttf`, `.otf` or a collection): a `.woff2` needs a Brotli decompressor,
// which the dependency rule forbids, so convert it when the app is built.
//
// `name` is what the family is remembered under: a second call with it
// returns the first id, and `text_family` finds it too. 0 when the engine
// is not ready, the name is empty, or the bytes are not a font the shaper
// can read; drawing then uses the theme's fonts.
text_family_bytes :: proc(te: ^Text_Engine, name: string, regular: []u8, bold: []u8 = nil, italic: []u8 = nil, bold_italic: []u8 = nil, medium: []u8 = nil, medium_italic: []u8 = nil) -> Family_Id {
	if te == nil || !te.ok || len(name) == 0 || len(regular) == 0 do return 0
	key := strings.to_lower(name, context.temp_allocator)
	had, known := te.family_ids[key]
	if known {
		if e := family_of(te, had); e != nil && e.ok do return had
		// Asked for by that name before it was registered (by a theme or
		// `text_family`), so remembered as missing. These bytes are that
		// family: it takes the id it already has, below.
	}

	out := Font_Family{
		name  = strings.clone(name, te.allocator),
		asked = strings.clone(name, te.allocator),
		blobs = make([dynamic][]u8, te.allocator),
	}
	// A variable file is set to each face's weight, as in family_load, and a
	// variable `regular` stands for the faces not given, each set to its own:
	// one variable file gives a real medium and bold.
	given := [Family_Face][]u8{.Regular = regular, .Medium = medium, .Bold = bold, .Italic = italic, .Medium_Italic = medium_italic, .Bold_Italic = bold_italic}
	regular_blob: []u8
	for face in Family_Face {
		if len(given[face]) == 0 do continue
		out.faces[face] = family_font_from_bytes(te, &out, given[face])
		if out.faces[face] == nil do continue
		if face == .Regular do regular_blob = out.blobs[len(out.blobs) - 1]
		_ = font_set_instance(out.faces[face], FAMILY_WANTS[face].weight, FAMILY_WANTS[face].italic)
	}
	if out.faces[.Regular] == nil { // not a font we can read: the theme's fonts draw instead
		family_destroy(te, &out)
		return 0
	}
	if font_is_variable(out.faces[.Regular]) {
		for face in Family_Face {
			if out.faces[face] != nil do continue
			loaded, ferr := runa.font_load(regular_blob, te.allocator) // another instance over the same bytes: runa keeps the axis values on the font
			if ferr != .None do continue
			f := new(runa.Font, te.allocator)
			f^ = loaded
			_ = font_set_instance(f, FAMILY_WANTS[face].weight, FAMILY_WANTS[face].italic)
			out.faces[face] = f
		}
	}
	for face in Family_Face {
		f := out.faces[face]
		if f == nil do f = out.faces[.Regular]
		out.stack[face] = {f, te.fonts[.UI], te.fonts[.Emoji]}
	}
	out.ok = true
	id: Family_Id
	if known {
		// In the place of the one that could not be found, so an id handed
		// out for that name draws these faces now; and the theme looks
		// again, so a step of its type scale that names it draws in it.
		e := family_of(te, had)
		family_destroy(te, e)
		e^ = out
		id = had
		_ = theme_families_look(te)
	} else {
		append(&te.families, out)
		id = Family_Id(len(te.families))
		te.family_ids[strings.clone(key, te.allocator)] = id
	}
	for f in out.faces do if f != nil do face_id(te, f)
	return id
}

// family_font_from_bytes copies `data` into the engine and loads the face
// in it. The copy is the point: an app's `#load`ed bytes are static and
// must not be freed with the family, and a buffer it read is its own.
@(private)
family_font_from_bytes :: proc(te: ^Text_Engine, fam: ^Font_Family, data: []u8) -> ^runa.Font {
	face, copied, ok := sfnt_face_extract(data, 0, te.allocator)
	if !ok do return nil
	if !copied { // extract handed back a slice of the caller's bytes: take our own
		own := make([]u8, len(face), te.allocator)
		copy(own, face)
		face = own
	}
	loaded, ferr := runa.font_load(face, te.allocator)
	if ferr != .None {
		delete(face, te.allocator)
		return nil
	}
	f := new(runa.Font, te.allocator)
	f^ = loaded
	append(&fam.blobs, face)
	return f
}

// text_family_ok says whether the family behind `id` was found and loaded;
// false means the theme's fonts are drawing instead.
text_family_ok :: proc(te: ^Text_Engine, id: Family_Id) -> bool {
	e := family_of(te, id)
	return e != nil && (e.ok || e.pending) // still being looked for: not known to be missing
}

// text_family_name is the family `id` draws in, as this machine has it (""
// for 0). It aliases the text engine's own storage, which lives as long as
// the tree does.
text_family_name :: proc(te: ^Text_Engine, id: Family_Id) -> string {
	e := family_of(te, id)
	if e == nil do return ""
	if e.ok do return e.name
	return e.asked if e.pending else ""
}

@(private)
family_of :: proc(te: ^Text_Engine, id: Family_Id) -> ^Font_Family {
	if te == nil || id == 0 do return nil
	i := int(id) - 1
	if i < 0 || i >= len(te.families) do return nil
	return &te.families[i]
}

// family_stack is what to shape with for a face of `id`, or nil when the
// family cannot draw it and the theme's fonts should.
@(private)
family_stack :: proc(te: ^Text_Engine, id: Family_Id, weight: Font_Weight, italic: bool) -> []^runa.Font {
	e := family_of(te, id)
	if e == nil || !e.ok do return nil
	face := Family_Face.Regular
	switch weight {
	case .Semibold: face = .Bold_Italic if italic else .Bold
	case .Medium:   face = .Medium_Italic if italic else .Medium
	case .Regular:  face = .Italic if italic else .Regular
	}
	if e.faces[face] == nil && italic do face = .Italic // nothing at that weight: its upright is further still
	if e.faces[face] == nil do face = .Regular
	if e.faces[face] == nil do return nil
	return e.stack[face][:]
}

// family_font is the face a family's metrics come from (its regular one).
@(private)
family_font :: proc(te: ^Text_Engine, id: Family_Id) -> ^runa.Font {
	e := family_of(te, id)
	if e == nil || !e.ok do return nil
	return e.faces[.Regular]
}

// family_load finds the files of `family` and loads its faces.
@(private)
family_load :: proc(te: ^Text_Engine, family: string) -> (out: Font_Family) {
	out.asked = strings.clone(family, te.allocator)
	idx := font_index(te)
	files: []Font_Face_File
	for name, list in idx.families {
		if strings.equal_fold(name, family) {
			out.name = strings.clone(name, te.allocator)
			files = list[:]
			break
		}
	}
	if len(files) == 0 {
		out.pending = !idx.built // the font list is still being read: not known to be missing
		return
	}
	out.blobs = make([dynamic][]u8, te.allocator)
	// A family with no cut for one of the weights FAMILY_WANTS names is
	// drawn in the nearest it has (family_pick), which the key below sees is
	// the same face twice and loads once.
	wants := FAMILY_WANTS
	blobs := make(map[Family_Blob_Key][]u8, context.temp_allocator)        // each file read once
	faces := make(map[Family_Face_Key]^runa.Font, context.temp_allocator) // …and loaded once per instance
	for face in Family_Face {
		want := wants[face]
		file, found := family_pick(files, want.weight, want.italic)
		if !found do continue
		key := Family_Face_Key{{file.path, file.face}, want.weight if file.variable else 0, want.italic if file.variable else false}
		if f, had := faces[key]; had {
			out.faces[face] = f // the same file set the same way: one face serving both weights
			continue
		}
		f := family_face_load(te, &out, &blobs, file, want.weight, want.italic)
		if f == nil do continue
		faces[key] = f
		out.faces[face] = f
	}
	if out.faces[.Regular] == nil { // nothing usable: the theme's fonts draw instead
		family_destroy(te, &out)
		out = {asked = strings.clone(family, te.allocator), pending = !idx.built}
		return
	}
	for face in Family_Face {
		f := out.faces[face]
		if f == nil do f = out.faces[.Regular]
		out.stack[face] = {f, te.fonts[.UI], te.fonts[.Emoji]}
	}
	out.ok = true
	return
}

// FAMILY_WANTS is the weight and slant each of a family's faces is: the
// weights the type scale asks for, and their italics. Medium is what a
// label is set in and semibold what a title is — drawn from a family's
// bold, 700, because the toolkit's own semibold is a cut a family seldom
// has, and its bold is what a document's bold text means.
@(private)
FAMILY_WANTS := [Family_Face]struct{ weight: int, italic: bool }{
	.Regular       = {400, false},
	.Medium        = {MEDIUM_WEIGHT, false},
	.Bold          = {700, false},
	.Italic        = {400, true},
	.Medium_Italic = {MEDIUM_WEIGHT, true},
	.Bold_Italic   = {700, true},
}

// family_pick is the file closest to the width, slant and weight wanted: an
// exact face first, then a variable file that can be set to it.
//
// A family's normal width comes first: name id 16 groups every cut of a
// family, so Condensed and SemiCondensed faces share the typographic family
// name. As in CSS, stretch is matched before weight, so a normal-width face
// wins even when a condensed cut is nearer the weight, and narrow cuts are
// used only when there is nothing else. An unset usWidthClass is normal.
@(private)
family_pick :: proc(files: []Font_Face_File, weight: int, italic: bool) -> (out: Font_Face_File, ok: bool) {
	best := min(int)
	for f in files {
		score := 0
		if f.italic == italic { score += 100 } else if !italic || !f.variable { continue } // no synthetic slant
		width := f.width if f.width > 0 else 5 // unsaid is normal
		score -= abs(width - 5) * 1000         // before weight, as CSS orders it
		score -= abs(f.weight - weight) / 10
		if f.variable do score += 5 // one file, set to the weight asked for
		if score > best {
			best, out, ok = score, f, true
		}
	}
	return
}

// Family_Blob_Key is one font file's bytes: a face of a collection is a
// file of its own, so which face belongs in the key.
@(private)
Family_Blob_Key :: struct {
	path: string,
	face: int,
}

// Family_Face_Key is one loaded face of a family: the file it came from
// and, for a variable file, the instance it was set to. Two of a family's
// faces that come to the same key are the same face — a static family's
// regular standing in for its medium — and are loaded once (family_load).
@(private)
Family_Face_Key :: struct {
	blob:  Family_Blob_Key,
	wght:  int,  // 0 for a static file: nothing is set on it
	slope: bool, // …and no axis is sloped
}

// family_face_load loads one face of a family, setting a variable font's
// axes to the weight and slant the face wants. A file's bytes are read
// once however many of the family's faces are set from them, which is what
// `blobs` remembers; the family owns them.
@(private)
family_face_load :: proc(te: ^Text_Engine, fam: ^Font_Family, blobs: ^map[Family_Blob_Key][]u8, file: Font_Face_File, weight: int, italic: bool) -> ^runa.Font {
	key := Family_Blob_Key{file.path, file.face}
	data, had := blobs[key]
	if !had {
		bytes, ok := font_file_bytes(te, file)
		if !ok do return nil
		data = bytes
		blobs[key] = bytes
		append(&fam.blobs, bytes)
	}
	loaded, ferr := runa.font_load(data, te.allocator)
	if ferr != .None do return nil // the bytes stay: the family owns them either way
	f := new(runa.Font, te.allocator)
	f^ = loaded
	if file.variable do _ = font_set_instance(f, weight, italic)
	return f
}

// font_set_instance sets a variable font to `weight` and, for an italic
// face, slants it (its `ital` axis, or `slnt` where it has that instead).
// A weight past the axis's range is set to its end, so a family whose
// boldest is 600 draws its bold at 600. False, and the font left as it is,
// when it has no weight axis — a static cut.
@(private)
font_set_instance :: proc(f: ^runa.Font, weight: int, italic: bool) -> bool {
	for a in runa.font_axes(f) {
		if a.tag != AXIS_WGHT do continue
		_ = runa.font_set_variation(f, AXIS_WGHT, clamp(f32(weight), a.min_value, a.max_value))
		if italic {
			ital := runa.Axis_Tag(u32('i') << 24 | u32('t') << 16 | u32('a') << 8 | u32('l'))
			slnt := runa.Axis_Tag(u32('s') << 24 | u32('l') << 16 | u32('n') << 8 | u32('t'))
			if runa.font_set_variation(f, ital, 1) != .None do _ = runa.font_set_variation(f, slnt, -10)
		}
		return true
	}
	return false
}

@(private)
AXIS_WGHT :: runa.Axis_Tag(u32('w') << 24 | u32('g') << 16 | u32('h') << 8 | u32('t'))

// font_is_variable says whether a font has a weight axis to set.
@(private)
font_is_variable :: proc(f: ^runa.Font) -> bool {
	for a in runa.font_axes(f) do if a.tag == AXIS_WGHT do return true
	return false
}

// font_file_bytes reads a font file and takes out the face it names — a
// face of a collection made a file of its own. The bytes are the engine's
// allocator's and must outlive every font loaded over them. Several fonts
// may read one set of bytes: runa keeps a variable instance's axis values
// on the font, not in the file, so one file can serve a family's regular,
// medium and bold at once.
@(private)
font_file_bytes :: proc(te: ^Text_Engine, file: Font_Face_File) -> (blob: []u8, ok: bool) {
	data, err := os.read_entire_file_from_path(file.path, te.allocator)
	if err != nil do return
	face, copied, fine := sfnt_face_extract(data, file.face, te.allocator)
	if copied do delete(data, te.allocator)
	if !fine {
		if !copied do delete(data, te.allocator)
		return
	}
	return face, true
}

// font_file_load reads a font file and loads the face it names — a face of
// a collection made a file of its own first. The bytes and the font are
// the engine's allocator's; the bytes must outlive the font. nil when it
// cannot be read or the shaper cannot make sense of it.
@(private)
font_file_load :: proc(te: ^Text_Engine, file: Font_Face_File) -> (blob: []u8, f: ^runa.Font) {
	face, ok := font_file_bytes(te, file)
	if !ok do return
	loaded, ferr := runa.font_load(face, te.allocator)
	if ferr != .None {
		delete(face, te.allocator)
		return
	}
	out := new(runa.Font, te.allocator)
	out^ = loaded
	return face, out
}

@(private)
family_destroy :: proc(te: ^Text_Engine, e: ^Font_Family) {
	seen: map[rawptr]bool
	defer delete(seen)
	for f in e.faces {
		if f == nil || seen[rawptr(f)] do continue
		seen[rawptr(f)] = true
		runa.font_destroy(f)
		free(f, te.allocator)
	}
	for b in e.blobs do delete(b, te.allocator)
	delete(e.blobs)
	if len(e.name) > 0 do delete(e.name, te.allocator)
	if len(e.asked) > 0 do delete(e.asked, te.allocator)
	e^ = {}
}

@(private)
families_destroy :: proc(te: ^Text_Engine) {
	for &e in te.families do family_destroy(te, &e)
	delete(te.families)
	for name in te.family_ids do delete(name, te.allocator)
	delete(te.family_ids)
	delete(te.face_ids)
	te.families = {}
	te.family_ids = {}
	te.face_ids = {}
}

// face_id numbers a face for the glyph cache: the embedded slots first, then
// every face a family loads.
@(private)
face_id :: proc(te: ^Text_Engine, f: ^runa.Font) -> u16 {
	if f == nil do return 0
	if id, has := te.face_ids[rawptr(f)]; has do return id
	id := u16(len(te.face_ids) + 1)
	te.face_ids[rawptr(f)] = id
	return id
}

// family_now is the family a draw really uses. One that named none —
// Family_Id 0, the theme's own text — follows the family the theme set
// (theme_families), which is 0 again when the theme named
// none or this machine has not got it: the embedded faces draw then. The
// paragraph cache is keyed on what this returns, so text laid out in one
// family is never drawn in another.
@(private)
family_now :: proc "contextless" (te: ^Text_Engine, id: Family_Id, mono := false) -> Family_Id {
	if te == nil do return id
	id := id
	if id >= FAMILY_OF_ROLE && id <= FAMILY_OF_ROLE + Family_Id(max(Text_Role)) {
		// a step of the type scale with a family of its own; one
		// that cannot draw is set as the rest of the theme's text is
		if f := te.role_family[Text_Role(id - FAMILY_OF_ROLE)]; f != 0 do return f
		id = 0
	}
	if id != 0 do return id
	return te.mono_family if mono else te.ui_family
}

// theme_families makes `ui` and `mono` the families the theme's own text is
// set in: every label, field, menu, tooltip and dialog the toolkit draws,
// and every app text that asked for no family of its own. "" is the
// embedded face (Inter, JetBrains Mono).
//
// A family this machine has not got draws as the embedded face, and is
// looked for again when the font list arrives (fonts_arrived). `roles` are
// the families the steps of its type scale name (Text_Style.family). The
// names are copied. Returns whether what is drawn changed.
@(private)
theme_families :: proc(te: ^Text_Engine, ui, mono: string, roles: [Text_Role]string = {}) -> (changed: bool) {
	if te == nil || !te.ok do return false
	if ui == te.ui_name && mono == te.mono_name && roles == te.role_names do return false // the usual case: the same theme installed again
	if ui != te.ui_name {
		delete(te.ui_name, te.allocator)
		te.ui_name = strings.clone(ui, te.allocator)
	}
	if mono != te.mono_name {
		delete(te.mono_name, te.allocator)
		te.mono_name = strings.clone(mono, te.allocator)
	}
	for name, r in roles {
		if name == te.role_names[r] do continue
		delete(te.role_names[r], te.allocator)
		te.role_names[r] = strings.clone(name, te.allocator)
	}
	return theme_families_look(te)
}

// theme_families_look resolves the names the theme gave to the ids they
// draw with, which is where a family that was pending becomes one that
// draws. Returns whether either changed.
@(private)
theme_families_look :: proc(te: ^Text_Engine) -> (changed: bool) {
	ui := family_drawing(te, text_family(te, te.ui_name))
	mono := family_drawing(te, text_family(te, te.mono_name))
	roles: [Text_Role]Family_Id
	for name, r in te.role_names do roles[r] = family_drawing(te, text_family(te, name))
	changed = ui != te.ui_family || mono != te.mono_family || roles != te.role_family
	te.ui_family, te.mono_family, te.role_family = ui, mono, roles
	return
}

// family_drawing is `id` when the family behind it draws, and 0 — the
// embedded faces — when it does not: not installed, or not loaded yet. The
// theme's families are kept as what actually draws, so nothing downstream
// has to ask twice.
@(private)
family_drawing :: proc(te: ^Text_Engine, id: Family_Id) -> Family_Id {
	e := family_of(te, id)
	return id if e != nil && e.ok else 0
}

// tree_fonts_follow takes the families this tree's theme names and lays its
// text out again when what is drawn changed. It runs wherever
// a theme is installed. The families are the engine's, one set per app, so
// every surface draws in the same face however many themes an app sets —
// the last one installed names it, and the others follow (tree_fonts_sync).
@(private)
tree_fonts_follow :: proc(t: ^Tree) {
	te := t.text
	if te == nil || !te.ok do return
	_ = theme_families(te, t.theme_asked.font_family, t.theme_asked.mono_family, type_families(t.theme_asked.type))
	_ = tree_fonts_sync(t)
}

// tree_fonts_sync lays this tree's text out again when the theme's
// families moved under it — another surface installed a theme naming
// another family, or the font list arrived and one of them is found now.
// True when it did. The run loop asks every surface each time round,
// because a tree that is not the one that set the theme has no other way
// to hear of it.
@(private)
tree_fonts_sync :: proc(t: ^Tree) -> bool {
	te := t.text
	if te == nil || !te.ok do return false
	if t.ui_family == te.ui_family && t.mono_family == te.mono_family && t.role_family == te.role_family do return false
	tree_fonts_changed(t) // which records the families it laid out with
	return true
}

// ui_font_family is the family this tree's text is set in, as this machine
// names it — "" when the embedded face is drawing, because the theme named
// no family or named one that is not installed. A settings screen shows
// what took effect with it. The string is the text engine's and lives as
// long as the tree.
ui_font_family :: proc(t: ^Tree) -> string {
	if t == nil || t.text == nil do return ""
	return text_family_name(t.text, t.text.ui_family)
}

// mono_font_family is the family this tree's code face is set in — editors,
// terminals, and text asked for with `mono`; see ui_font_family.
mono_font_family :: proc(t: ^Tree) -> string {
	if t == nil || t.text == nil do return ""
	return text_family_name(t.text, t.text.mono_family)
}
