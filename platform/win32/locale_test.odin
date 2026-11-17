#+build windows
package win32

// Runs on Windows: `odin test platform/win32`. The date pattern translation
// is pure and the part most likely to be wrong, so it is checked against the
// short-date patterns Windows ships rather than the machine's own locale.
@(require) import "core:testing"
@(require) import "baldr:platform"

// Behind the `when` like every other test file: the bodies are otherwise
// type-checked by every Windows app that imports the backend (CONTRIBUTING.md).
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
windows_short_date_patterns_become_strftime :: proc(t: ^testing.T) {
	Case :: struct { locale, pattern, want: string }
	// Named with its type: an inline slice of structs inferred through the
	// parameter costs the compiler minutes (CONTRIBUTING.md).
	cases := []Case{
		{"en-GB",  "dd/MM/yyyy",          "%d/%m/%Y"},
		{"en-US",  "M/d/yyyy",            "%m/%e/%Y"},
		{"de-DE",  "dd.MM.yyyy",          "%d.%m.%Y"},
		{"sv-SE",  "yyyy-MM-dd",          "%Y-%m-%d"},
		{"ja-JP",  "yyyy'年'M'月'd'日'",  "%Y年%m月%e日"},
		{"long",   "dddd, d MMMM yyyy",   "%e %B %Y"}, // the weekday name has no token here
		{"medium", "d MMM yyyy",          "%e %b %Y"},
		{"2-digit","yy/MM/dd",            "%y/%m/%d"},
		{"era",    "g yyyy/M/d",          "%Y/%m/%e"}, // the era has no token either
	}
	for c in cases {
		got := platform.date_pattern_to_strftime(c.pattern, .Windows, context.temp_allocator)
		testing.expectf(t, got == c.want, "%s: %q -> %q, wanted %q", c.locale, c.pattern, got, c.want)
	}
}

// Nothing may reach widget_date.odin's parser that it does not know: it
// prints an unknown %X literally, so a stray token would show up in a date.
@(test)
translation_emits_only_tokens_the_parser_knows :: proc(t: ^testing.T) {
	known :: "dembByY%"
	pats := []string{"dddd, MMMM d, yyyy", "g yy'年'MMM ddd d/M/y", "dd-MMM-yy"}
	for p in pats {
		out := platform.date_pattern_to_strftime(p, .Windows, context.temp_allocator)
		for i := 0; i < len(out); i += 1 {
			if out[i] != '%' do continue
			testing.expectf(t, i + 1 < len(out), "%q ends in a bare %%: %q", p, out)
			if i + 1 >= len(out) do break
			found := false
			for k in known do if rune(out[i + 1]) == k do found = true
			testing.expectf(t, found, "%q -> %q has %%%c, which widget_date.odin does not know", p, out, out[i + 1])
			i += 1
		}
	}
}

}
