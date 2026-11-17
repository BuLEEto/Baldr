package baldr

// What a Baldr binary carries, and what its licences ask be passed on.
//
// Every Baldr app embeds Baldr's fonts, because `#load` puts the bytes in
// the binary whether or not the app draws with them: Inter and JetBrains
// Mono (SIL Open Font Licence 1.1) and Twemoji Mozilla (CC-BY 4.0). It also
// embeds Lucide's icons as path data (ISC), tables built from Unicode's
// data files (Unicode License v3), and on Linux the bindings generated from
// the Wayland protocol definitions, each with its own notice. An app
// shipped on an installer or a package must carry those notices with it.
//
// So the notices are embedded too, and `notices()` hands them over. It
// follows the `#config` choices: an app that swaps the UI face with
// `-define:BALDR_UI_FONT=…` gets a notice saying that face is its own to
// account for. Only the build knows what went into it, which is why this
// cannot live in the app. A theme's system family (`Theme.font_family`)
// changes what is drawn, not what is carried, so it changes nothing here.

import "core:strings"

// Notice is one thing this binary carries that its licence asks be passed
// on: what it is, what Baldr uses it for, the licence's name, and the full
// text to show. Every string is static — embedded in the binary — so it
// lives as long as the program and needs no freeing.
Notice :: struct {
	name:    string, // "Inter"
	use:     string, // "the UI typeface"
	licence: string, // "SIL Open Font Licence 1.1"
	text:    string, // the notice in full, as it must be passed on
}

// The notices Baldr's own assets and data carry, embedded beside what
// they describe so the two cannot drift apart.
@(rodata, private)
OFL_INTER := #load("../assets/fonts/InterVariable-OFL.txt", string)

@(rodata, private)
OFL_JETBRAINS := #load("../assets/fonts/JetBrainsMono-OFL.txt", string)

@(rodata, private)
CCBY_TWEMOJI := #load("../assets/fonts/Twemoji-Mozilla-CCBY.txt", string)

@(rodata, private)
ISC_LUCIDE := #load("../third_party/lucide/LICENSE", string)

@(rodata, private)
UNICODE_LICENCE := #load("../third_party/unicode/LICENSE", string)

// Only where the Wayland backend is built in: a Mac or Windows binary
// carries none of these bindings, so it carries none of their notices.
when ODIN_OS == .Linux {
	@(rodata, private)
	WAYLAND_NOTICES := #load("../platform/wayland/wl/NOTICE.txt", string)
}

// Whether each slot is still the font Baldr ships. An overridden face
// carries its own licence, which Baldr cannot name.
@(private) UI_IS_INTER :: BALDR_UI_FONT == "../assets/fonts/InterVariable.ttf" &&
                          BALDR_ITALIC_FONT == "../assets/fonts/InterVariable-Italic.ttf"
@(private) MONO_IS_JB  :: BALDR_MONO_FONT == "../assets/fonts/JetBrainsMono-Variable.ttf"

// SWAPPED_FONT is what is said about a face the app chose itself: Baldr
// cannot know its licence, and an app that swapped one knows it did.
@(private)
SWAPPED_FONT :: `This build was given a font of its own with -define:BALDR_UI_FONT
or -define:BALDR_MONO_FONT. Baldr embeds its bytes but knows nothing
about its licence: whoever chose it carries that notice.`

// notices is what this build embeds that asks to be passed on, in a stable
// order. An app shows them in its About or settings, alongside its own. A
// system family a theme sets (`Theme.font_family`) is not here: the binary
// does not carry it. The slice and its strings are static: nothing to free.
//
//	for n in baldr.notices() {
//		baldr.text(ui, n.name, role = .Title)
//		baldr.text(ui, n.use, muted = true)
//		baldr.text(ui, n.text, size = 12)
//	}
notices :: proc() -> []Notice {
	return NOTICES[:]
}

// notices_text is every notice run together as one block of plain text, for
// an app that would rather write a LICENCES file at build time or print
// them than lay them out. The caller owns it.
notices_text :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for n, i in NOTICES {
		if i > 0 do strings.write_string(&b, "\n\n")
		strings.write_string(&b, n.name)
		strings.write_string(&b, " — ")
		strings.write_string(&b, n.use)
		strings.write_string(&b, " — ")
		strings.write_string(&b, n.licence)
		strings.write_string(&b, "\n\n")
		strings.write_string(&b, n.text)
	}
	return strings.to_string(b)
}

// Not @(rodata): the texts come from `#load`, which is a value rather than
// a constant, so these are built once at start-up and never changed.
@(private)
NOTICE_INTER := Notice{
	name    = "Inter" when UI_IS_INTER else "the app's own UI font",
	use     = "the UI typeface and its italic: every label, every field, every reply — and behind any family a theme sets",
	licence = "SIL Open Font Licence 1.1" when UI_IS_INTER else "the app's to say",
	text    = OFL_INTER when UI_IS_INTER else SWAPPED_FONT,
}

@(private)
NOTICE_JETBRAINS := Notice{
	name    = "JetBrains Mono" when MONO_IS_JB else "the app's own monospace font",
	use     = "the code face: editors, terminals, and text asked for with mono — and behind any family a theme sets",
	licence = "SIL Open Font Licence 1.1" when MONO_IS_JB else "the app's to say",
	text    = OFL_JETBRAINS when MONO_IS_JB else SWAPPED_FONT,
}

@(private)
NOTICE_TWEMOJI := Notice{
	name    = "Twemoji (Mozilla build)",
	use     = "colour emoji, behind every family the toolkit draws with",
	licence = "CC-BY 4.0 (artwork); Apache 2.0 (the build tooling)",
	text    = CCBY_TWEMOJI,
}

@(private)
NOTICE_LUCIDE := Notice{
	name    = "Lucide",
	use     = "the icons: every icon a button, a menu, a field or a row draws, compiled in as path data",
	licence = "ISC (and MIT for the icons Lucide took from Feather)",
	text    = ISC_LUCIDE,
}

@(private)
NOTICE_UNICODE := Notice{
	name    = "Unicode data",
	use     = "the tables behind line breaking, word and grapheme boundaries, bidirectional text, scripts, normalisation and the emoji picker, built from Unicode's data files",
	licence = "Unicode License v3",
	text    = UNICODE_LICENCE,
}

// The Wayland notice only where the Wayland backend is built in.
when ODIN_OS == .Linux {
	@(private)
	NOTICE_WAYLAND := Notice{
		name    = "Wayland protocol definitions",
		use     = "the Wayland backend's bindings, generated from each protocol's definition",
		licence = "MIT, HPND and zlib, as each definition states",
		text    = WAYLAND_NOTICES,
	}

	@(private)
	NOTICES := [?]Notice{NOTICE_INTER, NOTICE_JETBRAINS, NOTICE_TWEMOJI, NOTICE_LUCIDE, NOTICE_UNICODE, NOTICE_WAYLAND}
} else {
	@(private)
	NOTICES := [?]Notice{NOTICE_INTER, NOTICE_JETBRAINS, NOTICE_TWEMOJI, NOTICE_LUCIDE, NOTICE_UNICODE}
}
