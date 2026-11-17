package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Every Baldr binary carries Baldr's fonts whether the app draws with them
// or not, and two of the three licences ask that their notice travel with
// the font. Only the build knows what went into it, so the build says; a
// copy in an app's own tree goes stale the day a font changes.

@(test)
a_build_says_what_it_carries :: proc(t: ^testing.T) {
	ns := notices()
	testing.expect(t, len(ns) >= 3, "the fonts every binary embeds")

	for n in ns {
		testing.expect(t, len(n.name) > 0, "each is named")
		testing.expect(t, len(n.use) > 0, "…and says what it is for")
		testing.expect(t, len(n.licence) > 0, "…and under what")
		testing.expect(t, len(n.text) > 200, "…and carries the notice itself, not a summary")
	}
}

// The notice must be the real thing: what a licence asks to be passed on is
// its own words, not a line about them.
@(test)
the_notices_are_the_licences_themselves :: proc(t: ^testing.T) {
	ns := notices()
	found_ofl, found_ccby := false, false
	for n in ns {
		if strings.contains(n.text, "SIL OPEN FONT LICENSE") do found_ofl = true
		if strings.contains(n.text, "CC-BY-4.0") || strings.contains(n.text, "Creative Commons Attribution") do found_ccby = true
	}
	testing.expect(t, found_ofl, "the OFL in full")
	testing.expect(t, found_ccby, "and Twemoji's attribution")
}

// The file an app shows a person must be about this toolkit, not the one the
// font was borrowed from, naming none of another tree's asset paths or API.
@(test)
the_emoji_notice_is_about_this_toolkit :: proc(t: ^testing.T) {
	ns := notices()
	for n in ns {
		testing.expectf(t, !strings.contains(n.text, "font_use_default_emoji"),
			"%s's notice names an API that is not Baldr's", n.name)
	}
	twemoji := false
	for n in ns do if strings.contains(n.name, "Twemoji") {
		twemoji = true
		testing.expect(t, strings.contains(n.text, "Baldr"), "it says whose binary carries it")
		testing.expect(t, strings.contains(n.text, "baldr/assets/fonts"), "…and points at this tree, not the one it came from")
		testing.expect(t, strings.contains(n.text, "twemoji.twitter.com"), "and the attribution it asks for")
	}
	testing.expect(t, twemoji, "the emoji font is listed: #load embeds it either way")
}

// notices_text is the same thing as one block, for an app that would rather
// write a LICENCES file than lay them out.
@(test)
the_notices_can_be_had_as_one_block :: proc(t: ^testing.T) {
	all := notices_text(context.temp_allocator)
	testing.expect(t, len(all) > 1000, "every notice, run together")
	for n in notices() {
		testing.expectf(t, strings.contains(all, n.name), "%s is in it", n.name)
		testing.expectf(t, strings.contains(all, n.licence), "…under its licence", n.name)
	}
}


// Every binary also carries Lucide's icons, compiled in as path data under
// ISC, which asks for its notice in all copies, and tables built from
// Unicode's data files (runa's line breaking, bidi and scripts; the emoji
// picker's list), whose licence asks for its notice with copies or in their
// documentation.
@(test)
the_icons_and_the_unicode_tables_are_passed_on :: proc(t: ^testing.T) {
	lucide, unicode := false, false
	for n in notices() {
		if strings.contains(n.text, "ISC License") && strings.contains(n.text, "Lucide Icons") do lucide = true
		if strings.contains(n.text, "UNICODE LICENSE V3") && strings.contains(n.text, "Unicode, Inc.") do unicode = true
	}
	testing.expect(t, lucide, "Lucide's ISC notice, in its own words")
	testing.expect(t, unicode, "the Unicode License v3, in its own words")
}

// A Linux build carries bindings generated from the Wayland protocol
// definitions, and each definition carries its own notice. The collected
// notice must have every one of them: a protocol added to the backend and
// not to platform/wayland/wl/NOTICE.txt fails here, naming it.
@(test)
every_wayland_protocols_notice_is_passed_on :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		text := ""
		for n in notices() do if strings.contains(n.name, "Wayland") do text = n.text
		testing.expect(t, len(text) > 0, "a Linux build lists the Wayland protocol definitions")
		xmls := #load_directory("../platform/wayland/wl/xml")
		testing.expect(t, len(xmls) >= 20, "the definitions were found")
		for f in xmls {
			if !strings.has_suffix(f.name, ".xml") do continue
			testing.expectf(t, strings.contains(text, f.name), "%s is named in the notice", f.name)
			body := string(f.data)
			a := strings.index(body, "<copyright>")
			if a < 0 do continue
			first := strings.trim_space(body[a + len("<copyright>"):])
			if nl := strings.index_byte(first, '\n'); nl >= 0 do first = first[:nl]
			if amp := strings.index_any(first, "&<"); amp >= 0 do first = first[:amp] // an escaped address
			first = strings.trim_space(first)
			testing.expectf(t, strings.contains(text, first), "%s: its notice (%q) is carried", f.name, first)
		}
	}
}

}
