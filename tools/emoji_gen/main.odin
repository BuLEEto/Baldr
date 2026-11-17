package main

// emoji_gen turns Unicode's emoji-test.txt into baldr/emoji_data.odin,
// keeping only what the bundled emoji font can actually draw.
//
//	odin run tools/emoji_gen -collection:baldr=. -- \
//	    /usr/share/unicode/emoji/emoji-test.txt assets/fonts/Twemoji-Mozilla.ttf \
//	    baldr/emoji_data.odin
//
// Pass `--stats` instead of an output path to print what the font covers
// without writing anything; the keep rule below follows those numbers.
//
// The data is emitted as one string blob, not an array of structs: a
// thousand-entry slice-of-struct literal costs the compiler minutes, while a
// single string literal costs it nothing and is parsed once, in about a
// millisecond, the first time a picker opens.

import "core:fmt"
import "core:os"
import "core:strings"
import runa "baldr:third_party/runa"

Entry :: struct {
	seq:     string, // the emoji itself, fully qualified
	name:    string, // CLDR short name, lower case: what search matches
	group:   int,    // index into GROUPS
	skin:    bool,   // it has skin-tone variants
}

// The nine groups emoji-test.txt uses, in its own order. "Component" is
// dropped: skin-tone swatches and hair components are not emoji anyone
// picks from a grid.
GROUPS := []string{
	"Smileys & Emotion",
	"People & Body",
	"Animals & Nature",
	"Food & Drink",
	"Travel & Places",
	"Activities",
	"Objects",
	"Symbols",
	"Flags",
}

group_index :: proc(name: string) -> (int, bool) {
	for g, i in GROUPS do if g == name do return i, true
	return 0, false
}

main :: proc() {
	args := os.args[1:]
	if len(args) < 3 {
		fmt.eprintln("usage: emoji_gen <emoji-test.txt> <font.ttf> <out.odin|--stats>")
		os.exit(2)
	}
	src, rerr := os.read_entire_file_from_path(args[0], context.allocator)
	if rerr != nil { fmt.eprintfln("read %s: %v", args[0], rerr); os.exit(1) }
	font_bytes, ferr := os.read_entire_file_from_path(args[1], context.allocator)
	if ferr != nil { fmt.eprintfln("read %s: %v", args[1], ferr); os.exit(1) }
	font, lerr := runa.font_load(font_bytes, context.allocator)
	if lerr != .None { fmt.eprintfln("font_load: %v", lerr); os.exit(1) }

	entries := make([dynamic]Entry)
	skins := make(map[string]bool) // base name -> has a skin-tone variant

	// counters, for --stats
	total, kept, no_glyph, multi, not_rgi := 0, 0, 0, 0, 0

	group := -1
	glyphs := make([dynamic]runa.Shaped_Glyph)
	text := string(src)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "# group:") {
			name := strings.trim_space(line[len("# group:"):])
			group, _ = group_index(name)
			if _, ok := group_index(name); !ok do group = -1
			continue
		}
		if len(line) == 0 || line[0] == '#' do continue
		semi := strings.index_byte(line, ';')
		hash := strings.index_byte(line, '#')
		if semi < 0 || hash < 0 || group < 0 do continue
		status := strings.trim_space(line[semi + 1:hash])
		if status != "fully-qualified" do continue
		total += 1

		// after the '#': "<emoji> E<version> <cldr short name>"
		rest := strings.trim_space(line[hash + 1:])
		sp := strings.index_byte(rest, ' ')
		if sp < 0 do continue
		seq := rest[:sp]
		rest = strings.trim_space(rest[sp:])
		sp = strings.index_byte(rest, ' ') // skip the E-version
		if sp < 0 do continue
		name := strings.to_lower(strings.trim_space(rest[sp:]))

		// Skin-tone variants are not entries of their own: they are a flag
		// on the base, which is how a picker shows them (one grid cell with
		// a long-press or a chosen tone).
		if strings.contains(name, " skin tone") {
			if i := strings.index(name, ":"); i > 0 {
				skins[strings.clone(strings.trim_space(name[:i]))] = true
			}
			continue
		}

		clear(&glyphs)
		runa.shape_text(&font, seq, 32, &glyphs)
		ok, why := renders(glyphs[:])
		switch why {
		case .None:      kept += 1
		case .No_Glyph:  no_glyph += 1
		case .Multi:     multi += 1
		case .Not_Rgi:   not_rgi += 1
		}
		if !ok do continue
		append(&entries, Entry{seq = strings.clone(seq), name = strings.clone(name), group = group})
	}

	for &e in entries do if skins[e.name] do e.skin = true

	if args[2] == "--stats" {
		fmt.printfln("emoji-test.txt: %d fully-qualified entries (skin-tone variants folded in)", total)
		fmt.printfln("  kept           %4d", kept)
		fmt.printfln("  no glyph       %4d  (the font has nothing for a codepoint in it)", no_glyph)
		fmt.printfln("  did not ligate %4d  (a sequence the font draws as its parts)", multi)
		fmt.printfln("  entries        %4d, of which %d have skin tones", len(entries), count_skins(entries[:]))
		per := make([]int, len(GROUPS))
		for e in entries do per[e.group] += 1
		for g, i in GROUPS do fmt.printfln("    %-20s %4d", g, per[i])
		return
	}

	write_odin(args[2], entries[:])
	fmt.printfln("%s: %d emoji, %d groups", args[2], len(entries), len(GROUPS))
}

