package cocoa

// The CLDR side of the shared date-pattern reader. Pure, so it runs
// anywhere `platform/cocoa`'s tests do.
//
// Windows and macOS write the same tokens and mean one of them
// differently: macOS gives "dd/MM/y" for en_GB, and read by the Windows
// rule that is a two-digit year.

@(require) import "core:testing"
@(require) import "baldr:platform"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
cldr_reads_a_lone_y_as_the_whole_year :: proc(t: ^testing.T) {
	Case :: struct { pattern, want, why: string }
	cases := []Case{
		{"dd/MM/y",   "%d/%m/%Y", "en_GB, which is what the box here answers"},
		{"M/d/y",     "%m/%e/%Y", "en_US"},
		{"dd.MM.y",   "%d.%m.%Y", "de_DE"},
		{"y/MM/dd",   "%Y/%m/%d", "ja_JP"},
		{"dd/MM/yy",  "%d/%m/%y", "exactly two y is the only two-digit year in CLDR"},
		{"dd/MM/yyyy","%d/%m/%Y", "…and four is still the whole year"},
	}
	for c in cases {
		got := platform.date_pattern_to_strftime(c.pattern, .Cldr, context.temp_allocator)
		testing.expectf(t, got == c.want, "%s: %q -> %q, wanted %q", c.why, c.pattern, got, c.want)
	}
}

@(test)
the_windows_rule_is_not_the_cldr_one :: proc(t: ^testing.T) {
	// The one token the two desktops disagree about, pinned from both
	// sides so neither can be "simplified" into the other.
	cldr := platform.date_pattern_to_strftime("dd/MM/y", .Cldr, context.temp_allocator)
	win  := platform.date_pattern_to_strftime("dd/MM/y", .Windows, context.temp_allocator)
	testing.expect_value(t, cldr, "%d/%m/%Y")
	testing.expect_value(t, win, "%d/%m/%y")
}

@(test)
a_cldr_pattern_drops_what_the_parser_cannot_say :: proc(t: ^testing.T) {
	// A short date can still carry a weekday name or an era; the parser
	// has no token for either, so they go along with the separator that
	// was only there to sit beside them, rather than printing as a stray.
	got := platform.date_pattern_to_strftime("EEEE, d MMMM y", .Cldr, context.temp_allocator)
	testing.expect_value(t, got, "%e %B %Y")
	era := platform.date_pattern_to_strftime("G y/MM/dd", .Cldr, context.temp_allocator)
	testing.expect_value(t, era, "%Y/%m/%d")
}

}