count_skins :: proc(es: []Entry) -> (n: int) {
	for e in es do if e.skin do n += 1
	return
}

Why :: enum { None, No_Glyph, Multi, Not_Rgi }

// renders says whether the font draws this sequence as one emoji.
//
// **One glyph, none of them .notdef** is the rule: a font that lacks a ZWJ
// sequence or a flag shapes it
// into its parts instead (a man, a ZWJ, a rocket), which a picker must not
// offer as though it were one emoji. Zero-width glyphs are not counted —
// a variation selector shapes to a glyph of no width and is not a second
// emoji.
renders :: proc(gs: []runa.Shaped_Glyph) -> (bool, Why) {
	drawn := 0
	for g in gs {
		if g.glyph_id == 0 do return false, .No_Glyph
		if g.x_advance > 0 do drawn += 1
	}
	if drawn == 0 do return false, .No_Glyph
	if drawn > 1 do return false, .Multi
	return true, .None
}

// write_odin emits the blob. One line per emoji:
//
//	<seq>\t<group index>\t<0|1 skin>\t<name>
//
// Tab-separated because no CLDR name contains a tab, and newline-separated
// because no emoji does either.
write_odin :: proc(path: string, es: []Entry) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "package baldr")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "// Generated by tools/emoji_gen — do not edit.")
	fmt.sbprintln(&b, "//")
	fmt.sbprintln(&b, "//\todin run tools/emoji_gen -collection:baldr=. -- \\\\")
	fmt.sbprintln(&b, "//\t    /usr/share/unicode/emoji/emoji-test.txt \\\\")
	fmt.sbprintln(&b, "//\t    assets/fonts/Twemoji-Mozilla.ttf baldr/emoji_data.odin")
	fmt.sbprintln(&b, "//")
	fmt.sbprintln(&b, "// Unicode's emoji-test.txt, filtered to what the bundled Twemoji face")
	fmt.sbprintln(&b, "// actually draws as a single emoji — so the picker cannot offer a")
	fmt.sbprintln(&b, "// sequence that would come out as its parts.")
	fmt.sbprintln(&b, "//")
	fmt.sbprintln(&b, "// The data is Unicode's: © Unicode, Inc., under the Unicode License v3")
	fmt.sbprintln(&b, "// (third_party/unicode/LICENSE), which baldr.notices() passes on.")
	fmt.sbprintln(&b, "//")
	fmt.sbprintln(&b, "// It is **one string**, not an array of structs: a thousand-entry")
	fmt.sbprintln(&b, "// slice-of-struct literal is the shape that has cost this project")
	fmt.sbprintln(&b, "// minutes of compile time (CONTRIBUTING.md), and this costs the compiler")
	fmt.sbprintln(&b, "// nothing. emoji_table parses it once, on the first picker opened.")
	fmt.sbprintln(&b, "")
	fmt.sbprintf(&b, "// EMOJI_COUNT is how many there are, so the parsed table is static\n")
	fmt.sbprintf(&b, "// storage rather than an allocation nothing ever frees.\n")
	fmt.sbprintf(&b, "EMOJI_COUNT :: %d\n\n", len(es))
	fmt.sbprintf(&b, "// EMOJI_GROUP_COUNT is len(EMOJI_GROUPS) as a constant, for the same reason.\n")
	fmt.sbprintf(&b, "EMOJI_GROUP_COUNT :: %d\n\n", len(GROUPS))
	fmt.sbprintln(&b, "// EMOJI_GROUPS are the groups, in Unicode's own order.")
	fmt.sbprint(&b, "EMOJI_GROUPS := []string{")
	for g, i in GROUPS {
		if i > 0 do fmt.sbprint(&b, ", ")
		fmt.sbprintf(&b, "%q", g)
	}
	fmt.sbprintln(&b, "}")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "// EMOJI_DATA is one line per emoji: sequence, group index, 1 if it has")
	fmt.sbprintln(&b, "// skin-tone variants, CLDR short name — tab separated.")
	fmt.sbprintln(&b, "EMOJI_DATA :: `")
	for e in es {
		fmt.sbprintf(&b, "%s\t%d\t%d\t%s\n", e.seq, e.group, 1 if e.skin else 0, e.name)
	}
	fmt.sbprintln(&b, "`")
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); err != nil {
		fmt.eprintfln("write %s: %v", path, err)
		os.exit(1)
	}
}

